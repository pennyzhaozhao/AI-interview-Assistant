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
            Text("语音识别与 LLM 分开配置。所有凭证只保存在本机钥匙串，请求直接发送给对应服务商。")
                .font(.appCaption)
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var speechRecognitionSection: some View {
        configCard(
            title: "语音识别",
            subtitle: "用于实时识别面试官语音。豆包语音识别使用 App ID 与 Access Token；Apple 本地识别无需凭证。"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                configRow(title: "识别引擎") {
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
                        TextField("从豆包语音控制台的应用信息中获取", text: $asrAppID)
                            .textFieldStyle(.plain)
                            .darkField()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Access Token")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                        SecureField("从豆包语音控制台的应用信息中获取", text: $asrAccessToken)
                            .textFieldStyle(.plain)
                            .darkField()
                    }

                    configRow(title: "识别模型") {
                        PremiumMenuPicker(
                            selection: $asrResourceID,
                            options: [
                                ("volc.seedasr.sauc.duration", "豆包流式语音 2.0 · 小时版"),
                                ("volc.seedasr.sauc.concurrent", "豆包流式语音 2.0 · 并发版"),
                                ("volc.bigasr.sauc.duration", "流式语音 1.0 · 小时版")
                            ],
                            minWidth: isCompact ? 220 : 320
                        )
                    }

                    Text("推荐选择 2.0 小时版。请先在豆包语音控制台创建应用并开通对应模型，然后复制该应用的 App ID 和 Access Token。")
                        .font(.appSmall)
                        .foregroundStyle(Color.appMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Link("查看豆包双向流式语音识别文档", destination: URL(string: "https://docs.volcengine.com/docs/DoubaoVoice/bidirectional-streaming-automatic-speech-recognition-websocket?lang=zh")!)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appPrimary)
                }

                HStack(spacing: 12) {
                    Button(isTestingASR ? "正在测试..." : "测试连接") {
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
        configCard(title: L.t("Connection"), subtitle: "API Key 只保存在本机钥匙串，不会上传到 InterviewAssistant 服务。Ollama 通常无需 Key。") {
            VStack(alignment: .leading, spacing: 14) {
                TextField(apiURLPlaceholder, text: $apiURL)
                    .textFieldStyle(.plain)
                    .darkField()
                SecureField("API Key（Ollama 可留空）", text: $apiKey)
                    .textFieldStyle(.plain)
                    .darkField()
                Text("直接连接：\(provider.label)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.appMuted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appField)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.input, style: .continuous))

                HStack(spacing: 12) {
                    Button("测试连接") {
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
            connectionTestResult = "✅ 连接成功：已直接连接到 \(provider.label)"
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
                ? "✅ Apple 本地语音识别可以使用。"
                : "需要先在系统设置中允许麦克风和语音识别权限。"
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
