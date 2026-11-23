#if os(macOS)
import Foundation
import OSLog
import AppKit

enum SupportFeedbackStatus: String, Codable, Sendable {
    case new
    case review
    case resolved

    var title: String {
        switch self {
        case .new: return L.t("New")
        case .review: return L.t("Under Review")
        case .resolved: return L.t("Resolved")
        }
    }
}

struct SupportFeedbackRecord: Codable, Identifiable, Sendable {
    var id: String { code }
    let code: String
    let trackingToken: String
    let issue: String
    let createdAt: Date
    var status: SupportFeedbackStatus
    var updatedAt: Date
    let hasLogs: Bool
    var hasImage: Bool?
}

struct SupportFeedbackImage: Sendable {
    let fileName: String
    let mimeType: String
    let data: Data
}

@MainActor
enum SupportLogUploader {
    private static let endpoint = URL(string: "https://interview-assistant-log-upload.zhaopeiyu1507288.workers.dev/v1/feedback")!
    private static let historyKey = "supportFeedbackHistoryV1"

    private struct Upload: Encodable {
        let platform: String
        let appVersion: String
        let osVersion: String
        let createdAt: String
        let issue: String
        let includeLogs: Bool
        let logs: String
        let image: ImageUpload?
    }

    private struct ImageUpload: Encodable {
        let fileName: String
        let mimeType: String
        let base64: String
    }

    private struct UploadResponse: Decodable {
        let code: String
        let trackingToken: String
        let status: SupportFeedbackStatus
        let updatedAt: String
        let hasImage: Bool?
    }

    private struct StatusResponse: Decodable {
        let code: String
        let status: SupportFeedbackStatus
        let updatedAt: String
        let hasImage: Bool?
    }

    static func submitFeedback(
        issue: String,
        includeLogs: Bool,
        image: SupportFeedbackImage? = nil
    ) async throws -> SupportFeedbackRecord {
        let cleanIssue = issue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIssue.isEmpty else { throw UploadError.emptyIssue }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let createdAt = Date()
        let payload = Upload(
            platform: "macOS",
            appVersion: "\(version) (\(build))",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            createdAt: ISO8601DateFormatter().string(from: createdAt),
            issue: String(cleanIssue.prefix(2_000)),
            includeLogs: includeLogs,
            logs: includeLogs ? try recentProcessLogs() : "",
            image: image.map {
                ImageUpload(fileName: $0.fileName, mimeType: $0.mimeType, base64: $0.data.base64EncodedString())
            }
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        guard http.statusCode == 201 else { throw UploadError.server(http.statusCode) }
        let result = try JSONDecoder().decode(UploadResponse.self, from: data)
        let record = SupportFeedbackRecord(
            code: result.code,
            trackingToken: result.trackingToken,
            issue: cleanIssue,
            createdAt: createdAt,
            status: result.status,
            updatedAt: parseDate(result.updatedAt) ?? createdAt,
            hasLogs: includeLogs,
            hasImage: result.hasImage ?? (image != nil)
        )
        var records = history()
        records.removeAll { $0.code == record.code }
        records.insert(record, at: 0)
        saveHistory(records)
        return record
    }

    static func history() -> [SupportFeedbackRecord] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let records = try? JSONDecoder().decode([SupportFeedbackRecord].self, from: data) else { return [] }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    static func refreshHistory() async -> [SupportFeedbackRecord] {
        var records = history()
        for index in records.indices {
            guard let url = URL(string: "\(endpoint.absoluteString)/\(records[index].code)") else { continue }
            var request = URLRequest(url: url)
            request.setValue(records[index].trackingToken, forHTTPHeaderField: "X-Feedback-Token")
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let status = try? JSONDecoder().decode(StatusResponse.self, from: data) else { continue }
            records[index].status = status.status
            records[index].updatedAt = parseDate(status.updatedAt) ?? records[index].updatedAt
            records[index].hasImage = status.hasImage ?? records[index].hasImage
        }
        saveHistory(records)
        return records
    }

    static func prepareImage(from url: URL) throws -> SupportFeedbackImage {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let source = NSImage(contentsOf: url), source.isValid else { throw UploadError.invalidImage }
        let targetLimits: [CGFloat] = [1_600, 1_280, 1_024]
        let qualities: [CGFloat] = [0.82, 0.68, 0.52]
        for limit in targetLimits {
            let size = fittedSize(source.size, maximumDimension: limit)
            let rendered = NSImage(size: size)
            rendered.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
            rendered.unlockFocus()
            guard let tiff = rendered.tiffRepresentation,
                  let representation = NSBitmapImageRep(data: tiff) else { continue }
            for quality in qualities {
                if let data = representation.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                   data.count <= 4 * 1024 * 1024 {
                    let name = url.deletingPathExtension().lastPathComponent + ".jpg"
                    return SupportFeedbackImage(fileName: name, mimeType: "image/jpeg", data: data)
                }
            }
        }
        throw UploadError.imageTooLarge
    }

    private static func fittedSize(_ size: NSSize, maximumDimension: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: maximumDimension, height: maximumDimension) }
        let scale = min(1, maximumDimension / max(size.width, size.height))
        return NSSize(width: max(1, round(size.width * scale)), height: max(1, round(size.height * scale)))
    }

    private static func saveHistory(_ records: [SupportFeedbackRecord]) {
        let retained = Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(30))
        if let data = try? JSONEncoder().encode(retained) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func recentProcessLogs() throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-24 * 60 * 60))
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        for entry in try store.getEntries(at: position) {
            guard let log = entry as? OSLogEntryLog else { continue }
            lines.append("[\(formatter.string(from: log.date))] [\(log.category)] \(log.composedMessage)")
            if lines.count > 1_200 { lines.removeFirst(lines.count - 1_200) }
        }
        let joined = lines.isEmpty ? "No process log entries were available." : lines.joined(separator: "\n")
        return redact(String(joined.suffix(200_000)))
    }

    private static func redact(_ input: String) -> String {
        let rules: [(String, String)] = [
            (#"(?i)(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s,;]+"#, "$1<redacted>"),
            (#"(?i)((?:api[-_ ]?key|access[-_ ]?token|secret|password)\s*[:=]\s*)[^\s,;]+"#, "$1<redacted>"),
            (#"\bsk-[A-Za-z0-9_-]{12,}\b"#, "<redacted-api-key>"),
            (#"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<redacted-email>"),
            (#"/Users/[^/\s]+"#, "/Users/<user>")
        ]
        return rules.reduce(input) { value, rule in
            value.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
        }
    }

    enum UploadError: LocalizedError {
        case emptyIssue
        case invalidResponse
        case server(Int)
        case invalidImage
        case imageTooLarge

        var errorDescription: String? {
            switch self {
            case .emptyIssue: return L.t("Please describe the problem before submitting.")
            case .invalidResponse: return L.t("The feedback service returned an invalid response.")
            case let .server(status): return String(format: L.t("The feedback service returned error %d."), status)
            case .invalidImage: return L.t("The selected image could not be read.")
            case .imageTooLarge: return L.t("The selected image is too large to upload.")
            }
        }
    }
}
#endif
