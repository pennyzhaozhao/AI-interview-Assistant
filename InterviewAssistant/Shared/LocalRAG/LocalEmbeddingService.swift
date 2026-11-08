import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Local sentence embeddings with ONNX Runtime (CPU): intfloat/multilingual-e5-small, int8 ONNX export (Xenova),
/// 384 dimensions, MIT license; mean pooling over the attention mask + L2 normalization. Same model, tokenizer and
/// pooling as the Windows app (LocalEmbeddingService.cs). No network access.
///
/// ONNX Runtime is the copy that already ships inside the app for speaker verification (sherpa-onnx's
/// onnxruntime.framework). It is reached through its stable C API: `OrtGetApiBase` is looked up at run time and
/// API version 17 is requested, which every runtime from 1.17 on provides (the API table only ever grows).
final class LocalEmbeddingService: @unchecked Sendable {
    /// Changing the model, export, pooling or tokenizer must change this string: stored vectors are then re-embedded.
    static let modelVersion = "multilingual-e5-small/xenova-int8/mean-l2/v1"
    static let dimension = 384
    static let maxSequenceLength = 512
    static let modelFileName = "model_quantized.onnx"
    static let tokenizerFileName = "tokenizer.json"
    private static let apiVersion: UInt32 = 17

    let tokenizer: XLMRobertaTokenizer
    private let api: UnsafePointer<OrtApi>
    private var env: OpaquePointer?
    private var session: OpaquePointer?
    private var memoryInfo: OpaquePointer?

    static func filesExist(in directory: URL?) -> Bool {
        guard let directory else { return false }
        let manager = FileManager.default
        return manager.fileExists(atPath: directory.appendingPathComponent(modelFileName).path)
            && manager.fileExists(atPath: directory.appendingPathComponent(tokenizerFileName).path)
    }

    init(modelDirectory: URL, threads: Int? = nil) throws {
        tokenizer = try XLMRobertaTokenizer(contentsOf: modelDirectory.appendingPathComponent(Self.tokenizerFileName))
        api = try Self.loadAPI()
        try check(api.pointee.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "InterviewAssistant.LocalRAG", &env))
        var options: OpaquePointer?
        try check(api.pointee.CreateSessionOptions(&options))
        defer { api.pointee.ReleaseSessionOptions(options) }
        let threadCount = threads ?? max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        try check(api.pointee.SetIntraOpNumThreads(options, Int32(threadCount)))
        try check(api.pointee.SetInterOpNumThreads(options, 1))
        try check(api.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        let modelPath = modelDirectory.appendingPathComponent(Self.modelFileName).path
        try modelPath.withCString { path in
            try check(api.pointee.CreateSession(env, path, options, &session))
        }
        try check(api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo))
    }

    deinit {
        if let memoryInfo { api.pointee.ReleaseMemoryInfo(memoryInfo) }
        if let session { api.pointee.ReleaseSession(session) }
        if let env { api.pointee.ReleaseEnv(env) }
    }

    /// Embeds an interview question ("query: " prefix, as e5 expects).
    func embedQuery(_ query: String) throws -> [Float] { try embed(["query: " + query])[0] }

    /// Embeds passages (callers pass RagChunk.embeddingText, which carries the "passage: " prefix).
    /// One text per run: the int8 model quantizes activations over the whole input, so batching would make vectors
    /// depend on their neighbours. Single runs keep every vector reproducible.
    func embed(_ texts: [String], isCancelled: () -> Bool = { false }) throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            if isCancelled() { throw CancellationError() }
            vectors.append(try run(tokenizer.encode(text, maxLength: Self.maxSequenceLength)))
        }
        return vectors
    }

    private func run(_ ids: [Int]) throws -> [Float] {
        let length = ids.count
        let inputIDs = UnsafeMutablePointer<Int64>.allocate(capacity: length)
        let mask = UnsafeMutablePointer<Int64>.allocate(capacity: length)
        let types = UnsafeMutablePointer<Int64>.allocate(capacity: length)
        defer { inputIDs.deallocate(); mask.deallocate(); types.deallocate() }
        for index in 0..<length {
            inputIDs[index] = Int64(ids[index])
            mask[index] = 1
            types[index] = 0
        }
        var shape: [Int64] = [1, Int64(length)]
        var values: [OpaquePointer?] = [nil, nil, nil]
        defer { for value in values where value != nil { api.pointee.ReleaseValue(value) } }
        let byteCount = length * MemoryLayout<Int64>.size
        for (slot, buffer) in [inputIDs, mask, types].enumerated() {
            var value: OpaquePointer?
            try check(api.pointee.CreateTensorWithDataAsOrtValue(memoryInfo, UnsafeMutableRawPointer(buffer), byteCount, &shape, 2,
                                                                ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &value))
            values[slot] = value
        }

        let inputNames = ["input_ids", "attention_mask", "token_type_ids"].map { strdup($0) }
        let outputNames = [strdup("last_hidden_state")]
        defer { (inputNames + outputNames).forEach { free($0) } }
        let inputNamePointers: [UnsafePointer<CChar>?] = inputNames.map { UnsafePointer($0) }
        let outputNamePointers: [UnsafePointer<CChar>?] = outputNames.map { UnsafePointer($0) }
        var outputs: [OpaquePointer?] = [nil]
        try check(api.pointee.Run(session, nil, inputNamePointers, values, 3, outputNamePointers, 1, &outputs))
        defer { if let output = outputs[0] { api.pointee.ReleaseValue(output) } }

        var raw: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(outputs[0], &raw))
        guard let raw else { throw LocalRAGError.runtime("Empty model output") }
        let hidden = raw.bindMemory(to: Float.self, capacity: length * Self.dimension)
        var vector = [Float](repeating: 0, count: Self.dimension)
        for token in 0..<length {
            let base = token * Self.dimension
            for dimension in 0..<Self.dimension { vector[dimension] += hidden[base + dimension] }
        }
        let count = Float(length)
        return VectorMath.normalize(vector.map { $0 / count })
    }

    private func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "ONNX Runtime error"
        api.pointee.ReleaseStatus(status)
        throw LocalRAGError.runtime(message)
    }

    private static func loadAPI() throws -> UnsafePointer<OrtApi> {
        typealias GetAPIBase = @convention(c) () -> UnsafePointer<OrtApiBase>?
        #if canImport(Darwin)
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT: images already loaded in the process
        #else
        let defaultHandle: UnsafeMutableRawPointer? = nil
        #endif
        var symbol = dlsym(defaultHandle, "OrtGetApiBase")
        if symbol == nil {
            for path in libraryCandidates() {
                guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
                if let found = dlsym(handle, "OrtGetApiBase") { symbol = found; break }
            }
        }
        guard let symbol else { throw LocalRAGError.runtimeUnavailable("ONNX Runtime is not available") }
        let getAPIBase = unsafeBitCast(symbol, to: GetAPIBase.self)
        guard let base = getAPIBase(), let api = base.pointee.GetApi(apiVersion) else {
            throw LocalRAGError.runtimeUnavailable("This ONNX Runtime does not support C API version \(apiVersion)")
        }
        return api
    }

    private static func libraryCandidates() -> [String] {
        var paths: [String] = []
        if let frameworks = Bundle.main.privateFrameworksURL {
            paths.append(frameworks.appendingPathComponent("libonnxruntime.dylib").path)
            paths.append(frameworks.appendingPathComponent("onnxruntime.framework/Versions/A/onnxruntime").path)
            paths.append(frameworks.appendingPathComponent("onnxruntime.framework/onnxruntime").path)
        }
        paths.append("libonnxruntime.dylib")
        paths.append("libonnxruntime.so")
        return paths
    }
}
