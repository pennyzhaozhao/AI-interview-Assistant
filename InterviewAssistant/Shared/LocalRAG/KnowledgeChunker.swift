import Foundation

struct ChunkerOptions: Sendable {
    var targetTokens = 350
    var maxTokens = 450
    var overlapTokens = 60
    static let `default` = ChunkerOptions()
}

/// Paragraph- and sentence-aware chunking with Markdown headings, code blocks, Q&A pairing and token overlap.
/// Line-for-line port of KnowledgeChunker.cs so chunk text and chunk IDs are identical on macOS and Windows.
enum KnowledgeChunker {
    /// Bump when the chunking rules change: every entry is then re-chunked once.
    static let version = "chunker-v1"

    private struct Unit {
        var text: String
        var tokens: Int
        var section: String
        var isQuestionAnswer: Bool
        var group: Int
    }

    private static let headingLine = try! NSRegularExpression(pattern: #"^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$"#)
    private static let numberedQuestion = try! NSRegularExpression(pattern: #"^(q|问题|题)?\s*\d{1,3}\s*[\.、:：\)]"#)
    private static let questionPrefixes = ["q:", "q：", "q.", "question:", "问：", "问:", "问题：", "问题:", "面试题"]

    static func contentHash(_ document: RagDocument) -> String {
        RagText.sha256Hex([version, document.kind, document.title, document.summary, document.meta, document.source,
                           RagText.normalizeNewlines(document.content)].joined(separator: "\u{1F}"))
    }

    /// Stable chunk ID: hash(entry ID, content hash, chunk index). UUIDs are lowercased like .NET's Guid "D" format.
    static func chunkID(entryID: UUID, contentHash: String, index: Int) -> String {
        String(RagText.sha256Hex("\(entryID.uuidString.lowercased())|\(contentHash)|\(index)").prefix(32))
    }

    static func chunk(_ document: RagDocument, options: ChunkerOptions = .default) -> [RagChunk] {
        let hash = contentHash(document)
        var texts: [(section: String, text: String, isQA: Bool)] = []
        let summary = document.summary.dotNetTrimmed
        if document.kind == RagKinds.project {
            var header = "Project: \(document.title)"
            let meta = document.meta.dotNetTrimmed
            if !meta.isEmpty { header += " (\(meta))" }
            if !summary.isEmpty { header += "\n" + summary }
            if document.source.lowercased().hasPrefix("http") { header += "\n" + document.source }
            texts.append(("Overview", header, false))
        } else if document.kind == RagKinds.resume && !summary.isEmpty {
            texts.append(("Summary", summary, false))
        }
        texts += splitContent(document.content, options: options)
        return texts.enumerated().map { index, item in
            RagChunk(chunkID: chunkID(entryID: document.entryID, contentHash: hash, index: index), knowledgeBaseID: document.knowledgeBaseID,
                     entryID: document.entryID, title: document.title, kind: document.kind, source: document.source, chunkIndex: index,
                     section: item.section, text: item.text, contentHash: hash, isQuestionAnswer: item.isQA)
        }
    }

    static func splitContent(_ content: String, options: ChunkerOptions) -> [(section: String, text: String, isQA: Bool)] {
        let text = RagText.normalizeNewlines(content).dotNetTrimmed
        var result: [(section: String, text: String, isQA: Bool)] = []
        if text.isEmpty { return result }
        if TokenEstimator.estimate(text) <= options.targetTokens {
            let units = blocks(text)
            let section = units.first(where: { !$0.section.isEmpty })?.section ?? ""
            result.append((section, text, !units.isEmpty && units.allSatisfy(\.isQuestionAnswer)))
            return result
        }

        var pieces: [Unit] = []
        for block in blocks(text) {
            if block.tokens <= options.maxTokens { pieces.append(block); continue }
            let question = block.isQuestionAnswer ? firstLine(block.text) : nil
            let budget = question.map { max(options.maxTokens - TokenEstimator.estimate($0), options.maxTokens / 2) } ?? options.maxTokens
            let parts = packSentences(splitSentences(block.text, maxTokens: budget).filter { $0 != question }, maxTokens: budget)
            for part in parts {
                let unitText = question.map { $0 + "\n" + part } ?? part
                pieces.append(Unit(text: unitText, tokens: TokenEstimator.estimate(unitText), section: block.section, isQuestionAnswer: block.isQuestionAnswer, group: block.group))
            }
        }

        var current: [Unit] = []
        var currentTokens = 0
        func flush() {
            guard !current.isEmpty else { return }
            let chunkText = current.map(\.text).joined(separator: "\n\n").dotNetTrimmed
            if !chunkText.isEmpty { result.append((current[0].section, chunkText, current.allSatisfy(\.isQuestionAnswer))) }
            current.removeAll()
            currentTokens = 0
        }
        for unit in pieces {
            if let last = current.last {
                let crossesQA = (unit.isQuestionAnswer || last.isQuestionAnswer) && unit.group != last.group
                let sectionChanged = unit.section != last.section && currentTokens >= options.targetTokens / 3
                let full = currentTokens + unit.tokens > options.targetTokens
                if crossesQA || sectionChanged || full {
                    let overlap = !crossesQA && !sectionChanged && !unit.isQuestionAnswer && !last.isQuestionAnswer
                        ? tailSentences(current.map(\.text).joined(separator: "\n\n"), maxTokens: options.overlapTokens)
                        : ""
                    flush()
                    if !overlap.isEmpty {
                        current.append(Unit(text: overlap, tokens: TokenEstimator.estimate(overlap), section: unit.section, isQuestionAnswer: false, group: -1))
                        currentTokens = current[0].tokens
                    }
                }
            }
            current.append(unit)
            currentTokens += unit.tokens
        }
        flush()
        return result
    }

    static func tailSentences(_ text: String, maxTokens: Int) -> String {
        let sentences = splitSentences(text, maxTokens: maxTokens)
        var tail: [String] = []
        var tokens = 0
        for sentence in sentences.reversed() {
            let count = TokenEstimator.estimate(sentence)
            if tokens + count > maxTokens { break }
            tail.insert(sentence, at: 0)
            tokens += count
        }
        return tail.count == sentences.count ? "" : tail.joined(separator: " ")
    }

    private static func packSentences(_ sentences: [String], maxTokens: Int) -> [String] {
        var parts: [String] = []
        var buffer = ""
        var tokens = 0
        for sentence in sentences {
            let count = TokenEstimator.estimate(sentence)
            if !buffer.isEmpty && tokens + count > maxTokens { parts.append(buffer); buffer = ""; tokens = 0 }
            if !buffer.isEmpty { buffer += " " }
            buffer += sentence
            tokens += count
        }
        if !buffer.isEmpty { parts.append(buffer) }
        return parts
    }

    private static func blocks(_ text: String) -> [Unit] {
        var units: [Unit] = []
        var section = ""
        var buffer: [String] = []
        var bufferIsQA = false
        var inCode = false
        var group = 0
        func flushBuffer() {
            let block = buffer.joined(separator: "\n").dotNetTrimmed
            buffer.removeAll()
            let isQA = bufferIsQA
            bufferIsQA = false
            if !block.isEmpty {
                units.append(Unit(text: block, tokens: TokenEstimator.estimate(block), section: section, isQuestionAnswer: isQA, group: group))
                group += 1
            }
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.dotNetTrimmedEnd
            let trimmed = line.dotNetTrimmed
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inCode && !bufferIsQA { flushBuffer() }
                buffer.append(line)
                inCode.toggle()
                if !inCode && !bufferIsQA { flushBuffer() }
                continue
            }
            if inCode { buffer.append(line); continue }
            if let heading = match(headingLine, line), !isQuestionStart(trimmed) {
                flushBuffer()
                section = heading.dotNetTrimmed
                continue
            }
            if isQuestionStart(trimmed) {
                flushBuffer()
                bufferIsQA = true
                buffer.append(line)
                continue
            }
            if trimmed.isEmpty {
                if bufferIsQA { buffer.append(""); continue }
                flushBuffer()
                continue
            }
            buffer.append(line)
        }
        flushBuffer()
        return units
    }

    /// Second capture group of the heading regex (the heading text), if the line is a heading.
    private static func match(_ regex: NSRegularExpression, _ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let result = regex.firstMatch(in: line, range: range), result.numberOfRanges > 2,
              let textRange = Range(result.range(at: 2), in: line) else { return nil }
        return String(line[textRange])
    }

    static func isQuestionStart(_ line: String) -> Bool {
        let lower = line.dotNetTrimmed.lowercased()
        if lower.isEmpty { return false }
        if questionPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        let endsWithQuestionMark = lower.hasSuffix("?") || lower.hasSuffix("？")
        if lower.hasPrefix("#") && endsWithQuestionMark { return true }
        return endsWithQuestionMark && numberedQuestion.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
    }

    private static func firstLine(_ text: String) -> String {
        text.components(separatedBy: "\n").first ?? text
    }

    /// Sentence units no longer than `maxTokens` (over-long sentences cut at a space). Works on UTF-16 like the C# port.
    static func splitSentences(_ text: String, maxTokens: Int) -> [String] {
        let units = Array(text.utf16)
        var sentences: [String] = []
        var start = 0
        for index in 0..<units.count {
            let unit = units[index]
            let strongEnd = unit == 0x3002 || unit == 0xFF01 || unit == 0xFF1F || unit == 0xFF1B || unit == 0x0A   // 。！？；\n
            let weakEnd = (unit == 0x2E || unit == 0x21 || unit == 0x3F || unit == 0x3B)
                && (index + 1 == units.count || isWhiteSpace(units[index + 1]))
            guard strongEnd || weakEnd else { continue }
            let sentence = string(units[start...index]).dotNetTrimmed
            if !sentence.isEmpty { sentences.append(sentence) }
            start = index + 1
        }
        let tail = start < units.count ? string(units[start...]).dotNetTrimmed : ""
        if !tail.isEmpty { sentences.append(tail) }
        var result: [String] = []
        for sentence in sentences {
            if TokenEstimator.estimate(sentence) <= maxTokens { result.append(sentence); continue }
            result += hardSplit(sentence, maxTokens: maxTokens)
        }
        return result
    }

    private static func hardSplit(_ text: String, maxTokens: Int) -> [String] {
        let units = Array(text.utf16)
        var pieces: [String] = []
        var start = 0
        while start < units.count {
            var end = start
            var tokens = 0
            while end < units.count && tokens < maxTokens {
                tokens = TokenEstimator.estimate(string(units[start..<min(units.count, end + 16)]))
                end = min(units.count, end + 16)
            }
            if end < units.count {
                // C# LastIndexOf(' ', end - 1, count): search backwards from end - 1 over `count` characters.
                let count = min(end - start, 80)
                var position = end - 1
                var found = -1
                while position > end - 1 - count && position >= 0 {
                    if units[position] == 0x20 { found = position; break }
                    position -= 1
                }
                if found > start { end = found + 1 }
            }
            let piece = string(units[start..<end]).dotNetTrimmed
            if !piece.isEmpty { pieces.append(piece) }
            start = end
        }
        return pieces
    }

    private static func string<S: Sequence>(_ units: S) -> String where S.Element == UInt16 {
        String(decoding: Array(units), as: UTF16.self)
    }

    private static func isWhiteSpace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return scalar.properties.isWhitespace || (unit >= 0x09 && unit <= 0x0D) || unit == 0x85 || unit == 0xA0
    }
}

extension String {
    /// Trims like .NET's String.Trim(): Unicode white space at both ends.
    var dotNetTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var dotNetTrimmedEnd: String {
        var scalars = unicodeScalars[...]
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { scalars = scalars.dropLast() }
        return String(String.UnicodeScalarView(scalars))
    }
}
