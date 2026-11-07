import Foundation

/// AI processing for knowledge bases: resume → Markdown + summary + skills, and project summaries.
/// Mirrors Windows `KnowledgeAssistant.cs` so both apps behave the same.
enum KnowledgeAssistant {
    struct ResumeDigest {
        let summary: String
        let skills: [String]
        let projects: [ResumeProject]
    }

    /// A project the resume links to (GitHub repository, demo site, app page…).
    struct ResumeProject {
        let name: String
        let url: String
        let description: String
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
        {"summary":"...","skills":["...","..."],"projects":[{"name":"...","url":"https://...","description":"..."}]}
        - summary: 120-220 words, written in \(language) — the same language as the resume (keep technical terms, company and school names as written).
          Cover role focus, strongest achievements with their real numbers, education, work history, core technologies, certifications.
          Use only facts from the resume; never invent.
        - skills: 8-20 concise skill names actually supported by the resume (languages, frameworks, tools, methods, domains),
          most relevant first, no duplicates, each at most 4 words. Write each skill the way the resume writes it
          (technical terms keep their usual English form); do not translate skills into another language.
        - projects: every project in the resume that has its own link (GitHub repository, live demo, app store page, paper, website).
          name: the project name as written; url: the exact link from the resume (never invent or complete a link);
          description: one sentence in \(language) from the resume text. Do not include personal profile links
          (LinkedIn, personal homepage, email, a GitHub profile without a repository). Use [] when there are none.
        """
        let raw = try await AIService.callAIModel(config: config, systemPrompt: system, question: String(markdown.prefix(24_000)), maxTokens: 1500)
        guard let data = extractJSON(raw).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            throw NSError(domain: "InterviewAssistant", code: 11, userInfo: [NSLocalizedDescriptionKey: L.t("The AI did not return a summary.")])
        }
        let skills = (json["skills"] as? [Any])?.compactMap { $0 as? String } ?? []
        var projects: [ResumeProject] = []
        for item in (json["projects"] as? [Any])?.compactMap({ $0 as? [String: Any] }) ?? [] {
            func field(_ name: String) -> String { ((item[name] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let url = field("url")
            // Only links that really appear in the resume.
            guard let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            let bare = url.hasSuffix("/") ? String(url.dropLast()) : url
            guard markdown.range(of: bare, options: .caseInsensitive) != nil else { continue }
            projects.append(ResumeProject(name: field("name"), url: url, description: field("description")))
        }
        // Any GitHub repository link the model missed.
        for url in findGitHubRepositoryLinks(markdown) where !projects.contains(where: { sameURL($0.url, url) }) {
            projects.append(ResumeProject(name: "", url: url, description: ""))
        }
        return ResumeDigest(summary: summary, skills: normalizeSkills(skills), projects: projects)
    }

    /// github.com/owner/repo links in the text (profile-only links are left out).
    static func findGitHubRepositoryLinks(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:https?://)?(?:www\.)?github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)"#, options: [.caseInsensitive]) else { return [] }
        let excluded: Set<String> = ["orgs", "topics", "features", "about", "sponsors"]
        var result: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let ownerRange = Range(match.range(at: 1), in: text), let repoRange = Range(match.range(at: 2), in: text) else { continue }
            let owner = String(text[ownerRange])
            var repo = String(text[repoRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)"))
            if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
            guard !repo.isEmpty, !excluded.contains(owner.lowercased()) else { continue }
            let url = "https://github.com/\(owner)/\(repo)"
            if !result.contains(where: { sameURL($0, url) }) { result.append(url) }
        }
        return result
    }

    /// Compares links ignoring scheme, "www.", a trailing slash and case.
    static func sameURL(_ lhs: String, _ rhs: String) -> Bool {
        normalizeURL(lhs).caseInsensitiveCompare(normalizeURL(rhs)) == .orderedSame
    }

    private static func normalizeURL(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        for prefix in ["https://", "http://"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.lowercased().hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value
    }

    /// "Save original only": tidy extracted text locally (no AI).
    static func cleanResumeText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        text = text.replacingOccurrences(of: #"[ \x{00A0}]+\n"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^[ \t]*[•●▪◦·]\s*"#, with: "- ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when an AI provider is set up (Ollama needs no key).
    static func isAIConfigured(_ config: APIConfig) -> Bool {
        config.provider == .ollama || !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
///
/// Small knowledge bases are sent in full. Once the enabled content is larger than
/// `retrievalThreshold`, only a compact profile (resume summary, skills, project list) is always
/// sent, plus the passages that best match the current question (local BM25 retrieval, no
/// embedding API or extra cost). This keeps token use roughly constant however much material
/// the user imports.
enum KnowledgeFormatter {
    /// Above this many characters of enabled knowledge, switch from "send everything" to retrieval.
    static let retrievalThreshold = 12_000
    /// Character budget for retrieved passages.
    static let retrievalBudget = 7_000

    static func build(_ knowledgeBases: [KnowledgeBase], activeIDs: [UUID], limit: Int = 24_000, query: String? = nil) -> String {
        let active = Set(activeIDs)
        let selected = knowledgeBases.filter { active.contains($0.id) }
        let cleanQuery = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanQuery.isEmpty, totalCharacters(selected) > retrievalThreshold {
            return buildRetrieved(selected, query: cleanQuery, limit: limit)
        }
        return buildFull(selected, limit: limit)
    }

    private static func totalCharacters(_ bases: [KnowledgeBase]) -> Int {
        bases.reduce(0) { sum, kb in
            sum + kb.entries.filter(\.isEnabled).reduce(0) { $0 + $1.content.count + $1.summary.count }
        }
    }

    private static func buildFull(_ bases: [KnowledgeBase], limit: Int) -> String {
        var blocks: [String] = []
        for kb in bases {
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

    /// Compact profile for every knowledge base + the passages most relevant to `query`.
    private static func buildRetrieved(_ bases: [KnowledgeBase], query: String, limit: Int) -> String {
        var blocks: [String] = []
        var chunks: [KnowledgeChunk] = []
        for kb in bases {
            var lines = ["[\(kb.name)]"]
            let entries = kb.entries.filter(\.isEnabled)
            if let resume = entries.first(where: { $0.kind == KnowledgeEntryKind.resume }) {
                let summary = resume.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = resume.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty {
                    lines += ["Resume summary:", summary, ""]
                } else if !content.isEmpty {
                    lines += ["Resume (beginning):", String(content.prefix(1500)), ""]
                }
            }
            let skills = kb.skills
            if !skills.isEmpty { lines += ["Skills: " + skills.joined(separator: ", "), ""] }
            let projects = entries.filter { $0.kind == KnowledgeEntryKind.project }.sorted { $0.createdAt < $1.createdAt }
            if !projects.isEmpty {
                lines.append("Projects:")
                for project in projects {
                    let meta = project.meta.isEmpty ? "" : " (\(project.meta))"
                    let summary = project.summary.isEmpty
                        ? String(project.content.replacingOccurrences(of: "\n", with: " ").prefix(300))
                        : project.summary
                    lines.append("- \(project.title)\(meta): \(summary)")
                }
                lines.append("")
            }
            if lines.count > 1 { blocks.append(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
            for entry in entries { chunks += KnowledgeRetriever.chunks(for: entry, baseName: kb.name) }
        }

        let profile = blocks.joined(separator: "\n\n")
        let budget = max(2_000, min(retrievalBudget, limit - profile.count))
        let hits = KnowledgeRetriever.topChunks(chunks, query: query, budget: budget)
        guard !hits.isEmpty else { return String(profile.prefix(limit)) }
        let excerpts = hits.map { "(\($0.label))\n\($0.text)" }.joined(separator: "\n\n")
        let result = """
        \(profile)

        Relevant excerpts from the candidate's materials (retrieved for this question; prepared Q&A here is the candidate's own answer, adapt it):
        \(excerpts)
        """
        return String(result.prefix(limit))
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

// MARK: - Local retrieval (RAG without embeddings)

struct KnowledgeChunk {
    let label: String
    let text: String
    let termFrequencies: [String: Int]
    let length: Int
}

/// Splits knowledge entries into passages and ranks them against a question with BM25.
/// Latin text is matched by words, Chinese / Japanese / Korean text by character bigrams,
/// so it works for mixed-language material without any model or network call.
enum KnowledgeRetriever {
    static let targetChunkSize = 700
    static let maxChunkSize = 1_400

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [UUID: (signature: String, chunks: [KnowledgeChunk])] = [:]

    static func chunks(for entry: KnowledgeEntry, baseName: String) -> [KnowledgeChunk] {
        let content = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return [] }
        let signature = "\(entry.updatedAt.timeIntervalSince1970)|\(content.count)|\(entry.title)|\(baseName)"
        cacheLock.lock()
        if let cached = cache[entry.id], cached.signature == signature {
            cacheLock.unlock()
            return cached.chunks
        }
        cacheLock.unlock()

        let kindLabel: String
        switch entry.kind {
        case KnowledgeEntryKind.resume: kindLabel = "Resume"
        case KnowledgeEntryKind.project: kindLabel = "Project"
        default: kindLabel = "Material"
        }
        let label = "\(baseName) · \(kindLabel) · \(entry.title)"
        let result = split(content).map { piece -> KnowledgeChunk in
            // The title is indexed with every passage so "tell me about <project>" finds it.
            let terms = tokenize(entry.title + "\n" + piece)
            var frequencies: [String: Int] = [:]
            for term in terms { frequencies[term, default: 0] += 1 }
            return KnowledgeChunk(label: label, text: piece, termFrequencies: frequencies, length: max(1, terms.count))
        }
        cacheLock.lock()
        cache[entry.id] = (signature, result)
        cacheLock.unlock()
        return result
    }

    /// Best-matching passages, highest score first, within `budget` characters.
    static func topChunks(_ chunks: [KnowledgeChunk], query: String, budget: Int) -> [KnowledgeChunk] {
        let queryTerms = Set(tokenize(query))
        guard !queryTerms.isEmpty, !chunks.isEmpty else { return [] }
        let count = Double(chunks.count)
        let averageLength = Double(chunks.reduce(0) { $0 + $1.length }) / count
        var documentFrequency: [String: Int] = [:]
        for chunk in chunks {
            for term in queryTerms where chunk.termFrequencies[term] != nil {
                documentFrequency[term, default: 0] += 1
            }
        }
        let k1 = 1.2
        let b = 0.75
        var scored: [(Double, Int)] = []
        for (index, chunk) in chunks.enumerated() {
            var score = 0.0
            for term in queryTerms {
                guard let tf = chunk.termFrequencies[term], let df = documentFrequency[term] else { continue }
                let idf = log(1 + (count - Double(df) + 0.5) / (Double(df) + 0.5))
                let frequency = Double(tf)
                score += idf * (frequency * (k1 + 1)) / (frequency + k1 * (1 - b + b * Double(chunk.length) / averageLength))
            }
            if score > 0 { scored.append((score, index)) }
        }
        guard let best = scored.map({ $0.0 }).max() else { return [] }
        // Drop weak matches (a single shared common bigram) once something clearly better exists.
        let floor = best * 0.2
        var used = 0
        var result: [KnowledgeChunk] = []
        for (score, index) in scored.sorted(by: { $0.0 > $1.0 }) where score >= floor {
            let chunk = chunks[index]
            let cost = chunk.text.count + chunk.label.count + 4
            if used + cost > budget { if result.isEmpty { continue } else { break } }
            used += cost
            result.append(chunk)
        }
        return result
    }

    /// Paragraph-based passages. A line that starts a new question ("Q:", "问：", "## …", "1. …?")
    /// always starts a new passage, so a prepared question stays together with its answer.
    static func split(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [String] = []
        var current: [String] = []
        func flushParagraph() {
            let paragraph = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            current = []
        }
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushParagraph(); continue }
            if isQuestionStart(trimmed) { flushParagraph() }
            current.append(line)
        }
        flushParagraph()

        var pieces: [String] = []
        var buffer = ""
        func flushBuffer() {
            let piece = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            buffer = ""
        }
        for paragraph in paragraphs {
            if paragraph.count > maxChunkSize {
                flushBuffer()
                pieces += hardSplit(paragraph)
                continue
            }
            let startsQuestion = isQuestionStart(paragraph.components(separatedBy: "\n").first ?? "")
            let bufferIsQuestion = isQuestionStart(buffer.components(separatedBy: "\n").first ?? "")
            // Keep an answer with its question; otherwise pack paragraphs up to the target size.
            let wouldOverflow = buffer.count + paragraph.count + 2 > (bufferIsQuestion ? maxChunkSize : targetChunkSize)
            if !buffer.isEmpty && (startsQuestion || wouldOverflow) { flushBuffer() }
            buffer += buffer.isEmpty ? paragraph : "\n\n" + paragraph
        }
        flushBuffer()
        return pieces
    }

    private static func isQuestionStart(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty else { return false }
        let prefixes = ["q:", "q：", "q.", "question:", "问：", "问:", "问题：", "问题:", "面试题", "#"]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if lower.range(of: #"^(q|问题|题)?\s*\d{1,3}\s*[\.、:：\)]"#, options: .regularExpression) != nil,
           lower.hasSuffix("?") || lower.hasSuffix("？") {
            return true
        }
        return false
    }

    private static func hardSplit(_ text: String) -> [String] {
        var pieces: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: targetChunkSize, limitedBy: text.endIndex) ?? text.endIndex
            // Prefer to cut after a sentence end within the last 200 characters.
            if end < text.endIndex {
                let windowStart = text.index(end, offsetBy: -200, limitedBy: start) ?? start
                let window = text[windowStart..<end]
                if let cut = window.lastIndex(where: { "。！？.!?\n；;".contains($0) }) {
                    end = text.index(after: cut)
                }
            }
            let piece = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            start = end
        }
        return pieces
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "you", "your", "are", "was", "were", "with", "that", "this", "what", "how", "why",
        "can", "could", "would", "about", "have", "has", "had", "did", "does", "from", "tell", "me", "is", "it",
        "of", "to", "in", "on", "a", "an", "or", "be", "do", "as", "at", "by", "we", "our", "my", "i"
    ]
    private static let cjkStopBigrams: Set<String> = [
        "一下", "什么", "怎么", "如何", "你的", "我的", "一个", "这个", "那个", "可以", "是否", "为什", "么样",
        "请问", "介绍", "说说", "讲讲", "谈谈", "觉得", "我们", "你们", "他们", "的时", "时候", "有没", "没有"
    ]

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        var previousCJK: Character?
        func flushWord() {
            if word.count >= 2, !stopWords.contains(word) { tokens.append(stem(word)) }
            word = ""
        }
        for character in text.lowercased() {
            if isCJK(character) {
                flushWord()
                if let previous = previousCJK {
                    let bigram = String([previous, character])
                    if !cjkStopBigrams.contains(bigram) { tokens.append(bigram) }
                }
                previousCJK = character
            } else if character.isLetter || character.isNumber || character == "+" || character == "#" {
                previousCJK = nil
                word.append(character)
            } else {
                previousCJK = nil
                flushWord()
            }
        }
        flushWord()
        return tokens
    }

    /// Very light English stemming so "conflicts" / "conflict" and "handled" / "handling" match.
    private static func stem(_ word: String) -> String {
        guard word.count > 4, word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("ing"), word.count > 5 { return String(word.dropLast(3)) }
        if word.hasSuffix("ed") { return String(word.dropLast(2)) }
        if word.hasSuffix("es"), !word.hasSuffix("ses") { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }
}
