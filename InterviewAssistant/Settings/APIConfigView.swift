import SwiftUI
import SwiftData

struct APIConfigView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var provider: AIProvider = AIProvider.productionDefault
    @State private var apiURL = ""
    @State private var model = AIProvider.productionDefault.defaultModel
    @State private var apiKey = ""
    @State private var connectionTestResult: String?
    @State private var asrProviderRaw = ASRProvider.volcano.rawValue
    @State private var asrAppID = ""
    @State private var asrAccessToken = ""
    @State private var asrResourceID = "volc.seedasr.sauc.duration"
    @State private var asrConnectionTestResult: String?
    @State private var isTestingASR = false

    private let providerOptions: [AIProvider] = AIProvider.productionOptions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsBackButton()
                header
                speechRecognitionSection
                providerSection
                modelSection
                connectionSection
            }
            .padding(20)
            .padding(.bottom, 120)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appBG.ignoresSafeArea())
        .foregroundStyle(Color.appText)
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
        .onAppear { load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("API Configure"))
                .font(.appTitleCompact)
                .foregroundStyle(Color.appText)
            Text(L.t("Configure speech recognition and the LLM separately. Credentials stay in the local Keychain, and requests go directly to the selected provider."))
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var speechRecognitionSection: some View {
        configCard(
            title: L.t("Speech Recognition"),
            subtitle: L.t("Used to transcribe the interviewer in real time. Doubao requires an App ID and Access Token; Apple on-device recognition requires no credentials.")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                configRow(title: L.t("Recognition Engine")) {
                    PremiumMenuPicker(
                        selection: $asrProviderRaw,
                        options: ASRProvider.allCases.map { ($0.rawValue, $0.settingsTitle) },
                        minWidth: isCompact ? 190 : 260
                    )
                }

                if asrProviderRaw == ASRProvider.volcano.rawValue {
                    Divider().overlay(Color.appBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("App ID")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                        TextField(L.t("Get this from the app details in the Doubao Voice console"), text: $asrAppID)
                            .textFieldStyle(.plain)
                            .darkField()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Access Token")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                        SecureField(L.t("Get this from the app details in the Doubao Voice console"), text: $asrAccessToken)
                            .textFieldStyle(.plain)
                            .darkField()
                    }

                    configRow(title: L.t("Recognition Model")) {
                        PremiumMenuPicker(
                            selection: $asrResourceID,
                            options: [
                                ("volc.seedasr.sauc.duration", L.t("Doubao Streaming Speech 2.0 · Hourly")),
                                ("volc.seedasr.sauc.concurrent", L.t("Doubao Streaming Speech 2.0 · Concurrent")),
                                ("volc.bigasr.sauc.duration", L.t("Streaming Speech 1.0 · Hourly"))
                            ],
                            minWidth: isCompact ? 220 : 320
                        )
                    }

                    Text(L.t("The 2.0 hourly plan is recommended. Create an app in the Doubao Voice console, enable the matching model, then copy its App ID and Access Token."))
                        .font(.appSmall)
                        .foregroundStyle(Color.appMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Link(L.t("View Doubao streaming speech documentation"), destination: URL(string: "https://docs.volcengine.com/docs/DoubaoVoice/bidirectional-streaming-automatic-speech-recognition-websocket?lang=zh")!)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                }

                HStack(spacing: 12) {
                    Button(isTestingASR ? L.t("Testing...") : L.t("Test Connection")) {
                        Task { await testASRConnection() }
                    }
                    .buttonStyle(AppButtonStyle())
                    .disabled(isTestingASR)

                    Spacer()

                    Button(L.t("Save")) { saveASRConfiguration() }
                        .buttonStyle(AppButtonStyle(prominent: true))
                }

                if let asrConnectionTestResult {
                    connectionStatus(asrConnectionTestResult)
                }
            }
        }
    }

    private var providerSection: some View {
        configCard(title: L.t("Provider"), subtitle: L.t("Select where responses should be generated.")) {
            HStack(spacing: 14) {
                Text(L.t("Provider"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appText)
                PremiumSegmentedPicker(
                    selection: Binding(
                        get: { provider.rawValue },
                        set: { if let value = AIProvider(rawValue: $0) { provider = value } }
                    ),
                    options: providerOptions.map { ($0.rawValue, $0.shortLabel) }
                )
            }
            .onChange(of: provider) { _, newValue in
                applyProvider(newValue, force: true)
            }
        }
    }

    private var modelSection: some View {
        configCard(title: L.t("Model"), subtitle: provider.help) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Text(L.t("Current model"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.appText)
                    PremiumMenuPicker(
                        selection: $model,
                        options: provider.models.map { ($0, $0) },
                        minWidth: isCompact ? 180 : 260
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(Color.appField.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous)
                        .stroke(Color.appBorder.opacity(0.8), lineWidth: 1)
                }

                TextField(L.t("Custom model"), text: $model)
                    .textFieldStyle(.plain)
                    .darkField()
            }
        }
    }

    private var connectionSection: some View {
        configCard(title: L.t("Connection"), subtitle: L.t("The API key stays in the local Keychain and is never uploaded to an InterviewAssistant service. Ollama usually needs no key.")) {
            VStack(alignment: .leading, spacing: 14) {
                TextField(apiURLPlaceholder, text: $apiURL)
                    .textFieldStyle(.plain)
                    .darkField()
                SecureField(L.t("API Key (optional for Ollama)"), text: $apiKey)
                    .textFieldStyle(.plain)
                    .darkField()
                Text("\(L.t("Direct connection")): \(provider.label)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.appMuted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appField)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous))

                HStack(spacing: 12) {
                    Button(L.t("Test Connection")) {
                        Task { await testConnection() }
                    }
                    .buttonStyle(AppButtonStyle())

                    Spacer()

                    Button(L.t("Save")) { _ = save() }
                        .buttonStyle(AppButtonStyle(prominent: true))
                }

                if let connectionTestResult {
                    connectionStatus(connectionTestResult)
                }

                #if os(iOS)
                if provider == .ollama {
                    ollamaLANTip
                }
                #endif
            }
        }
    }

    private func configCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.appText)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(isCompact ? 16 : 20)
        .background(cardBackground(radius: 22))
    }

    private func configRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appText)
            Spacer(minLength: 12)
            content()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(Color.appField.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous)
                .stroke(Color.appBorder.opacity(0.8), lineWidth: 1)
        }
    }

    private func connectionStatus(_ value: String) -> some View {
        let isSuccess = value.contains("success") || value.contains("✅")
        return HStack(spacing: 10) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isSuccess ? Color.appGreen : Color.appDanger)
            Text(value)
                .font(.appCaption)
                .foregroundStyle(isSuccess ? Color.appGreen : Color.appDanger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isSuccess ? Color.appGreen : Color.appDanger).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func load() {
        let storedProvider = AIProvider(rawValue: modelContext.setting("api_provider", default: AIProvider.productionDefault.rawValue)) ?? AIProvider.productionDefault
        provider = providerOptions.contains(storedProvider) ? storedProvider : AIProvider.productionDefault
        apiURL = storedAPIURL(for: provider)
        model = storedModel(for: provider)
        apiKey = KeychainStore.read("api-key-\(provider.rawValue)")
        asrProviderRaw = UserDefaults.standard.string(forKey: AppPreferenceKey.asrProvider)
            ?? ASRProvider.volcano.rawValue
        asrAppID = KeychainStore.read("asr-volcano-app-key")
        asrAccessToken = KeychainStore.read("asr-volcano-access-key")
        asrResourceID = UserDefaults.standard.string(forKey: "asr_volcano_resource_id")
            ?? "volc.seedasr.sauc.duration"
    }

    private func applyProvider(_ provider: AIProvider, force: Bool) {
        if force || apiURL.isEmpty { apiURL = storedAPIURL(for: provider) }
        if force || model.isEmpty || !provider.models.contains(model) { model = storedModel(for: provider) }
        apiKey = KeychainStore.read("api-key-\(provider.rawValue)")
        connectionTestResult = nil
    }

    @discardableResult
    private func save() -> Bool {
        modelContext.setSetting("api_provider", value: provider.rawValue)
        modelContext.setSetting("api_url_\(provider.rawValue)", value: apiURL)
        modelContext.setSetting("api_model_\(provider.rawValue)", value: model)
        modelContext.setSetting("api_url", value: apiURL)
        modelContext.setSetting("api_model", value: model)
        do {
            try KeychainStore.save(
                apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                account: "api-key-\(provider.rawValue)"
            )
            connectionTestResult = L.t("Configuration saved.")
            return true
        } catch {
            connectionTestResult = error.localizedDescription
            return false
        }
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var apiURLPlaceholder: String {
        #if os(iOS)
        if provider == .ollama {
            return "http://192.168.x.x:11434/v1"
        }
        #endif
        return provider.defaultURL.isEmpty ? L.t("API URL") : provider.defaultURL
    }

    private func validModel(_ storedValue: String, for provider: AIProvider) -> String {
        if provider.models.contains(storedValue) {
            return storedValue
        }
        return provider.models.first ?? provider.defaultModel
    }

    private func storedAPIURL(for provider: AIProvider) -> String {
        let scoped = modelContext.setting("api_url_\(provider.rawValue)")
        if !scoped.isEmpty { return scoped }
        return compatibleLegacyURL(modelContext.setting("api_url"), for: provider)
    }

    private func storedModel(for provider: AIProvider) -> String {
        let scoped = modelContext.setting("api_model_\(provider.rawValue)")
        let legacy = modelContext.setting("api_model", default: provider.defaultModel)
        return validModel(scoped.isEmpty ? legacy : scoped, for: provider)
    }

    private func compatibleLegacyURL(_ url: String, for provider: AIProvider) -> String {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return provider.defaultURL }
        switch provider {
        case .ollama:
            return value.contains("localhost:11434") || value.contains(":11434") ? value : provider.defaultURL
        case .deepseek:
            return value.contains("deepseek.com") ? value : provider.defaultURL
        case .openai:
            return value.contains("api.openai.com") ? value : provider.defaultURL
        case .claude:
            return value.contains("anthropic.com") ? value : provider.defaultURL
        case .volcano:
            return value.contains("volces.com") ? value : provider.defaultURL
        case .gemini:
            return value.contains("googleapis.com") ? value : provider.defaultURL
        }
    }

    #if os(iOS)
    private var ollamaLANTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("Local network"))
                .font(.appCaptionMedium)
            Text(L.t("Keep iPhone and Mac on the same Wi-Fi, then use the Mac LAN IP."))
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
            Text("OLLAMA_HOST=0.0.0.0 ollama serve")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.appGreen)
                .padding(10)
                .background(Color.appField)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("\(L.t("Local IP")): \(NetworkUtils.localIPAddresses().first ?? L.t("Unknown"))")
                .font(.appSmall)
                .foregroundStyle(Color.appMuted)
        }
        .padding(14)
        .background(Color.appField)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    #endif

    private func testConnection() async {
        guard save() else { return }
        connectionTestResult = L.t("Testing...")
        do {
            let config = AIService.config(from: modelContext)
            _ = try await AIService.callAIModel(config: config, systemPrompt: "Reply with the single word OK.", question: "Connection test", maxTokens: 64)
            connectionTestResult = String(format: L.t("✅ Connection successful: connected directly to %@"), provider.label)
        } catch {
            connectionTestResult = "\(L.t("Connection failed")): \(error.localizedDescription)"
        }
    }

    private func saveASRConfiguration(showConfirmation: Bool = true) {
        UserDefaults.standard.set(asrProviderRaw, forKey: AppPreferenceKey.asrProvider)
        UserDefaults.standard.set(asrResourceID, forKey: "asr_volcano_resource_id")
        do {
            try KeychainStore.save(
                asrAppID.trimmingCharacters(in: .whitespacesAndNewlines),
                account: "asr-volcano-app-key"
            )
            try KeychainStore.save(
                asrAccessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                account: "asr-volcano-access-key"
            )
            if showConfirmation {
                asrConnectionTestResult = L.t("Configuration saved.")
            }
        } catch {
            asrConnectionTestResult = error.localizedDescription
        }
    }

    @MainActor
    private func testASRConnection() async {
        saveASRConfiguration(showConfirmation: false)
        isTestingASR = true
        asrConnectionTestResult = L.t("Testing...")
        defer { isTestingASR = false }

        if asrProviderRaw == ASRProvider.apple.rawValue {
            let granted = await SpeechEngine().requestPermissions()
            asrConnectionTestResult = granted
                ? L.t("✅ Apple on-device speech recognition is available.")
                : L.t("Allow microphone and speech-recognition access in System Settings first.")
            return
        }

        let config = VolcanoASREngine.Config(
            appID: asrAppID.trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken: asrAccessToken.trimmingCharacters(in: .whitespacesAndNewlines),
            resourceID: asrResourceID,
            language: "zh-CN"
        )
        asrConnectionTestResult = await VolcanoASREngine.testConnection(config: config)
    }

}
