import SwiftUI
import SwiftData

struct MockInterviewLaunchConfig: Identifiable {
    let id = UUID()
    var role: String
    var jobDescription: String
    var activeKBIds: Set<UUID>
    var language: MockInterviewLanguage = .followApp
    var questionCount: Int = 6
}

struct MockInterviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \KnowledgeBase.updatedAt, order: .reverse) private var knowledgeBases: [KnowledgeBase]
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue

    @State private var role = ""
    @State private var jobDescription = ""
    @State private var selectedKBIds = Set<UUID>()
    @State private var interviewLanguage: MockInterviewLanguage = .followApp
    @State private var questionCount = 6
    @State private var session: InterviewSession?
    @State private var questions: [MockQuestionDraft] = []
    @State private var currentIndex = 0
    @State private var answerDraft = ""
    @State private var isGeneratingQuestions = false
    @State private var isEvaluating = false
    @State private var evaluationRingProgress: CGFloat = 0
    @State private var errorMessage = ""
    @State private var speech = SpeechEngine()
    @FocusState private var answerFocused: Bool
    private let config: MockInterviewLaunchConfig?
    private let onEnd: () -> Void

    init(config: MockInterviewLaunchConfig? = nil, onEnd: @escaping () -> Void = {}) {
        self.config = config
        self.onEnd = onEnd
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var currentLanguage: AppLanguage { AppLanguage(rawValue: language) ?? .english }
    private var isInterviewing: Bool { session != nil && !questions.isEmpty && currentIndex < questions.count }
    private var progress: Double { questions.isEmpty ? 0 : Double(currentIndex) / Double(questions.count) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if isEvaluating {
                    evaluationLoadingPanel
                } else if isInterviewing {
                    interviewPanel
                } else if let session, !session.summaryFeedback.isEmpty {
                    completionPanel(session)
                } else if !errorMessage.isEmpty {
                    errorPanel
                } else if isGeneratingQuestions {
                    loadingPanel
                } else {
                    emptyLaunchPanel
                }
            }
            .padding(isCompact ? 16 : 32)
            .padding(.bottom, isCompact ? 120 : 40)
            .frame(maxWidth: 1180, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(mockPageBackground)
        .onAppear {
            if let config {
                role = config.role
                jobDescription = config.jobDescription
                selectedKBIds = config.activeKBIds
                interviewLanguage = config.language
                questionCount = config.questionCount
            } else {
                role = modelContext.setting("last_role")
                jobDescription = modelContext.setting("last_job_description")
                selectedKBIds = Set(knowledgeBases.prefix(2).map(\.id))
                interviewLanguage = .followApp
            }
            speech.onRecognizedText = { text in
                Task { @MainActor in
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    answerDraft = answerDraft.isEmpty ? clean : "\(answerDraft)\n\(clean)"
                }
            }
            if config != nil, session == nil, questions.isEmpty, !isGeneratingQuestions {
                Task { await startMockInterview() }
            }
        }
        .onDisappear {
            speech.stop()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Spacer()
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.appPrimary)
                        .frame(width: 52, height: 52)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("Mock Interview"))
                        .font(isCompact ? .appTitleCompact : .appTitle)
                    Text(L.t("Answer with your own voice. AI asks, records, and evaluates after the interview."))
                        .font(.appBody)
                        .foregroundStyle(Color.appMuted)
                }
            }
            Spacer()
            endInterviewButton
        }
    }

    private var endInterviewButton: some View {
        Button {
            endInterview()
        } label: {
            Label(L.t("End Interview"), systemImage: "xmark")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(AppButtonStyle())
    }

    private var loadingPanel: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(L.t("Generating..."))
                .font(.appSection)
            Text(L.t("Generating mock interview questions from your role, JD, and selected knowledge bases."))
                .font(.appBody)
                .foregroundStyle(Color.appMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .premiumCard()
    }

    private var emptyLaunchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("Start Mock Interview from Home"))
                .font(.appSection)
            Text(L.t("Fill in the role, job description, model, and knowledge bases on the Home page, then click Mock Interview."))
                .font(.appBody)
                .foregroundStyle(Color.appMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private var errorPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L.t("Mock Interview Failed"), systemImage: "exclamationmark.triangle.fill")
                .font(.appSection)
                .foregroundStyle(Color.appDanger)
            Text(errorMessage)
                .font(.appBody)
                .foregroundStyle(Color.appText)
                .textSelection(.enabled)
            HStack {
                Button {
                    Task { await startMockInterview() }
                } label: {
                    Label(L.t("Retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(AppButtonStyle(prominent: true))
                Button(L.t("End Interview")) {
                    endInterview()
                }
                .buttonStyle(AppButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private var evaluationLoadingPanel: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.appPrimary.opacity(0.16), lineWidth: 12)
                    .frame(width: 118, height: 118)
                Circle()
                    .trim(from: 0, to: evaluationRingProgress)
                    .stroke(
                        Color.appPrimary,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 118, height: 118)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.appPrimary)
            }
            Text(L.t("Generating Interview Evaluation"))
                .font(.appSection)
            Text(L.t("AI is reviewing your answers, scoring each question, and preparing improvement suggestions."))
                .font(.appBody)
                .foregroundStyle(Color.appMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .premiumCard()
        .onAppear {
            evaluationRingProgress = 0
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                evaluationRingProgress = 1
            }
        }
        .onDisappear {
            evaluationRingProgress = 0
        }
    }

    private var interviewPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            progressCard
            questionCard
            answerComposer
        }
        .frame(maxWidth: 980, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(L.t("Question")) \(currentIndex + 1) / \(questions.count)")
                    .font(.appBodyMedium)
                Spacer()
                Text("\(Int((Double(currentIndex + 1) / Double(max(questions.count, 1))) * 100))%")
                    .font(.appCaptionMedium)
                    .foregroundStyle(Color.appMuted)
            }
            ProgressView(value: min(1, progress + (questions.isEmpty ? 0 : 1 / Double(questions.count))))
                .tint(Color.appPrimary)
        }
        .premiumCard(padding: 18)
    }

    private var questionCard: some View {
        let question = questions[currentIndex]
        return HStack(alignment: .top, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.appPrimary)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(L.t("Interviewer"))
                        .font(.appBodyMedium)
                    if !question.category.isEmpty {
                        StatusPill(text: question.category, tint: .appPrimary)
                    }
                }
                Text(question.question)
                    .font(.system(size: isCompact ? 22 : 24, weight: .semibold))
                    .lineSpacing(5)
                    .foregroundStyle(Color.appText)
                    .textSelection(.enabled)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "#EEF3FA"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private var answerComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    Task { await toggleRecording() }
                } label: {
                    Label(speech.isListening ? L.t("Stop Recording") : L.t("Start Recording"), systemImage: speech.isListening ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(AppButtonStyle(prominent: speech.isListening))

                Button(L.t("Clear")) {
                    answerFocused = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        answerDraft = ""
                    }
                }
                .buttonStyle(AppButtonStyle())

                Spacer()
                Text(speech.statusText)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
            }

            TextEditor(text: $answerDraft)
                .scrollContentBackground(.hidden)
                .focused($answerFocused)
                .frame(minHeight: 180)
                .darkField()

            HStack {
                Text(L.t("Edit the transcript before submitting. No AI help is shown during mock interviews."))
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                Spacer()
                Button {
                    submitCurrentAnswer()
                } label: {
                    Label(currentIndex == questions.count - 1 ? L.t("Submit Interview") : L.t("Submit Answer"), systemImage: "paperplane.fill")
                }
                .buttonStyle(AppButtonStyle(prominent: true))
                .disabled(answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEvaluating)
            }
        }
        .premiumCard()
    }

    private func completionPanel(_ session: InterviewSession) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            evaluationHero(session)
            feedbackBlock(title: L.t("Strengths"), text: session.strengthsText, tint: .appGreen, icon: "checkmark.circle")
            feedbackBlock(title: L.t("Improvement Suggestions"), text: session.improvementsText, tint: .appYellow, icon: "exclamationmark.circle")
            mockQuestionReview(session)
            Button {
                reset()
            } label: {
                Label(L.t("Start Another Mock Interview"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(AppButtonStyle(prominent: true))
        }
        .premiumCard()
    }

    private func evaluationHero(_ session: InterviewSession) -> some View {
        VStack(spacing: 16) {
            scoreBadge(session.overallScore)
            Text(L.t("Interview Evaluation"))
                .font(.appSection)
                .foregroundStyle(Color.white)
            Text(session.summaryFeedback.isEmpty ? L.t("No feedback yet.") : session.summaryFeedback)
                .font(.appBody)
                .lineSpacing(5)
                .foregroundStyle(Color.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 28)
        .background(
            LinearGradient(
                colors: [Color(hex: "#9333EA"), Color(hex: "#4F46E5")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func feedbackBlock(title: String, text: String, tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.appBodyMedium)
                .foregroundStyle(tint)
            Text(text.isEmpty ? L.t("No feedback yet.") : text)
                .font(.appBody)
                .lineSpacing(5)
                .foregroundStyle(Color.appText)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.appField)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func mockQuestionReview(_ session: InterviewSession) -> some View {
        let turns = session.turns.sorted { $0.createdAt < $1.createdAt }
        return VStack(alignment: .leading, spacing: 12) {
            Label(L.t("Question Review Details"), systemImage: "bubble.left.and.text.bubble.right")
                .font(.appBodyMedium)
                .foregroundStyle(Color.appPrimary)
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        StatusPill(text: "\(index + 1)", tint: .appPrimary)
                        if !turn.category.isEmpty {
                            StatusPill(text: turn.category, tint: .appPrimary)
                        }
                        if turn.score > 0 {
                            StatusPill(text: "\(turn.score) \(L.t("Score"))", tint: .appGreen)
                        }
                    }
                    Text(turn.question)
                        .font(.appBodyMedium)
                        .foregroundStyle(Color.appText)
                    reviewSubBlock(L.t("Your Answer"), text: turn.answer)
                    if !turn.feedback.isEmpty {
                        reviewSubBlock(L.t("AI Deep Feedback"), text: turn.feedback)
                    }
                    if !turn.suggestedAnswer.isEmpty {
                        reviewSubBlock(L.t("Suggested Answer"), text: turn.suggestedAnswer)
                    }
                }
                .padding(14)
                .background(Color.appField)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func reviewSubBlock(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.appCaptionMedium)
                .foregroundStyle(Color.appMuted)
            Text(text)
                .font(.appBody)
                .lineSpacing(4)
                .foregroundStyle(Color.appText)
                .textSelection(.enabled)
        }
    }

    private func scoreBadge(_ score: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(score)")
                .font(.system(size: 34, weight: .bold))
            Text(L.t("Score"))
                .font(.appSmall)
                .foregroundStyle(Color.white.opacity(0.82))
        }
        .frame(width: 84, height: 84)
        .background(Color.white.opacity(0.16))
        .foregroundStyle(Color.white)
        .clipShape(Circle())
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.appCaptionMedium)
                .foregroundStyle(Color.appMuted)
            content()
        }
    }

    @MainActor
    private func startMockInterview() async {
        guard !isGeneratingQuestions else { return }
        isGeneratingQuestions = true
        errorMessage = ""
        defer { isGeneratingQuestions = false }

        let cleanRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanJD = jobDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = buildContext(role: cleanRole, jobDescription: cleanJD)
        let newSession = InterviewSession(
            title: cleanRole.isEmpty ? L.t("Mock Interview") : "\(L.t("Mock Interview")) - \(cleanRole)",
            role: cleanRole,
            context: context,
            activeKBIds: Array(selectedKBIds),
            kind: .mock
        )
        modelContext.insert(newSession)
        do {
            let generated = try await generateQuestions(role: cleanRole, jobDescription: cleanJD, context: context)
            questions = generated.isEmpty ? fallbackQuestions(role: cleanRole) : generated
            session = newSession
            currentIndex = 0
            answerDraft = ""
            modelContext.setSetting("last_role", value: role)
            modelContext.setSetting("last_job_description", value: jobDescription)
            try modelContext.save()
        } catch {
            modelContext.delete(newSession)
            try? modelContext.save()
            session = nil
            questions = []
            currentIndex = 0
            errorMessage = error.localizedDescription
        }
    }

    private func toggleRecording() async {
        if speech.isListening {
            speech.forceTrigger()
            speech.stop()
        } else {
            speech.languageCode = interviewLanguage.speechCode(appLanguage: currentLanguage)
            speech.audioSource = .microphone
            _ = await speech.start()
        }
    }

    private func submitCurrentAnswer() {
        guard let session else { return }
        answerFocused = false
        speech.forceTrigger()
        speech.stop()
        let clean = answerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let current = questions[currentIndex]
        let turn = ConversationTurn(question: current.question, answer: clean, category: current.category, session: session)
        session.turns.append(turn)
        session.updatedAt = .now
        try? modelContext.save()
        if currentIndex < questions.count - 1 {
            currentIndex += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                answerDraft = ""
            }
        } else {
            isEvaluating = true
            Task { await finishInterview() }
        }
    }

    @MainActor
    private func finishInterview() async {
        guard let session else { return }
        defer { isEvaluating = false }
        do {
            try await evaluate(session)
            session.endedAt = .now
            session.updatedAt = .now
            try modelContext.save()
        } catch {
            session.summaryFeedback = error.localizedDescription
            session.endedAt = .now
            session.updatedAt = .now
            try? modelContext.save()
        }
        currentIndex = questions.count
    }

    private func reset() {
        session = nil
        questions = []
        currentIndex = 0
        answerDraft = ""
        errorMessage = ""
    }

    private func endInterview() {
        speech.stop()
        onEnd()
    }

    private var mockPageBackground: some View {
        ZStack {
            Color(hex: "#F3F6FC").ignoresSafeArea()
            RadialGradient(
                colors: [Color.appPrimary.opacity(0.08), Color.clear],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )
            .ignoresSafeArea()
        }
    }

    private func buildContext(role: String, jobDescription: String) -> String {
        let kbText = knowledgeBases
            .filter { selectedKBIds.contains($0.id) }
            .flatMap(\.entries)
            .filter(\.isEnabled)
            .map { "【\($0.title)】\n\($0.content)" }
            .joined(separator: "\n\n")
        return """
        Target role: \(role)

        Job description:
        \(jobDescription)

        Candidate knowledge base:
        \(kbText)
        """
    }

    private func generateQuestions(role: String, jobDescription: String, context: String) async throws -> [MockQuestionDraft] {
        let outputLanguage = interviewLanguage.instruction(appLanguage: currentLanguage)
        let prompt = """
        Generate \(questionCount) realistic interview questions for a mock interview.
        Role: \(role)
        Job description: \(jobDescription)
        Interviewer language: \(outputLanguage)

        Use the candidate knowledge base to ask personal, project-specific questions. Include behavioral, project deep-dive, and role-specific questions.
        All category and question values must be written in \(outputLanguage).
        Return strict JSON only:
        {"questions":[{"category":"Project Deep Dive","question":"..."}]}

        Context:
        \(context)
        """
        let text = try await AIService.callAIModel(
            config: AIService.config(from: modelContext),
            systemPrompt: "You are a realistic interviewer. Return valid JSON only. Write all content in \(outputLanguage).",
            question: prompt,
            maxTokens: 1600
        )
        return decodeQuestions(text)
    }

    private func evaluate(_ session: InterviewSession) async throws {
        let outputLanguage = interviewLanguage.instruction(appLanguage: currentLanguage)
        let qa = session.turns.sorted { $0.createdAt < $1.createdAt }.enumerated().map { index, turn in
            """
            Q\(index + 1) [\(turn.category)] \(turn.question)
            Answer: \(turn.answer)
            """
        }.joined(separator: "\n\n")
        let prompt = """
        Evaluate this mock interview for role "\(session.role)".
        Evaluation language: \(outputLanguage)
        Give polished, professional, specific coaching like a senior interviewer. Do not be vague. Every strength and improvement must cite evidence from the candidate's answers or explain what was missing.
        For each question:
        - feedback must evaluate the user's actual answer: what was strong, what was missing, why it matters, and one concrete next action.
        - suggestedAnswer must be a rewritten model answer in first person, customized to the user's answer, role, JD, and context.
        - feedback and suggestedAnswer must NOT be the same text.
        - If the user's answer is short, explicitly say which details are missing and produce a stronger sample answer with plausible structure, not a generic template.
        Return strict JSON only:
        {
          "overallScore": 76,
          "summary": "A concise 120-180 word overall evaluation with role fit, answer structure, evidence quality, and readiness.",
          "strengths": ["Specific observed strength with evidence", "Specific observed strength with evidence", "Specific observed strength with evidence"],
          "improvements": ["Concrete improvement with next action", "Concrete improvement with next action", "Concrete improvement with next action"],
          "questions": [
            {"index":1,"score":88,"feedback":"Specific critique of this answer only. Mention evidence and missing details.","suggestedAnswer":"First-person polished answer that the candidate could say."}
          ]
        }
        Include one questions item for every interview question.

        Interview:
        \(qa)

        Context:
        \(session.context)
        """
        let text = try await AIService.callAIModel(
            config: AIService.config(from: modelContext),
            systemPrompt: "You are a senior interview coach. Return valid JSON only. Write all feedback and suggested answers in \(outputLanguage).",
            question: prompt,
            maxTokens: 3600
        )
        applyEvaluation(text, to: session)
    }

    private func decodeQuestions(_ raw: String) -> [MockQuestionDraft] {
        let data = Data(extractJSON(raw).utf8)
        if let wrapped = try? JSONDecoder().decode(MockQuestionList.self, from: data) {
            return wrapped.questions
        }
        if let decoded = try? JSONDecoder().decode([MockQuestionDraft].self, from: data) {
            return decoded
        }
        return []
    }

    private func applyEvaluation(_ raw: String, to session: InterviewSession) {
        let data = Data(extractJSON(raw).utf8)
        guard let decoded = try? JSONDecoder().decode(MockEvaluation.self, from: data) else {
            applyLooseEvaluation(raw, to: session)
            return
        }
        session.overallScore = decoded.overallScore
        session.summaryFeedback = decoded.summary
        session.strengthsText = decoded.strengths.map { "• \($0)" }.joined(separator: "\n")
        session.improvementsText = decoded.improvements.map { "• \($0)" }.joined(separator: "\n")
        let turns = session.turns.sorted { $0.createdAt < $1.createdAt }
        for item in decoded.questions {
            let index = item.index - 1
            guard turns.indices.contains(index) else { continue }
            turns[index].score = item.score
            turns[index].feedback = item.feedback
            turns[index].suggestedAnswer = item.suggestedAnswer
        }
        fillMissingEvaluationDetails(for: session)
    }

    private func applyLooseEvaluation(_ raw: String, to session: InterviewSession) {
        let clean = extractJSON(raw)
        guard let data = clean.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            applyTextEvaluation(raw, to: session)
            return
        }
        session.overallScore = intValue(json["overallScore"]) ?? intValue(json["score"]) ?? 70
        session.summaryFeedback = stringValue(json["summary"]) ?? stringValue(json["overall"]) ?? L.t("Evaluation complete.")
        if let strengths = stringArray(json["strengths"]) {
            session.strengthsText = strengths.map { "• \($0)" }.joined(separator: "\n")
        }
        if let improvements = stringArray(json["improvements"]) {
            session.improvementsText = improvements.map { "• \($0)" }.joined(separator: "\n")
        }
        let turns = session.turns.sorted { $0.createdAt < $1.createdAt }
        if let questionItems = json["questions"] as? [[String: Any]] {
            for item in questionItems {
                let index = (intValue(item["index"]) ?? 0) - 1
                guard turns.indices.contains(index) else { continue }
                turns[index].score = intValue(item["score"]) ?? turns[index].score
                turns[index].feedback = stringValue(item["feedback"]) ?? turns[index].feedback
                turns[index].suggestedAnswer = stringValue(item["suggestedAnswer"]) ?? stringValue(item["suggestion"]) ?? turns[index].suggestedAnswer
            }
        }
        fillMissingEvaluationDetails(for: session)
    }

    private func applyTextEvaluation(_ raw: String, to session: InterviewSession) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        session.overallScore = regexInt(in: text, key: "overallScore") ?? regexInt(in: text, key: "score") ?? 70
        session.summaryFeedback = regexString(in: text, key: "summary")
            ?? text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? L.t("Evaluation complete.")
        let strengths = regexStringArray(in: text, key: "strengths")
        let improvements = regexStringArray(in: text, key: "improvements")
        session.strengthsText = strengths.isEmpty ? "" : strengths.map { "• \($0)" }.joined(separator: "\n")
        session.improvementsText = improvements.isEmpty ? "" : improvements.map { "• \($0)" }.joined(separator: "\n")
        fillMissingEvaluationDetails(for: session)
    }

    private func fillMissingEvaluationDetails(for session: InterviewSession) {
        let turns = session.turns.sorted { $0.createdAt < $1.createdAt }
        if session.summaryFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.summaryFeedback = L.t("Evaluation complete.")
        }
        if session.strengthsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let answered = turns.filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            session.strengthsText = "• \(L.t("Completed the mock interview with recorded answers."))\n• \(L.t("The answers provide material for follow-up coaching and formal interview personalization."))"
            if answered > 1 {
                session.strengthsText += "\n• \(L.t("Maintained continuity across multiple interview questions."))"
            }
        }
        if session.improvementsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.improvementsText = "• \(L.t("Use the STAR structure to make each answer easier to evaluate."))\n• \(L.t("Add concrete metrics, trade-offs, and personal contribution for each project example."))\n• \(L.t("Prepare one concise closing sentence that connects your experience to the target role."))"
        }
        for (index, turn) in turns.enumerated() {
            if turn.score <= 0 {
                turn.score = fallbackScore(for: turn)
            }
            if turn.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                turn.feedback = fallbackFeedback(index: index, turn: turn, role: session.role)
            }
            if turn.suggestedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                turn.suggestedAnswer = suggestedFallbackAnswer(index: index, turn: turn, role: session.role)
            }
            if answersAreTooSimilar(turn.feedback, turn.suggestedAnswer) {
                turn.suggestedAnswer = suggestedFallbackAnswer(index: index, turn: turn, role: session.role)
            }
        }
    }

    private func fallbackScore(for turn: ConversationTurn) -> Int {
        let answer = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.count < 24 { return 45 }
        if answer.count < 80 { return 60 }
        let hasMetric = answer.range(of: #"\d|%|提升|降低|增长|减少|倍|分|秒|ms|users|students"#, options: .regularExpression) != nil
        return hasMetric ? 78 : 68
    }

    private func fallbackFeedback(index: Int, turn: ConversationTurn, role: String) -> String {
        let answer = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleText = role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L.t("this role") : role
        let hasTool = answer.range(of: "AI|ai|Notability|notability|腾讯|会议|可视化|工具|software|tool", options: .regularExpression) != nil
        let hasMetric = answer.range(of: #"\d|%|提升|降低|增长|减少|倍|分|秒|ms"#, options: .regularExpression) != nil
        let hasAction = answer.range(of: "我会|我使用|我设计|我负责|我调整|I used|I designed|I led|I would", options: .regularExpression) != nil

        if currentLanguage == .chinese {
            var parts = ["这题的回答方向是对的，能看出你抓住了题目里的关键词，但目前表达还停留在“我用了什么”的层面。"]
            if !hasTool {
                parts.append("建议直接点名具体工具、材料或教学方法，否则面试官很难判断你的实践能力。")
            }
            if !hasAction {
                parts.append("需要补充你的个人动作，比如你如何拆解学生问题、如何设计互动、如何根据反馈调整节奏。")
            }
            if !hasMetric {
                parts.append("缺少结果证据，可以加入学生理解度、作业正确率、课堂参与度、续课反馈等可观察结果。")
            }
            parts.append("最后用一句话把这个例子连接到 \(roleText)，说明它证明了你的教学设计、沟通或现场调整能力。")
            return parts.joined(separator: " ")
        }

        var parts = ["The answer points in the right direction, but it is still too high-level for an interview."]
        if !hasTool {
            parts.append("Name the specific tool, material, or teaching method so the interviewer can assess your hands-on experience.")
        }
        if !hasAction {
            parts.append("Add your personal actions: how you diagnosed the learner's issue, structured the activity, and adjusted based on feedback.")
        }
        if !hasMetric {
            parts.append("Add evidence such as student understanding, accuracy, engagement, retention, or concrete feedback.")
        }
        parts.append("Close by connecting the example to \(roleText), especially the skill it proves.")
        return parts.joined(separator: " ")
    }

    private func suggestedFallbackAnswer(index: Int, turn: ConversationTurn, role: String) -> String {
        let targetRole = role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L.t("this role") : role
        let answer = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentLanguage == .chinese {
            let seed = answer.isEmpty ? "我会先明确学生当前卡住的知识点" : answer
            return "我会先说明学生的具体背景和学习困难，例如他在哪个概念上不理解、之前尝试过什么方法。然后我会结合 \(seed)，把知识点拆成可视化步骤或互动任务，让学生先观察、再解释、最后自己复述。过程中我会根据学生的反应实时调整节奏，比如如果他只会套公式，我会追问原因；如果他能说出思路，我会增加一道迁移题。最后我会用一个可观察结果收尾，例如学生能独立完成同类题、正确解释关键概念，或者课后反馈更有信心。这个例子能体现我在 \(targetRole) 中需要的教学设计、沟通和即时调整能力。"
        }
        let seed = answer.isEmpty ? "I would first identify the student's blocker" : answer
        return "I would start by clarifying the student's specific blocker and learning goal. Then, building on \(seed), I would break the concept into a visual or interactive sequence: first let the student observe the pattern, then ask them to explain it back, and finally give a transfer question to test whether they can apply it independently. During the session, I would adjust based on their response rather than just continue the plan. I would close with evidence, such as improved accuracy on a similar question or clearer self-explanation. That example shows the teaching design, communication, and real-time adjustment skills required for \(targetRole)."
    }

    private func answersAreTooSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let shorter = min(left.count, right.count)
        let longer = max(left.count, right.count)
        guard longer > 0 else { return false }
        return shorter > 30 && Double(shorter) / Double(longer) > 0.82 && (left.contains(right.prefix(30)) || right.contains(left.prefix(30)))
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }
        return nil
    }

    private func stringArray(_ value: Any?) -> [String]? {
        if let values = value as? [String] {
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let values = value as? [Any] {
            let strings = values.compactMap(stringValue)
            return strings.isEmpty ? nil : strings
        }
        return nil
    }

    private func regexInt(in text: String, key: String) -> Int? {
        if let value = regexString(in: text, key: key) {
            return Int(value)
        }
        return regexRawMatch(in: text, pattern: #""\#(key)"\s*:\s*(\d+)"#).flatMap(Int.init)
    }

    private func regexString(in text: String, key: String) -> String? {
        regexRawMatch(in: text, pattern: #""\#(key)"\s*:\s*"((?:\\.|[^"\\])*)""#)
            .map(unescapeJSONString)
    }

    private func regexStringArray(in text: String, key: String) -> [String] {
        guard let body = regexRawMatch(in: text, pattern: #""\#(key)"\s*:\s*\[(.*?)\]"#) else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)""#, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: body) else { return nil }
            return unescapeJSONString(String(body[valueRange]))
        }
    }

    private func regexRawMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unescapeJSONString(_ value: String) -> String {
        let wrapped = "\"\(value)\""
        if let data = wrapped.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return value.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    private func extractJSON(_ text: String) -> String {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```") {
            clean = clean.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = clean.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let end = clean.lastIndex(where: { $0 == "}" || $0 == "]" }) {
            return String(clean[start...end])
        }
        return clean
    }

    private func fallbackQuestions(role: String) -> [MockQuestionDraft] {
        [
            MockQuestionDraft(category: L.t("Behavioral"), question: L.t("Tell me about yourself and why this role fits your experience.")),
            MockQuestionDraft(category: L.t("Project Deep Dive"), question: L.t("Pick one project from your background. What problem did you solve and what was your personal contribution?")),
            MockQuestionDraft(category: L.t("Role Fit"), question: L.t("What strengths would you bring to this position, and what evidence supports them?"))
        ]
    }
}

private struct MockQuestionDraft: Codable, Identifiable {
    var id = UUID()
    var category: String
    var question: String

    private enum CodingKeys: String, CodingKey {
        case category
        case question
    }
}

private struct MockQuestionList: Codable {
    var questions: [MockQuestionDraft]
}

private struct MockEvaluation: Codable {
    var overallScore: Int
    var summary: String
    var strengths: [String]
    var improvements: [String]
    var questions: [MockQuestionEvaluation]
}

private struct MockQuestionEvaluation: Codable {
    var index: Int
    var score: Int
    var feedback: String
    var suggestedAnswer: String
}
