import Foundation
import SQLite3

struct IndexedEntryState: Sendable {
    var entryID: UUID
    var knowledgeBaseID: UUID
    var contentHash: String
    var chunkCount: Int
}

/// Persistent local index in one SQLite file (system libsqlite3) inside the app's data folder — the same schema as
/// LocalVectorIndex.cs. Derived data: it can be deleted at any time and is rebuilt from the knowledge bases.
/// Every entry update is one transaction, so an interrupted shutdown never leaves a half-written entry.
/// Search runs on an in-memory copy (exact cosine + BM25).
final class LocalVectorIndex: @unchecked Sendable {
    static let schemaVersion = 1
    static let fileName = "rag-index.sqlite"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    let url: URL
    private(set) var wasRecreated = false
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var chunksByID: [String: IndexedChunk] = [:]
    private var entryStates: [UUID: IndexedEntryState] = [:]

    /// Opens (or creates) the index; a corrupt file, an old schema or another embedding model are handled here.
    init(directory: URL, modelVersion: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(Self.fileName)
        do {
            try open(modelVersion: modelVersion)
        } catch {
            // Unreadable or corrupt: start over (derived data).
            closeDatabase()
            for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            wasRecreated = true
            try open(modelVersion: modelVersion)
        }
    }

    deinit { closeDatabase() }

    private func closeDatabase() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func open(modelVersion: String) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw LocalRAGError.storage("Cannot open the local index")
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        guard try scalarText("PRAGMA quick_check;")?.lowercased() == "ok" else { throw LocalRAGError.storage("Index failed integrity check") }
        try execute("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS entries (
                entry_id TEXT PRIMARY KEY, kb_id TEXT NOT NULL, content_hash TEXT NOT NULL,
                chunk_count INTEGER NOT NULL, indexed_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS chunks (
                chunk_id TEXT PRIMARY KEY, kb_id TEXT NOT NULL, entry_id TEXT NOT NULL, title TEXT NOT NULL,
                kind TEXT NOT NULL, source TEXT NOT NULL, chunk_index INTEGER NOT NULL, section TEXT NOT NULL,
                text TEXT NOT NULL, is_qa INTEGER NOT NULL, content_hash TEXT NOT NULL, embedding BLOB,
                model_version TEXT, indexed_at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS chunks_entry ON chunks(entry_id);
            """)
        if let schema = try readMeta("schema_version"), schema != String(Self.schemaVersion) {
            try execute("DELETE FROM chunks; DELETE FROM entries;")
        }
        try writeMeta("schema_version", String(Self.schemaVersion))
        if try readMeta("model_version") != modelVersion {
            // Another embedding model (or tokenizer/pooling): old vectors are not comparable.
            try execute("UPDATE chunks SET embedding = NULL, model_version = NULL;")
            try writeMeta("model_version", modelVersion)
        }
        try writeMeta("dimension", String(LocalEmbeddingService.dimension))
        try execute("DELETE FROM chunks WHERE entry_id NOT IN (SELECT entry_id FROM entries);")
        try loadAll()
    }

    private func loadAll() throws {
        var entries: [UUID: IndexedEntryState] = [:]
        try query("SELECT entry_id, kb_id, content_hash, chunk_count FROM entries;") { row in
            guard let entryID = UUID(uuidString: Self.text(row, 0)), let kbID = UUID(uuidString: Self.text(row, 1)) else { return }
            entries[entryID] = IndexedEntryState(entryID: entryID, knowledgeBaseID: kbID, contentHash: Self.text(row, 2), chunkCount: Int(sqlite3_column_int(row, 3)))
        }
        var chunks: [String: IndexedChunk] = [:]
        try query("SELECT chunk_id, kb_id, entry_id, title, kind, source, chunk_index, section, text, is_qa, content_hash, embedding FROM chunks;") { row in
            guard let kbID = UUID(uuidString: Self.text(row, 1)), let entryID = UUID(uuidString: Self.text(row, 2)) else { return }
            let chunk = RagChunk(chunkID: Self.text(row, 0), knowledgeBaseID: kbID, entryID: entryID, title: Self.text(row, 3), kind: Self.text(row, 4),
                                 source: Self.text(row, 5), chunkIndex: Int(sqlite3_column_int(row, 6)), section: Self.text(row, 7), text: Self.text(row, 8),
                                 contentHash: Self.text(row, 10), isQuestionAnswer: sqlite3_column_int(row, 9) != 0)
            var blob: Data?
            if let bytes = sqlite3_column_blob(row, 11) {
                blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 11)))
            }
            // Wrong-size vectors (dimension mismatch) are ignored and re-embedded.
            chunks[chunk.chunkID] = IndexedChunk(chunk: chunk, vector: VectorMath.fromData(blob, dimension: LocalEmbeddingService.dimension))
        }
        lock.lock()
        entryStates = entries
        chunksByID = chunks
        lock.unlock()
    }

    var entries: [UUID: IndexedEntryState] { lock.lock(); defer { lock.unlock() }; return entryStates }
    var chunks: [IndexedChunk] { lock.lock(); defer { lock.unlock() }; return Array(chunksByID.values) }
    var chunksWithoutEmbedding: Int { lock.lock(); defer { lock.unlock() }; return chunksByID.values.filter { $0.vector == nil }.count }

    /// Replaces all chunks of one entry in a single transaction; chunks whose ID is unchanged keep their vectors.
    func replaceEntry(knowledgeBaseID: UUID, entryID: UUID, contentHash: String, chunks newChunks: [RagChunk], modelVersion: String) throws {
        lock.lock()
        let previous = Dictionary(uniqueKeysWithValues: chunksByID.values.filter { $0.chunk.entryID == entryID }.map { ($0.chunk.chunkID, $0.vector) })
        lock.unlock()
        let now = Date().timeIntervalSince1970
        let entry = entryID.uuidString.lowercased()
        let kb = knowledgeBaseID.uuidString.lowercased()
        try transaction {
            try run("DELETE FROM chunks WHERE entry_id = ?;", [.text(entry)])
            for chunk in newChunks {
                let vector = previous[chunk.chunkID] ?? nil
                try run("""
                    INSERT INTO chunks (chunk_id, kb_id, entry_id, title, kind, source, chunk_index, section, text, is_qa, content_hash, embedding, model_version, indexed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, [.text(chunk.chunkID), .text(kb), .text(entry), .text(chunk.title), .text(chunk.kind), .text(chunk.source), .int(chunk.chunkIndex),
                          .text(chunk.section), .text(chunk.text), .int(chunk.isQuestionAnswer ? 1 : 0), .text(contentHash),
                          vector.map { Value.blob(VectorMath.toData($0)) } ?? Value.null, vector == nil ? Value.null : Value.text(modelVersion), .real(now)])
            }
            try run("""
                INSERT INTO entries (entry_id, kb_id, content_hash, chunk_count, indexed_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(entry_id) DO UPDATE SET kb_id = excluded.kb_id, content_hash = excluded.content_hash, chunk_count = excluded.chunk_count, indexed_at = excluded.indexed_at;
                """, [.text(entry), .text(kb), .text(contentHash), .int(newChunks.count), .real(now)])
        }
        lock.lock()
        for key in chunksByID.filter({ $0.value.chunk.entryID == entryID }).map(\.key) { chunksByID.removeValue(forKey: key) }
        for chunk in newChunks { chunksByID[chunk.chunkID] = IndexedChunk(chunk: chunk, vector: previous[chunk.chunkID] ?? nil) }
        entryStates[entryID] = IndexedEntryState(entryID: entryID, knowledgeBaseID: knowledgeBaseID, contentHash: contentHash, chunkCount: newChunks.count)
        lock.unlock()
    }

    func removeEntries(_ entryIDs: [UUID]) throws {
        guard !entryIDs.isEmpty else { return }
        try transaction {
            for entryID in entryIDs {
                let entry = entryID.uuidString.lowercased()
                try run("DELETE FROM chunks WHERE entry_id = ?;", [.text(entry)])
                try run("DELETE FROM entries WHERE entry_id = ?;", [.text(entry)])
            }
        }
        let removed = Set(entryIDs)
        lock.lock()
        for key in chunksByID.filter({ removed.contains($0.value.chunk.entryID) }).map(\.key) { chunksByID.removeValue(forKey: key) }
        for entryID in removed { entryStates.removeValue(forKey: entryID) }
        lock.unlock()
    }

    func storeEmbeddings(_ vectors: [(chunkID: String, vector: [Float])], modelVersion: String) throws {
        guard !vectors.isEmpty else { return }
        try transaction {
            for item in vectors {
                try run("UPDATE chunks SET embedding = ?, model_version = ? WHERE chunk_id = ?;",
                        [.blob(VectorMath.toData(item.vector)), .text(modelVersion), .text(item.chunkID)])
            }
        }
        lock.lock()
        for item in vectors { chunksByID[item.chunkID]?.vector = item.vector }
        lock.unlock()
    }

    func clear() throws {
        try execute("DELETE FROM chunks; DELETE FROM entries;")
        lock.lock()
        chunksByID.removeAll()
        entryStates.removeAll()
        lock.unlock()
    }

    // MARK: - SQLite helpers

    private enum Value { case text(String), int(Int), real(Double), blob(Data), null }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(error)
            throw LocalRAGError.storage(message)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LocalRAGError.storage(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .int(let number): sqlite3_bind_int64(statement, index, sqlite3_int64(number))
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalRAGError.storage(String(cString: sqlite3_errmsg(db))) }
    }

    private func query(_ sql: String, _ row: (OpaquePointer?) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw LocalRAGError.storage(String(cString: sqlite3_errmsg(db))) }
            try row(statement)
        }
    }

    private func scalarText(_ sql: String) throws -> String? {
        var value: String?
        try query(sql) { row in if value == nil { value = Self.text(row, 0) } }
        return value
    }

    private func readMeta(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_ROW ? Self.text(statement, 0) : nil
    }

    private func writeMeta(_ key: String, _ value: String) throws {
        try run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", [.text(key), .text(value)])
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
}
