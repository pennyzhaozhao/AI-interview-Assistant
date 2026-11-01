import Foundation

/// AI processing for knowledge bases: resume → Markdown + summary + skills, and project summaries.
/// Mirrors Windows `KnowledgeAssistant.cs` so both apps behave the same.
enum KnowledgeAssistant {
    struct ResumeDigest {
        let summary: String
        let skills: [String]
    }

    /// Turns text extracted from a PDF / Word resume into clean Markdown, keeping every fact.
    @MainActor
    static func resumeToMarkdown(_ rawText: String, config: APIConfig) async throws -> String {
        let system = """
        You convert resume text extracted from PDF or Word files into clean Markdown.
        Keep every fact exactly: names, dates, companies, schools, numbers, metrics, links, and wording.
        Do not summarize, translate, add, or invent anything. Fix only broken line wraps and bullet characters.
        Use "# Name", "## Section" headings and "-" bullets. Output Markdown only, with no code fences.
        """
        let markdown = try await AIService.callAIModel(config: config, systemPrompt: system, question: String(rawText.prefix(24_000)), maxTokens: 4000)
        return stripFences(markdown)
    }

    /// Short profile summary plus a skills list. Both follow the resume's own language, not the app language.
    @MainActor
    static func digestResume(_ markdown: String, config: APIConfig) async throws -> ResumeDigest {
        let language = detectLanguage(markdown)
        let system = """
        You prepare interview context from a candidate's resume. Return valid JSON only:
        {"summary":"...","skills":["...","..."]}
        - summary: 120-220 words, written in \(language) — the same language as the resume (keep technical terms, company and school names as written).
          Cover role focus, strongest achievements with their real numbers, education, work history, core technologies, certifications.
          Use only facts from the resume; never invent.
        - skills: 8-20 concise skill names actually supported by the resume (languages, frameworks, tools, methods, domains),
          most relevant first, no duplicates, each at most 4 words. Write each skill the way the resume writes it
          (technical terms keep their usual English form); do not translate skills into another language.
        """
        let raw = try await AIService.callAIModel(config: config, systemPrompt: system, question: String(markdown.prefix(24_000)), maxTokens: 1500)
        guard let data = extractJSON(raw).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            throw NSError(domain: "InterviewAssistant", code: 11, userInfo: [NSLocalizedDescriptionKey: L.t("The AI did not return a summary.")])
        }
        let skills = (json["skills"] as? [Any])?.compactMap { $0 as? String } ?? []
        return ResumeDigest(summary: summary, skills: normalizeSkills(skills))
    }

    /// One or two sentences describing a GitHub project, in the README's language.
    @MainActor
    static func summarizeProject(name: String, readme: String, description: String, config: APIConfig) async throws -> String {
        let language = detectLanguage("\(description)\n\(readme)")
        let system = """
        You summarize a candidate's GitHub project for interview preparation.
        Write 1-2 sentences in \(language) (the language of the README): what it does, the main technical approach or stack, and any concrete result or scale mentioned.
        Use only the supplied text. Output plain text only.
        """
        let question = "Repository: \(name)\nDescription: \(description)\n\nREADME:\n\(readme.prefix(12_000))"
        return try await AIService.callAIModel(config: config, systemPrompt: system, question: question, maxTokens: 400)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Simplified Chinese" when CJK characters make up a meaningful share of the text, otherwise "English".
    static func detectLanguage(_ text: String) -> String {
        var cjk = 0
        var latin = 0
        for scalar in text.prefix(20_000).unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: cjk += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        if cjk + latin < 40 { return AppLanguage.current == .chinese ? "Simplified Chinese" : "English" }
        // One Chinese character carries roughly as much as a short English word (~4 letters).
        return Double(cjk * 4) >= Double(latin) * 0.6 ? "Simplified Chinese" : "English"
    }

    static func normalizeSkills(_ skills: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•·,，、"))
        for skill in skills {
            let clean = skill.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: trimSet)
            guard !clean.isEmpty, clean.count <= 40, seen.insert(clean.lowercased()).inserted else { continue }
            result.append(clean)
        }
        return result
    }

    /// Heuristic used to offer "set as resume" when a file is uploaded as general material.
    static func looksLikeResume(fileName: String, text: String) -> Bool {
        let name = fileName.lowercased()
        if name.contains("resume") || name.contains("cv") || name.contains("简历") || name.contains("履历") { return true }
        let lower = String(text.prefix(4000)).lowercased()
        let markers = ["education", "experience", "skills", "教育", "工作经历", "实习经历", "项目经历", "专业技能"]
        return markers.filter { lower.contains($0) }.count >= 3
    }

    private static func stripFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let firstBreak = trimmed.firstIndex(of: "\n") { trimmed = String(trimmed[trimmed.index(after: firstBreak)...]) }
            if trimmed.hasSuffix("```") { trimmed = String(trimmed.dropLast(3)) }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSON(_ raw: String) -> String {
        guard let first = raw.firstIndex(of: "{"), let last = raw.lastIndex(of: "}"), first < last else { return raw }
        return String(raw[first...last])
    }
}

/// Imports public GitHub repositories (README + metadata) as knowledge-base projects.
enum GitHubProjectImporter {
    struct ProjectInfo {
        let name: String
        let url: String
        let description: String
        let language: String
        let stars: Int
        let readme: String
    }

    static func isGitHubURL(_ value: String) -> Bool {
        guard let host = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
    }

    /// A repository link returns one project; a profile link returns the owner's most recent non-fork repositories.
    static func fetch(_ urlString: String, profileLimit: Int = 6) async throws -> [ProjectInfo] {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw importError(L.t("Enter a valid GitHub link.")) }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { throw importError(L.t("Enter a valid GitHub link.")) }
        if parts.count == 1 {
            let json = try await getJSON("https://api.github.com/users/\(parts[0])/repos?sort=pushed&per_page=30")
            let names = (json as? [[String: Any]] ?? [])
                .filter { ($0["fork"] as? Bool) != true }
                .compactMap { $0["name"] as? String }
                .prefix(profileLimit)
            var projects: [ProjectInfo] = []
            for name in names { projects.append(try await fetchRepository(owner: parts[0], repo: name)) }
            return projects
        }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return [try await fetchRepository(owner: parts[0], repo: repo)]
    }

    static func buildContent(_ project: ProjectInfo) -> String {
        var lines = ["Repository: \(project.url)"]
        if !project.description.isEmpty { lines.append("Description: \(project.description)") }
        if !project.language.isEmpty { lines.append("Main language: \(project.language)") }
        if !project.readme.isEmpty { lines.append(""); lines.append(project.readme) }
        return lines.joined(separator: "\n")
    }

    static func buildMeta(_ project: ProjectInfo) -> String {
        var parts: [String] = []
        if !project.language.isEmpty { parts.append(project.language) }
        if project.stars > 0 { parts.append("★ \(project.stars)") }
        return parts.joined(separator: " · ")
    }

    private static func fetchRepository(owner: String, repo: String) async throws -> ProjectInfo {
        let json = try await getJSON("https://api.github.com/repos/\(owner)/\(repo)") as? [String: Any] ?? [:]
        var readme = ""
        if let readmeURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/readme") {
            var request = URLRequest(url: readmeURL)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
            request.setValue("InterviewAssistant", forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                readme = String(decoding: data.prefix(30_000), as: UTF8.self)
            }
        }
        return ProjectInfo(
            name: (json["name"] as? String) ?? repo,
            url: (json["html_url"] as? String) ?? "https://github.com/\(owner)/\(repo)",
            description: (json["description"] as? String) ?? "",
            language: (json["language"] as? String) ?? "",
            stars: (json["stargazers_count"] as? Int) ?? 0,
            readme: readme
        )
    }

    private static func getJSON(_ urlString: String) async throws -> Any {
        guard let url = URL(string: urlString) else { throw importError(L.t("Enter a valid GitHub link.")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("InterviewAssistant", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try JSONSerialization.jsonObject(with: data)
        case 404: throw importError(L.t("GitHub repository not found or not public."))
        case 403, 429: throw importError(L.t("GitHub rate limit reached. Try again in a few minutes."))
        default: throw importError("GitHub HTTP \(status)")
        }
    }

    private static func importError(_ message: String) -> NSError {
        NSError(domain: "InterviewAssistant.GitHub", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Builds the knowledge-base section of interview prompts from the structured knowledge bases.
enum KnowledgeFormatter {
    static func build(_ knowledgeBases: [KnowledgeBase], activeIDs: [UUID], limit: Int = 24_000) -> String {
        let active = Set(activeIDs)
        var blocks: [String] = []
        for kb in knowledgeBases where active.contains(kb.id) {
            var lines = ["[\(kb.name)]"]
            let entries = kb.entries.filter(\.isEnabled)
            if let resume = entries.first(where: { $0.kind == KnowledgeEntryKind.resume }) {
                let summary = resume.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty { lines += ["Resume summary:", summary, ""] }
                let content = resume.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { lines += ["Resume (full text, use for specific details and numbers):", content, ""] }
            }
            let skills = kb.skills
            if !skills.isEmpty { lines += ["Skills: " + skills.joined(separator: ", "), ""] }
            let projects = entries.filter { $0.kind == KnowledgeEntryKind.project }.sorted { $0.createdAt < $1.createdAt }
            if !projects.isEmpty {
                lines.append("Projects:")
                for project in projects {
                    let meta = project.meta.isEmpty ? "" : " (\(project.meta))"
                    lines.append("- \(project.title)\(meta): \(project.summary)")
                    if !project.content.isEmpty {
                        lines.append("  Details: " + String(project.content.replacingOccurrences(of: "\n", with: " ").prefix(2500)))
                    }
                }
                lines.append("")
            }
            for material in entries where material.kind == KnowledgeEntryKind.material {
                let content = material.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                lines += ["\(material.title):", content, ""]
            }
            if lines.count > 1 { blocks.append(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return String(blocks.joined(separator: "\n\n").prefix(limit))
    }

    /// Per-knowledge-base custom instructions, appended to the system prompt.
    static func instructionsBlock(_ knowledgeBases: [KnowledgeBase], activeIDs: [UUID]) -> String {
        let active = Set(activeIDs)
        let text = knowledgeBases
            .filter { active.contains($0.id) }
            .map { $0.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? "" : "\n\nCANDIDATE'S OWN ANSWER PREFERENCES (follow them unless they conflict with the rules above):\n\(text)"
    }

    static func skills(_ knowledgeBases: [KnowledgeBase], activeIDs: [UUID]) -> [String] {
        let active = Set(activeIDs)
        return KnowledgeAssistant.normalizeSkills(knowledgeBases.filter { active.contains($0.id) }.flatMap(\.skills))
    }
}
