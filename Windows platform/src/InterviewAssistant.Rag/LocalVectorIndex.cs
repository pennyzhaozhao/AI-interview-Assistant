using Microsoft.Data.Sqlite;

namespace InterviewAssistant.Rag;

/// <summary>A chunk loaded in memory for search: its text, keyword terms and (when available) its embedding.</summary>
public sealed class IndexedChunk(RagChunk chunk, Dictionary<string, int> terms, int termCount, float[]? vector)
{
    public RagChunk Chunk { get; } = chunk;
    public Dictionary<string, int> Terms { get; } = terms;
    public int TermCount { get; } = termCount;
    public float[]? Vector { get; set; } = vector;
}

public sealed record IndexedEntryState(Guid EntryId, Guid KnowledgeBaseId, string ContentHash, int ChunkCount);

/// <summary>
/// Persistent local index in one SQLite file inside the app's data folder. It is derived data: it can be deleted
/// at any time and is rebuilt from the knowledge bases. Writes are transactional, so an interrupted shutdown leaves
/// either the old or the new chunks of an entry, never a mix. Search runs on an in-memory copy: exact cosine over
/// all vectors (fast enough for personal knowledge bases of tens of thousands of passages) plus BM25.
/// </summary>
public sealed class LocalVectorIndex : IDisposable
{
    public const int SchemaVersion = 1;
    public const string FileName = "rag-index.sqlite";

    private readonly string _path;
    private readonly object _gate = new();
    private SqliteConnection _connection;
    private Dictionary<string, IndexedChunk> _chunks = new(StringComparer.Ordinal);
    private Dictionary<Guid, IndexedEntryState> _entries = [];

    private LocalVectorIndex(string path, SqliteConnection connection)
    {
        _path = path;
        _connection = connection;
    }

    public string Path => _path;
    /// <summary>Set when the file was unreadable and has been recreated (for status display).</summary>
    public bool WasRecreated { get; private set; }

    /// <summary>Opens (or creates) the index. A corrupt file, an old schema or another embedding model are handled here.</summary>
    public static LocalVectorIndex Open(string directory, string modelVersion)
    {
        Directory.CreateDirectory(directory);
        var path = System.IO.Path.Combine(directory, FileName);
        for (var attempt = 0; ; attempt++)
        {
            SqliteConnection? connection = null;
            try
            {
                connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
                connection.Open();
                var index = new LocalVectorIndex(path, connection) { WasRecreated = attempt > 0 };
                index.Initialize(modelVersion);
                index.LoadAll();
                return index;
            }
            catch (Exception) when (attempt == 0)
            {
                // Corrupt or unreadable: the index is derived data, so start over.
                connection?.Dispose();
                SqliteConnection.ClearAllPools();
                DeleteFiles(path);
            }
        }
    }

    private static void DeleteFiles(string path)
    {
        foreach (var file in new[] { path, path + "-wal", path + "-shm", path + "-journal" })
        {
            try { if (File.Exists(file)) File.Delete(file); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private void Initialize(string modelVersion)
    {
        Execute("PRAGMA journal_mode=WAL;");
        Execute("PRAGMA synchronous=NORMAL;");
        using (var check = _connection.CreateCommand())
        {
            check.CommandText = "PRAGMA quick_check;";
            var result = check.ExecuteScalar() as string;
            if (!string.Equals(result, "ok", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("RAG index failed integrity check.");
        }
        Execute("""
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
            """);
        var schema = ReadMeta("schema_version");
        if (schema is not null && schema != SchemaVersion.ToString())
        {
            // Future schema changes: the index is rebuilt rather than migrated in place.
            Execute("DELETE FROM chunks; DELETE FROM entries;");
        }
        WriteMeta("schema_version", SchemaVersion.ToString());
        if (ReadMeta("model_version") != modelVersion)
        {
            // Another embedding model (or tokenizer/pooling): old vectors are not comparable, so drop them.
            Execute("UPDATE chunks SET embedding = NULL, model_version = NULL;");
            WriteMeta("model_version", modelVersion);
        }
        WriteMeta("dimension", LocalEmbeddingService.Dimension.ToString());
        // Orphans (chunks whose entry row is missing) can only come from a crash in an older build; remove them.
        Execute("DELETE FROM chunks WHERE entry_id NOT IN (SELECT entry_id FROM entries);");
    }

    private void LoadAll()
    {
        var chunks = new Dictionary<string, IndexedChunk>(StringComparer.Ordinal);
        var entries = new Dictionary<Guid, IndexedEntryState>();
        using (var command = _connection.CreateCommand())
        {
            command.CommandText = "SELECT entry_id, kb_id, content_hash, chunk_count FROM entries;";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                var state = new IndexedEntryState(Guid.Parse(reader.GetString(0)), Guid.Parse(reader.GetString(1)), reader.GetString(2), reader.GetInt32(3));
                entries[state.EntryId] = state;
            }
        }
        using (var command = _connection.CreateCommand())
        {
            command.CommandText = "SELECT chunk_id, kb_id, entry_id, title, kind, source, chunk_index, section, text, is_qa, content_hash, embedding FROM chunks;";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                var chunk = new RagChunk(reader.GetString(0), Guid.Parse(reader.GetString(1)), Guid.Parse(reader.GetString(2)), reader.GetString(3),
                    reader.GetString(4), reader.GetString(5), reader.GetInt32(6), reader.GetString(7), reader.GetString(8), reader.GetString(10), reader.GetInt32(9) != 0);
                var blob = reader.IsDBNull(11) ? null : (byte[])reader[11];
                // A vector with the wrong size (dimension mismatch) is ignored and re-embedded.
                var vector = VectorMath.FromBytes(blob, LocalEmbeddingService.Dimension);
                chunks[chunk.ChunkId] = Indexed(chunk, vector);
            }
        }
        lock (_gate)
        {
            _chunks = chunks;
            _entries = entries;
        }
    }

    private static IndexedChunk Indexed(RagChunk chunk, float[]? vector)
    {
        var terms = LexicalAnalyzer.TermFrequencies(chunk.LexicalText);
        return new IndexedChunk(chunk, terms, Math.Max(1, terms.Values.Sum()), vector);
    }

    public IReadOnlyDictionary<Guid, IndexedEntryState> Entries { get { lock (_gate) return new Dictionary<Guid, IndexedEntryState>(_entries); } }

    /// <summary>Snapshot of the in-memory chunks (cheap: the list holds references).</summary>
    public IReadOnlyList<IndexedChunk> Chunks { get { lock (_gate) return _chunks.Values.ToList(); } }

    public int ChunksWithoutEmbedding { get { lock (_gate) return _chunks.Values.Count(item => item.Vector is null); } }

    /// <summary>Replaces all chunks of one entry in a single transaction. Chunks whose ID is unchanged keep their vectors.</summary>
    public void ReplaceEntry(Guid knowledgeBaseId, Guid entryId, string contentHash, IReadOnlyList<RagChunk> chunks, string modelVersion)
    {
        Dictionary<string, float[]?> previousVectors;
        lock (_gate)
        {
            previousVectors = _chunks.Values.Where(item => item.Chunk.EntryId == entryId).ToDictionary(item => item.Chunk.ChunkId, item => item.Vector);
        }
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        using (var transaction = _connection.BeginTransaction())
        {
            using (var delete = _connection.CreateCommand())
            {
                delete.Transaction = transaction;
                delete.CommandText = "DELETE FROM chunks WHERE entry_id = $entry;";
                delete.Parameters.AddWithValue("$entry", entryId.ToString("D"));
                delete.ExecuteNonQuery();
            }
            foreach (var chunk in chunks)
            {
                using var insert = _connection.CreateCommand();
                insert.Transaction = transaction;
                insert.CommandText = """
                    INSERT INTO chunks (chunk_id, kb_id, entry_id, title, kind, source, chunk_index, section, text, is_qa, content_hash, embedding, model_version, indexed_at)
                    VALUES ($id, $kb, $entry, $title, $kind, $source, $index, $section, $text, $qa, $hash, $embedding, $model, $now);
                    """;
                var vector = previousVectors.GetValueOrDefault(chunk.ChunkId);
                insert.Parameters.AddWithValue("$id", chunk.ChunkId);
                insert.Parameters.AddWithValue("$kb", knowledgeBaseId.ToString("D"));
                insert.Parameters.AddWithValue("$entry", entryId.ToString("D"));
                insert.Parameters.AddWithValue("$title", chunk.Title);
                insert.Parameters.AddWithValue("$kind", chunk.Kind);
                insert.Parameters.AddWithValue("$source", chunk.Source);
                insert.Parameters.AddWithValue("$index", chunk.ChunkIndex);
                insert.Parameters.AddWithValue("$section", chunk.Section);
                insert.Parameters.AddWithValue("$text", chunk.Text);
                insert.Parameters.AddWithValue("$qa", chunk.IsQuestionAnswer ? 1 : 0);
                insert.Parameters.AddWithValue("$hash", contentHash);
                insert.Parameters.AddWithValue("$embedding", vector is null ? DBNull.Value : VectorMath.ToBytes(vector));
                insert.Parameters.AddWithValue("$model", vector is null ? DBNull.Value : modelVersion);
                insert.Parameters.AddWithValue("$now", now);
                insert.ExecuteNonQuery();
            }
            using (var upsert = _connection.CreateCommand())
            {
                upsert.Transaction = transaction;
                upsert.CommandText = """
                    INSERT INTO entries (entry_id, kb_id, content_hash, chunk_count, indexed_at) VALUES ($entry, $kb, $hash, $count, $now)
                    ON CONFLICT(entry_id) DO UPDATE SET kb_id = excluded.kb_id, content_hash = excluded.content_hash, chunk_count = excluded.chunk_count, indexed_at = excluded.indexed_at;
                    """;
                upsert.Parameters.AddWithValue("$entry", entryId.ToString("D"));
                upsert.Parameters.AddWithValue("$kb", knowledgeBaseId.ToString("D"));
                upsert.Parameters.AddWithValue("$hash", contentHash);
                upsert.Parameters.AddWithValue("$count", chunks.Count);
                upsert.Parameters.AddWithValue("$now", now);
                upsert.ExecuteNonQuery();
            }
            transaction.Commit();
        }
        lock (_gate)
        {
            foreach (var key in _chunks.Where(pair => pair.Value.Chunk.EntryId == entryId).Select(pair => pair.Key).ToList()) _chunks.Remove(key);
            foreach (var chunk in chunks) _chunks[chunk.ChunkId] = Indexed(chunk, previousVectors.GetValueOrDefault(chunk.ChunkId));
            _entries[entryId] = new IndexedEntryState(entryId, knowledgeBaseId, contentHash, chunks.Count);
        }
    }

    /// <summary>Removes entries (deleted documents or knowledge bases) and their chunks.</summary>
    public void RemoveEntries(IReadOnlyCollection<Guid> entryIds)
    {
        if (entryIds.Count == 0) return;
        using (var transaction = _connection.BeginTransaction())
        {
            foreach (var entryId in entryIds)
            {
                using var command = _connection.CreateCommand();
                command.Transaction = transaction;
                command.CommandText = "DELETE FROM chunks WHERE entry_id = $entry; DELETE FROM entries WHERE entry_id = $entry;";
                command.Parameters.AddWithValue("$entry", entryId.ToString("D"));
                command.ExecuteNonQuery();
            }
            transaction.Commit();
        }
        var removed = entryIds.ToHashSet();
        lock (_gate)
        {
            foreach (var key in _chunks.Where(pair => removed.Contains(pair.Value.Chunk.EntryId)).Select(pair => pair.Key).ToList()) _chunks.Remove(key);
            foreach (var entryId in removed) _entries.Remove(entryId);
        }
    }

    /// <summary>Stores embeddings for chunks that still exist (a chunk replaced meanwhile is skipped).</summary>
    public void StoreEmbeddings(IReadOnlyList<(string ChunkId, float[] Vector)> vectors, string modelVersion)
    {
        if (vectors.Count == 0) return;
        using (var transaction = _connection.BeginTransaction())
        {
            foreach (var (chunkId, vector) in vectors)
            {
                using var command = _connection.CreateCommand();
                command.Transaction = transaction;
                command.CommandText = "UPDATE chunks SET embedding = $embedding, model_version = $model WHERE chunk_id = $id;";
                command.Parameters.AddWithValue("$embedding", VectorMath.ToBytes(vector));
                command.Parameters.AddWithValue("$model", modelVersion);
                command.Parameters.AddWithValue("$id", chunkId);
                command.ExecuteNonQuery();
            }
            transaction.Commit();
        }
        lock (_gate)
        {
            foreach (var (chunkId, vector) in vectors)
                if (_chunks.TryGetValue(chunkId, out var item)) item.Vector = vector;
        }
    }

    /// <summary>Deletes every chunk and entry row (an explicit "rebuild index").</summary>
    public void Clear()
    {
        Execute("DELETE FROM chunks; DELETE FROM entries;");
        lock (_gate)
        {
            _chunks.Clear();
            _entries.Clear();
        }
    }

    private string? ReadMeta(string key)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = "SELECT value FROM meta WHERE key = $key;";
        command.Parameters.AddWithValue("$key", key);
        return command.ExecuteScalar() as string;
    }

    private void WriteMeta(string key, string value)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = "INSERT INTO meta (key, value) VALUES ($key, $value) ON CONFLICT(key) DO UPDATE SET value = excluded.value;";
        command.Parameters.AddWithValue("$key", key);
        command.Parameters.AddWithValue("$value", value);
        command.ExecuteNonQuery();
    }

    private void Execute(string sql)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    public void Dispose()
    {
        _connection.Dispose();
        SqliteConnection.ClearAllPools();
    }
}
