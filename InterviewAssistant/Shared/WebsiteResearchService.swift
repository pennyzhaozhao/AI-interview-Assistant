import Foundation

enum WebsiteResearchService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()

    static func researchCompany(from input: String, config: APIConfig) async throws -> String {
        let urlString = normalizedURL(input)
        let html = try await fetchRawText(urlString, maxCharacters: 350_000)
        let context = try await websiteContext(from: html, baseURLString: urlString)
        guard !context.isEmpty else {
            throw NSError(
                domain: "InterviewAssistant",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: L.t("No content suitable for analysis was extracted from the company website.")]
            )
        }
        return try await summarizeCompany(context: context, sourceURL: urlString, config: config)
    }

    private static func normalizedURL(_ input: String) -> String {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("http://") || clean.lowercased().hasPrefix("https://") {
            return clean
        }
        return "https://\(clean)"
    }

    private static func fetchRawText(_ urlString: String, maxCharacters: Int) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLFetcher.FetchError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 InterviewAssistant/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLFetcher.FetchError.httpStatus(http.statusCode)
        }
        let text = String(data: data.prefix(maxCharacters), encoding: .utf8) ?? String(decoding: data.prefix(maxCharacters), as: UTF8.self)
        return String(text.prefix(maxCharacters))
    }

    private static func websiteContext(from html: String, baseURLString: String) async throws -> String {
        var parts: [String] = []
        let metadata = extractMetadata(from: html)
        if !metadata.isEmpty {
            parts.append("Metadata:\n\(metadata)")
        }

        let jsonText = extractJSONScriptText(from: html)
        if !jsonText.isEmpty {
            parts.append("Embedded JSON / app data:\n\(jsonText)")
        }

        let visible = cleanHTMLText(html)
        if !visible.isEmpty {
            parts.append("Visible page text:\n\(visible)")
        }

        let scriptText = try await fetchScriptStringContext(from: html, baseURLString: baseURLString)
        if !scriptText.isEmpty {
            parts.append("JavaScript text clues:\n\(scriptText)")
        }

        return parts
            .joined(separator: "\n\n---\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func summarizeCompany(context: String, sourceURL: String, config: APIConfig) async throws -> String {
        let systemPrompt = """
        You are a company research analyst helping a candidate prepare for an interview.
        Write in Simplified Chinese. Use only the supplied website text. If a detail is uncertain, say it looks like or appears to be, not as a fact.
        The output should be useful for answering “你对我们公司有什么了解？” in an interview.
        Avoid generic website-summary language. Extract business model, target customers, services, market, proof points, and interview talking points.
        """
        let question = """
        Source URL: \(sourceURL)

        Website text:
        \(context.prefix(24_000))

        Please produce a concise but rich company research note with this structure:
        1. 一句话概括这家公司
        2. 目标客户 / 服务对象
        3. 主要业务或产品
        4. 关键卖点、数据或资源
        5. 面试中可以怎么回答“你对我们公司有什么了解”
        6. 候选人可以追问公司的 3 个问题
        """
        let result = try await AIService.callAIModel(
            config: config,
            systemPrompt: systemPrompt,
            question: question,
            maxTokens: 1200
        )
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "InterviewAssistant",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: L.t("The current AI provider did not return company information.")]
            )
        }
        return result
    }

    private static func extractMetadata(from html: String) -> String {
        var lines: [String] = []
        if let title = firstMatch(#"(?is)<title[^>]*>(.*?)</title>"#, in: html) {
            lines.append("title: \(decodeEntities(stripTags(title)))")
        }
        let patterns = [
            #"(?is)<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["'][^>]*>"#,
            #"(?is)<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["'][^>]*>"#,
            #"(?is)<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)["'][^>]*>"#,
            #"(?is)<meta[^>]+name=["']keywords["'][^>]+content=["']([^"']+)["'][^>]*>"#
        ]
        for pattern in patterns {
            lines.append(contentsOf: matches(pattern, in: html).map { decodeEntities($0) })
        }
        return uniqueLines(lines).joined(separator: "\n")
    }

    private static func extractJSONScriptText(from html: String) -> String {
        let scripts = matches(#"(?is)<script[^>]*type=["']application/json["'][^>]*>(.*?)</script>"#, in: html)
            + matches(#"(?is)<script[^>]*id=["']__NEXT_DATA__["'][^>]*>(.*?)</script>"#, in: html)
        let cleaned = scripts
            .map { decodeEntities($0) }
            .map { $0.replacingOccurrences(of: #"["{}:,\\]+"#, with: " ", options: .regularExpression) }
            .map(normalizeWhitespace)
            .filter { $0.count > 30 }
        return uniqueLines(cleaned).joined(separator: "\n").prefixString(8_000)
    }

    private static func cleanHTMLText(_ html: String) -> String {
        let text = html
            .replacingOccurrences(of: #"(?is)<script.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style.*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<svg.*?</svg>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "\n", options: .regularExpression)
        return normalizeWhitespace(decodeEntities(text)).prefixString(8_000)
    }

    private static func fetchScriptStringContext(from html: String, baseURLString: String) async throws -> String {
        guard let baseURL = URL(string: baseURLString) else { return "" }
        let sources = matches(#"(?is)<script[^>]+src=["']([^"']+\.js[^"']*)["'][^>]*>"#, in: html)
            .compactMap { source -> URL? in
                if source.hasPrefix("http") { return URL(string: source) }
                return URL(string: source, relativeTo: baseURL)?.absoluteURL
            }
            .filter { $0.host == baseURL.host }
            .prefix(8)

        var snippets: [String] = []
        for url in sources {
            guard let text = try? await fetchRawText(url.absoluteString, maxCharacters: 80_000) else { continue }
            let strings = matches(#""([^"\\]{12,180})""#, in: text)
                + matches(#"'([^'\\]{12,180})'"#, in: text)
            let useful = strings
                .map(decodeEntities)
                .map(normalizeWhitespace)
                .filter(isUsefulScriptString)
                .prefix(80)
            snippets.append(contentsOf: useful)
            if snippets.count > 180 { break }
        }
        return uniqueLines(snippets).joined(separator: "\n").prefixString(10_000)
    }

    private static func isUsefulScriptString(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard value.count >= 12 else { return false }
        if lower.contains("function") || lower.contains("webpack") || lower.contains("chunk") { return false }
        if lower.contains(".css") || lower.contains(".svg") || lower.contains("http") { return false }
        if value.range(of: #"[A-Za-z\u{4e00}-\u{9fff}]"#, options: .regularExpression) == nil { return false }
        return true
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text).first
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { line in
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return false }
            return seen.insert(clean).inserted
        }
    }
}

private extension String {
    func prefixString(_ count: Int) -> String {
        String(prefix(count))
    }
}
