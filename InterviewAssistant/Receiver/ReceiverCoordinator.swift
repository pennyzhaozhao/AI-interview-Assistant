import Foundation
import SwiftData
import Observation
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class ReceiverCoordinator {
    var prompterText = "Waiting for interview question..."
    var aiText = ""
    var statusText = ""
    var aiEnabled = false
    var isStartingAI = false
    var pinned = true
    var autoScrollEnabled = true
    var fontSize: CGFloat = 26
    var lastQuestion = ""
    var lastUpdatedAt: Date?
    var confidence: Double = 0
    var languageCode = "en-US"
    var audioSource: AudioSource = .microphone
    #if os(macOS)
    var screenshotImage: NSImage?
    #endif
    var isAwaitingCodeLanguage = false
    var codeLanguageDraft = "python"
    private var isGeneratingCode = false
    private var pendingCodeRawQuestion = ""
    private var pendingSpeechQuestion = ""
    private var pendingSpeechQuestionTask: Task<Void, Never>?
    private var cachedMockMemory: String?
    private var activeSpeechAnswerTask: Task<Void, Never>?
    private var activeSpeechQuestion = ""
    private var activeSpeechQuestionStartedAt: Date?
    // VAD已等1.2s，完整句子只需短debounce；片段需更长等待保证合并
    private let quickSpeechQuestionDebounceSeconds: TimeInterval = 0.35
    private let unfinishedSpeechQuestionDebounceSeconds: TimeInterval = 1.5
    private let speechContinuationMergeWindow: TimeInterval = 10.0
    var canGeneratePendingCode: Bool { !pendingCodeRawQuestion.isEmpty && !isGeneratingCode }
    var isCodeGenerationRunning: Bool { isGeneratingCode }
    var isSpeechListening: Bool {
        activeOrPreferredASRProvider == .volcano ? volcanoSpeech.isListening : speech.isListening
    }
    var audioLevel: Double {
        activeOrPreferredASRProvider == .volcano ? volcanoSpeech.audioLevel : speech.audioLevel
    }
    var isVoiceDetected: Bool {
        activeOrPreferredASRProvider == .volcano ? volcanoSpeech.isVoiceDetected : speech.isVoiceDetected
    }
    var speechStatusText: String {
        activeOrPreferredASRProvider == .volcano ? volcanoSpeech.statusText : speech.statusText
    }
    var canForceTriggerSpeech: Bool {
        activeOrPreferredASRProvider == .volcano ? volcanoSpeech.canForceTrigger : speech.canForceTrigger
    }

    let speech = SpeechEngine()
    let volcanoSpeech = VolcanoASREngine()
    let tcp = TCPLineConnection()
    var session: InterviewSession?
    var knowledgeBases: [KnowledgeBase] = []
    var modelContext: ModelContext?
    private var activeASRProvider: ASRProvider?
    private var activeOrPreferredASRProvider: ASRProvider {
        activeASRProvider ?? currentASRProvider
    }
    private var currentASRProvider: ASRProvider {
        let stored = UserDefaults.standard.string(forKey: AppPreferenceKey.asrProvider)
            ?? ASRProvider.volcano.rawValue
        return ASRProvider(rawValue: stored) ?? .volcano
    }

    init() {
        speech.onRecognizedText = { [weak self] text in
            Task { @MainActor in
                self?.enqueueSpeechQuestion(text)
            }
        }
        volcanoSpeech.onRecognizedText = { [weak self] text in
            Task { @MainActor in
                self?.enqueueSpeechQuestion(text)
            }
        }
        tcp.onLine = { [weak self] line in
            Task { @MainActor in
                self?.showSenderPrompt(line)
            }
        }
    }

    private func showSenderPrompt(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(macOS)
        screenshotImage = nil
        #endif
        pendingCodeRawQuestion = ""
        isAwaitingCodeLanguage = false
        isGeneratingCode = false
        lastQuestion = "Prompt Sender"
        prompterText = lastQuestion
        aiText = trimmed
        confidence = trimmed.isEmpty ? 0 : 0.62
        lastUpdatedAt = .now
    }

    func start(session: InterviewSession, knowledgeBases: [KnowledgeBase], modelContext: ModelContext, host: String) {
        self.session = session
        self.knowledgeBases = knowledgeBases
        self.modelContext = modelContext
        let appLanguage = AppLanguage.current
        let interviewerLanguage = MockInterviewLanguage(
            rawValue: UserDefaults.standard.string(forKey: AppPreferenceKey.interviewerLanguage) ?? ""
        ) ?? .followApp
        languageCode = interviewerLanguage.speechCode(appLanguage: appLanguage)
        prompterText = "Waiting for interview question..."
        aiText = ""
        statusText = ""
        lastQuestion = ""
        lastUpdatedAt = nil
        confidence = 0
        #if os(macOS)
        screenshotImage = nil
        #endif
        isAwaitingCodeLanguage = false
        isGeneratingCode = false
        pendingCodeRawQuestion = ""
        pendingSpeechQuestion = ""
        pendingSpeechQuestionTask?.cancel()
        pendingSpeechQuestionTask = nil
        activeSpeechAnswerTask?.cancel()
        activeSpeechAnswerTask = nil
        activeSpeechQuestion = ""
        activeSpeechQuestionStartedAt = nil
        // Pre-build mock memory once at session start so AI calls don't hit SwiftData every time
        cachedMockMemory = nil
        cachedMockMemory = buildMockTrainingMemory()
        if host.isEmpty {
            statusText = "Local mode"
        } else {
            tcp.connect(host: host, mode: .receiver)
        }
    }

    func stop() {
        pendingSpeechQuestionTask?.cancel()
        pendingSpeechQuestionTask = nil
        pendingSpeechQuestion = ""
        activeSpeechAnswerTask?.cancel()
        activeSpeechAnswerTask = nil
        activeSpeechQuestion = ""
        activeSpeechQuestionStartedAt = nil
        speech.stop()
        volcanoSpeech.stop()
        activeASRProvider = nil
        tcp.disconnect()
        session?.endedAt = .now
        try? modelContext?.save()
    }

    func toggleAI() async {
        guard !isStartingAI else { return }
        if !aiEnabled {
            isStartingAI = true
            defer { isStartingAI = false }
            aiEnabled = true
            var didStart: Bool
            switch currentASRProvider {
            case .apple:
                volcanoSpeech.stop()
                activeASRProvider = .apple
                didStart = await startAppleSpeech()
            case .volcano:
                speech.stop()
                var config = VolcanoASREngine.builtinConfig(language: effectiveSpeechLanguageCode)
                config.hotWords = extractHotWords(from: session?.context ?? "")
                activeASRProvider = .volcano
                volcanoSpeech.languageCode = effectiveSpeechLanguageCode
                volcanoSpeech.audioSource = audioSource
                volcanoSpeech.updateConfig(config)
                volcanoSpeech.statusText = "正在启动豆包语音识别..."
                didStart = await volcanoSpeech.start()
                if !didStart {
                    let volcanoError = volcanoSpeech.lastErrorText.isEmpty ? volcanoSpeech.statusText : volcanoSpeech.lastErrorText
                    activeASRProvider = .apple
                    speech.languageCode = effectiveSpeechLanguageCode
                    speech.audioSource = audioSource
                    speech.statusText = "豆包语音暂不可用，正在切换 Apple 本地识别..."
                    didStart = await speech.start()
                    if didStart {
                        speech.statusText = "🎙 Apple 本地识别中（豆包语音启动失败：\(volcanoError)）"
                    } else {
                        volcanoSpeech.statusText = volcanoError.isEmpty ? "豆包语音和 Apple 本地识别都未能启动" : volcanoError
                    }
                }
            }
            if !didStart {
                activeASRProvider = nil
                aiEnabled = false
            }
        } else {
            aiEnabled = false
            pendingSpeechQuestionTask?.cancel()
            pendingSpeechQuestionTask = nil
            pendingSpeechQuestion = ""
            activeSpeechAnswerTask?.cancel()
            activeSpeechAnswerTask = nil
            activeSpeechQuestion = ""
            activeSpeechQuestionStartedAt = nil
            speech.stop()
            volcanoSpeech.stop()
            activeASRProvider = nil
        }
    }

    private func startAppleSpeech() async -> Bool {
        speech.languageCode = effectiveSpeechLanguageCode
        speech.audioSource = audioSource
        speech.statusText = "正在启动..."
        return await speech.start()
    }

    private func enqueueSpeechQuestion(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if pendingSpeechQuestion.isEmpty {
            pendingSpeechQuestion = clean
        } else if !pendingSpeechQuestion.localizedCaseInsensitiveContains(clean) {
            pendingSpeechQuestion = "\(pendingSpeechQuestion) \(clean)"
        }
        // Keep the overlay subtitle live while the utterance is still being debounced.
        prompterText = pendingSpeechQuestion
        lastQuestion = pendingSpeechQuestion
        lastUpdatedAt = .now

        pendingSpeechQuestionTask?.cancel()
        pendingSpeechQuestionTask = Task { [weak self] in
            let delaySeconds = await MainActor.run {
                self?.speechQuestionDebounceSeconds(for: self?.pendingSpeechQuestion ?? "") ?? 0.55
            }
            let delay = UInt64(delaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let question = self.pendingSpeechQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                self.pendingSpeechQuestion = ""
                self.pendingSpeechQuestionTask = nil
                guard !question.isEmpty else { return }
                self.submitSpeechQuestion(question)
            }
        }
    }

    private func submitSpeechQuestion(_ question: String) {
        var finalQuestion = question
        if shouldMergeWithActiveSpeechQuestion(question) {
            finalQuestion = mergeSpeechQuestions(activeSpeechQuestion, question)
            activeSpeechAnswerTask?.cancel()
            aiText = "Preparing answer suggestion..."
            confidence = 0.34
            lastUpdatedAt = .now
        }
        activeSpeechQuestion = finalQuestion
        activeSpeechQuestionStartedAt = .now
        activeSpeechAnswerTask = Task { [weak self] in
            await self?.askAI(question: finalQuestion)
            await MainActor.run {
                guard let self, self.activeSpeechQuestion == finalQuestion else { return }
                self.activeSpeechAnswerTask = nil
            }
        }
    }

    private func shouldMergeWithActiveSpeechQuestion(_ newQuestion: String) -> Bool {
        guard let started = activeSpeechQuestionStartedAt,
              !activeSpeechQuestion.isEmpty,
              Date().timeIntervalSince(started) <= speechContinuationMergeWindow else {
            return false
        }
        let clean = newQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if clean.count <= 20 { return true }
        if isContinuationFragment(clean) { return true }
        return isLikelySameQuestion(activeSpeechQuestion, clean)
    }

    private func mergeSpeechQuestions(_ first: String, _ second: String) -> String {
        let lhs = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        if lhs.localizedCaseInsensitiveContains(rhs) { return lhs }
        if rhs.localizedCaseInsensitiveContains(lhs) { return rhs }
        return "\(lhs) \(rhs)"
    }

    private func isContinuationFragment(_ text: String) -> Bool {
        let lower = text.lowercased()
        let prefixes = [
            "在", "做", "是", "到", "从", "对", "怎么", "什么", "哪", "哪个", "哪些", "为什么", "然后", "还有",
            "或者", "而且", "那", "但", "所以", "因为", "如果", "虽然", "其实", "就是", "比如",
            "where", "what", "which", "how", "why", "and", "or", "about", "but", "so", "if"
        ]
        return prefixes.contains { lower.hasPrefix($0) }
    }

    private func isLikelySameQuestion(_ existing: String, _ newQuestion: String) -> Bool {
        let combined = "\(existing) \(newQuestion)"
        let intentKeywords = ["挑战", "困难", "问题", "遇到", "项目", "做", "怎么", "例子", "challenge", "problem", "project", "example"]
        let hitCount = intentKeywords.filter { combined.localizedCaseInsensitiveContains($0) }.count
        return hitCount >= 2 && newQuestion.count < 24
    }

    private func speechQuestionDebounceSeconds(for text: String) -> TimeInterval {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return quickSpeechQuestionDebounceSeconds }

        // Very short fragment — almost certainly mid-sentence
        if clean.count < 15 { return unfinishedSpeechQuestionDebounceSeconds }

        // Sentence ends with punctuation — treat as complete
        let sentenceEnders: Set<Character> = ["。", "？", "！", "?", "!"]
        if let last = clean.last, sentenceEnders.contains(last) {
            return quickSpeechQuestionDebounceSeconds
        }

        // Ends with connector words — definitely incomplete
        let unfinishedSuffixes = [
            "或", "或者", "和", "以及", "跟", "与", "比如", "例如", "关于", "就是",
            "or", "and", "with", "about", "such as", "for example"
        ]
        let lower = clean.lowercased()
        if unfinishedSuffixes.contains(where: { lower.hasSuffix($0) }) {
            return unfinishedSpeechQuestionDebounceSeconds
        }
        if clean.hasSuffix("，") || clean.hasSuffix(",") || clean.hasSuffix("、") {
            return unfinishedSpeechQuestionDebounceSeconds
        }

        // Ambiguous — use a middle delay
        return (quickSpeechQuestionDebounceSeconds + unfinishedSpeechQuestionDebounceSeconds) / 2
    }

    func toggleLanguage() {
        switch languageCode {
        case "en-US":
            languageCode = "zh-CN"
        case "zh-CN":
            languageCode = "auto"
        default:
            languageCode = "en-US"
        }
        speech.languageCode = effectiveSpeechLanguageCode
        volcanoSpeech.languageCode = effectiveSpeechLanguageCode
    }

    func toggleAudioSource() {
        audioSource = audioSource == .microphone ? .system : .microphone
        speech.audioSource = audioSource
        volcanoSpeech.audioSource = audioSource
    }

    func setAudioSource(_ source: AudioSource) {
        audioSource = source
        speech.audioSource = source
        volcanoSpeech.audioSource = source
    }

    func forceTriggerSpeech() {
        switch activeOrPreferredASRProvider {
        case .apple:
            speech.forceTrigger()
        case .volcano:
            volcanoSpeech.forceTrigger()
        }
    }

    func askAI(question: String) async {
        #if os(macOS)
        screenshotImage = nil
        #endif
        if !Task.isCancelled {
            pendingSpeechQuestionTask?.cancel()
            pendingSpeechQuestionTask = nil
            pendingSpeechQuestion = ""
        }
        await askAI(question: question, displayQuestion: nil, historyQuestion: nil, requiresListeningAI: true)
    }

    #if os(macOS)
    func showScreenshotImage(_ image: NSImage, status: String) {
        screenshotImage = image
        lastQuestion = status
        prompterText = status
        aiText = ""
        confidence = 0.12
        lastUpdatedAt = .now
    }
    #endif

    func askScreenshotQuestion(rawText: String) async {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let answerLanguageCode = configuredAnswerLanguageCode
        let screenshotData = currentScreenshotPNGData()
        pendingCodeRawQuestion = trimmed
        isAwaitingCodeLanguage = false
        isGeneratingCode = false
        let selectedCodeLanguage = codeLanguageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "python"
            : codeLanguageDraft
        let prompt = KnowledgeContextBuilder.buildQuestionPrompt(
            rawText: trimmed,
            answerLanguage: answerLanguageCode,
            codeLanguage: selectedCodeLanguage
        )
        var systemPrompt = KnowledgeContextBuilder.buildStructuredTechnicalSystemPrompt(
            context: session?.context ?? "",
            knowledgeBases: knowledgeBases,
            activeIDs: session?.activeKBIds ?? []
        )
        let mockMemory = buildMockTrainingMemory()
        if !mockMemory.isEmpty {
            systemPrompt += """

            Candidate mock interview memory:
            \(mockMemory)

            Prefer the candidate's practiced examples, wording style, and revised answers when relevant.
            """
        }
        await askAI(
            question: prompt,
            displayQuestion: String(trimmed.prefix(240)),
            historyQuestion: "[截图] \(String(trimmed.prefix(300)))",
            requiresListeningAI: false,
            systemPromptOverride: systemPrompt,
            isApproachForPendingCode: false,
            maxTokens: 1800,
            turnConfigurator: { turn in
                turn.screenshotData = screenshotData
                turn.category = "Screenshot OCR"
            }
        )
    }

    func generatePendingCode(language: String) async {
        guard !pendingCodeRawQuestion.isEmpty, let session, let modelContext else { return }
        let selectedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "python" : language.trimmingCharacters(in: .whitespacesAndNewlines)
        codeLanguageDraft = selectedLanguage
        isAwaitingCodeLanguage = false
        isGeneratingCode = true
        let existingAnswer = aiText.trimmingCharacters(in: .whitespacesAndNewlines)
        aiText = "\(existingAnswer)\n\n代码生成中..."
        let systemPrompt = KnowledgeContextBuilder.buildStructuredTechnicalSystemPrompt(
            context: session.context,
            knowledgeBases: knowledgeBases,
            activeIDs: session.activeKBIds
        )
        let codePrompt = KnowledgeContextBuilder.buildAlgorithmCodePrompt(rawText: pendingCodeRawQuestion, language: selectedLanguage)
        var streamingCode = ""
        var lastUIUpdate = Date.distantPast
        do {
            try await AIService.streamResponse(
                config: AIService.config(from: modelContext),
                systemPrompt: systemPrompt,
                question: codePrompt,
                maxTokens: 1600,
                onToken: { token in
                    streamingCode += token
                    let now = Date()
                    if now.timeIntervalSince(lastUIUpdate) >= 0.06 {
                        self.aiText = self.combinedAnswer(existing: existingAnswer, code: streamingCode, language: selectedLanguage)
                        self.confidence = self.estimatedConfidence(for: self.aiText)
                        self.lastUpdatedAt = now
                        lastUIUpdate = now
                    }
                },
                onComplete: { fullText in
                    self.aiText = self.combinedAnswer(existing: existingAnswer, code: fullText, language: selectedLanguage)
                    self.confidence = self.estimatedConfidence(for: self.aiText)
                    self.lastUpdatedAt = .now
                    let turn = ConversationTurn(question: "[代码] \(String(self.pendingCodeRawQuestion.prefix(200)))", answer: self.aiText, session: session)
                    session.turns.append(turn)
                    modelContext.insert(turn)
                    try? modelContext.save()
                    self.pendingCodeRawQuestion = ""
                    self.isGeneratingCode = false
                }
            )
        } catch {
            aiText = "\(existingAnswer)\n\n代码生成失败，请换一种语言或重试。"
            confidence = 0.18
            isGeneratingCode = false
        }
    }

    private func askAI(
        question: String,
        displayQuestion: String?,
        historyQuestion: String?,
        requiresListeningAI: Bool,
        systemPromptOverride: String? = nil,
        isApproachForPendingCode: Bool = false,
        maxTokens: Int = 500,
        onProgress: ((String) -> Void)? = nil,
        onComplete: (() -> Void)? = nil,
        turnConfigurator: ((ConversationTurn) -> Void)? = nil
    ) async {
        guard !Task.isCancelled else { return }
        guard (!requiresListeningAI || aiEnabled), let session, let modelContext else { return }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else { return }
        let visibleQuestion = displayQuestion ?? cleanQuestion
        lastQuestion = visibleQuestion
        prompterText = visibleQuestion
        aiText = "Preparing answer suggestion..."
        confidence = 0.34
        lastUpdatedAt = .now
        do {
            var prompt = systemPromptOverride ?? enrichedSystemPrompt(for: session)
            let answerLanguageCode = configuredAnswerLanguageCode
            prompt += answerLanguageCode == "zh-CN"
                ? "\n\nOUTPUT LANGUAGE (MANDATORY): Use Simplified Chinese for the entire answer. The captured question may be in English, but the answer must still be Chinese."
                : "\n\nOUTPUT LANGUAGE (MANDATORY): Use English for the entire answer."
            if systemPromptOverride == nil {
                let reference = commonQuestionReference(for: cleanQuestion)
                if !reference.isEmpty {
                    prompt += """

                    Local common interview answer reference:
                    \(reference)

                    Use this reference only as background guidance. Adapt the answer to the actual live question, the candidate profile, the active knowledge base, and mock interview memory. Do not copy a template mechanically.
                    """
                }
            }
            var streamingAnswer = ""
            var lastUIUpdate = Date.distantPast
            let uiUpdateInterval: TimeInterval = 0.025
            try await AIService.streamResponse(
                config: AIService.config(from: modelContext),
                systemPrompt: prompt,
                question: cleanQuestion,
                maxTokens: maxTokens,
                onToken: { token in
                    if isApproachForPendingCode && self.isGeneratingCode { return }
                    streamingAnswer += token
                    let now = Date()
                    if now.timeIntervalSince(lastUIUpdate) >= uiUpdateInterval {
                        let displayAnswer = self.displayableAnswer(from: streamingAnswer)
                        if !displayAnswer.isEmpty {
                            self.aiText = displayAnswer
                            self.confidence = self.estimatedConfidence(for: displayAnswer)
                            self.lastUpdatedAt = now
                            lastUIUpdate = now
                            onProgress?(displayAnswer)
                        }
                    }
                },
                onComplete: { fullText in
                    if isApproachForPendingCode && self.isGeneratingCode { return }
                    let answer = self.displayableAnswer(from: fullText)
                    let turn = ConversationTurn(question: historyQuestion ?? visibleQuestion, answer: answer, session: session)
                    turnConfigurator?(turn)
                    session.turns.append(turn)
                    modelContext.insert(turn)
                    try? modelContext.save()
                    self.aiText = answer
                    self.confidence = self.estimatedConfidence(for: answer)
                    self.lastUpdatedAt = .now
                    onProgress?(answer)
                    onComplete?()
                }
            )
        } catch {
            if Task.isCancelled { return }
            aiText = configuredAnswerLanguageCode == "zh-CN"
                ? "暂时无法生成建议。请稍后重试，或重新截取更清晰的题目区域。"
                : "I could not generate a suggestion yet. Please try again or capture a clearer question area."
            confidence = 0.18
            lastUpdatedAt = .now
        }
    }

    private var configuredAnswerLanguageCode: String {
        let appLanguage = AppLanguage.current
        let configuredLanguage = MockInterviewLanguage(
            rawValue: UserDefaults.standard.string(forKey: AppPreferenceKey.interviewerLanguage) ?? ""
        ) ?? .followApp
        return configuredLanguage.speechCode(appLanguage: appLanguage)
    }

    private func enrichedSystemPrompt(for session: InterviewSession) -> String {
        let basePrompt = KnowledgeContextBuilder.buildSystemPrompt(
            context: session.context,
            knowledgeBases: knowledgeBases,
            activeIDs: session.activeKBIds,
            recentTurns: session.turns
        )
        let mockMemory = buildMockTrainingMemory()
        guard !mockMemory.isEmpty else { return basePrompt }
        return """
        \(basePrompt)

        Candidate mock interview memory:
        \(mockMemory)

        When answering in a formal interview, prefer the candidate's practiced examples, wording style, and revised answers from mock interviews. Avoid inventing experience that is not supported by the memory or knowledge base.
        """
    }

    private func commonQuestionReference(for question: String) -> String {
        let lower = question.lowercased()
        var blocks: [String] = []

        func add(_ title: String, _ body: String) {
            blocks.append("\(title): \(body)")
        }

        if question.contains("自我介绍") || lower.contains("tell me about yourself") {
            add("Self introduction", "Use a natural first-person answer. Start with the candidate's real background, then mention one or two strongest projects, and close with why that experience fits the current role. Avoid meta phrases like 'I will answer in three parts'.")
        }
        if question.contains("挑战") || question.contains("困难") || lower.contains("challenge") {
            add("Project challenge", "Pick one concrete project obstacle. Explain the constraint, what the candidate personally did, how they aligned people or changed the approach, and the measurable or observable result.")
        }
        if question.contains("怎么做") || question.contains("如何") || lower.contains("how did") || lower.contains("how would") {
            add("How it was done", "Answer from the actual action path: situation, key decision, tradeoff, execution detail, result. Keep it spoken and direct, with one vivid detail from the project.")
        }
        if question.contains("为什么") || lower.contains("why") {
            add("Why question", "Give the real reason first, then support it with a project example or personal pattern. Connect the reason to the role, company, or interviewer's concern.")
        }
        if question.contains("例子") || lower.contains("example") || lower.contains("tell me about a time") {
            add("Example question", "Use a specific story with context, the candidate's action, and a result. Do not stay abstract; include one concrete number, user behavior, technical constraint, or stakeholder detail when available.")
        }
        if question.contains("优势") || question.contains("长处") || lower.contains("strength") {
            add("Strengths", "Name one strength and immediately prove it with project evidence. The answer should sound grounded, not self-promotional.")
        }
        if question.contains("缺点") || question.contains("不足") || lower.contains("weakness") {
            add("Weakness", "Use a controlled weakness that is real but not fatal for the role. Show the concrete system the candidate uses to improve it.")
        }
        if question.contains("冲突") || question.contains("合作") || question.contains("团队") || lower.contains("conflict") || lower.contains("team") {
            add("Teamwork", "Describe how the candidate clarified goals, made tradeoffs explicit, communicated with stakeholders, and protected the project outcome.")
        }
        if question.contains("结果") || question.contains("效果") || lower.contains("impact") || lower.contains("result") {
            add("Impact", "Use before-and-after contrast. Mention metrics when supported, but do not invent numbers. If exact metrics are unavailable, describe observable improvement.")
        }
        if blocks.isEmpty {
            add("General answer style", "Answer directly in first person. Prefer one real project over broad claims. Keep the first sentence useful by itself, then add context, action, and result.")
            add("Follow-up handling", "If the question is a fragment, infer the likely intent from recent conversation and answer the more complete interview question, not just the last short phrase.")
        }
        return blocks.prefix(4).joined(separator: "\n")
    }

    private func buildMockTrainingMemory() -> String {
        if let cached = cachedMockMemory { return cached }
        guard let modelContext else { return "" }
        let descriptor = FetchDescriptor<InterviewSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        let sessions = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { $0.kind == .mock }
            .prefix(2)
        var blocks: [String] = []
        for session in sessions {
            let turns = session.turns.sorted { $0.createdAt < $1.createdAt }.prefix(3)
            let turnText = turns.map { turn in
                """
                Q: \(turn.question)
                A: \(turn.answer.prefix(500))
                Feedback: \(turn.feedback.prefix(200))
                Suggested: \(turn.suggestedAnswer.prefix(300))
                """
            }.joined(separator: "\n\n")
            let block = """
            Mock session: \(session.title)
            Feedback: \(session.summaryFeedback.prefix(200))
            Strengths: \(session.strengthsText.prefix(150))
            Improvements: \(session.improvementsText.prefix(150))
            \(turnText)
            """
            blocks.append(block)
        }
        let result = blocks.joined(separator: "\n\n---\n\n")
        cachedMockMemory = result
        return result
    }

    #if os(macOS)
    private func currentScreenshotPNGData() -> Data? {
        guard let image = screenshotImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    #else
    private func currentScreenshotPNGData() -> Data? { nil }
    #endif

    private func combinedAnswer(existing: String, code: String, language: String) -> String {
        let trimmedCode = code
            .replacingOccurrences(of: "```\(language)", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(existing)\n\n代码:\n```\(language)\n\(trimmedCode)\n```"
    }

    private func estimatedConfidence(for answer: String) -> Double {
        let wordCount = answer.split { $0.isWhitespace || $0.isNewline }.count
        if wordCount > 90 { return 0.88 }
        if wordCount > 45 { return 0.76 }
        if wordCount > 18 { return 0.62 }
        return 0.42
    }

    private func displayableAnswer(from rawText: String) -> String {
        var text = rawText
            .replacingOccurrences(of: "💡", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Accept the delimiter format used by older prompts/providers and
        // normalize it to fenced markdown so AnswerRenderer always creates an
        // embedded, independently scrolling code block.
        if text.contains("<<<CODE_START>>>") {
            let language = codeLanguageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "python"
                : codeLanguageDraft
            text = text
                .replacingOccurrences(of: "<<<CODE_START>>>", with: "```\(language)")
                .replacingOccurrences(of: "<<<CODE_END>>>", with: "```")
        }

        let unwantedPrefixes = [
            "我们开始面试。",
            "我们开始回答面试问题。",
            "面试官让我",
            "我需要",
            "需要以自然口语方式",
            "注意角色：",
            "根据背景，",
            "I need to",
            "The interviewer asks",
            "I should"
        ]

        var didTrim = true
        while didTrim {
            didTrim = false
            for prefix in unwantedPrefixes where text.hasPrefix(prefix) {
                if let sentenceEnd = text.firstIndex(where: { "。.!?\n".contains($0) }) {
                    text = String(text[text.index(after: sentenceEnd)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    didTrim = true
                }
            }
        }
        return text
    }

    private var effectiveSpeechLanguageCode: String {
        languageCode == "auto" ? "en-US" : languageCode
    }

    // MARK: - ASR Hot Words

    private func extractHotWords(from context: String) -> [String] {
        var words = Set<String>(baseHotWords)
        guard !context.isEmpty else { return Array(words) }
        // CamelCase / PascalCase / ALL-CAPS English tokens (tech terms, product names, acronyms)
        if let pattern = try? NSRegularExpression(pattern: #"\b([A-Z][a-zA-Z0-9+#.]{1,19}|[A-Z]{2,9})\b"#) {
            let range = NSRange(context.startIndex..., in: context)
            pattern.enumerateMatches(in: context, range: range) { match, _, _ in
                if let r = match.flatMap({ Range($0.range, in: context) }) {
                    words.insert(String(context[r]))
                }
            }
        }
        // Chinese sequences of 3–6 characters (company names, role titles, product names)
        if let pattern = try? NSRegularExpression(pattern: "[\\u4e00-\\u9fff]{3,6}") {
            let range = NSRange(context.startIndex..., in: context)
            pattern.enumerateMatches(in: context, range: range) { match, _, _ in
                if let r = match.flatMap({ Range($0.range, in: context) }) {
                    words.insert(String(context[r]))
                }
            }
        }
        return Array(words.prefix(90))
    }

    private let baseHotWords: [String] = [
        // 通用技术
        "React", "TypeScript", "JavaScript", "Python", "Swift", "Kotlin", "Java", "Go",
        "Node", "Vue", "Flutter", "Figma", "Sketch", "API", "iOS", "Android", "SQL", "Git",
        // 设计/产品
        "UX", "UI", "PRD", "MVP", "OKR", "KPI", "Agile", "Scrum", "STAR", "A/B",
        // 中文通用
        "设计系统", "用户体验", "产品思维", "数据分析", "组件库", "交互设计",
        "前端开发", "后端开发", "全栈开发", "产品经理", "需求分析"
    ]
}
