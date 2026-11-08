namespace InterviewAssistant.Rag;

/// <summary>Kinds of knowledge entries (same strings as the app's KnowledgeEntryKinds and macOS).</summary>
public static class RagKinds
{
    public const string Resume = "resume";
    public const string Project = "project";
    public const string Material = "material";
}

/// <summary>
/// Read-only snapshot of one knowledge entry, taken from the app's own data. The RAG index never
/// writes back to the knowledge base: it is derived data that can be deleted and rebuilt at any time.
/// </summary>
public sealed record RagDocument(
    Guid KnowledgeBaseId,
    string KnowledgeBaseName,
    Guid EntryId,
    string Title,
    string Kind,
    string Source,
    string Summary,
    string Meta,
    string Content,
    bool IsEnabled);

/// <summary>A searchable passage of one knowledge entry.</summary>
public sealed record RagChunk(
    string ChunkId,
    Guid KnowledgeBaseId,
    Guid EntryId,
    string Title,
    string Kind,
    string Source,
    int ChunkIndex,
    string Section,
    string Text,
    string ContentHash,
    bool IsQuestionAnswer)
{
    /// <summary>Text given to the embedding model (e5 needs the "passage: " prefix).</summary>
    public string EmbeddingText => "passage: " + Title + (Section.Length > 0 ? " / " + Section : "") + "\n" + Text;

    /// <summary>Text indexed for keyword search; the title is repeated so project names weigh more.</summary>
    public string LexicalText => Title + "\n" + Title + "\n" + Section + "\n" + Text;
}

/// <summary>A retrieved passage with the scores that selected it (scores are ranks, not probabilities).</summary>
public sealed record RetrievedChunk(RagChunk Chunk, string Text, double FusedScore, double? Cosine, double? Bm25);

public enum RetrievalMode { Hybrid, LexicalOnly, Fallback, None }

public sealed record RetrievalTimings(double QueryEmbeddingMs, double VectorSearchMs, double KeywordSearchMs, double FusionMs, double TotalMs);

public sealed record RetrievalResult(IReadOnlyList<RetrievedChunk> Chunks, RetrievalMode Mode, RetrievalTimings Timings)
{
    public static RetrievalResult Empty(RetrievalMode mode) => new([], mode, new(0, 0, 0, 0, 0));
}
