import Foundation
import CryptoKit
@preconcurrency import AVFoundation
import SherpaOnnxShared

protocol SpeakerEmbeddingExtractor: Sendable {
    func embedding(for samples16kMono: [Float]) throws -> [Float]
}

struct SpeakerProfile: Codable, Sendable, Equatable {
    var embedding: [Float]
    var rmsBaseline: Float
    var highThreshold: Float
    var lowThreshold: Float
    var modelID: String
    var modelVersion: String
}

struct StoredSpeakerVoice: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var profile: SpeakerProfile
    let createdAt: Date
}

private struct SpeakerProfileCollection: Codable {
    var voices: [StoredSpeakerVoice]
    var selectedID: UUID?
}

enum SpeakerVerificationConstants {
    static let embeddingWeight: Float = 0.60
    static let rmsWeight: Float = 0.25
    static let answerOverlapWeight: Float = 0.15
    static let minimumEmbeddingDuration: Double = 1.2
    static let defaultHighThreshold: Float = 0.72
    static let defaultLowThreshold: Float = 0.48
    static let windowSeconds: Double = 1.5
    static let windowStepSeconds: Double = 0.75
    static let changeSimilarityThreshold: Float = 0.62
}

enum SpeakerVerifierError: LocalizedError {
    case noProfile
    case emptyEnrollment
    case invalidEmbedding
    case modelNotDownloaded
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .noProfile: return L.t("No voice profile is enrolled")
        case .emptyEnrollment: return L.t("Record at least three voice samples")
        case .invalidEmbedding: return L.t("The voice sample was too short or unclear")
        case .modelNotDownloaded: return L.t("Download the speaker model first")
        case .checksumMismatch: return L.t("The downloaded speaker model failed verification")
        }
    }
}

final class SherpaSpeakerEmbeddingExtractor: SpeakerEmbeddingExtractor, @unchecked Sendable {
    private let extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper

    init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw SpeakerVerifierError.modelNotDownloaded
        }
        var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: modelURL.path,
            numThreads: 1,
            debug: 0,
            provider: "cpu"
        )
        extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
    }

    func embedding(for samples16kMono: [Float]) throws -> [Float] {
        guard samples16kMono.count >= 8_000 else { throw SpeakerVerifierError.invalidEmbedding }
        let stream = extractor.createStream()
        stream.acceptWaveform(samples: samples16kMono, sampleRate: 16_000)
        stream.inputFinished()
        let result = extractor.compute(stream: stream)
        guard !result.isEmpty else { throw SpeakerVerifierError.invalidEmbedding }
        return SpeakerVerifier.normalized(result)
    }
}

actor SpeakerVerifier {
    static let profileKeychainAccount = "speaker-verifier-profile-v1"

    private let extractor: SpeakerEmbeddingExtractor
    private(set) var profile: SpeakerProfile?

    init(extractor: SpeakerEmbeddingExtractor, profile: SpeakerProfile? = SpeakerProfileStore.load()) {
        self.extractor = extractor
        self.profile = profile
    }

    @discardableResult
    func enroll(samples: [[Float]], meanRMS: Float, modelID: String, modelVersion: String) throws -> SpeakerProfile {
        guard samples.count >= 3 else { throw SpeakerVerifierError.emptyEnrollment }
        let vectors = try samples.map { try extractor.embedding(for: $0) }
        guard let dimension = vectors.first?.count, dimension > 0,
              vectors.allSatisfy({ $0.count == dimension }) else {
            throw SpeakerVerifierError.invalidEmbedding
        }
        var centroid = [Float](repeating: 0, count: dimension)
        for vector in vectors {
            for index in vector.indices { centroid[index] += vector[index] }
        }
        centroid = Self.normalized(centroid.map { $0 / Float(vectors.count) })
        let enrolled = SpeakerProfile(
            embedding: centroid,
            rmsBaseline: meanRMS,
            highThreshold: SpeakerVerificationConstants.defaultHighThreshold,
            lowThreshold: SpeakerVerificationConstants.defaultLowThreshold,
            modelID: modelID,
            modelVersion: modelVersion
        )
        profile = enrolled
        return enrolled
    }

    func calibrate(with samples16kMono: [Float]) throws -> Float {
        guard var profile else { throw SpeakerVerifierError.noProfile }
        let score = try Self.cosineSimilarity(extractor.embedding(for: samples16kMono), profile.embedding)
        profile.highThreshold = max(0.55, min(0.90, score - 0.10))
        profile.lowThreshold = max(0.35, profile.highThreshold - 0.20)
        self.profile = profile
        return score
    }

    func currentProfile() -> SpeakerProfile? {
        profile
    }

    func score(_ samples16kMono: [Float]) throws -> Float {
        guard let profile else { throw SpeakerVerifierError.noProfile }
        return try Self.cosineSimilarity(extractor.embedding(for: samples16kMono), profile.embedding)
    }

    func classify(
        _ samples16kMono: [Float],
        meanRMS: Float,
        answerOverlap: Float = 0
    ) throws -> (SpeakerLabel, Float) {
        guard let profile else { return (.unknown, 0) }
        let duration = Double(samples16kMono.count) / 16_000
        let rmsCloseness = Self.rmsCloseness(meanRMS, baseline: profile.rmsBaseline)
        if duration < SpeakerVerificationConstants.minimumEmbeddingDuration {
            let shortScore = (0.625 * rmsCloseness) + (0.375 * max(0, min(1, answerOverlap)))
            return (.unknown, shortScore)
        }

        let started = ContinuousClock.now
        let similarity = try score(samples16kMono)
        let fused = Self.fusedScore(
            similarity: similarity,
            rmsCloseness: rmsCloseness,
            answerOverlap: answerOverlap
        )
        let sensitivity = Float(UserDefaults.standard.object(forKey: AppPreferenceKey.speakerRecognitionSensitivity) as? Double ?? 0.5)
        let adjustment = (0.5 - max(0, min(1, sensitivity))) * 0.20
        let label = Self.classify(
            score: fused,
            high: profile.highThreshold + adjustment,
            low: profile.lowThreshold + adjustment
        )
        #if DEBUG
        if UserDefaults.standard.bool(forKey: AppPreferenceKey.speakerRecognitionDebugLogging) {
            let elapsed = started.duration(to: .now)
            print("[SpeakerVerifier] speaker=\(String(format: "%.3f", similarity)) rms=\(String(format: "%.3f", rmsCloseness)) overlap=\(String(format: "%.3f", answerOverlap)) fused=\(String(format: "%.3f", fused)) label=\(label.rawValue) elapsed=\(elapsed)")
        }
        #endif
        return (label, fused)
    }

    func segmentChangePoints(_ samples16kMono: [Float]) throws -> [ClosedRange<Double>] {
        let size = Int(SpeakerVerificationConstants.windowSeconds * 16_000)
        let step = Int(SpeakerVerificationConstants.windowStepSeconds * 16_000)
        guard samples16kMono.count >= size else { return [] }
        var embeddings: [[Float]] = []
        var starts: [Double] = []
        var offset = 0
        while offset + size <= samples16kMono.count {
            embeddings.append(try extractor.embedding(for: Array(samples16kMono[offset..<(offset + size)])))
            starts.append(Double(offset) / 16_000)
            offset += step
        }
        return Self.changePointRanges(embeddings: embeddings, windowStarts: starts)
    }

    static func fusedScore(similarity: Float, rmsCloseness: Float, answerOverlap: Float) -> Float {
        (SpeakerVerificationConstants.embeddingWeight * max(-1, min(1, similarity)))
            + (SpeakerVerificationConstants.rmsWeight * max(0, min(1, rmsCloseness)))
            + (SpeakerVerificationConstants.answerOverlapWeight * max(0, min(1, answerOverlap)))
    }

    static func classify(score: Float, high: Float, low: Float) -> SpeakerLabel {
        if score >= high { return .candidate }
        if score <= low { return .interviewer }
        return .unknown
    }

    static func changePointRanges(
        embeddings: [[Float]],
        windowStarts: [Double],
        threshold: Float = SpeakerVerificationConstants.changeSimilarityThreshold
    ) -> [ClosedRange<Double>] {
        guard embeddings.count == windowStarts.count, embeddings.count > 1 else { return [] }
        return (1..<embeddings.count).compactMap { index in
            guard let similarity = try? cosineSimilarity(embeddings[index - 1], embeddings[index]),
                  similarity < threshold else { return nil }
            let center = windowStarts[index] + (SpeakerVerificationConstants.windowSeconds / 2)
            let radius = SpeakerVerificationConstants.windowStepSeconds / 2
            return (center - radius)...(center + radius)
        }
    }

    static func rmsCloseness(_ value: Float, baseline: Float) -> Float {
        guard value > 0, baseline > 0 else { return 0 }
        let ratio = max(value, baseline) / min(value, baseline)
        return max(0, 1 - (log(ratio) / log(4)))
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) throws -> Float {
        guard !lhs.isEmpty, lhs.count == rhs.count else { throw SpeakerVerifierError.invalidEmbedding }
        var dot: Float = 0
        var leftNorm: Float = 0
        var rightNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftNorm += lhs[index] * lhs[index]
            rightNorm += rhs[index] * rhs[index]
        }
        guard leftNorm > 0, rightNorm > 0 else { throw SpeakerVerifierError.invalidEmbedding }
        return dot / (sqrt(leftNorm) * sqrt(rightNorm))
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + ($1 * $1) })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

enum SpeakerProfileStore {
    private static let collectionKeychainAccount = "speaker-verifier-profiles-v2"

    static func load() -> SpeakerProfile? {
        selectedVoice()?.profile
    }

    static func voices() -> [StoredSpeakerVoice] {
        loadCollection().voices.sorted { $0.createdAt < $1.createdAt }
    }

    static func selectedVoice() -> StoredSpeakerVoice? {
        let collection = loadCollection()
        guard let selectedID = collection.selectedID else { return nil }
        return collection.voices.first { $0.id == selectedID }
    }

    @discardableResult
    static func add(_ profile: SpeakerProfile, named name: String) throws -> StoredSpeakerVoice {
        var collection = loadCollection()
        let voice = StoredSpeakerVoice(
            id: UUID(),
            name: normalizedName(name, fallbackIndex: collection.voices.count + 1),
            profile: profile,
            createdAt: Date()
        )
        collection.voices.append(voice)
        collection.selectedID = voice.id
        try persist(collection)
        UserDefaults.standard.set(true, forKey: AppPreferenceKey.speakerRecognitionEnabled)
        return voice
    }

    static func select(_ id: UUID?) throws {
        var collection = loadCollection()
        guard id == nil || collection.voices.contains(where: { $0.id == id }) else { return }
        collection.selectedID = id
        try persist(collection)
        UserDefaults.standard.set(id != nil, forKey: AppPreferenceKey.speakerRecognitionEnabled)
    }

    static func rename(_ id: UUID, to name: String) throws {
        var collection = loadCollection()
        guard let index = collection.voices.firstIndex(where: { $0.id == id }) else { return }
        collection.voices[index].name = normalizedName(name, fallbackIndex: index + 1)
        try persist(collection)
    }

    static func update(_ id: UUID, profile: SpeakerProfile) throws {
        var collection = loadCollection()
        guard let index = collection.voices.firstIndex(where: { $0.id == id }) else { return }
        collection.voices[index].profile = profile
        try persist(collection)
    }

    static func delete(_ id: UUID) throws {
        var collection = loadCollection()
        collection.voices.removeAll { $0.id == id }
        if collection.selectedID == id {
            collection.selectedID = nil
            UserDefaults.standard.set(false, forKey: AppPreferenceKey.speakerRecognitionEnabled)
        }
        try persist(collection)
    }

    static func save(_ profile: SpeakerProfile) throws {
        var collection = loadCollection()
        if let selectedID = collection.selectedID,
           let index = collection.voices.firstIndex(where: { $0.id == selectedID }) {
            collection.voices[index].profile = profile
            try persist(collection)
        } else {
            _ = try add(profile, named: L.t("Voice"))
        }
    }

    static func delete() throws {
        try KeychainStore.save("", account: collectionKeychainAccount)
        try KeychainStore.save("", account: SpeakerVerifier.profileKeychainAccount)
        UserDefaults.standard.set(false, forKey: AppPreferenceKey.speakerRecognitionEnabled)
    }

    private static func loadCollection() -> SpeakerProfileCollection {
        let encoded = KeychainStore.read(collectionKeychainAccount)
        if let data = Data(base64Encoded: encoded),
           let collection = try? JSONDecoder().decode(SpeakerProfileCollection.self, from: data) {
            return collection
        }

        let legacyEncoded = KeychainStore.read(SpeakerVerifier.profileKeychainAccount)
        guard let legacyData = Data(base64Encoded: legacyEncoded),
              let profile = try? JSONDecoder().decode(SpeakerProfile.self, from: legacyData) else {
            return SpeakerProfileCollection(voices: [], selectedID: nil)
        }
        let voice = StoredSpeakerVoice(id: UUID(), name: L.t("Voice") + " 1", profile: profile, createdAt: Date())
        let selectedID = UserDefaults.standard.bool(forKey: AppPreferenceKey.speakerRecognitionEnabled) ? voice.id : nil
        let migrated = SpeakerProfileCollection(voices: [voice], selectedID: selectedID)
        try? persist(migrated)
        return migrated
    }

    private static func persist(_ collection: SpeakerProfileCollection) throws {
        let data = try JSONEncoder().encode(collection)
        try KeychainStore.save(data.base64EncodedString(), account: collectionKeychainAccount)
    }

    private static func normalizedName(_ name: String, fallbackIndex: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L.t("Voice") + " \(fallbackIndex)" : trimmed
    }
}

enum SpeakerModelManager {
    static let modelID = "3dspeaker-campplus-zh-cn-16k-common"
    static let modelVersion = "sha256:f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11"
    static let expectedSHA256 = "f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11"
    static let downloadURL = URL(string: "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")!

    static var modelURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "InterviewAssistant/SpeakerModels", directoryHint: .isDirectory)
            .appending(path: "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")
    }

    static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    static func download() async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try await Task.detached {
            let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expectedSHA256 else { throw SpeakerVerifierError.checksumMismatch }
            let destination = modelURL
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return destination
        }.value
    }
}

enum SpeakerAudioConverter {
    static func samples16kMono(from buffers: [SendablePCMBuffer]) throws -> [Float] {
        try samples16kMono(from: buffers.map(\.buffer))
    }

    static func samples16kMono(from buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        var output: [Float] = []
        for buffer in buffers {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: buffer.format, to: target) else { continue }
            let ratio = 16_000 / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { continue }
            var supplied = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                guard !supplied else {
                    status.pointee = .endOfStream
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if let conversionError { throw conversionError }
            if let channel = converted.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            }
        }
        return output
    }
}

actor SpeakerVerificationService {
    static let shared = SpeakerVerificationService()

    private var verifier: SpeakerVerifier?
    private var loadedVoiceID: UUID?

    struct Analysis: Sendable {
        let label: SpeakerLabel
        let score: Float
        let interviewerSamples: [Float]?
    }

    func analyze(
        buffers: [SendablePCMBuffer],
        meanRMS: Float,
        answerOverlap: Float
    ) async -> Analysis? {
        guard let samples = try? SpeakerAudioConverter.samples16kMono(from: buffers),
              let full = await classify(samples16kMono: samples, meanRMS: meanRMS, answerOverlap: answerOverlap),
              let verifier else { return nil }
        guard samples.count >= Int(SpeakerVerificationConstants.windowSeconds * 2 * 16_000),
              let changes = try? await verifier.segmentChangePoints(samples),
              !changes.isEmpty else {
            return Analysis(label: full.0, score: full.1, interviewerSamples: nil)
        }

        let boundaries = changes.map { Int((($0.lowerBound + $0.upperBound) / 2) * 16_000) }
            .filter { $0 > 0 && $0 < samples.count }
        var accepted: [Float] = []
        var labels: [SpeakerLabel] = []
        var scores: [Float] = []
        var start = 0
        for end in boundaries + [samples.count] {
            let segment = Array(samples[start..<end])
            let rms = sqrt(segment.reduce(Float.zero) { $0 + ($1 * $1) } / Float(max(segment.count, 1))) * Float(Int16.max)
            if let result = try? await verifier.classify(segment, meanRMS: rms, answerOverlap: answerOverlap) {
                labels.append(result.0)
                scores.append(result.1)
                if result.0 != .candidate { accepted.append(contentsOf: segment) }
            } else {
                accepted.append(contentsOf: segment)
            }
            start = end
        }
        guard !accepted.isEmpty else { return Analysis(label: .candidate, score: scores.max() ?? full.1, interviewerSamples: []) }
        let label: SpeakerLabel = labels.contains(.interviewer) ? .interviewer : .unknown
        return Analysis(label: label, score: scores.isEmpty ? full.1 : scores.reduce(0, +) / Float(scores.count), interviewerSamples: accepted)
    }

    func classify(
        buffers: [SendablePCMBuffer],
        meanRMS: Float,
        answerOverlap: Float
    ) async -> (SpeakerLabel, Float)? {
        guard let samples = try? SpeakerAudioConverter.samples16kMono(from: buffers) else { return nil }
        return await classify(samples16kMono: samples, meanRMS: meanRMS, answerOverlap: answerOverlap)
    }

    func classify(
        samples16kMono: [Float],
        meanRMS: Float,
        answerOverlap: Float
    ) async -> (SpeakerLabel, Float)? {
        guard UserDefaults.standard.bool(forKey: AppPreferenceKey.speakerRecognitionEnabled),
              SpeakerModelManager.isDownloaded,
              let voice = SpeakerProfileStore.selectedVoice(),
              voice.profile.modelID == SpeakerModelManager.modelID,
              voice.profile.modelVersion == SpeakerModelManager.modelVersion else { return nil }
        let profile = voice.profile
        do {
            if verifier == nil || loadedVoiceID != voice.id {
                let extractor = try SherpaSpeakerEmbeddingExtractor(modelURL: SpeakerModelManager.modelURL)
                verifier = SpeakerVerifier(extractor: extractor, profile: profile)
                loadedVoiceID = voice.id
            }
            return try await verifier?.classify(samples16kMono, meanRMS: meanRMS, answerOverlap: answerOverlap)
        } catch {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: AppPreferenceKey.speakerRecognitionDebugLogging) {
                print("[SpeakerVerifier] classification failed: \(error.localizedDescription)")
            }
            #endif
            return nil
        }
    }

    func reset() {
        verifier = nil
        loadedVoiceID = nil
    }
}
