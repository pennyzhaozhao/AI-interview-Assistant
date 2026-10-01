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
    static let strongQuestionMinimumGap: TimeInterval = 1.5

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
