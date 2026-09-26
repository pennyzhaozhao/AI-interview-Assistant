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
            return PDFImporter.extractText(from: url, maxCharacters: maxCharacters)
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
        return String(attributed.string.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw NSError(domain: "InterviewAssistant", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported file type"])
        #endif
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
