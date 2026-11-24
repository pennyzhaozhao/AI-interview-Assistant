import Foundation
import SwiftData

enum AIProvider: String, CaseIterable, Identifiable {
    case ollama
    case volcano
    case claude
    case openai
    case deepseek
    case gemini

    static let productionDefault: AIProvider = .deepseek
    static let productionOptions: [AIProvider] = [.ollama, .deepseek, .openai, .claude, .gemini, .volcano]

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ollama: "Ollama 本地"
        case .volcano: "火山方舟 (Volcano Ark)"
        case .claude: "Claude (Anthropic)"
        case .openai: "OpenAI / ChatGPT"
        case .deepseek: "DeepSeek"
        case .gemini: "Gemini"
        }
    }
    var shortLabel: String {
        switch self {
        case .ollama: "Ollama"
        case .volcano: "火山方舟"
        case .claude: "Claude"
        case .openai: "OpenAI"
        case .deepseek: "DeepSeek"
        case .gemini: "Gemini"
        }
    }
    var defaultOllamaURL: String {
        #if os(macOS)
        return "http://localhost:11434/v1"
        #else
        return ""
        #endif
    }
    var defaultURL: String {
        switch self {
        case .ollama: defaultOllamaURL
        case .volcano: "https://ark.cn-beijing.volces.com/api/v3"
        case .claude: "https://api.anthropic.com/v1/messages"
        case .openai: "https://api.openai.com/v1"
        case .deepseek: "https://api.deepseek.com"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        }
    }
    var defaultModel: String {
        switch self {
        case .ollama: "qwen2.5:7b"
        case .volcano: "doubao-seed-1-8-251228"
        case .claude: "claude-sonnet-4-5"
        case .openai: "gpt-4.1-mini"
        case .deepseek: "deepseek-flash"
        case .gemini: "gemini-2.0-flash"
        }
    }
    var models: [String] {
        switch self {
        case .ollama: ["qwen2.5:7b", "llama3.1:8b", "qwen2.5:14b"]
        case .volcano: ["doubao-seed-1-8-251228", "doubao-seed-1-6-250615"]
        case .claude: ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"]
        case .openai: ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o"]
        case .deepseek: ["deepseek-flash", "deepseek-v4-pro"]
        case .gemini: ["gemini-2.0-flash", "gemini-2.5-pro"]
        }
    }
    /// Whether `model` on this provider accepts an image next to the text. Screenshot
    /// questions are sent with the image to these, so figure options and the real option
    /// layout are visible instead of relying on OCR alone. DeepSeek: `deepseek-flash` reads
    /// images (Chat Completions `image_url`), `deepseek-v4-pro` does not. The default local
    /// Ollama models are text-only. A wrong guess only costs a text-only retry.
    func supportsImageInput(model: String) -> Bool {
        switch self {
        case .openai, .claude, .gemini, .volcano:
            return true
        case .deepseek:
            let name = model.lowercased()
            return name.hasPrefix("deepseek-flash") || name.contains("vision")
        case .ollama:
            return false
        }
    }

    var help: String {
        switch self {
        case .ollama: "本地 Ollama，默认不需要 API Key。"
        case .volcano: "火山方舟 API 地址通常填写到 /api/v3，使用 OpenAI 兼容调用。"
        case .claude: "Claude 使用 Anthropic Messages API。"
        case .openai: "OpenAI 官方 API，填写 API Key 后使用。"
        case .deepseek: "DeepSeek 使用 OpenAI 兼容调用。API 地址填写 https://api.deepseek.com，并填入 DeepSeek API Key。"
        case .gemini: "Gemini 使用 Google AI API，填写 API Key 后使用。"
        }
    }
}

extension APIConfig {
    var supportsImageInput: Bool { provider.supportsImageInput(model: model) }
}

struct APIConfig {
    var provider: AIProvider
    var apiURL: String
    var apiKey: String
    var model: String
}

enum AIService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    static func config(from context: ModelContext) -> APIConfig {
        let storedProvider = AIProvider(rawValue: context.setting("api_provider", default: AIProvider.productionDefault.rawValue)) ?? AIProvider.productionDefault
        let provider = AIProvider.productionOptions.contains(storedProvider) ? storedProvider : AIProvider.productionDefault
        let providerURL = context.setting("api_url_\(provider.rawValue)")
        let legacyURL = context.setting("api_url")
        let apiURL = providerURL.isEmpty ? compatibleLegacyURL(legacyURL, for: provider) : providerURL
        let providerModel = context.setting("api_model_\(provider.rawValue)")
        let storedModel = providerModel.isEmpty ? context.setting("api_model", default: provider.defaultModel) : providerModel
        return APIConfig(
            provider: provider,
            apiURL: apiURL.isEmpty ? provider.defaultURL : apiURL,
            apiKey: apiKey(for: provider),
            // Any model the user picked (built-in, fetched from the provider, or typed in) is used as is.
            model: storedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? provider.defaultModel
                : storedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: Model catalog

    /// Models to offer for `provider`: the list last fetched from the provider (newest names first),
    /// then the built-in suggestions, plus `current` so a custom choice never disappears.
    static func availableModels(for provider: AIProvider, including current: String = "") -> [String] {
        var result: [String] = []
        for name in cachedModels(for: provider) + provider.models + [current] {
            let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !result.contains(value) { result.append(value) }
        }
        return result
    }

    static func cachedModels(for provider: AIProvider) -> [String] {
        UserDefaults.standard.stringArray(forKey: "ai_models_\(provider.rawValue)") ?? []
    }

    static func modelsRefreshedAt(for provider: AIProvider) -> Date? {
        UserDefaults.standard.object(forKey: "ai_models_refreshed_\(provider.rawValue)") as? Date
    }

    /// Fetches the provider's current model list (its `/models` endpoint) and caches it, so newly
    /// released models appear without an app update. Throws when the provider offers no list.
    @discardableResult
    static func refreshModels(config: APIConfig) async throws -> [String] {
        var request: URLRequest
        switch config.provider {
        case .claude:
            var base = config.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            if base.hasSuffix("/messages") { base.removeLast("/messages".count) }
            guard let url = URL(string: "\(base)/models?limit=100") else { throw catalogError(L.t("The API URL is invalid.")) }
            request = URLRequest(url: url)
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            let base = config.apiURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let key = config.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            guard let url = URL(string: "\(base)/models?pageSize=200&key=\(key)") else { throw catalogError(L.t("The API URL is invalid.")) }
            request = URLRequest(url: url)
        case .ollama, .openai, .deepseek, .volcano:
            let base = normalizeAPIBase(config.apiURL)
            guard !base.isEmpty, let url = URL(string: "\(base)/models") else { throw catalogError(L.t("The API URL is invalid.")) }
            request = URLRequest(url: url)
            request.setValue("Bearer \(config.apiKey.isEmpty ? "ollama" : config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw catalogError(String(format: L.t("This provider did not return a model list (HTTP %d)."), status))
        }
        var names: [String]
        if config.provider == .gemini {
            names = (json["models"] as? [[String: Any]] ?? []).compactMap { model in
                let methods = model["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent"), let name = model["name"] as? String else { return nil }
                return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            }
        } else {
            names = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        names = names.filter { isChatModel($0, provider: config.provider) }.sorted(by: >)
        guard !names.isEmpty else { throw catalogError(L.t("This provider did not return a model list.")) }
        UserDefaults.standard.set(names, forKey: "ai_models_\(config.provider.rawValue)")
        UserDefaults.standard.set(Date(), forKey: "ai_models_refreshed_\(config.provider.rawValue)")
        return names
    }

    /// Drops embedding, image, audio and other non-chat models from a provider's list.
    static func isChatModel(_ id: String, provider: AIProvider) -> Bool {
        let name = id.lowercased()
        let excluded = ["embed", "embedding", "tts", "whisper", "transcribe", "audio", "realtime", "moderation",
                        "dall-e", "image", "imagen", "davinci", "babbage", "search", "computer-use", "rerank", "aqa"]
        if excluded.contains(where: { name.contains($0) }) { return false }
        switch provider {
        case .openai:
            return ["gpt-", "chatgpt-", "o1", "o3", "o4"].contains { name.hasPrefix($0) }
        case .claude:
            return name.hasPrefix("claude")
        case .gemini:
            return name.hasPrefix("gemini")
        case .deepseek, .volcano, .ollama:
            return true
        }
    }

    private static func catalogError(_ message: String) -> NSError {
        NSError(domain: "InterviewAssistant.Models", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Account balance

    /// A short balance line for the connection test, or nil when the provider has no balance API
    /// that works with an API key (OpenAI, Anthropic, Gemini and Volcano Ark only show it in their consoles).
    static func accountBalanceSummary(config: APIConfig) async -> String? {
        guard config.provider == .deepseek else { return nil }
        let base = normalizeAPIBase(config.apiURL)
        guard let url = URL(string: "\(base)/user/balance") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        guard let result = try? await session.data(for: request),
              ((result.1 as? HTTPURLResponse)?.statusCode ?? 0) == 200,
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let infos = json["balance_infos"] as? [[String: Any]], !infos.isEmpty else { return nil }
        let parts = infos.map { info -> String in
            let currency = info["currency"] as? String ?? ""
            let symbol = currency == "CNY" ? "¥" : (currency == "USD" ? "$" : currency + " ")
            let total = info["total_balance"] as? String ?? "\(info["total_balance"] ?? "")"
            let toppedUp = info["topped_up_balance"] as? String
            let granted = info["granted_balance"] as? String
            var line = "\(symbol)\(total)"
            if let toppedUp, let granted {
                line += String(format: L.t(" (top-up %@%@ + granted %@%@)"), symbol, toppedUp, symbol, granted)
            }
            return line
        }
        var summary = String(format: L.t("Account balance: %@"), parts.joined(separator: "; "))
        if json["is_available"] as? Bool == false { summary += L.t(" — insufficient balance") }
        return summary
    }

    private static func apiKey(for provider: AIProvider) -> String {
        KeychainStore.read("api-key-\(provider.rawValue)")
    }

    @MainActor
    static func callAIModel(config: APIConfig, systemPrompt: String, question: String, maxTokens: Int = 900) async throws -> String {
        try validateCredentials(config)
        switch config.provider {
        case .claude:
            return try await completeClaude(config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens)
        case .ollama, .openai, .deepseek, .volcano:
            return try await completeOpenAICompatible(config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens)
        case .gemini:
            return try await completeGemini(config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens)
        }
    }

    private final class TokenFlag: @unchecked Sendable { var value = false }

    /// - Parameter imagesJPEG: optional images (screenshots) sent with the question to providers
    ///   that accept images. If that request fails before any text arrives (for example a
    ///   custom model without vision), the question is retried as text only.
    static func streamResponse(
        config: APIConfig,
        systemPrompt: String,
        question: String,
        maxTokens: Int = 400,
        imagesJPEG: [Data] = [],
        onToken: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (String) -> Void
    ) async throws {
        try validateCredentials(config)
        if !imagesJPEG.isEmpty, config.supportsImageInput {
            let received = TokenFlag()
            do {
                try await dispatchStream(
                    config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens,
                    imagesBase64: imagesJPEG.map { $0.base64EncodedString() },
                    onToken: { token in
                        received.value = true
                        onToken(token)
                    },
                    onComplete: onComplete
                )
                return
            } catch {
                if received.value || error is CancellationError { throw error }
                NSLog("[AIService] image request failed, retrying as text only: %@", error.localizedDescription)
            }
        }
        try await dispatchStream(
            config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens,
            imagesBase64: [], onToken: onToken, onComplete: onComplete
        )
    }

    private static func dispatchStream(
        config: APIConfig,
        systemPrompt: String,
        question: String,
        maxTokens: Int,
        imagesBase64: [String],
        onToken: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (String) -> Void
    ) async throws {
        switch config.provider {
        case .claude:
            try await streamClaude(config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens, imagesBase64: imagesBase64, onToken: onToken, onComplete: onComplete)
        case .ollama, .openai, .deepseek, .volcano:
            try await streamOpenAICompatible(config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens, imagesBase64: imagesBase64, onToken: onToken, onComplete: onComplete)
        case .gemini:
            let text = try await completeGemini(config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens, imagesBase64: imagesBase64)
            await onToken(text)
            await onComplete(text)
        }
    }

    private static func extractOpenAICompatibleText(from json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func streamClaude(
        config: APIConfig,
        systemPrompt: String,
        question: String,
        maxTokens: Int,
        imagesBase64: [String] = [],
        onToken: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (String) -> Void
    ) async throws {
        guard let url = URL(string: config.apiURL), !config.apiURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "InterviewAssistant", code: 2, userInfo: [NSLocalizedDescriptionKey: "API 地址为空或格式错误"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": systemPrompt,
            "messages": [["role": "user", "content": claudeContent(question, imagesBase64: imagesBase64)] as [String: Any]]
        ])

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "InterviewAssistant", code: status, userInfo: [NSLocalizedDescriptionKey: "Claude API 请求失败 (HTTP \(status))"])
        }

        var fullText = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
            let jsonString = String(line.dropFirst(6))
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            if type == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               let token = delta["text"] as? String {
                fullText += token
                await onToken(token)
            } else if type == "message_delta",
                      let delta = json["delta"] as? [String: Any],
                      let token = delta["text"] as? String {
                fullText += token
                await onToken(token)
            }
        }
        let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NSError(domain: "InterviewAssistant", code: 3, userInfo: [NSLocalizedDescriptionKey: "Claude 返回为空，请检查模型名称或 API Key。"])
        }
        await onComplete(text)
    }

    private static func completeClaude(
        config: APIConfig,
        systemPrompt: String,
        question: String,
        maxTokens: Int
    ) async throws -> String {
        guard let url = URL(string: config.apiURL), !config.apiURL.isEmpty else {
            throw NSError(domain: "InterviewAssistant", code: 2, userInfo: [NSLocalizedDescriptionKey: "Claude API 地址为空或格式错误"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": question]]
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first?["text"] as? String else {
            throw NSError(domain: "InterviewAssistant", code: status, userInfo: [NSLocalizedDescriptionKey: "Claude API 请求失败 (HTTP \(status))"])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func completeGemini(
        config: APIConfig,
        systemPrompt: String,
        question: String,
        maxTokens: Int,
        imagesBase64: [String] = []
    ) async throws -> String {
        let base = config.apiURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/models/\(config.model):generateContent?key=\(config.apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else {
            throw NSError(domain: "InterviewAssistant", code: 2, userInfo: [NSLocalizedDescriptionKey: "Gemini API 地址或 API Key 格式错误"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": geminiParts(question, imagesBase64: imagesBase64)] as [String: Any]],
            "generationConfig": ["maxOutputTokens": maxTokens]
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw NSError(domain: "InterviewAssistant", code: status, userInfo: [NSLocalizedDescriptionKey: "Gemini API 请求失败 (HTTP \(status))"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func streamOpenAICompatible(
        config: APIConfig,
        systemPrompt: String,
        question: String,
        maxTokens: Int,
        imagesBase64: [String] = [],
        onToken: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (String) -> Void
    ) async throws {
        let base = normalizeAPIBase(config.apiURL)
        guard !base.isEmpty, let url = URL(string: "\(base)/chat/completions") else {
            throw NSError(domain: "InterviewAssistant", code: 2, userInfo: [NSLocalizedDescriptionKey: "API 地址为空或格式错误"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey.isEmpty ? "ollama" : config.apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": openAIContent("Interview question: \(question)", imagesBase64: imagesBase64)]
            ] as [[String: Any]],
            "max_tokens": maxTokens
        ]
        if config.provider == .deepseek {
            // DeepSeek Flash enables thinking by default. Interview answers need
            // the final content immediately, and short connection tests can spend
            // their entire token budget on reasoning_content otherwise.
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "InterviewAssistant", code: status, userInfo: [NSLocalizedDescriptionKey: "AI API 请求失败 (HTTP \(status))"])
        }

        var fullText = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]",
                  let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }
            let token = delta["content"] as? String ?? ""
            guard !token.isEmpty else { continue }
            fullText += token
            await onToken(token)
        }
        let content = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw NSError(domain: "InterviewAssistant", code: 3, userInfo: [NSLocalizedDescriptionKey: "AI 返回为空，请检查模型名称、API Key 或 API 地址。"])
        }
        await onComplete(content)
    }

    private static func completeOpenAICompatible(
        config: APIConfig,
        systemPrompt: String,
        question: String,
        maxTokens: Int
    ) async throws -> String {
        let base = normalizeAPIBase(config.apiURL)
        guard !base.isEmpty, let url = URL(string: "\(base)/chat/completions") else {
            throw NSError(domain: "InterviewAssistant", code: 2, userInfo: [NSLocalizedDescriptionKey: "API 地址为空或格式错误"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey.isEmpty ? "ollama" : config.apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": config.model,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": question]
            ],
            "max_tokens": maxTokens
        ]
        if config.provider == .openai || config.provider == .deepseek || config.provider == .volcano,
           systemPrompt.localizedCaseInsensitiveContains("valid json") {
            body["response_format"] = ["type": "json_object"]
        }
        if config.provider == .deepseek {
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let message = body.isEmpty ? "AI API 请求失败 (HTTP \(status))" : "AI API 请求失败 (HTTP \(status)): \(body)"
            throw NSError(domain: "InterviewAssistant", code: status, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "InterviewAssistant", code: 4, userInfo: [NSLocalizedDescriptionKey: "AI 响应格式无法解析：\(body.prefix(500))"])
        }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NSError(domain: "InterviewAssistant", code: 3, userInfo: [NSLocalizedDescriptionKey: "AI 返回为空，请检查模型名称、API Key 或 API 地址。"])
        }
        return text
    }

    // MARK: Image content blocks

    private static func openAIContent(_ text: String, imagesBase64: [String]) -> Any {
        guard !imagesBase64.isEmpty else { return text }
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        for image in imagesBase64 {
            blocks.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)"]])
        }
        return blocks
    }

    private static func claudeContent(_ text: String, imagesBase64: [String]) -> Any {
        guard !imagesBase64.isEmpty else { return text }
        var blocks: [[String: Any]] = imagesBase64.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0]]
        }
        blocks.append(["type": "text", "text": text])
        return blocks
    }

    private static func geminiParts(_ text: String, imagesBase64: [String]) -> [[String: Any]] {
        var parts: [[String: Any]] = imagesBase64.map { ["inline_data": ["mime_type": "image/jpeg", "data": $0]] }
        parts.append(["text": text])
        return parts
    }

    private static func normalizeAPIBase(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        for suffix in ["/chat/completions", "/responses", "/messages"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            break
        }
        return value
    }

    private static func compatibleLegacyURL(_ url: String, for provider: AIProvider) -> String {
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

    private static func apiErrorMessage(from json: [String: Any]?, fallback: String) -> String {
        if let error = json?["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = error["code"] as? String, !code.isEmpty {
                return "\(fallback): \(code)"
            }
        }
        if let message = json?["message"] as? String, !message.isEmpty {
            return message
        }
        return fallback
    }

    private static func validateCredentials(_ config: APIConfig) throws {
        guard config.provider == .ollama
                || !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "InterviewAssistant",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "未读取到 \(config.provider.shortLabel) API Key。请重新填写并保存；如果仍然出现此提示，请检查 App 签名与钥匙串权限。"]
            )
        }
    }
}
