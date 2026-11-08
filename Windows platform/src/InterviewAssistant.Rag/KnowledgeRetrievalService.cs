using System.Diagnostics;

namespace InterviewAssistant.Rag;

/// <summary>Retrieval defaults (tuned with the tests in InterviewAssistant.Rag.Tests).</summary>
public sealed record RetrievalOptions
{
    public int SemanticCandidates { get; init; } = 12;
    public int KeywordCandidates { get; init; } = 12;
    public int TopK { get; init; } = 5;
    public int MaxContextTokens { get; init; } = 2_500;
    public int MaxChunksPerEntry { get; init; } = 2;
    /// <summary>e5 cosines are compressed (unrelated text still scores ~0.78), so a match must also stand out from the rest.</summary>
    public double SemanticFloor { get; init; } = 0.80;
    public double SemanticMargin { get; init; } = 0.05;
    public double SemanticAboveMedian { get; init; } = 0.035;
    public double KeywordRelativeFloor { get; init; } = 0.30;
    public int RrfK { get; init; } = 60;
    public static RetrievalOptions Default { get; } = new();
}

/// <summary>
/// Hybrid retrieval over the in-memory index: exact cosine search on local embeddings + BM25 keyword search,
/// combined with Reciprocal Rank Fusion, restricted to the active knowledge bases and enabled entries, with
/// weak-match gating, per-document diversity and a token budget. Pure and synchronous: callers embed the query first.
/// </summary>
public static class KnowledgeRetrievalService
{
    public static RetrievalResult Retrieve(
        IReadOnlyList<IndexedChunk> index,
        RetrievalQuery query,
        float[]? queryVector,
        IReadOnlySet<Guid> activeKnowledgeBaseIds,
        IReadOnlySet<Guid>? enabledEntryIds,
        RetrievalOptions? options = null,
        double queryEmbeddingMs = 0)
    {
        options ??= RetrievalOptions.Default;
        var total = Stopwatch.StartNew();
        if (query.IsEmpty || activeKnowledgeBaseIds.Count == 0) return RetrievalResult.Empty(RetrievalMode.None);
        var candidates = index.Where(item => activeKnowledgeBaseIds.Contains(item.Chunk.KnowledgeBaseId)
                                             && (enabledEntryIds is null || enabledEntryIds.Contains(item.Chunk.EntryId))).ToList();
        if (candidates.Count == 0) return RetrievalResult.Empty(RetrievalMode.None);

        // 1. Semantic: cosine (vectors are L2-normalized, so a dot product), then gate weak matches.
        var vectorTimer = Stopwatch.StartNew();
        var semantic = new List<(IndexedChunk Item, double Score)>();
        var useSemantic = VectorMath.IsUsable(queryVector);
        if (useSemantic)
        {
            var scored = candidates.Where(item => VectorMath.IsUsable(item.Vector))
                .Select(item => (Item: item, Score: VectorMath.Dot(queryVector, item.Vector)))
                .OrderByDescending(pair => pair.Score).ToList();
            if (scored.Count > 0)
            {
                var best = scored[0].Score;
                var median = scored[scored.Count / 2].Score;
                var smallCorpus = scored.Count < 6;
                foreach (var pair in scored.Take(options.SemanticCandidates))
                {
                    var standsOut = smallCorpus ? pair.Score >= options.SemanticFloor + options.SemanticAboveMedian : pair.Score - median >= options.SemanticAboveMedian;
                    if (pair.Score >= options.SemanticFloor && pair.Score >= best - options.SemanticMargin && standsOut) semantic.Add(pair);
                }
            }
            else useSemantic = false;
        }
        vectorTimer.Stop();

        // 2. Keyword: BM25 with weighted query terms (follow-up context terms weigh less than the question's own).
        var keywordTimer = Stopwatch.StartNew();
        var keyword = Bm25(candidates, query.KeywordWeights, options);
        keywordTimer.Stop();

        // 3. Reciprocal Rank Fusion of the two ranked lists.
        var fusionTimer = Stopwatch.StartNew();
        var fused = new Dictionary<string, (IndexedChunk Item, double Score, double? Cosine, double? Bm25)>(StringComparer.Ordinal);
        for (var rank = 0; rank < semantic.Count; rank++)
        {
            var (item, score) = semantic[rank];
            fused[item.Chunk.ChunkId] = (item, 1.0 / (options.RrfK + rank + 1), score, null);
        }
        for (var rank = 0; rank < keyword.Count; rank++)
        {
            var (item, score) = keyword[rank];
            var value = 1.0 / (options.RrfK + rank + 1);
            fused[item.Chunk.ChunkId] = fused.TryGetValue(item.Chunk.ChunkId, out var existing)
                ? (item, existing.Score + value, existing.Cosine, score)
                : (item, value, null, score);
        }

        // 4. Diversity + budget: at most N passages per document, no near-duplicates, stop at Top-K or the token budget.
        var selected = new List<RetrievedChunk>();
        var perEntry = new Dictionary<Guid, int>();
        var seenTexts = new HashSet<string>(StringComparer.Ordinal);
        var selectedVectors = new List<float[]>();
        var usedTokens = 0;
        foreach (var candidate in fused.Values.OrderByDescending(item => item.Score).ThenBy(item => item.Item.Chunk.ChunkId, StringComparer.Ordinal))
        {
            if (selected.Count >= options.TopK) break;
            var chunk = candidate.Item.Chunk;
            if (perEntry.GetValueOrDefault(chunk.EntryId) >= options.MaxChunksPerEntry) continue;
            var normalized = string.Join(' ', chunk.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).ToLowerInvariant();
            if (!seenTexts.Add(normalized)) continue;
            if (candidate.Item.Vector is { } vector && VectorMath.IsUsable(vector) && selectedVectors.Any(other => VectorMath.Dot(vector, other) > 0.985)) continue;
            var text = chunk.Text;
            var tokens = TokenEstimator.Estimate(text) + TokenEstimator.Estimate(chunk.Title) + 12;
            if (usedTokens + tokens > options.MaxContextTokens)
            {
                var remaining = options.MaxContextTokens - usedTokens - TokenEstimator.Estimate(chunk.Title) - 12;
                if (remaining < 120) continue;
                text = PromptTokenBudget.Fit(text, remaining);
                tokens = TokenEstimator.Estimate(text) + TokenEstimator.Estimate(chunk.Title) + 12;
            }
            usedTokens += tokens;
            perEntry[chunk.EntryId] = perEntry.GetValueOrDefault(chunk.EntryId) + 1;
            selected.Add(new RetrievedChunk(chunk, text, candidate.Score, candidate.Cosine, candidate.Bm25));
            if (candidate.Item.Vector is { } chosen && VectorMath.IsUsable(chosen)) selectedVectors.Add(chosen);
        }
        fusionTimer.Stop();
        total.Stop();
        var mode = useSemantic ? RetrievalMode.Hybrid : RetrievalMode.LexicalOnly;
        return new RetrievalResult(selected, mode, new RetrievalTimings(queryEmbeddingMs, vectorTimer.Elapsed.TotalMilliseconds,
            keywordTimer.Elapsed.TotalMilliseconds, fusionTimer.Elapsed.TotalMilliseconds, total.Elapsed.TotalMilliseconds + queryEmbeddingMs));
    }

    /// <summary>Terms from the question itself (1.0) or a resolved follow-up topic (1.0) qualify; context terms (≤ 0.5) do not.</summary>
    public const double QualifyingWeight = 0.8;

    internal static List<(IndexedChunk Item, double Score)> Bm25(IReadOnlyList<IndexedChunk> candidates, IReadOnlyDictionary<string, double> weights, RetrievalOptions options)
    {
        if (weights.Count == 0 || candidates.Count == 0) return [];
        const double k1 = 1.2, b = 0.75;
        double count = candidates.Count;
        var averageLength = candidates.Average(item => (double)item.TermCount);
        var documentFrequency = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var item in candidates)
            foreach (var term in weights.Keys)
                if (item.Terms.ContainsKey(term)) documentFrequency[term] = documentFrequency.GetValueOrDefault(term) + 1;
        var scored = new List<(IndexedChunk Item, double Score)>();
        foreach (var item in candidates)
        {
            double score = 0;
            var qualifies = false;
            foreach (var (term, weight) in weights)
            {
                if (!item.Terms.TryGetValue(term, out var tf) || !documentFrequency.TryGetValue(term, out var df)) continue;
                var idf = Math.Log(1 + (count - df + 0.5) / (df + 0.5));
                score += weight * idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * item.TermCount / averageLength));
                qualifies |= weight >= QualifyingWeight;
            }
            // Context-only matches (role, previous question) re-rank but never select a passage by themselves.
            if (score > 0 && qualifies) scored.Add((item, score));
        }
        if (scored.Count == 0) return [];
        var best = scored.Max(pair => pair.Score);
        return scored.Where(pair => pair.Score >= best * options.KeywordRelativeFloor)
            .OrderByDescending(pair => pair.Score).ThenBy(pair => pair.Item.Chunk.ChunkId, StringComparer.Ordinal)
            .Take(options.KeywordCandidates).ToList();
    }
}
