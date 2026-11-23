import Foundation

enum SpeakerLabel: String, Codable, Sendable {
    case candidate
    case interviewer
    case unknown
}

struct RecognizedUtterance: Sendable {
    let text: String
    let meanVoiceRMS: Float
    let peakVoiceRMS: Float
    let durationSeconds: Double
    let speaker: SpeakerLabel
    let speakerScore: Float?
    let endedAt: Date

    init(
        text: String,
        meanVoiceRMS: Float = 0,
        peakVoiceRMS: Float = 0,
        durationSeconds: Double = 0,
        speaker: SpeakerLabel = .unknown,
        speakerScore: Float? = nil,
        endedAt: Date = .now
    ) {
        self.text = text
        self.meanVoiceRMS = meanVoiceRMS
        self.peakVoiceRMS = peakVoiceRMS
        self.durationSeconds = durationSeconds
        self.speaker = speaker
        self.speakerScore = speakerScore
        self.endedAt = endedAt
    }
}

enum SpeechProtectionPolicy {
    static let answerOverlapThreshold = 0.35
    /// Require a real five-second pause before an unknown speaker can be
    /// treated as a new interviewer question while an answer is on screen.
    static let strongQuestionMinimumGap: TimeInterval = 5.0

    /// Phase-one behavior can be disabled independently while tuning in production.
    static var heuristicsEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferenceKey.speechHeuristicsEnabled) as? Bool ?? true
    }

    static func answerOverlap(_ transcript: String, _ answer: String) -> Double {
        let lhs = tokens(for: transcript)
        let rhs = tokens(for: answer)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        return Double(intersection) / Double(min(lhs.count, rhs.count))
    }

    static func isLikelyAnswerRepetition(
        transcript: String,
        answer: String,
        threshold: Double = answerOverlapThreshold
    ) -> Bool {
        answerOverlap(transcript, answer) >= threshold
    }

    /// A question is considered strong only when its wording looks interrogative
    /// and it starts after a real pause. This prevents an answer sentence that
    /// happens to contain “why/how” from interrupting an active suggestion.
    static func isStrongQuestionSignal(
        _ text: String,
        gapSincePreviousUtterance: TimeInterval,
        minimumGap: TimeInterval = strongQuestionMinimumGap
    ) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, gapSincePreviousUtterance >= minimumGap else { return false }
        if clean.hasSuffix("?") || clean.hasSuffix("？") { return true }

        let lower = clean.lowercased()
        let patterns = [
            "请", "能不能", "介绍一下", "为什么", "怎么", "如何", "说说", "讲讲",
            "what", "how", "why", "tell me", "can you", "could you", "walk me through"
        ]
        let hasChineseModalQuestion = lower.contains("可以") && lower.contains("吗")
        return hasChineseModalQuestion || patterns.contains { lower.contains($0) }
    }

    private static func tokens(for text: String) -> Set<String> {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let containsCJK = normalized.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
        if containsCJK {
            let characters = normalized.filter { !$0.isWhitespace && !$0.isPunctuation }
            guard characters.count >= 2 else { return characters.isEmpty ? [] : [String(characters)] }
            let values = Array(characters)
            return Set((0..<(values.count - 1)).map { String(values[$0...($0 + 1)]) })
        }

        let words = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words)
    }
}

// MARK: - Content-based self-speech filter

/// How aggressively microphone transcripts that read like the candidate's own
/// answer are discarded. This complements voiceprint recognition, which can
/// misclassify the candidate on some microphones or rooms.
enum SpeechContentFilterLevel: String, CaseIterable, Identifiable, Sendable {
    case off
    case relaxed
    case standard
    case strict

    var id: String { rawValue }

    static var current: SpeechContentFilterLevel {
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.speechContentFilterLevel)
        return raw.flatMap(SpeechContentFilterLevel.init(rawValue:)) ?? .standard
    }

    /// Minimum `answerScore - questionScore` required to drop an utterance.
    var dropMargin: Double? {
        switch self {
        case .off: return nil
        case .relaxed: return 3.0
        case .standard: return 2.0
        case .strict: return 1.0
        }
    }

    var title: String {
        switch self {
        case .off: return L.t("Off")
        case .relaxed: return L.t("Relaxed")
        case .standard: return L.t("Standard")
        case .strict: return L.t("Strict")
        }
    }
}

/// Scores whether a transcript reads like an interviewer question or like the
/// candidate answering. Purely local and lexical so it adds no latency.
///
/// The filter is deliberately one-sided: it only drops text with clear
/// answer-style evidence (first-person narration, storytelling connectors,
/// repeating the on-screen suggestion). Neutral fragments such as “你上一个项目”
/// pass through so split interviewer questions can still be merged.
enum UtteranceIntentClassifier {
    struct Assessment: Equatable {
        let questionScore: Double
        let answerScore: Double

        var margin: Double { answerScore - questionScore }
    }

    /// Extra margin required when the voiceprint already labelled the speaker
    /// as the interviewer, so content only overrides it on strong evidence.
    static let interviewerLabelBonus = 1.5

    static func shouldDrop(
        _ text: String,
        currentAnswer: String,
        speaker: SpeakerLabel,
        level: SpeechContentFilterLevel
    ) -> Bool {
        guard var margin = level.dropMargin, speaker != .candidate else { return false }
        if speaker == .interviewer { margin += interviewerLabelBonus }
        return assess(text, currentAnswer: currentAnswer).margin >= margin
    }

    static func assess(_ text: String, currentAnswer: String = "") -> Assessment {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return Assessment(questionScore: 0, answerScore: 0) }
        let lower = clean.lowercased()
        let words = lower.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        let wordSet = Set(words)
        let core = String(lower.filter { !$0.isWhitespace && !$0.isPunctuation })
        let opening = strippingFillers(core)
        let englishOpening = Array(words.drop { englishFillers.contains($0) })

        // Question evidence.
        var question = 0.0
        if clean.hasSuffix("?") || clean.hasSuffix("？") { question += 3 }
        if let last = core.last, "吗呢么".contains(last) { question += 2 }
        question += capped(count(of: chineseInterrogatives, in: lower) * 1.5, max: 3)
        question += capped(count(of: chinesePrompts, in: lower) * 1.5, max: 3)
        if lower.contains("你") || lower.contains("您") { question += 1 }
        if let first = englishOpening.first, englishQuestionOpeners.contains(first) { question += 2 }
        question += capped(count(of: englishPromptPhrases, in: lower) * 1.5, max: 3)
        if wordSet.contains("you") || wordSet.contains("your") || wordSet.contains("yourself") { question += 1 }

        // Answer evidence.
        var answer = 0.0
        let firstPersonCJK = ["我们", "我"]
        if firstPersonCJK.contains(where: { opening.hasPrefix($0) }) { answer += 2 }
        if let first = englishOpening.first, englishFirstPerson.contains(first) { answer += 2 }
        let cjkFirstPersonCount = lower.filter { $0 == "我" }.count
        let englishFirstPersonCount = words.filter { englishFirstPerson.contains($0) }.count
        if cjkFirstPersonCount + englishFirstPersonCount >= 2 { answer += 1 }
        answer += capped(count(of: chineseNarrative, in: lower) * 0.75, max: 3)
        answer += capped(count(of: englishNarrative, in: " \(words.joined(separator: " ")) ") * 0.75, max: 3)
        if answerOpeners.contains(where: { core.hasPrefix($0) || opening.hasPrefix($0) }) { answer += 2 }

        let overlap = SpeechProtectionPolicy.answerOverlap(clean, currentAnswer)
        if overlap >= 0.2 { answer += overlap * 4 }

        let isLong = core.count > 40 || words.count > 25
        if isLong, question < 1.5 { answer += 1 }

        return Assessment(questionScore: question, answerScore: answer)
    }

    // MARK: Lexicons

    private static let chineseInterrogatives = [
        "什么", "为什么", "为啥", "怎么", "怎样", "如何", "哪个", "哪些", "哪里", "哪儿",
        "多少", "多久", "几个", "是否", "是不是", "有没有", "能不能", "会不会", "可不可以",
        "要不要", "请问"
    ]
    private static let chinesePrompts = [
        "介绍一下", "介绍下", "说说", "说一下", "讲讲", "讲一下", "谈谈", "聊聊", "描述一下",
        "举个例子", "举例", "解释一下", "分享一下", "展开讲", "具体说", "问一下", "问你"
    ]
    private static let chineseNarrative = [
        "然后", "当时", "所以", "因为", "首先", "其次", "最后", "主要是", "负责", "实现了",
        "完成了", "带领", "团队", "上线", "优化了", "提升了", "降低了", "项目中", "那时候",
        "基本上", "其实", "用了", "做了", "采用", "我觉得", "我认为", "我的经验"
    ]
    /// Openers a candidate uses when starting to answer.
    private static let answerOpeners = [
        "这个问题", "这是一个好问题", "好问题", "我来回答", "我先说", "我先简单", "我简单介绍",
        "goodquestion", "thatsagoodquestion", "thatsagreatquestion"
    ]
    /// Fillers and connectors skipped before checking how a sentence opens.
    private static let chineseFillers = [
        "嗯", "呃", "额", "啊", "那个", "就是", "对", "好的", "好", "是的", "ok",
        "然后", "所以", "其实", "当时", "那"
    ]

    private static let englishQuestionOpeners: Set<String> = [
        "what", "what's", "why", "how", "when", "where", "which", "who", "whose",
        "can", "could", "would", "will", "do", "does", "did", "are", "is", "have", "has", "should"
    ]
    private static let englishPromptPhrases = [
        "tell me", "walk me through", "describe", "explain", "give me an example",
        "talk about", "share an example", "how would you", "what would you", "can you", "could you"
    ]
    private static let englishFirstPerson: Set<String> = ["i", "i'm", "i've", "i'd", "my", "we", "we're", "we've", "our"]
    private static let englishNarrative = [
        " so ", " then ", " because ", " basically ", " actually ", " i was responsible ",
        " we built ", " i built ", " i led ", " i implemented ", " we implemented ", " in my previous ",
        " at my last ", " my role ", " the result ", " we reduced ", " we improved ", " i think "
    ]
    private static let englishFillers: Set<String> = ["um", "uh", "er", "well", "yeah", "yes", "ok", "okay", "sure", "right", "so"]

    // MARK: Helpers

    private static func count(of needles: [String], in haystack: String) -> Double {
        Double(needles.filter { haystack.contains($0) }.count)
    }

    private static func capped(_ value: Double, max upper: Double) -> Double {
        min(value, upper)
    }

    private static func strippingFillers(_ text: String) -> String {
        var result = Substring(text)
        var changed = true
        while changed {
            changed = false
            for filler in chineseFillers where result.hasPrefix(filler) {
                result = result.dropFirst(filler.count)
                changed = true
            }
        }
        return String(result)
    }
}
