import Foundation
import UniformTypeIdentifiers
import PDFKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum DocumentTextImporter {
    static func extractText(from url: URL, maxCharacters: Int = 20_000) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            let text = PDFImporter.extractText(from: url, maxCharacters: maxCharacters)
            return appendLinks(to: text, links: pdfLinks(at: url))
        }
        if ["txt", "md", "markdown", "csv", "json"].contains(ext) {
            let text = try String(contentsOf: url, encoding: .utf8)
            return String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #if os(macOS) || os(iOS)
        let data = try Data(contentsOf: url)
        let documentType = attributedDocumentType(for: ext)
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: documentType],
            documentAttributes: nil
        )
        let text = String(attributed.string.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        return appendLinks(to: text, links: attributedLinks(in: attributed))
        #else
        throw NSError(domain: "InterviewAssistant", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported file type"])
        #endif
    }

    // MARK: - Links
    //
    // Links that are clickable in a document but not visible in its text (e.g. a "GitHub" or
    // "Demo" label in a resume) are appended as a "Links:" list so AI can find project links.

    private static func pdfLinks(at url: URL) -> [(label: String, url: String)] {
        guard let document = PDFDocument(url: url) else { return [] }
        var links: [(label: String, url: String)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                let target = annotation.url ?? (annotation.action as? PDFActionURL)?.url
                guard let target else { continue }
                let label = page.selection(for: annotation.bounds)?.string ?? ""
                links.append((label, target.absoluteString))
            }
        }
        return links
    }

    #if os(macOS) || os(iOS)
    private static func attributedLinks(in attributed: NSAttributedString) -> [(label: String, url: String)] {
        var links: [(label: String, url: String)] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let target: String? = (value as? URL)?.absoluteString ?? (value as? String)
            guard let target else { return }
            links.append((attributed.attributedSubstring(from: range).string, target))
        }
        return links
    }
    #endif

    private static func appendLinks(to text: String, links: [(label: String, url: String)]) -> String {
        var lines: [String] = []
        var seen = Set<String>()
        for link in links {
            var clean = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = clean.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { continue }
            while clean.hasSuffix("/") { clean.removeLast() }
            guard seen.insert(clean.lowercased()).inserted, text.range(of: clean, options: .caseInsensitive) == nil else { continue }
            let caption = link.label.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(!caption.isEmpty && caption.count <= 60 ? "- \(caption): \(link.url)" : "- \(link.url)")
        }
        guard !lines.isEmpty else { return text }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nLinks:\n" + lines.joined(separator: "\n")
    }

    #if os(macOS) || os(iOS)
    private static func attributedDocumentType(for ext: String) -> NSAttributedString.DocumentType {
        switch ext {
        case "rtf":
            return .rtf
        case "rtfd":
            return .rtfd
        #if os(macOS)
        case "doc":
            return .docFormat
        case "docx":
            return .officeOpenXML
        #endif
        case "html", "htm":
            return .html
        default:
            return .plain
        }
    }
    #endif
}
