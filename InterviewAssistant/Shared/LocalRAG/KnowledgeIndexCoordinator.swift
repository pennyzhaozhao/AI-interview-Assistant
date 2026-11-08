import Foundation

enum RagIndexState: Sendable { case starting, indexing, ready, keywordOnly, error }

/// What the knowledge-base screen shows: state, progress and the last error (never document text).
struct RagIndexStatus: Sendable, Equatable {
    var state: RagIndexState
    var indexedEntries: Int
    var totalChunks: Int
    var pendingEmbeddings: Int
    var message: String
    static let initial = RagIndexStatus(state: .starting, indexedEntries: 0, totalChunks: 0, pendingEmbeddings: 0, message: "")
}

/// Owns the local index and the embedding model; keeps the index in sync incrementally (content hashes; only changed
/// entries are re-chunked, only chunks without a vector are embedded) on a background serial queue; answers retrieval
/// requests off the main actor. Port of KnowledgeIndexCoordinator.cs. If the model or the index is unavailable,
/// retrieval degrades to keyword search over a bounded set of passages — never to the whole knowledge base.
final class KnowledgeIndexCoordinator: @unchecked Sendable {
    private let indexDirectory: URL
    private let modelDirectories: [URL]
    private let queue = DispatchQueue(label: "InterviewAssistant.LocalRAG.index", qos: .utility)
    private let lock = NSLock()
    private let startLock = NSLock()
    private var started = false
    private var index: LocalVectorIndex?
    private var embedder: LocalEmbeddingService?
    private var startError: String?
    private var pendingSnapshot: [RagDocument]?
    private var lastSnapshot: [RagDocument] = []
    private var rebuildRequested = false
    private var workerRunning = false
    private var generation = 0
    private var disposed = false
    private var queryCache: [String: [Float]] = [:]
    private var queryCacheOrder: [String] = []
    private(set) var status = RagIndexStatus.initial
    var onStatusChange: (@Sendable (RagIndexStatus) -> Void)?

    init(indexDirectory: URL, modelDirectories: [URL]) {
        self.indexDirectory = indexDirectory
        self.modelDirectories = modelDirectories
    }

    var isSemanticAvailable: Bool { lock.lock(); defer { lock.unlock() }; return embedder != nil }

    /// Opens the index and loads the model (idempotent; call from a background thread).
    func ensureStarted() {
        startLock.lock()
        defer { startLock.unlock() }
        guard !started else { return }
        started = true
        var openedIndex: LocalVectorIndex?
        var failure: String?
        do { openedIndex = try LocalVectorIndex(directory: indexDirectory, modelVersion: LocalEmbeddingService.modelVersion) }
        catch { failure = "The local index could not be opened." }
        var loadedEmbedder: LocalEmbeddingService?
        if let directory = modelDirectories.first(where: { LocalEmbeddingService.filesExist(in: $0) }) {
            do { loadedEmbedder = try LocalEmbeddingService(modelDirectory: directory) }
            catch { failure = failure ?? "The local embedding model could not be loaded." }
        }
        lock.lock()
        index = openedIndex
        embedder = loadedEmbedder
        startError = failure
        lock.unlock()
        publish()
    }

    func start() { queue.async { self.ensureStarted() } }

    /// Queues a sync with the current knowledge bases (coalesced: only the newest snapshot is processed).
    func requestSync(_ snapshot: [RagDocument], rebuild: Bool = false) {
        lock.lock()
        guard !disposed else { lock.unlock(); return }
        pendingSnapshot = snapshot
        lastSnapshot = snapshot
        rebuildRequested = rebuildRequested || rebuild
        generation += 1                       // cancels embedding of the previous snapshot; finished work is kept
        let startWorker = !workerRunning
        workerRunning = true
        lock.unlock()
        if startWorker { queue.async { self.workerLoop() } }
    }

    private func workerLoop() {
        ensureStarted()
        while true {
            lock.lock()
            guard let snapshot = pendingSnapshot, !disposed else {
                workerRunning = false
                lock.unlock()
                return
            }
            let rebuild = rebuildRequested
            let myGeneration = generation
            pendingSnapshot = nil
            rebuildRequested = false
            lock.unlock()
            do { try sync(snapshot, rebuild: rebuild, generation: myGeneration) }
            catch is CancellationError {}
            catch { lock.lock(); startError = "Indexing failed."; lock.unlock() }   // never logs document text
            publish()
        }
    }

    private func isCancelled(_ myGeneration: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation != myGeneration || disposed
    }

    private func sync(_ snapshot: [RagDocument], rebuild: Bool, generation myGeneration: Int) throws {
        lock.lock()
        let index = self.index
        let embedder = self.embedder
        lock.unlock()
        guard let index else { return }
        if rebuild { try index.clear() }

        // 1. Structure: remove deleted entries, re-chunk new or changed ones (fast, no model needed).
        var current: [UUID: RagDocument] = [:]
        for document in snapshot where current[document.entryID] == nil { current[document.entryID] = document }
        let indexed = index.entries
        try index.removeEntries(indexed.keys.filter { current[$0] == nil })
        for document in current.values {
            if isCancelled(myGeneration) { throw CancellationError() }
            let hash = KnowledgeChunker.contentHash(document)
            if let state = indexed[document.entryID], state.contentHash == hash, state.knowledgeBaseID == document.knowledgeBaseID { continue }
            try index.replaceEntry(knowledgeBaseID: document.knowledgeBaseID, entryID: document.entryID, contentHash: hash,
                                   chunks: KnowledgeChunker.chunk(document), modelVersion: LocalEmbeddingService.modelVersion)
        }
        publish(.indexing)

        // 2. Vectors: embed only chunks without one, in small batches that are saved as they finish.
        guard let embedder else { return }
        let missing = index.chunks.filter { $0.vector == nil }.map(\.chunk)
            .sorted { $0.entryID.uuidString != $1.entryID.uuidString ? $0.entryID.uuidString < $1.entryID.uuidString : $0.chunkIndex < $1.chunkIndex }
        var offset = 0
        while offset < missing.count {
            if isCancelled(myGeneration) { throw CancellationError() }
            let batch = Array(missing[offset..<min(missing.count, offset + 16)])
            let vectors = try embedder.embed(batch.map(\.embeddingText), isCancelled: { self.isCancelled(myGeneration) })
            try index.storeEmbeddings(zip(batch, vectors).filter { VectorMath.isUsable($0.1) }.map { (chunkID: $0.0.chunkID, vector: $0.1) },
                                      modelVersion: LocalEmbeddingService.modelVersion)
            offset += batch.count
            publish(.indexing)
        }
    }

    /// Retrieves passages for a prepared query from the active knowledge bases, off the calling thread.
    /// Never throws: it degrades to keyword-only, then to a bounded fallback.
    func retrieve(_ query: RetrievalQuery, activeKnowledgeBaseIDs: Set<UUID>, enabledEntryIDs: Set<UUID>?,
                  options: RetrievalOptions = .default) async -> RetrievalResult {
        if query.isEmpty || activeKnowledgeBaseIDs.isEmpty { return .empty(.none) }
        return await Task.detached(priority: .userInitiated) { [self] in
            retrieveNow(query, activeKnowledgeBaseIDs: activeKnowledgeBaseIDs, enabledEntryIDs: enabledEntryIDs, options: options)
        }.value
    }

    private func retrieveNow(_ query: RetrievalQuery, activeKnowledgeBaseIDs: Set<UUID>, enabledEntryIDs: Set<UUID>?, options: RetrievalOptions) -> RetrievalResult {
        ensureStarted()
        lock.lock()
        let index = self.index
        let embedder = self.embedder
        let snapshot = lastSnapshot
        lock.unlock()
        guard let index else { return fallbackRetrieve(query, snapshot: snapshot, activeKnowledgeBaseIDs: activeKnowledgeBaseIDs, enabledEntryIDs: enabledEntryIDs, options: options) }
        var vector: [Float]?
        var embeddingMs = 0.0
        if let embedder, !query.semanticText.isEmpty {
            let start = DispatchTime.now()
            vector = cachedQueryVector(embedder, query.semanticText)
            embeddingMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        }
        let result = KnowledgeRetrievalService.retrieve(index: index.chunks, query: query, queryVector: vector, activeKnowledgeBaseIDs: activeKnowledgeBaseIDs,
                                                        enabledEntryIDs: enabledEntryIDs, options: options, queryEmbeddingMs: embeddingMs)
        if result.chunks.isEmpty && index.entries.isEmpty && !snapshot.isEmpty {
            return fallbackRetrieve(query, snapshot: snapshot, activeKnowledgeBaseIDs: activeKnowledgeBaseIDs, enabledEntryIDs: enabledEntryIDs, options: options)
        }
        return result
    }

    private func cachedQueryVector(_ embedder: LocalEmbeddingService, _ text: String) -> [Float]? {
        lock.lock()
        if let cached = queryCache[text] { lock.unlock(); return cached }
        lock.unlock()
        guard let vector = try? embedder.embedQuery(text) else { return nil }
        lock.lock()
        if queryCache[text] == nil { queryCache[text] = vector; queryCacheOrder.append(text) }
        while queryCacheOrder.count > 64 { queryCache.removeValue(forKey: queryCacheOrder.removeFirst()) }
        lock.unlock()
        return vector
    }

    /// Keyword search over freshly chunked documents when no persistent index is available (bounded by the same budget).
    private func fallbackRetrieve(_ query: RetrievalQuery, snapshot: [RagDocument], activeKnowledgeBaseIDs: Set<UUID>, enabledEntryIDs: Set<UUID>?,
                                  options: RetrievalOptions) -> RetrievalResult {
        let chunks = snapshot
            .filter { activeKnowledgeBaseIDs.contains($0.knowledgeBaseID) && (enabledEntryIDs?.contains($0.entryID) ?? true) }
            .flatMap { KnowledgeChunker.chunk($0) }
            .map { IndexedChunk(chunk: $0, vector: nil) }
        var result = KnowledgeRetrievalService.retrieve(index: chunks, query: query, queryVector: nil, activeKnowledgeBaseIDs: activeKnowledgeBaseIDs,
                                                        enabledEntryIDs: enabledEntryIDs, options: options)
        result.mode = .fallback
        return result
    }

    private func publish(_ forced: RagIndexState? = nil) {
        lock.lock()
        let index = self.index
        let hasEmbedder = embedder != nil
        let failure = startError
        lock.unlock()
        let pending = index?.chunksWithoutEmbedding ?? 0
        let state: RagIndexState
        if let forced { state = forced }
        else if failure != nil && index == nil { state = .error }
        else if !hasEmbedder { state = .keywordOnly }
        else { state = pending > 0 ? .indexing : .ready }
        let message = failure ?? (hasEmbedder ? "" : "Local embedding model not installed; using keyword search.")
        let newStatus = RagIndexStatus(state: state, indexedEntries: index?.entries.count ?? 0, totalChunks: index?.chunks.count ?? 0,
                                       pendingEmbeddings: hasEmbedder ? pending : 0, message: message)
        lock.lock()
        status = newStatus
        let callback = onStatusChange
        lock.unlock()
        callback?(newStatus)
    }

    /// Stops background work (a half-finished batch is simply redone at the next launch).
    func shutdown() {
        lock.lock()
        disposed = true
        generation += 1
        lock.unlock()
    }
}
