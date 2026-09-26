import Foundation

enum URLFetcher {
    static func googleDriveDownloadURL(_ input: String) -> String {
        guard let components = URLComponents(string: input),
              components.host?.contains("drive.google.com") == true else { return input }
        let parts = components.path.split(separator: "/").map(String.init)
        if let dIndex = parts.firstIndex(of: "d"), dIndex + 1 < parts.count {
            return "https://drive.google.com/uc?export=download&id=\(parts[dIndex + 1])"
        }
        if let id = components.queryItems?.first(where: { $0.name == "id" })?.value {
            return "https://drive.google.com/uc?export=download&id=\(id)"
        }
        return input
    }

    static func githubRawURL(_ input: String) -> String {
        let input = plainURLString(from: input)
        guard let url = URL(string: input), url.host == "github.com" else { return input }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[2] == "blob" else { return input }
        let rest = parts.dropFirst(4).joined(separator: "/")
        return "https://raw.githubusercontent.com/\(parts[0])/\(cleanGitHubRepoName(parts[1]))/\(parts[3])/\(rest)"
    }

    static func fetchText(from input: String, maxCharacters: Int = 20_000) async throws -> String {
        let candidates = candidateURLs(for: plainURLString(from: input.trimmingCharacters(in: .whitespacesAndNewlines)))
        var lastError: Error?
        for target in candidates {
            do {
                return try await fetchSingleText(from: target, maxCharacters: maxCharacters)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FetchError.invalidURL
    }

    private static func candidateURLs(for input: String) -> [String] {
        let normalized = googleDriveDownloadURL(input)
        guard let url = URL(string: normalized),
              url.host == "github.com" else {
            return [githubRawURL(normalized)]
        }

        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return [normalized] }
        let owner = parts[0]
        let repo = cleanGitHubRepoName(parts[1])

        if parts.count >= 5, parts[2] == "blob" {
            return [githubRawURL(normalized)]
        }

        if parts.count >= 4, parts[2] == "tree" {
            return readmeCandidates(owner: owner, repo: repo, branches: [parts[3]])
        }

        return readmeCandidates(owner: owner, repo: repo, branches: ["main", "master", "develop"])
    }

    private static func plainURLString(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "("),
           let close = trimmed.lastIndex(of: ")"),
           open < close {
            return String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func cleanGitHubRepoName(_ repo: String) -> String {
        repo.hasSuffix(".git") ? String(repo.dropLast(4)) : repo
    }

    private static func readmeCandidates(owner: String, repo: String, branches: [String]) -> [String] {
        let names = ["README.md", "README", "README.rst", "README.txt", "readme.md"]
        return branches.flatMap { branch in
            names.map { name in
                "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(name)"
            }
        }
    }

    private static func fetchSingleText(from target: String, maxCharacters: Int) async throws -> String {
        guard let url = URL(string: target) else { throw FetchError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("InterviewAssistant/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.httpStatus(http.statusCode)
        }
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("pdf") || target.lowercased().hasSuffix(".pdf") {
            let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("pdf")
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            return PDFImporter.extractText(from: tmp, maxCharacters: maxCharacters)
        }
        let string = String(data: data.prefix(maxCharacters), encoding: .utf8) ?? String(decoding: data.prefix(maxCharacters), as: UTF8.self)
        return String(string.prefix(maxCharacters))
    }

    enum FetchError: LocalizedError {
        case invalidURL
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid source URL"
            case .httpStatus(let status):
                return "Source returned HTTP \(status)"
            }
        }
    }
}
