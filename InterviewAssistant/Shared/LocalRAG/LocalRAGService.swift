import Foundation
import SwiftData
import Observation

/// Knowledge for one LLM request: the compact core profile plus passages retrieved locally for this question.
struct KnowledgePromptContext: Sendable {
    var coreProfile: String
    var retrievedKnowledge: String
    var retrieval: RetrievalResult
    static let empty = KnowledgePromptContext(coreProfile: "", retrievedKnowledge: "", retrieval: .empty(.none))
}

/// Connects the local RAG index to SwiftData. The knowledge bases stay the single source of truth: the index only
/// reads snapshots of them (taken on the main actor), re-syncs after every save (debounced), and is stored as derived
/// data next to the app's data store. Retrieval and embedding run off the main actor; nothing here uses the network.
@MainActor
@Observable
final class LocalRAGService {
    static let shared = LocalRAGService()

    private(set) var status = RagIndexStatus.initial
    @ObservationIgnored private var coordinator: KnowledgeIndexCoordinator?
    @ObservationIgnored private weak var context: ModelContext?
    @ObservationIgnored private var lastFingerprint: Int?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?

    private init() {}

    /// Folders searched for model_quantized.onnx + tokenizer.json (bundled with the app first).
    static var modelDirectories: [URL] {
        var directories: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["INTERVIEW_ASSISTANT_RAG_MODEL_DIR"], !configured.isEmpty {
            directories.append(URL(fileURLWithPath: configured))
        }
        if let resources = Bundle.main.resourceURL { directories.append(resources.appendingPathComponent("LocalRAG/model")) }
        directories.append(indexDirectory.appendingPathComponent("model"))
        return directories
    }

    /// Next to the SwiftData store (the app's configured data folder); Application Support if that is not writable.
    static var indexDirectory: URL {
        let storeFolder = DataStorageManager.currentStoreURL.deletingLastPathComponent().appendingPathComponent("LocalRAG")
        if (try? FileManager.default.createDirectory(at: storeFolder, withIntermediateDirectories: true)) != nil,
           FileManager.default.isWritableFile(atPath: storeFolder.path) {
            return storeFolder
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("InterviewAssistant/LocalRAG")
    }

    /// Called once the model context exists (ContentView). Idempotent.
    func attach(_ modelContext: ModelContext) {
        context = modelContext
        if coordinator == nil {
            let coordinator = KnowledgeIndexCoordinator(indexDirectory: Self.indexDirectory, modelDirectories: Self.modelDirectories)
            coordinator.onStatusChange = { status in
                Task { @MainActor in LocalRAGService.shared.status = status }
            }
            coordinator.start()
            self.coordinator = coordinator
        }
        if saveObserver == nil {
            saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
                Task { @MainActor in LocalRAGService.shared.scheduleSync() }
            }
        }
        syncNow()
    }

    func scheduleSync() {
        debounce?.cancel()
        debounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self.syncNow()
        }
    }

    /// Snapshots the knowledge bases and queues an incremental sync when anything relevant changed.
    func syncNow(rebuild: Bool = false) {
        guard let context, let coordinator else { return }
        let bases = (try? context.fetch(FetchDescriptor<KnowledgeBase>())) ?? []
        let fingerprint = Self.fingerprint(bases)
        if !rebuild && fingerprint == lastFingerprint { return }
        lastFingerprint = fingerprint
        coordinator.requestSync(KnowledgeFormatter.ragDocuments(bases), rebuild: rebuild)
    }

    func shutdown() { coordinator?.shutdown() }

    /// Builds the knowledge part of a prompt for `question`: core profile + passages retrieved locally.
    /// The knowledge bases are read here on the main actor; embedding and search run in the background.
    func knowledgeContext(question: String, knowledgeBases: [KnowledgeBase], activeIDs: [UUID], recentTurns: [ConversationTurn],
                          role: String, budget: PromptBudget = .default, options: RetrievalOptions = .default) async -> KnowledgePromptContext {
        let coreProfile = KnowledgeFormatter.coreProfile(knowledgeBases, activeIDs: activeIDs, maxTokens: budget.coreProfile)
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let coordinator, !activeIDs.isEmpty, !cleanQuestion.isEmpty else {
            return KnowledgePromptContext(coreProfile: coreProfile, retrievedKnowledge: "", retrieval: .empty(.none))
        }
        let active = Set(activeIDs)
        let activeBases = knowledgeBases.filter { active.contains($0.id) }
        let enabled = Set(activeBases.flatMap(\.entries).filter(\.isEnabled).map(\.id))
        let titles = activeBases.flatMap(\.entries).filter { $0.isEnabled && $0.kind != KnowledgeEntryKind.resume }.map(\.title)
        let turns = recentTurns.filter { !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.createdAt < $1.createdAt }.suffix(3)
            .map { RagConversationTurn(question: $0.question, answer: $0.answer) }
        let query = QueryContextualizer.prepare(cleanQuestion, recentTurns: Array(turns), role: role, knownTitles: titles)
        var retrievalOptions = options
        retrievalOptions.maxContextTokens = budget.retrievedKnowledge
        let result = await coordinator.retrieve(query, activeKnowledgeBaseIDs: active, enabledEntryIDs: enabled, options: retrievalOptions)
        return KnowledgePromptContext(coreProfile: coreProfile, retrievedKnowledge: RagContextAssembler.format(result.chunks), retrieval: result)
    }

    /// Cheap change detector; the index compares full content hashes itself.
    private static func fingerprint(_ bases: [KnowledgeBase]) -> Int {
        var hasher = Hasher()
        for kb in bases {
            hasher.combine(kb.id)
            hasher.combine(kb.name)
            for entry in kb.entries {
                hasher.combine(entry.id)
                hasher.combine(entry.updatedAt)
                hasher.combine(entry.title)
                hasher.combine(entry.content)
                hasher.combine(entry.summary)
                hasher.combine(entry.kindRaw)
            }
        }
        return hasher.finalize()
    }
}
