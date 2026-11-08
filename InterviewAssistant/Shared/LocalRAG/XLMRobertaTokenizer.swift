import Foundation

/// SentencePiece Unigram tokenizer for the XLM-RoBERTa vocabulary of multilingual-e5-small, read from tokenizer.json.
/// Same algorithm as XlmRobertaTokenizer.cs: NFKC, whitespace → space, control/format characters removed, repeated
/// spaces collapsed, Metaspace pre-tokenization, Viterbi segmentation over Unicode scalars, <s> … </s>.
/// Verified identical to the Hugging Face tokenizer on 1,054 of 1,055 mixed Chinese/English test lines.
final class XLMRobertaTokenizer: @unchecked Sendable {
    static let bosID = 0
    static let padID = 1
    static let eosID = 2
    private static let unknownPenalty = 10.0
    private static let metaspace: Unicode.Scalar = "\u{2581}"

    private let pieces: [String: Int]
    private let scores: [Float]
    private let unknownID: Int
    private let unknownScore: Double
    private let maxPieceScalars: Int

    var vocabularySize: Int { scores.count }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              (model["type"] as? String) == "Unigram",
              let vocab = model["vocab"] as? [[Any]] else {
            throw LocalRAGError.invalidModel("tokenizer.json is not a Unigram model")
        }
        var pieces = [String: Int](minimumCapacity: vocab.count)
        var scores = [Float](repeating: 0, count: vocab.count)
        var maxScalars = 1
        for (index, item) in vocab.enumerated() {
            guard item.count == 2, let piece = item[0] as? String else { continue }
            scores[index] = Float((item[1] as? NSNumber)?.doubleValue ?? 0)
            if pieces[piece] == nil { pieces[piece] = index }   // first occurrence wins, as in the reference tokenizer
            maxScalars = max(maxScalars, piece.unicodeScalars.count)
        }
        self.pieces = pieces
        self.scores = scores
        self.unknownID = (model["unk_id"] as? NSNumber)?.intValue ?? 3
        self.maxPieceScalars = maxScalars
        self.unknownScore = Double(scores.min() ?? 0) - Self.unknownPenalty
    }

    /// Token IDs with <s> … </s>, truncated to `maxLength` (including the special tokens).
    func encode(_ text: String, maxLength: Int = 512) -> [Int] {
        var ids = [Self.bosID]
        let normalized = Self.normalize(text)
        if !normalized.isEmpty {
            for word in Self.preTokenize(normalized) {
                encodeWord(word, into: &ids)
                if ids.count >= maxLength - 1 { break }
            }
        }
        if ids.count > maxLength - 1 { ids.removeSubrange((maxLength - 1)...) }
        ids.append(Self.eosID)
        return ids
    }

    static func normalize(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        var previousSpace = false
        for scalar in nfkc.unicodeScalars {
            if scalar.properties.isWhitespace || (scalar.value >= 0x09 && scalar.value <= 0x0D) || scalar.value == 0x85 {
                if !previousSpace { scalars.append(" ") }
                previousSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format: continue
            default: break
            }
            scalars.append(scalar)
            previousSpace = false
        }
        return String(scalars)
    }

    /// Metaspace: spaces become "▁", a leading "▁" is added, and every word starts at a "▁".
    static func preTokenize(_ normalized: String) -> [[Unicode.Scalar]] {
        var scalars = normalized.unicodeScalars.map { $0 == " " ? metaspace : $0 }
        if scalars.first != metaspace { scalars.insert(metaspace, at: 0) }
        var words: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in scalars {
            if scalar == metaspace && !current.isEmpty {
                words.append(current)
                current = []
            }
            current.append(scalar)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Viterbi search for the most likely segmentation; unknown characters become <unk> (consecutive ones fused).
    private func encodeWord(_ word: [Unicode.Scalar], into output: inout [Int]) {
        let count = word.count
        var bestScore = [Double](repeating: -.infinity, count: count + 1)
        var bestStart = [Int](repeating: 0, count: count + 1)
        var bestID = [Int](repeating: 0, count: count + 1)
        bestScore[0] = 0
        for start in 0..<count where bestScore[start] > -.infinity {
            var hasSingle = false
            let limit = min(count, start + maxPieceScalars)
            var piece = String.UnicodeScalarView()
            for end in (start + 1)...max(start + 1, limit) {
                piece.append(word[end - 1])
                guard let id = pieces[String(piece)] else { continue }
                if end == start + 1 { hasSingle = true }
                let score = bestScore[start] + Double(scores[id])
                if score > bestScore[end] { bestScore[end] = score; bestStart[end] = start; bestID[end] = id }
            }
            if !hasSingle {
                let score = bestScore[start] + unknownScore
                if score > bestScore[start + 1] { bestScore[start + 1] = score; bestStart[start + 1] = start; bestID[start + 1] = unknownID }
            }
        }
        var path: [Int] = []
        var end = count
        while end > 0 {
            path.append(bestID[end])
            end = bestStart[end]
        }
        for id in path.reversed() {
            if id == unknownID, output.last == unknownID { continue }
            output.append(id)
        }
    }
}

enum LocalRAGError: Error, LocalizedError {
    case invalidModel(String)
    case runtimeUnavailable(String)
    case runtime(String)
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .invalidModel(let message), .runtimeUnavailable(let message), .runtime(let message), .storage(let message): return message
        }
    }
}
