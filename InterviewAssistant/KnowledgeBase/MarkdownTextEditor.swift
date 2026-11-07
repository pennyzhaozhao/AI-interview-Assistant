import SwiftUI
#if os(macOS)
import AppKit
typealias MarkdownPlatformFont = NSFont
typealias MarkdownPlatformColor = NSColor
#else
import UIKit
typealias MarkdownPlatformFont = UIFont
typealias MarkdownPlatformColor = UIColor
#endif

// MARK: - Formatting actions (shared by shortcuts and the toolbar)

enum MarkdownFormatAction {
    case bold, italic, underline, strikethrough, inlineCode, link
    case heading(Int)   // 0 = plain paragraph
    case quote, bulletList, orderedList, codeBlock
}

/// Pure text transformations: given the text and selection, returns the replacement to apply.
enum MarkdownEditing {
    struct Edit {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    static func edit(for action: MarkdownFormatAction, in text: NSString, selection: NSRange) -> Edit? {
        switch action {
        case .bold: return wrap(text, selection, open: "**", close: "**")
        case .italic: return wrap(text, selection, open: "*", close: "*")
        case .underline: return wrap(text, selection, open: "<u>", close: "</u>")
        case .strikethrough: return wrap(text, selection, open: "~~", close: "~~")
        case .inlineCode: return wrap(text, selection, open: "`", close: "`")
        case .link: return link(text, selection)
        case .heading(let level): return heading(text, selection, level: level)
        case .quote: return togglePrefix(text, selection, prefix: "> ", pattern: #"^>\s?"#)
        case .bulletList: return togglePrefix(text, selection, prefix: "- ", pattern: #"^\s*[-*+]\s+"#)
        case .orderedList: return orderedList(text, selection)
        case .codeBlock: return codeBlock(text, selection)
        }
    }

    /// Wraps the selection in markers, or removes them when the selection is already wrapped.
    private static func wrap(_ text: NSString, _ selection: NSRange, open: String, close: String) -> Edit {
        let openLength = (open as NSString).length
        let closeLength = (close as NSString).length
        let selected = text.substring(with: selection)
        // Markers just outside the selection: "**|bold|**" → unwrap.
        if selection.location >= openLength, NSMaxRange(selection) + closeLength <= text.length,
           text.substring(with: NSRange(location: selection.location - openLength, length: openLength)) == open,
           text.substring(with: NSRange(location: NSMaxRange(selection), length: closeLength)) == close {
            let outer = NSRange(location: selection.location - openLength, length: selection.length + openLength + closeLength)
            return Edit(range: outer, replacement: selected, selection: NSRange(location: outer.location, length: selection.length))
        }
        // Markers inside the selection: "|**bold**|" → unwrap.
        if selected.hasPrefix(open), selected.hasSuffix(close), (selected as NSString).length >= openLength + closeLength {
            let inner = (selected as NSString).substring(with: NSRange(location: openLength, length: (selected as NSString).length - openLength - closeLength))
            return Edit(range: selection, replacement: inner, selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        let replacement = open + selected + close
        return Edit(range: selection, replacement: replacement, selection: NSRange(location: selection.location + openLength, length: selection.length))
    }

    private static func link(_ text: NSString, _ selection: NSRange) -> Edit {
        let selected = text.substring(with: selection)
        let placeholder = "https://"
        if selected.isEmpty {
            // "[|](https://)": type the link text first, like Typora.
            return Edit(range: selection, replacement: "[](\(placeholder))", selection: NSRange(location: selection.location + 1, length: 0))
        }
        let replacement = "[\(selected)](\(placeholder))"
        let urlLocation = selection.location + (selected as NSString).length + 3
        return Edit(range: selection, replacement: replacement, selection: NSRange(location: urlLocation, length: (placeholder as NSString).length))
    }

    /// Applies `transform` to every line touched by the selection and selects the result.
    private static func transformLines(_ text: NSString, _ selection: NSRange, _ transform: ([String]) -> [String]) -> Edit {
        let lineRange = text.lineRange(for: selection)
        var block = text.substring(with: lineRange)
        var trailingNewline = ""
        if block.hasSuffix("\n") { block.removeLast(); trailingNewline = "\n" }
        let lines = block.components(separatedBy: "\n")
        let result = transform(lines).joined(separator: "\n")
        let length = (result as NSString).length
        let newSelection = selection.length == 0 && lines.count == 1
            ? NSRange(location: lineRange.location + length, length: 0)
            : NSRange(location: lineRange.location, length: length)
        return Edit(range: lineRange, replacement: result + trailingNewline, selection: newSelection)
    }

    private static func heading(_ text: NSString, _ selection: NSRange, level: Int) -> Edit {
        transformLines(text, selection) { lines in
            lines.map { line in
                let current = line.prefix { $0 == "#" }.count
                let body = current > 0 ? String(line.dropFirst(current)).trimmingLeadingSpaces() : line
                // Same level again turns the heading back into a paragraph (Typora behaviour).
                if level == 0 || current == level { return body }
                return String(repeating: "#", count: level) + " " + body
            }
        }
    }

    private static func togglePrefix(_ text: NSString, _ selection: NSRange, prefix: String, pattern: String) -> Edit {
        transformLines(text, selection) { lines in
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allHave = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil }
            return lines.map { line in
                if allHave { return line.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
                if line.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { return line }
                return prefix + line
            }
        }
    }

    private static func orderedList(_ text: NSString, _ selection: NSRange) -> Edit {
        let pattern = #"^\s*\d+[.)]\s+"#
        return transformLines(text, selection) { lines in
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allHave = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil }
            var number = 0
            return lines.map { line in
                if allHave { return line.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
                if line.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { return line }
                number += 1
                let body = line.replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
                return "\(number). " + body
            }
        }
    }

    private static func codeBlock(_ text: NSString, _ selection: NSRange) -> Edit {
        let lineRange = text.lineRange(for: selection)
        var block = text.substring(with: lineRange)
        var trailingNewline = ""
        if block.hasSuffix("\n") { block.removeLast(); trailingNewline = "\n" }
        if block.trimmingCharacters(in: .whitespaces).isEmpty {
            let replacement = "```\n\n```" + trailingNewline
            return Edit(range: lineRange, replacement: replacement, selection: NSRange(location: lineRange.location + 4, length: 0))
        }
        let replacement = "```\n" + block + "\n```" + trailingNewline
        return Edit(range: lineRange, replacement: replacement, selection: NSRange(location: lineRange.location + 4, length: (block as NSString).length))
    }

    /// Shortcut → action. `command` is ⌘ on macOS / iPadOS.
    static func action(key: String, command: Bool, control: Bool, option: Bool, shift: Bool) -> MarkdownFormatAction? {
        if command && option && !control {
            switch key {
            case "q": return .quote
            case "o": return .orderedList
            case "u": return .bulletList
            case "c": return .codeBlock
            default: return nil
            }
        }
        if control && !command && !option && key == "`" {
            return shift ? .strikethrough : .inlineCode
        }
        guard command, !control, !option else { return nil }
        if shift {
            return key == "`" || key == "~" ? .inlineCode : nil
        }
        switch key {
        case "b": return .bold
        case "i": return .italic
        case "u": return .underline
        case "k": return .link
        case "0": return .heading(0)
        case "1", "2", "3", "4", "5", "6": return .heading(Int(key) ?? 1)
        default: return nil
        }
    }
}

private extension String {
    func trimmingLeadingSpaces() -> String {
        String(drop { $0 == " " || $0 == "\t" })
    }
}

// MARK: - Live styling (Typora-like)

/// Styles Markdown in place. Syntax characters (`**`, `#`, `[`…`](url)`) are shown faintly on the
/// line being edited and hidden elsewhere, so the text reads like the rendered document.
enum MarkdownStyler {
    static let bodySize: CGFloat = 15

    struct Palette {
        let text: MarkdownPlatformColor
        let muted: MarkdownPlatformColor
        let accent: MarkdownPlatformColor
        let codeBackground: MarkdownPlatformColor

        @MainActor static var current: Palette {
            Palette(
                text: MarkdownPlatformColor(Color.appText),
                muted: MarkdownPlatformColor(Color.appMuted),
                accent: MarkdownPlatformColor(Color.appPrimary),
                codeBackground: MarkdownPlatformColor(Color.appMuted).withAlphaComponent(0.13)
            )
        }
    }

    static func baseFont() -> MarkdownPlatformFont { .systemFont(ofSize: bodySize) }

    static func baseAttributes(_ palette: Palette) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 4
        return [.font: baseFont(), .foregroundColor: palette.text, .paragraphStyle: paragraph]
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are constants; a failure is a programming error caught on first use.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    nonisolated(unsafe) private static let headingRegex = regex(#"^(#{1,6})[ \t]+.*$"#, .anchorsMatchLines)
    nonisolated(unsafe) private static let quoteRegex = regex(#"^>[ \t]?.*$"#, .anchorsMatchLines)
    nonisolated(unsafe) private static let listRegex = regex(#"^[ \t]*([-*+]|\d+[.)])[ \t]+"#, .anchorsMatchLines)
    nonisolated(unsafe) private static let ruleRegex = regex(#"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#, .anchorsMatchLines)
    nonisolated(unsafe) private static let inlineCodeRegex = regex(#"`[^`\n]+`"#)
    nonisolated(unsafe) private static let boldRegex = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    // "*斜体*" works next to Chinese text; "_" needs word boundaries so snake_case is left alone.
    nonisolated(unsafe) private static let italicRegex = regex(#"(?<![*\\])(\*)(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?!\*)"#)
    nonisolated(unsafe) private static let underscoreItalicRegex = regex(#"(?<![\w\\])(_)(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?!\w)"#)
    nonisolated(unsafe) private static let strikeRegex = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    nonisolated(unsafe) private static let underlineRegex = regex(#"<u>(.+?)</u>"#)
    nonisolated(unsafe) private static let linkRegex = regex(#"(?<!!)\[([^\]\n]+)\]\(([^)\s]+)\)"#)

    static func apply(to storage: NSTextStorage, activeRange: NSRange?, palette: Palette) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes(palette), range: full)
        guard text.length > 0 else { storage.endEditing(); return }

        var syntax: [NSRange] = []
        let codeBlocks = styleCodeBlocks(storage, text, palette)
        func inCode(_ range: NSRange) -> Bool {
            codeBlocks.contains { NSIntersectionRange($0, range).length > 0 }
        }

        for match in headingRegex.matches(in: storage.string, range: full) where !inCode(match.range) {
            let level = match.range(at: 1).length
            let sizes: [CGFloat] = [26, 22, 19, 17, 16, 15]
            storage.addAttribute(.font, value: MarkdownPlatformFont.systemFont(ofSize: sizes[level - 1], weight: .bold), range: match.range)
            // "## " including the space after the hashes.
            var markerLength = level
            while match.range.location + markerLength < NSMaxRange(match.range),
                  [" ", "\t"].contains(text.substring(with: NSRange(location: match.range.location + markerLength, length: 1))) {
                markerLength += 1
            }
            syntax.append(NSRange(location: match.range.location, length: markerLength))
        }
        for match in quoteRegex.matches(in: storage.string, range: full) where !inCode(match.range) {
            storage.addAttribute(.foregroundColor, value: palette.muted, range: match.range)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.firstLineHeadIndent = 12
            paragraph.headIndent = 12
            storage.addAttribute(.paragraphStyle, value: paragraph, range: match.range)
            let markerLength = text.substring(with: match.range).hasPrefix("> ") ? 2 : 1
            syntax.append(NSRange(location: match.range.location, length: markerLength))
        }
        for match in listRegex.matches(in: storage.string, range: full) where !inCode(match.range) {
            storage.addAttribute(.foregroundColor, value: palette.accent, range: match.range(at: 1))
            storage.addAttribute(.font, value: MarkdownPlatformFont.systemFont(ofSize: bodySize, weight: .semibold), range: match.range(at: 1))
        }
        for match in ruleRegex.matches(in: storage.string, range: full) where !inCode(match.range) {
            storage.addAttribute(.foregroundColor, value: palette.muted, range: match.range)
        }
        for match in inlineCodeRegex.matches(in: storage.string, range: full) where !inCode(match.range) {
            storage.addAttribute(.font, value: MarkdownPlatformFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular), range: match.range)
            storage.addAttribute(.backgroundColor, value: palette.codeBackground, range: match.range)
            syntax.append(NSRange(location: match.range.location, length: 1))
            syntax.append(NSRange(location: NSMaxRange(match.range) - 1, length: 1))
        }
        let inlineCode = inlineCodeRegex.matches(in: storage.string, range: full).map(\.range) + codeBlocks
        func protected(_ range: NSRange) -> Bool {
            inlineCode.contains { NSIntersectionRange($0, range).length > 0 }
        }
        for match in boldRegex.matches(in: storage.string, range: full) where !protected(match.range) {
            addTrait(storage, bold: true, range: match.range(at: 2))
            syntax.append(NSRange(location: match.range.location, length: 2))
            syntax.append(NSRange(location: NSMaxRange(match.range) - 2, length: 2))
        }
        let italics = italicRegex.matches(in: storage.string, range: full) + underscoreItalicRegex.matches(in: storage.string, range: full)
        for match in italics where !protected(match.range) {
            // Obliqueness also slants Chinese text, which has no italic face.
            storage.addAttribute(.obliqueness, value: 0.18, range: match.range(at: 2))
            syntax.append(NSRange(location: match.range.location, length: 1))
            syntax.append(NSRange(location: NSMaxRange(match.range) - 1, length: 1))
        }
        for match in strikeRegex.matches(in: storage.string, range: full) where !protected(match.range) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 1))
            syntax.append(NSRange(location: match.range.location, length: 2))
            syntax.append(NSRange(location: NSMaxRange(match.range) - 2, length: 2))
        }
        for match in underlineRegex.matches(in: storage.string, range: full) where !protected(match.range) {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 1))
            syntax.append(NSRange(location: match.range.location, length: 3))
            syntax.append(NSRange(location: NSMaxRange(match.range) - 4, length: 4))
        }
        for match in linkRegex.matches(in: storage.string, range: full) where !protected(match.range) {
            let label = match.range(at: 1)
            storage.addAttribute(.foregroundColor, value: palette.accent, range: label)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
            syntax.append(NSRange(location: match.range.location, length: 1))
            syntax.append(NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)))
        }

        let hiddenFont = MarkdownPlatformFont.systemFont(ofSize: 0.1)
        for range in syntax where range.length > 0 && NSMaxRange(range) <= text.length {
            if let activeRange, NSIntersectionRange(activeRange, range).length > 0 || NSLocationInRange(range.location, activeRange) {
                storage.addAttribute(.foregroundColor, value: palette.muted.withAlphaComponent(0.75), range: range)
            } else {
                storage.addAttribute(.font, value: hiddenFont, range: range)
                storage.addAttribute(.foregroundColor, value: MarkdownPlatformColor.clear, range: range)
                storage.removeAttribute(.backgroundColor, range: range)
                storage.removeAttribute(.underlineStyle, range: range)
                storage.removeAttribute(.strikethroughStyle, range: range)
            }
        }
        storage.endEditing()
    }

    /// Fenced code blocks: monospaced with a background; fence lines stay visible but faint.
    private static func styleCodeBlocks(_ storage: NSTextStorage, _ text: NSString, _ palette: Palette) -> [NSRange] {
        var blocks: [NSRange] = []
        var openStart: Int?
        var location = 0
        let mono = MarkdownPlatformFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let content = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasPrefix("```") || content.hasPrefix("~~~") {
                if let start = openStart {
                    blocks.append(NSRange(location: start, length: NSMaxRange(line) - start))
                    openStart = nil
                } else {
                    openStart = line.location
                }
            }
            location = NSMaxRange(line)
        }
        if let start = openStart { blocks.append(NSRange(location: start, length: text.length - start)) }
        for block in blocks {
            storage.addAttribute(.font, value: mono, range: block)
            storage.addAttribute(.backgroundColor, value: palette.codeBackground, range: block)
            let firstLine = text.lineRange(for: NSRange(location: block.location, length: 0))
            storage.addAttribute(.foregroundColor, value: palette.muted, range: firstLine)
            let lastLine = text.lineRange(for: NSRange(location: max(block.location, NSMaxRange(block) - 1), length: 0))
            if lastLine.location != firstLine.location {
                storage.addAttribute(.foregroundColor, value: palette.muted, range: lastLine)
            }
        }
        return blocks
    }

    private static func addTrait(_ storage: NSTextStorage, bold: Bool, range: NSRange) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? MarkdownPlatformFont) ?? baseFont()
            #if os(macOS)
            let converted = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            #else
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitBold)) ?? font.fontDescriptor
            let converted = UIFont(descriptor: descriptor, size: font.pointSize)
            #endif
            storage.addAttribute(.font, value: converted, range: subrange)
        }
    }
}

// MARK: - Controller (lets SwiftUI toolbar buttons format the text view)

@MainActor
final class MarkdownEditorController {
    #if os(macOS)
    weak var textView: MarkdownNSTextView?
    #else
    weak var textView: MarkdownUITextView?
    #endif

    func perform(_ action: MarkdownFormatAction) {
        textView?.apply(action)
    }
}

// MARK: - macOS

#if os(macOS)
final class MarkdownNSTextView: NSTextView {
    func apply(_ action: MarkdownFormatAction) {
        let text = string as NSString
        guard let edit = MarkdownEditing.edit(for: action, in: text, selection: selectedRange()) else { return }
        // shouldChangeText / didChangeText register the change with undo (⌘Z) and notify the delegate.
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        window?.makeFirstResponder(self)
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // keyCode 50 is the `/~ key, whatever the keyboard layout produces for it.
        let key = event.keyCode == 50 ? "`" : (event.charactersIgnoringModifiers ?? "").lowercased()
        guard let action = MarkdownEditing.action(
            key: key,
            command: flags.contains(.command),
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift)
        ) else { return false }
        apply(action)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleShortcut(event) { return }
        super.keyDown(with: event)
    }
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 on purpose: SwiftUI's TextEditor (TextKit 2) can stop laying out long text,
        // so the end of a long note was cut off.
        let textView = MarkdownNSTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let palette = MarkdownStyler.Palette.current
        textView.insertionPointColor = palette.accent
        textView.typingAttributes = MarkdownStyler.baseAttributes(palette)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        controller.textView = textView
        context.coordinator.textView = textView
        context.coordinator.restyle()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        controller.textView = textView
        if textView.string != text {
            textView.string = text
            context.coordinator.restyle()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        weak var textView: MarkdownNSTextView?
        private var activeLine: NSRange?

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = textView.string as NSString
            let selection = textView.selectedRange()
            activeLine = NSMaxRange(selection) <= text.length ? text.lineRange(for: selection) : nil
            MarkdownStyler.apply(to: storage, activeRange: activeLine, palette: .current)
            textView.typingAttributes = MarkdownStyler.baseAttributes(.current)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            restyle()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let text = textView.string as NSString
            let selection = textView.selectedRange()
            guard NSMaxRange(selection) <= text.length else { return }
            let line = text.lineRange(for: selection)
            if activeLine.map({ !NSEqualRanges($0, line) }) ?? true { restyle() }
        }
    }
}
#else

// MARK: - iOS / iPadOS

final class MarkdownUITextView: UITextView {
    func apply(_ action: MarkdownFormatAction) {
        let text = (self.text ?? "") as NSString
        guard let edit = MarkdownEditing.edit(for: action, in: text, selection: selectedRange),
              let start = position(from: beginningOfDocument, offset: edit.range.location),
              let end = position(from: start, offset: edit.range.length),
              let range = textRange(from: start, to: end) else { return }
        replace(range, withText: edit.replacement)   // registers undo and notifies the delegate
        selectedRange = edit.selection
    }

    override var keyCommands: [UIKeyCommand]? {
        func command(_ input: String, _ flags: UIKeyModifierFlags, _ selector: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: selector)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        var commands = [
            command("b", .command, #selector(formatBold)),
            command("i", .command, #selector(formatItalic)),
            command("u", .command, #selector(formatUnderline)),
            command("k", .command, #selector(formatLink)),
            command("`", .control, #selector(formatInlineCode)),
            command("`", [.control, .shift], #selector(formatStrikethrough)),
            command("q", [.command, .alternate], #selector(formatQuote)),
            command("o", [.command, .alternate], #selector(formatOrderedList)),
            command("u", [.command, .alternate], #selector(formatBulletList)),
            command("c", [.command, .alternate], #selector(formatCodeBlock)),
            command("0", .command, #selector(formatHeading(_:)))
        ]
        for level in 1...6 { commands.append(command("\(level)", .command, #selector(formatHeading(_:)))) }
        return commands + (super.keyCommands ?? [])
    }

    @objc private func formatBold() { apply(.bold) }
    @objc private func formatItalic() { apply(.italic) }
    @objc private func formatUnderline() { apply(.underline) }
    @objc private func formatLink() { apply(.link) }
    @objc private func formatInlineCode() { apply(.inlineCode) }
    @objc private func formatStrikethrough() { apply(.strikethrough) }
    @objc private func formatQuote() { apply(.quote) }
    @objc private func formatOrderedList() { apply(.orderedList) }
    @objc private func formatBulletList() { apply(.bulletList) }
    @objc private func formatCodeBlock() { apply(.codeBlock) }
    @objc private func formatHeading(_ sender: UIKeyCommand) { apply(.heading(Int(sender.input ?? "0") ?? 0)) }
}

struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MarkdownUITextView {
        let textView = MarkdownUITextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.allowsEditingTextAttributes = false
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)
        textView.text = text
        controller.textView = textView
        context.coordinator.textView = textView
        context.coordinator.restyle()
        return textView
    }

    func updateUIView(_ textView: MarkdownUITextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = textView
        if textView.text != text {
            textView.text = text
            context.coordinator.restyle()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextEditor
        weak var textView: MarkdownUITextView?
        private var activeLine: NSRange?

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func restyle() {
            guard let textView else { return }
            let text = (textView.text ?? "") as NSString
            let selection = textView.selectedRange
            activeLine = NSMaxRange(selection) <= text.length ? text.lineRange(for: selection) : nil
            MarkdownStyler.apply(to: textView.textStorage, activeRange: activeLine, palette: .current)
            textView.selectedRange = selection
            textView.typingAttributes = MarkdownStyler.baseAttributes(.current)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            restyle()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let text = (textView.text ?? "") as NSString
            let selection = textView.selectedRange
            guard NSMaxRange(selection) <= text.length else { return }
            let line = text.lineRange(for: selection)
            if activeLine.map({ !NSEqualRanges($0, line) }) ?? true { restyle() }
        }
    }
}
#endif

// MARK: - Toolbar

struct MarkdownFormatToolbar: View {
    let controller: MarkdownEditorController

    private static let cmd = "⌘", opt = "⌥", ctrl = "⌃", shift = "⇧"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                button(systemImage: "bold", help: L.t("Bold") + " \(Self.cmd)B", .bold)
                button(systemImage: "italic", help: L.t("Italic") + " \(Self.cmd)I", .italic)
                button(systemImage: "underline", help: L.t("Underline") + " \(Self.cmd)U", .underline)
                button(systemImage: "strikethrough", help: L.t("Strikethrough") + " \(Self.ctrl)\(Self.shift)`", .strikethrough)
                button(systemImage: "chevron.left.forwardslash.chevron.right", help: L.t("Inline code") + " \(Self.ctrl)`", .inlineCode)
                button(systemImage: "link", help: L.t("Link") + " \(Self.cmd)K", .link)
                Divider().frame(height: 18)
                button(text: "H1", help: L.t("Heading 1") + " \(Self.cmd)1", .heading(1))
                button(text: "H2", help: L.t("Heading 2") + " \(Self.cmd)2", .heading(2))
                button(text: "H3", help: L.t("Heading 3") + " \(Self.cmd)3", .heading(3))
                Divider().frame(height: 18)
                button(systemImage: "text.quote", help: L.t("Quote") + " \(Self.cmd)\(Self.opt)Q", .quote)
                button(systemImage: "list.bullet", help: L.t("Bulleted list") + " \(Self.cmd)\(Self.opt)U", .bulletList)
                button(systemImage: "list.number", help: L.t("Numbered list") + " \(Self.cmd)\(Self.opt)O", .orderedList)
                button(systemImage: "curlybraces", help: L.t("Code block") + " \(Self.cmd)\(Self.opt)C", .codeBlock)
            }
            .padding(4)
        }
        .background(Color.appField)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func button(systemImage: String? = nil, text: String? = nil, help: String, _ action: MarkdownFormatAction) -> some View {
        Button {
            controller.perform(action)
        } label: {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(text ?? "").font(.system(size: 12, weight: .bold))
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.appText)
            .frame(width: 30, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
