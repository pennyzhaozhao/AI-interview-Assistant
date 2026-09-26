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
            model: provider.models.contains(storedModel) ? storedModel : provider.defaultModel
        )
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

    static func streamResponse(
        config: APIConfig,
        systemPrompt: String,
        question: String,
        maxTokens: Int = 400,
        onToken: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (String) -> Void
    ) async throws {
        try validateCredentials(config)
        switch config.provider {
        case .claude:
            try await streamClaude(config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens, onToken: onToken, onComplete: onComplete)
        case .ollama, .openai, .deepseek, .volcano:
            try await streamOpenAICompatible(config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens, onToken: onToken, onComplete: onComplete)
        case .gemini:
            let text = try await completeGemini(config: config, systemPrompt: systemPrompt, question: question, maxTokens: maxTokens)
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
            "messages": [["role": "user", "content": question]]
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
        maxTokens: Int
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
            "contents": [["role": "user", "parts": [["text": question]]]],
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
                ["role": "user", "content": "Interview question: \(question)"]
            ],
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
