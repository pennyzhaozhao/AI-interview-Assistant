import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct CodeBlockView: View {
    let code: String
    let language: String
    @State private var isCopied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(codeLines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text("\(index + 1)")
                                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Color.black.opacity(0.20))
                                    .frame(width: 28, alignment: .trailing)
                                    .textSelection(.disabled)
                                Text(SyntaxHighlighter.highlight(line.isEmpty ? " " : line, language: language))
                                    .font(.system(size: 13, design: .monospaced))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 48)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 210)
            .background(Color.white)

            Button {
                copyToClipboard(code)
                isCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isCopied = false
                }
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isCopied ? Color.appGreen : Color.black.opacity(0.38))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(hex: "#E4E4E4")))
    }

    private var codeLines: [String] {
        code.components(separatedBy: .newlines)
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

private enum SyntaxHighlighter {
    static func highlight(_ code: String, language: String) -> AttributedString {
        let attributed = NSMutableAttributedString(
            string: code,
            attributes: [
                .foregroundColor: platformColor("#222222"),
                .font: platformMonospaceFont(size: 13)
            ]
        )
        apply(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, color: "#A5D6FF", to: attributed)
        apply(pattern: #"//.*|#.*"#, color: "#8B949E", to: attributed)
        apply(pattern: #"\b(class|def|func|return|if|else|elif|for|while|let|var|public|private|static|import|from|in|try|catch|throw|throws|new|const|int|double|float|bool|void|true|false|null|None|self|this)\b"#, color: "#FF7B72", to: attributed)
        apply(pattern: #"\b\d+(?:\.\d+)?\b"#, color: "#79C0FF", to: attributed)
        return AttributedString(attributed)
    }

    private static func apply(pattern: String, color: String, to attributed: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: attributed.string.utf16.count)
        regex.enumerateMatches(in: attributed.string, range: range) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: platformColor(color), range: match.range)
        }
    }

    private static func platformColor(_ hex: String) -> Any {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        #if os(macOS)
        return NSColor(red: red, green: green, blue: blue, alpha: 1)
        #else
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
        #endif
    }

    private static func platformMonospaceFont(size: CGFloat) -> Any {
        #if os(macOS)
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #else
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #endif
    }
}
