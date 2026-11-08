using System.Diagnostics;

namespace InterviewAssistant.Rag;

public enum RagIndexState { Starting, Indexing, Ready, KeywordOnly, Error }

/// <summary>What the knowledge-base screen shows: state, progress and the last error (never document text).</summary>
public sealed record RagIndexStatus(RagIndexState State, int IndexedEntries, int TotalChunks, int PendingEmbeddings, string Message)
{
    public static RagIndexStatus Initial { get; } = new(RagIndexState.Starting, 0, 0, 0, "");
}

/// <summary>
/// Owns the local index and the embedding model, keeps the index in sync with the knowledge bases incrementally
/// (content hashes; only changed entries are re-chunked, only chunks without a vector are embedded) on a background
/// task, and answers retrieval requests. Indexing is cancellable, coalesced (only the newest knowledge-base snapshot
/// is processed) and never blocks the UI thread. If the model or the index is unavailable, retrieval degrades to
/// keyword search over a bounded set of passages — it never falls back to sending the whole knowledge base.
/// </summary>
public sealed class KnowledgeIndexCoordinator : IKnowledgeRetriever, IDisposable
{
    private readonly string _indexDirectory;
    private readonly IReadOnlyList<string> _modelDirectories;
    private readonly object _gate = new();
    private readonly Dictionary<string, float[]> _queryCache = new(StringComparer.Ordinal);
    private readonly Queue<string> _queryCacheOrder = new();
    private Task? _startTask;
    private LocalVectorIndex? _index;
    private LocalEmbeddingService? _embedder;
    private string? _startError;
    private IReadOnlyList<RagDocument>? _pendingSnapshot;
    private IReadOnlyList<RagDocument> _lastSnapshot = [];
    private bool _rebuildRequested;
    private Task _worker = Task.CompletedTask;
    private CancellationTokenSource _runCancellation = new();
    private bool _disposed;

    public KnowledgeIndexCoordinator(string indexDirectory, IEnumerable<string> modelDirectories)
    {
        _indexDirectory = indexDirectory;
        _modelDirectories = modelDirectories.Where(path => !string.IsNullOrWhiteSpace(path)).ToList();
    }

    public RagIndexStatus Status { get; private set; } = RagIndexStatus.Initial;
    public event Action<RagIndexStatus>? StatusChanged;
    public bool IsSemanticAvailable => _embedder is not null;
    public string? ModelDirectory { get; private set; }

    /// <summary>Opens the index and loads the model in the background (idempotent).</summary>
    public Task StartAsync()
    {
        lock (_gate) return _startTask ??= Task.Run(Start);
    }

    private void Start()
    {
        try
        {
            _index = LocalVectorIndex.Open(_indexDirectory, LocalEmbeddingService.ModelVersion);
        }
        catch (Exception exception)
        {
            _startError = "The local index could not be opened: " + exception.GetType().Name;
        }
        ModelDirectory = _modelDirectories.FirstOrDefault(LocalEmbeddingService.FilesExist);
        if (ModelDirectory is not null)
        {
            try { _embedder = LocalEmbeddingService.Load(ModelDirectory); }
            catch (Exception exception) { _startError ??= "The local embedding model could not be loaded: " + exception.GetType().Name; }
        }
        Publish();
    }

    /// <summary>Queues a sync with the current knowledge bases. Called after every knowledge-base change; cheap and coalesced.</summary>
    public void RequestSync(IReadOnlyList<RagDocument> snapshot) => Enqueue(snapshot, rebuild: false);

    /// <summary>Deletes the derived index and indexes everything again (user action "Rebuild index").</summary>
    public void RequestRebuild(IReadOnlyList<RagDocument> snapshot) => Enqueue(snapshot, rebuild: true);

    private void Enqueue(IReadOnlyList<RagDocument> snapshot, bool rebuild)
    {
        lock (_gate)
        {
            if (_disposed) return;
            _pendingSnapshot = snapshot;
            _lastSnapshot = snapshot;
            _rebuildRequested |= rebuild;
            _runCancellation.Cancel();   // stop embedding the previous snapshot; finished work is kept
            if (!_worker.IsCompleted) return;
            _worker = Task.Run(WorkerLoop);
        }
    }

    /// <summary>Completes when no sync is queued or running (used by tests and before a rebuild report).</summary>
    public async Task WhenIdleAsync()
    {
        await StartAsync().ConfigureAwait(false);
        while (true)
        {
            Task worker;
            lock (_gate) worker = _worker;
            await worker.ConfigureAwait(false);
            lock (_gate) if (_worker == worker && _pendingSnapshot is null) return;
        }
    }

    private async Task WorkerLoop()
    {
        await StartAsync().ConfigureAwait(false);
        while (true)
        {
            IReadOnlyList<RagDocument> snapshot;
            bool rebuild;
            CancellationToken token;
            lock (_gate)
            {
                if (_pendingSnapshot is null || _disposed) return;
                snapshot = _pendingSnapshot;
                rebuild = _rebuildRequested;
                _pendingSnapshot = null;
                _rebuildRequested = false;
                _runCancellation.Dispose();
                _runCancellation = new CancellationTokenSource();
                token = _runCancellation.Token;
            }
            try { Sync(snapshot, rebuild, token); }
            catch (OperationCanceledException) { }
            catch (Exception exception) { _startError = "Indexing failed: " + exception.GetType().Name; }
            Publish();
        }
    }

    private void Sync(IReadOnlyList<RagDocument> snapshot, bool rebuild, CancellationToken token)
    {
        var index = _index;
        if (index is null) return;
        if (rebuild) index.Clear();

        // 1. Structure: remove deleted entries, re-chunk new or changed ones (fast, no model needed).
        var current = snapshot.GroupBy(document => document.EntryId).ToDictionary(group => group.Key, group => group.First());
        var indexed = index.Entries;
        index.RemoveEntries(indexed.Keys.Where(id => !current.ContainsKey(id)).ToList());
        foreach (var document in current.Values)
        {
            token.ThrowIfCancellationRequested();
            var hash = KnowledgeChunker.ContentHash(document);
            if (indexed.TryGetValue(document.EntryId, out var state) && state.ContentHash == hash && state.KnowledgeBaseId == document.KnowledgeBaseId) continue;
            index.ReplaceEntry(document.KnowledgeBaseId, document.EntryId, hash, KnowledgeChunker.Chunk(document), LocalEmbeddingService.ModelVersion);
        }
        Publish(RagIndexState.Indexing);

        // 2. Vectors: embed only chunks that have none (new, changed, or after a model change), in small batches.
        var embedder = _embedder;
        if (embedder is null) return;
        var missing = index.Chunks.Where(item => item.Vector is null).Select(item => item.Chunk).OrderBy(chunk => chunk.EntryId).ThenBy(chunk => chunk.ChunkIndex).ToList();
        for (var offset = 0; offset < missing.Count; offset += 16)
        {
            token.ThrowIfCancellationRequested();
            var batch = missing.Skip(offset).Take(16).ToList();
            var vectors = embedder.Embed(batch.Select(chunk => chunk.EmbeddingText).ToList(), token);
            index.StoreEmbeddings(batch.Select((chunk, position) => (chunk.ChunkId, vectors[position])).Where(pair => VectorMath.IsUsable(pair.Item2)).ToList(),
                LocalEmbeddingService.ModelVersion);
            Publish(RagIndexState.Indexing);
        }
    }

    /// <summary>
    /// Retrieves passages for a prepared query from the active knowledge bases. Runs the query embedding off the
    /// calling thread. Never throws for retrieval problems: it degrades to keyword-only, then to a bounded fallback.
    /// </summary>
    public async Task<RetrievalResult> RetrieveAsync(RetrievalQuery query, IReadOnlySet<Guid> activeKnowledgeBaseIds, IReadOnlySet<Guid>? enabledEntryIds,
        RetrievalOptions? options = null, CancellationToken cancellationToken = default)
    {
        if (query.IsEmpty || activeKnowledgeBaseIds.Count == 0) return RetrievalResult.Empty(RetrievalMode.None);
        await StartAsync().ConfigureAwait(false);
        var index = _index;
        if (index is null) return FallbackRetrieve(query, activeKnowledgeBaseIds, enabledEntryIds, options);

        float[]? vector = null;
        double embeddingMs = 0;
        var embedder = _embedder;
        if (embedder is not null && query.SemanticText.Length > 0)
        {
            var timer = Stopwatch.StartNew();
            try { vector = await Task.Run(() => CachedQueryVector(embedder, query.SemanticText), cancellationToken).ConfigureAwait(false); }
            catch (OperationCanceledException) { throw; }
            catch (Exception) { vector = null; }
            embeddingMs = timer.Elapsed.TotalMilliseconds;
        }
        cancellationToken.ThrowIfCancellationRequested();
        var result = KnowledgeRetrievalService.Retrieve(index.Chunks, query, vector, activeKnowledgeBaseIds, enabledEntryIds, options, embeddingMs);
        if (result.Chunks.Count == 0 && index.Entries.Count == 0 && _lastSnapshot.Count > 0)
            return FallbackRetrieve(query, activeKnowledgeBaseIds, enabledEntryIds, options);   // index still being built
        return result;
    }

    private float[] CachedQueryVector(LocalEmbeddingService embedder, string text)
    {
        lock (_queryCache) if (_queryCache.TryGetValue(text, out var cached)) return cached;
        var vector = embedder.EmbedQuery(text);
        lock (_queryCache)
        {
            if (_queryCache.TryAdd(text, vector)) _queryCacheOrder.Enqueue(text);
            while (_queryCacheOrder.Count > 64) _queryCache.Remove(_queryCacheOrder.Dequeue());
        }
        return vector;
    }

    /// <summary>Keyword search over freshly chunked documents when no persistent index is available. Bounded by the same budget.</summary>
    private RetrievalResult FallbackRetrieve(RetrievalQuery query, IReadOnlySet<Guid> activeKnowledgeBaseIds, IReadOnlySet<Guid>? enabledEntryIds, RetrievalOptions? options)
    {
        var chunks = _lastSnapshot
            .Where(document => activeKnowledgeBaseIds.Contains(document.KnowledgeBaseId) && (enabledEntryIds is null || enabledEntryIds.Contains(document.EntryId)))
            .SelectMany(document => KnowledgeChunker.Chunk(document))
            .Select(chunk =>
            {
                var terms = LexicalAnalyzer.TermFrequencies(chunk.LexicalText);
                return new IndexedChunk(chunk, terms, Math.Max(1, terms.Values.Sum()), null);
            }).ToList();
        var result = KnowledgeRetrievalService.Retrieve(chunks, query, null, activeKnowledgeBaseIds, enabledEntryIds, options);
        return result with { Mode = RetrievalMode.Fallback };
    }

    private void Publish(RagIndexState? state = null)
    {
        var index = _index;
        var pending = index?.ChunksWithoutEmbedding ?? 0;
        var resolved = state ?? (_startError is not null && index is null ? RagIndexState.Error
            : _embedder is null ? RagIndexState.KeywordOnly
            : pending > 0 ? RagIndexState.Indexing
            : RagIndexState.Ready);
        var message = _startError ?? (_embedder is null ? "Local embedding model not installed; using keyword search." : "");
        Status = new RagIndexStatus(resolved, index?.Entries.Count ?? 0, index?.Chunks.Count ?? 0, _embedder is null ? 0 : pending, message);
        StatusChanged?.Invoke(Status);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _runCancellation.Cancel();
        }
        try { _worker.Wait(TimeSpan.FromSeconds(3)); } catch (AggregateException) { }
        _index?.Dispose();
        _embedder?.Dispose();
    }
}

/// <summary>Retrieval entry point used by prompt construction (implemented by <see cref="KnowledgeIndexCoordinator"/>; faked in tests).</summary>
public interface IKnowledgeRetriever
{
    Task<RetrievalResult> RetrieveAsync(RetrievalQuery query, IReadOnlySet<Guid> activeKnowledgeBaseIds, IReadOnlySet<Guid>? enabledEntryIds,
        RetrievalOptions? options = null, CancellationToken cancellationToken = default);
}
