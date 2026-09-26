import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct SetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \KnowledgeBase.updatedAt, order: .reverse) private var knowledgeBases: [KnowledgeBase]

    @Binding var activeIDs: Set<UUID>
    var onOpenKnowledge: () -> Void = {}
    var onOpenAPISettings: () -> Void = {}
    var onOpenMockInterview: (MockInterviewLaunchConfig) -> Void = { _ in }

    @State private var host = ""
    @State private var role = ""
    @State private var jobDescription = ""
    @State private var companyName = ""
    @State private var companyWebsite = ""
    @State private var companyNotes = ""
    @State private var isParsingCompanyWebsite = false
    @State private var companyParseStatus = ""
    @State private var usedDefaultKB = false
    @State private var showReceiver = false
    @State private var session: InterviewSession?
    @State private var isStartingInterview = false
    @State private var selectedProvider: AIProvider = AIProvider.productionDefault
    @State private var selectedModel = AIProvider.productionDefault.defaultModel
    @State private var showMockOptions = false
    @State private var mockQuestionCount = 6
    @State private var mockQuestionCountText = "6"
    @AppStorage(AppPreferenceKey.mockInterviewLanguage) private var mockInterviewLanguageRaw = MockInterviewLanguage.followApp.rawValue
    #if os(macOS)
    @AppStorage(AppPreferenceKey.hideDockIcon) private var hideDockIcon = false
    @State private var floatingReceiver: NSWindowController?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 18 : 24) {
                hero

                if isCompact {
                    VStack(spacing: 16) {
                        roleCard
                    }
                } else {
                    desktopWorkflow
                }
            }
            .padding(isCompact ? 16 : 32)
            .padding(.bottom, isCompact ? 120 : 40)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .onAppear {
            loadWorkspaceDrafts()
            loadAISelection()
            applyDefaultKBSelection()
        }
        .onChange(of: role) { _, newValue in
            modelContext.setSetting("last_role", value: newValue)
        }
        .onChange(of: jobDescription) { _, newValue in
            modelContext.setSetting("last_job_description", value: newValue)
        }
        .onChange(of: companyName) { _, newValue in
            modelContext.setSetting("last_company_name", value: newValue)
        }
        .onChange(of: companyWebsite) { _, newValue in
            modelContext.setSetting("last_company_website", value: newValue)
        }
        .onChange(of: companyNotes) { _, newValue in
            modelContext.setSetting("last_company_notes", value: newValue)
        }
        .onChange(of: knowledgeBases.count) { _, _ in applyDefaultKBSelection() }
        .receiverPresentation(isPresented: $showReceiver) {
            if let session {
                ReceiverContainerView(session: session, host: "")
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Interview AI")
                        .font(isCompact ? .appTitleCompact : .appTitle)
                    Text(L.t("Practice smarter. Ace your next interview."))
                        .font(.appBody)
                        .foregroundStyle(Color.appMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if !isCompact {
                    StatusPill(text: knowledgeCountText, tint: .appPrimary)
                }
            }

            if isCompact {
                StatusPill(text: knowledgeCountText, tint: .appPrimary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 16) {
                    startButton
                    mockInterviewButton
                    Spacer()
                    heroKnowledgePicker
                    .frame(width: 360)
                }
                VStack(alignment: .leading, spacing: 14) {
                    startButton
                    mockInterviewButton
                    heroKnowledgePicker
                }
            }
        }
        .premiumCard(padding: isCompact ? 20 : 28)
        .sheet(isPresented: $showMockOptions) {
            mockOptionsSheet
        }
    }

    private var desktopWorkflow: some View {
        VStack(spacing: 24) {
            roleCard
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var startButton: some View {
        Button {
            Task { await startInterview() }
        } label: {
            Label(isStartingInterview ? L.t("Starting...") : L.t("Start Interview"), systemImage: "sparkles")
                .frame(maxWidth: isCompact ? .infinity : nil)
        }
        .buttonStyle(AppButtonStyle(prominent: true))
        .disabled(isStartingInterview)
    }

    private var mockInterviewButton: some View {
        Button {
            mockQuestionCountText = "\(mockQuestionCount)"
            showMockOptions = true
        } label: {
            Label(L.t("Mock Interview"), systemImage: "mic.fill")
                .frame(maxWidth: isCompact ? .infinity : nil)
        }
        .buttonStyle(AppButtonStyle())
    }

    private var mockOptionsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L.t("Mock Interview Options"))
                    .font(.appSection)
                Spacer()
                Button {
                    showMockOptions = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.appMuted)
                        .frame(width: 32, height: 32)
                        .background(Color.appButton)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Text(L.t("Choose how many questions this mock interview should include."))
                .font(.appBody)
                .foregroundStyle(Color.appMuted)

            HStack(spacing: 12) {
                Stepper("", value: $mockQuestionCount, in: 3...10)
                    .labelsHidden()
                    .onChange(of: mockQuestionCount) { _, newValue in
                        mockQuestionCountText = "\(newValue)"
                    }

                TextField("6", text: $mockQuestionCountText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .frame(width: 78, height: 46)
                    .background(Color.appField)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onSubmit {
                        applyMockQuestionCountText()
                    }

                Text(L.t("questions"))
                    .font(.appBodyMedium)
                    .foregroundStyle(Color.appMuted)
            }

            HStack {
                Button(L.t("Cancel")) {
                    showMockOptions = false
                }
                .buttonStyle(AppButtonStyle())

                Spacer()

                Button {
                    applyMockQuestionCountText()
                    showMockOptions = false
                    openMockInterview(questionCount: mockQuestionCount)
                } label: {
                    Label(L.t("Start Mock Interview"), systemImage: "play.fill")
                }
                .buttonStyle(AppButtonStyle(prominent: true))
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color.appBG)
    }

    private func applyMockQuestionCountText() {
        let value = Int(mockQuestionCountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? mockQuestionCount
        mockQuestionCount = min(10, max(3, value))
        mockQuestionCountText = "\(mockQuestionCount)"
    }

    private var mockInterviewLanguage: MockInterviewLanguage {
        MockInterviewLanguage(rawValue: mockInterviewLanguageRaw) ?? .followApp
    }

    private func openMockInterview(questionCount: Int) {
        let model = validModel(selectedModel, for: selectedProvider)
        modelContext.setSetting("last_role", value: role)
        modelContext.setSetting("last_job_description", value: jobDescription)
        modelContext.setSetting("api_provider", value: selectedProvider.rawValue)
        modelContext.setSetting("api_model", value: model)
        modelContext.setSetting("api_model_\(selectedProvider.rawValue)", value: model)
        try? modelContext.save()
        onOpenMockInterview(
            MockInterviewLaunchConfig(
                role: role,
                jobDescription: jobDescription,
                activeKBIds: activeIDs,
                language: mockInterviewLanguage,
                questionCount: questionCount
            )
        )
    }

    private var roleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeader(L.t("Role"), subtitle: L.t("Shape the interview around the exact opportunity."), icon: "person.text.rectangle")
            labeledField(L.t("Target role")) {
                TextField("Product Designer at Linear", text: $role)
                    .textFieldStyle(.plain)
                    .darkField()
            }
            labeledField(L.t("Job description")) {
                jobDescriptionEditor
            }
            Divider()
                .overlay(Color.appBorder)
            companyResearchSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .premiumCard()
    }

    private var companyResearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader(
                L.t("Company Introduction"),
                subtitle: L.t("Record the website, business, compensation structure, and company understanding you may be asked about in interviews."),
                icon: "building.2"
            )
            labeledField(L.t("Company Name")) {
                TextField(L.t("For example: Linear / DeepSeek / ByteDance"), text: $companyName)
                    .textFieldStyle(.plain)
                    .darkField()
            }
            labeledField(L.t("Company Website")) {
                HStack(spacing: 10) {
                    TextField("https://company.com", text: $companyWebsite)
                        .textFieldStyle(.plain)
                        .hostInputTraits()

                    Button {
                        Task { await parseCompanyWebsite() }
                    } label: {
                        Label(isParsingCompanyWebsite ? L.t("Parsing") : L.t("Parse Website"), systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(AppButtonStyle())
                    .disabled(companyWebsite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsingCompanyWebsite)
                }
            }
            labeledField(L.t("Company Notes")) {
                companyNotesEditor
            }
            if !companyParseStatus.isEmpty {
                Text(companyParseStatus)
                    .font(.appSmall)
                    .foregroundStyle(companyParseStatus.contains("失败") ? Color.appDanger : Color.appMuted)
            }
        }
    }

    private var jobDescriptionEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $jobDescription)
                .scrollContentBackground(.hidden)
                .frame(minHeight: isCompact ? 120 : 140)

            if jobDescription.isEmpty {
                Text(L.t("Paste the job description, responsibilities, or requirements here."))
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .darkField()
    }

    private var companyNotesEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $companyNotes)
                .scrollContentBackground(.hidden)
                .frame(minHeight: isCompact ? 140 : 170)

            if companyNotes.isEmpty {
                Text(L.t("You can write: business, products, target users, competitors, compensation structure, what interviewers may care about, and why you want to join."))
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .darkField()
    }

    private var heroKnowledgePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onOpenKnowledge()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(knowledgePickerTitle)
                            .font(.appCaptionMedium)
                            .foregroundStyle(Color.appText)
                            .lineLimit(1)
                        Text(knowledgePickerSubtitle)
                            .font(.appSmall)
                            .foregroundStyle(Color.appMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.appMuted)
                }
                .padding(.horizontal, 14)
                .frame(height: 56)
                .background(Color.appField)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Text(knowledgeCountText)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                Spacer()
                Button(enabledKnowledgeBases.isEmpty ? L.t("Choose Knowledge") : L.t("Manage Knowledge")) {
                    onOpenKnowledge()
                }
                .font(.appCaptionMedium)
                .buttonStyle(.plain)
                .foregroundStyle(Color.appPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var knowledgeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeader(L.t("Knowledge"), subtitle: enabledKnowledgeBases.isEmpty ? L.t("No knowledge selected") : L.t("Enabled for this interview"), icon: "folder.badge.gearshape")

            if enabledKnowledgeBases.isEmpty {
                Text(L.t("No knowledge base is enabled for this interview."))
                    .font(.appBody)
                    .foregroundStyle(Color.appMuted)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(enabledKnowledgeBases) { kb in
                        enabledKnowledgeRow(kb)
                    }
                }
            }

            Button {
                onOpenKnowledge()
            } label: {
                Label(enabledKnowledgeBases.isEmpty ? L.t("Choose Knowledge") : L.t("Manage Knowledge"), systemImage: "folder")
                    .frame(maxWidth: isCompact ? .infinity : nil)
            }
            .buttonStyle(AppButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .premiumCard()
    }

    private func enabledKnowledgeRow(_ kb: KnowledgeBase) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appGreen)
            VStack(alignment: .leading, spacing: 3) {
                Text(kb.name)
                    .font(.appCaptionMedium)
                    .foregroundStyle(Color.appText)
                let enabledSourceCount = kb.entries.filter(\.isEnabled).count
                Text(sourceCountText(enabledSourceCount))
                    .font(.appSmall)
                    .foregroundStyle(Color.appMuted)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.appField)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func cardHeader(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 36, height: 36)
                .background(Color.appPrimary.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.appSection)
                Text(subtitle)
                    .font(.appCaption)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.appCaptionMedium)
                .foregroundStyle(Color.appMuted)
            content()
        }
    }

    private var enabledKnowledgeBases: [KnowledgeBase] {
        knowledgeBases.filter { activeIDs.contains($0.id) }
    }

    private var homeModelOptions: [HomeModelOption] {
        let options = AIProvider.productionOptions.map { provider in
            HomeModelOption(provider: provider, model: storedModel(for: provider))
        }
        return options.reduce(into: [HomeModelOption]()) { result, option in
            if !result.contains(where: { $0.model == option.model }) {
                result.append(option)
            }
        }
    }

    private var knowledgeCountText: String {
        let count = enabledKnowledgeBases.count
        if AppLanguage.current == .chinese {
            return "\(count) 个知识库"
        }
        return "\(count) \(count == 1 ? "knowledge base" : "knowledge bases")"
    }

    private var knowledgePickerTitle: String {
        if enabledKnowledgeBases.isEmpty {
            return L.t("Choose Knowledge")
        }
        if enabledKnowledgeBases.count == 1 {
            return enabledKnowledgeBases[0].name
        }
        return knowledgeCountText
    }

    private var knowledgePickerSubtitle: String {
        if enabledKnowledgeBases.isEmpty {
            return L.t("No knowledge selected")
        }
        let sourceCount = enabledKnowledgeBases.reduce(0) { total, kb in
            total + kb.entries.filter(\.isEnabled).count
        }
        return sourceCountText(sourceCount)
    }

    private func sourceCountText(_ count: Int) -> String {
        if AppLanguage.current == .chinese {
            return "\(count) 个来源"
        }
        return "\(count) \(count == 1 ? "source" : "sources")"
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private func loadWorkspaceDrafts() {
        role = modelContext.setting("last_role")
        jobDescription = modelContext.setting("last_job_description")
        companyName = modelContext.setting("last_company_name")
        companyWebsite = modelContext.setting("last_company_website")
        companyNotes = modelContext.setting("last_company_notes")
        host = modelContext.setting("last_host")
    }

    private func clearWorkspaceDrafts() {
        role = ""
        jobDescription = ""
        companyName = ""
        companyWebsite = ""
        companyNotes = ""
        companyParseStatus = ""
        activeIDs.removeAll()
        usedDefaultKB = true
    }

    private func applyDefaultKBSelection() {
        guard !usedDefaultKB else { return }
        if activeIDs.isEmpty {
            activeIDs = Set(knowledgeBases.filter { $0.name == "UI/UX 经历" }.map(\.id))
        }
        usedDefaultKB = true
    }

    private func loadAISelection() {
        let storedProvider = AIProvider(rawValue: modelContext.setting("api_provider", default: AIProvider.productionDefault.rawValue)) ?? AIProvider.productionDefault
        selectedProvider = AIProvider.productionOptions.contains(storedProvider) ? storedProvider : AIProvider.productionDefault
        let scopedModel = modelContext.setting("api_model_\(selectedProvider.rawValue)")
        let legacyModel = modelContext.setting("api_model", default: selectedProvider.defaultModel)
        selectedModel = validModel(scopedModel.isEmpty ? legacyModel : scopedModel, for: selectedProvider)
    }

    private func validModel(_ storedValue: String, for provider: AIProvider) -> String {
        if provider.models.contains(storedValue) {
            return storedValue
        }
        return provider.models.first ?? provider.defaultModel
    }

    private func storedModel(for provider: AIProvider) -> String {
        let scopedModel = modelContext.setting("api_model_\(provider.rawValue)")
        let legacyModel = modelContext.setting("api_model", default: provider.defaultModel)
        return validModel(scopedModel.isEmpty ? legacyModel : scopedModel, for: provider)
    }

    private func clearHost() {
        host = ""
        modelContext.setSetting("last_host", value: "")
    }

    @MainActor
    private func parseCompanyWebsite() async {
        guard !isParsingCompanyWebsite else { return }
        let url = companyWebsite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        isParsingCompanyWebsite = true
        companyParseStatus = L.t("Parsing the company website and generating a research summary...")
        defer { isParsingCompanyWebsite = false }
        do {
            let summary = try await WebsiteResearchService.researchCompany(
                from: url,
                config: AIService.config(from: modelContext)
            )
            let block = """

            \(L.t("Website research summary (please review manually):"))
            \(summary)
            """
            companyNotes = companyNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? block.trimmingCharacters(in: .whitespacesAndNewlines)
                : "\(companyNotes.trimmingCharacters(in: .whitespacesAndNewlines))\n\(block)"
            companyParseStatus = L.t("Company research summary generated. Please review it quickly before the interview.")
        } catch {
            companyParseStatus = String(format: L.t("Parsing failed: %@. You can fill in the company notes manually."), error.localizedDescription)
        }
    }

    private func interviewContext(role: String, jobDescription: String) -> String {
        var parts: [String] = []
        if !role.isEmpty {
            parts.append("Role applying for: \(role)")
        }
        let cleanJobDescription = jobDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanJobDescription.isEmpty {
            parts.append("""
            Job description / company needs:
            \(cleanJobDescription)

            Tailor answers to this job description. Emphasize relevant skills, examples, language, responsibilities, and business priorities from the posting when they fit the question.
            """)
        }
        let cleanCompanyName = companyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCompanyWebsite = companyWebsite.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCompanyNotes = companyNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanCompanyName.isEmpty || !cleanCompanyWebsite.isEmpty || !cleanCompanyNotes.isEmpty {
            parts.append("""
            Company research:
            Company name: \(cleanCompanyName.isEmpty ? "Not provided" : cleanCompanyName)
            Website: \(cleanCompanyWebsite.isEmpty ? "Not provided" : cleanCompanyWebsite)

            Notes:
            \(cleanCompanyNotes)

            Use this when the interviewer asks about company understanding, motivation, compensation structure, product, users, market, or why this company. Do not overstate facts that are not in these notes.
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    @MainActor
    private func startInterview() async {
        guard !isStartingInterview else { return }
        isStartingInterview = true
        defer { isStartingInterview = false }

        await Task.yield()
        let cleanRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleRole = cleanRole.isEmpty ? "Local Interview" : cleanRole
        let context = interviewContext(role: cleanRole, jobDescription: jobDescription)
        let newSession = InterviewSession(
            title: titleRole,
            role: cleanRole,
            context: context,
            activeKBIds: Array(activeIDs)
        )
        modelContext.insert(newSession)
        modelContext.setSetting("last_role", value: role)
        modelContext.setSetting("last_job_description", value: jobDescription)
        modelContext.setSetting("last_company_name", value: companyName)
        modelContext.setSetting("last_company_website", value: companyWebsite)
        modelContext.setSetting("last_company_notes", value: companyNotes)
        modelContext.setSetting("last_host", value: "")
        let model = validModel(selectedModel, for: selectedProvider)
        modelContext.setSetting("api_model", value: model)
        modelContext.setSetting("api_model_\(selectedProvider.rawValue)", value: model)
        try? modelContext.save()
        session = newSession
        #if os(macOS)
        let miniaturizedWindows = NSApp.windows.filter { window in
            window.isMiniaturized && !(window is PrompterPanel)
        }
        NSApp.windows.compactMap { $0 as? PrompterPanel }.forEach { $0.close() }
        floatingReceiver = nil
        var controller: NSWindowController!
        let root = ReceiverContainerView(session: newSession, host: "", closeWindow: {
            controller?.close()
            if floatingReceiver === controller {
                floatingReceiver = nil
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        })
            .modelContext(modelContext)
        controller = FloatingWindowController(rootView: root)
        floatingReceiver = controller
        if hideDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
        controller.window?.orderFrontRegardless()
        DispatchQueue.main.async {
            for window in miniaturizedWindows where !window.isMiniaturized {
                window.miniaturize(nil)
            }
        }
        #else
        showReceiver = true
        #endif
    }
}

private struct HomeModelOption: Identifiable {
    let provider: AIProvider
    let model: String

    var id: String {
        model
    }
}

private extension View {
    @ViewBuilder
    func hostInputTraits() -> some View {
        #if os(iOS)
        self
            .keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
        #else
        self
        #endif
    }

    @ViewBuilder
    func receiverPresentation<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        self
        #endif
    }
}

private extension Date {
    static var formattedNow: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: .now)
    }
}
