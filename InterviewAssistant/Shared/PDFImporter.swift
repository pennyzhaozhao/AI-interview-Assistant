import Foundation
import PDFKit

enum PDFImporter {
    static func extractText(from url: URL, maxCharacters: Int? = nil) -> String {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let document = PDFDocument(url: url) else { return "" }
        var text = ""
        for index in 0..<document.pageCount {
            text += document.page(at: index)?.string ?? ""
            text += "\n"
            if let maxCharacters, text.count >= maxCharacters { break }
        }
        if let maxCharacters, text.count > maxCharacters {
            return String(text.prefix(maxCharacters))
        }
        return text
    }
}
