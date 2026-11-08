import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

// Local RAG core types and text utilities. This folder mirrors the Windows library
// (Windows platform/src/InterviewAssistant.Rag) one to one: the same tokenizer, chunking rules, chunk IDs,
// keyword terms and scoring, so both apps index and retrieve the same way and their vectors are compatible.

enum RagKinds {
    static let resume = "resume"
    static let project = "project"
    static let material = "material"
}

/// Read-only snapshot of one knowledge entry taken from SwiftData. The index never writes back to the knowledge base.
struct RagDocument: Sendable, Equatable {
    var knowledgeBaseID: UUID
    var knowledgeBaseName: String
    var entryID: UUID
    var title: String
    var kind: String
    var source: String
    var summary: String
    var meta: String
    var content: String
    var isEnabled: Bool
}

/// A searchable passage of one knowledge entry.
struct RagChunk: Sendable, Equatable {
    var chunkID: String
    var knowledgeBaseID: UUID
    var entryID: UUID
    var title: String
    var kind: String
    var source: String
    var chunkIndex: Int
    var section: String
    var text: String
    var contentHash: String
    var isQuestionAnswer: Bool

    /// Text given to the embedding model (e5 needs the "passage: " prefix).
    var embeddingText: String { "passage: " + title + (section.isEmpty ? "" : " / " + section) + "\n" + text }
    /// Text indexed for keyword search; the title is repeated so project names weigh more.
    var lexicalText: String { title + "\n" + title + "\n" + section + "\n" + text }
}

struct RetrievedChunk: Sendable {
    var chunk: RagChunk
    var text: String
    var fusedScore: Double
    var cosine: Double?
    var bm25: Double?
}

enum RetrievalMode: Sendable { case hybrid, lexicalOnly, fallback, none }

struct RetrievalTimings: Sendable {
    var queryEmbeddingMs: Double = 0
    var vectorSearchMs: Double = 0
    var keywordSearchMs: Double = 0
    var fusionMs: Double = 0
    var totalMs: Double = 0
}

struct RetrievalResult: Sendable {
    var chunks: [RetrievedChunk]
    var mode: RetrievalMode
    var timings: RetrievalTimings
    static func empty(_ mode: RetrievalMode) -> RetrievalResult { RetrievalResult(chunks: [], mode: mode, timings: RetrievalTimings()) }
}

enum RagText {
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func sha256Hex(_ text: String) -> String { SHA256Digest.hex(Array(text.utf8)) }
}

/// Conservative, model-independent token estimate (same weights as TokenEstimator.cs; see notes there).
/// Counted per UTF-16 unit like the C# version so chunk boundaries — and chunk IDs — match across platforms.
enum TokenEstimator {
    static func estimate(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        var total = 0.0
        for unit in text.utf16 {
            if unit >= 0xDC00 && unit <= 0xDFFF { continue }                 // low surrogate: counted with its pair
            if let scalar = Unicode.Scalar(UInt32(unit)) {
                if RagText.isCJK(scalar) { total += 1.0; continue }
                if scalar.properties.isWhitespace || isDotNetWhitespace(unit) { continue }
                if unit < 128 { total += isAsciiLetterOrDigit(unit) ? 0.34 : 1.0 } else { total += 1.0 }
            } else {
                total += 1.0                                                  // high surrogate (emoji, etc.)
            }
        }
        return Int(total.rounded(.up))
    }

    private static func isAsciiLetterOrDigit(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }

    /// .NET char.IsWhiteSpace also treats these control characters as white space.
    private static func isDotNetWhitespace(_ unit: UInt16) -> Bool {
        (unit >= 0x09 && unit <= 0x0D) || unit == 0x85 || unit == 0xA0
    }
}

/// Keyword terms for BM25 (same rules as LexicalAnalyzer.cs): lowercase Latin words/numbers, light stemming,
/// CJK character bigrams. Exact technical names (FastAPI, PyTorch, Kubernetes, SQL) match without semantics.
enum LexicalAnalyzer {
    private static let stopWords: Set<String> = [
        "the", "and", "for", "you", "your", "are", "was", "were", "with", "that", "this", "what", "how", "why",
        "can", "could", "would", "about", "have", "has", "had", "did", "does", "from", "tell", "me", "is", "it",
        "of", "to", "in", "on", "a", "an", "or", "be", "do", "as", "at", "by", "we", "our", "my", "i", "any",
        "some", "there", "their", "they", "them", "then", "than", "so", "if", "when", "which", "who", "will", "into",
        "more", "most", "very", "also", "just", "give", "example", "describe", "explain", "walk", "through", "please",
        "query", "passage"
    ]
    private static let cjkStopBigrams: Set<String> = [
        "一下", "什么", "怎么", "如何", "你的", "我的", "一个", "这个", "那个", "可以", "是否", "为什", "么样",
        "请问", "介绍", "说说", "讲讲", "谈谈", "觉得", "我们", "你们", "他们", "的时", "时候", "有没", "没有",
        "是什", "做过", "过什", "么项", "一些", "哪些", "这些", "那些", "以及", "还有", "然后"
    ]

    static func terms(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        var previousCJK: Unicode.Scalar?
        func flushWord() {
            if !word.isEmpty {
                let value = word.trimmingCharacters(in: CharacterSet(charactersIn: "+#.-"))
                if word == "c++" || word == "c#" || word == "f#" { tokens.append(word) }
                else if value.unicodeScalars.count >= 2 && !stopWords.contains(value) { tokens.append(stem(value)) }
                else if value.unicodeScalars.count == 1, let first = value.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) { tokens.append(value) }
            }
            word = ""
        }
        for scalar in text.lowercased().unicodeScalars {
            if RagText.isCJK(scalar) {
                flushWord()
                if let previous = previousCJK {
                    let bigram = String(String.UnicodeScalarView([previous, scalar]))
                    if !cjkStopBigrams.contains(bigram) { tokens.append(bigram) }
                }
                previousCJK = scalar
            } else if scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar) || scalar == "+" || scalar == "#" {
                previousCJK = nil
                word.unicodeScalars.append(scalar)
            } else if (scalar == "." || scalar == "-") && !word.isEmpty {
                if scalar == ".", let last = word.unicodeScalars.last, CharacterSet.decimalDigits.contains(last) {
                    word.unicodeScalars.append(scalar)
                    continue
                }
                flushWord()
                previousCJK = nil
            } else {
                previousCJK = nil
                flushWord()
            }
        }
        flushWord()
        return tokens
    }

    static func termFrequencies(_ text: String) -> [String: Int] {
        var frequencies: [String: Int] = [:]
        for term in terms(text) { frequencies[term, default: 0] += 1 }
        return frequencies
    }

    static func stem(_ word: String) -> String {
        guard word.count > 4, word.unicodeScalars.allSatisfy({ $0.value >= 97 && $0.value <= 122 }) else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("ing") && word.count > 5 { return String(word.dropLast(3)) }
        if word.hasSuffix("ed") { return String(word.dropLast(2)) }
        if word.hasSuffix("es") && !word.hasSuffix("ses") { return String(word.dropLast(2)) }
        if word.hasSuffix("s") && !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}

enum VectorMath {
    /// e = f(x) / ‖f(x)‖₂. Zero, NaN or infinite vectors become all-zero (and are never matched).
    static func normalize(_ vector: [Float]) -> [Float] {
        var sum = 0.0
        for value in vector {
            guard value.isFinite else { return [Float](repeating: 0, count: vector.count) }
            sum += Double(value) * Double(value)
        }
        let norm = sum.squareRoot()
        guard norm >= 1e-12, norm.isFinite else { return [Float](repeating: 0, count: vector.count) }
        return vector.map { Float(Double($0) / norm) }
    }

    static func isUsable(_ vector: [Float]?) -> Bool {
        guard let vector, !vector.isEmpty else { return false }
        return vector.contains { $0 != 0 }
    }

    static func dot(_ left: [Float], _ right: [Float]) -> Double {
        let count = min(left.count, right.count)
        #if canImport(Accelerate)
        var result: Float = 0
        vDSP_dotpr(left, 1, right, 1, &result, vDSP_Length(count))
        return Double(result)
        #else
        var result: Float = 0
        for index in 0..<count { result += left[index] * right[index] }
        return Double(result)
        #endif
    }

    static func toData(_ vector: [Float]) -> Data {
        var littleEndian = vector.map { $0.bitPattern.littleEndian }
        return Data(bytes: &littleEndian, count: littleEndian.count * MemoryLayout<UInt32>.size)
    }

    static func fromData(_ data: Data?, dimension: Int) -> [Float]? {
        guard let data, data.count == dimension * MemoryLayout<UInt32>.size else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<dimension).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }
}

/// Small dependency-free SHA-256 (FIPS 180-4) so chunk IDs are identical to the Windows app's
/// System.Security.Cryptography.SHA256 output on every platform.
enum SHA256Digest {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hex(_ bytes: [UInt8]) -> String {
        var hash: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = bytes
        let bitLength = UInt64(bytes.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let base = chunk + i * 4
                w[i] = UInt32(message[base]) << 24 | UInt32(message[base + 1]) << 16 | UInt32(message[base + 2]) << 8 | UInt32(message[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3], e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                h = g; g = f; f = e; e = d &+ temp1; d = c; c = b; b = a; a = temp1 &+ temp2
            }
            hash[0] &+= a; hash[1] &+= b; hash[2] &+= c; hash[3] &+= d
            hash[4] &+= e; hash[5] &+= f; hash[6] &+= g; hash[7] &+= h
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 { (value >> amount) | (value << (32 - amount)) }
}
