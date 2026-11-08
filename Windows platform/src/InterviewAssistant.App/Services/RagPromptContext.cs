using InterviewAssistant.Models;
using InterviewAssistant.Rag;

namespace InterviewAssistant.Services;

/// <summary>Knowledge for one LLM request: the compact core profile plus passages retrieved for this question.</summary>
public sealed record KnowledgePromptContext(string CoreProfile, string RetrievedKnowledge, RetrievalResult Retrieval)
{
    public static KnowledgePromptContext Empty { get; } = new("", "", RetrievalResult.Empty(RetrievalMode.None));
}

/// <summary>
/// Runs local retrieval for an interview question before the prompt is built. The knowledge-base snapshot is read
/// synchronously on the calling (UI) thread; embedding and search run in the background. Nothing here sends data
/// anywhere: the result is only placed into the prompt that the caller then sends to the user's chosen LLM.
/// </summary>
public static class RagPromptContext
{
    public static async Task<KnowledgePromptContext> BuildAsync(
        IKnowledgeRetriever? retriever,
        string question,
        IReadOnlyList<KnowledgeBaseModel> knowledgeBases,
        IReadOnlyCollection<Guid> activeIds,
        IEnumerable<ConversationTurnModel> recentTurns,
        string role,
        PromptBudget? budget = null,
        CancellationToken cancellationToken = default,
        RetrievalOptions? options = null)
    {
        budget ??= PromptBudget.Default;
        var coreProfile = KnowledgeContextFormatter.CoreProfile(knowledgeBases, activeIds, budget.CoreProfile);
        if (retriever is null || activeIds.Count == 0 || string.IsNullOrWhiteSpace(question))
            return new KnowledgePromptContext(coreProfile, "", RetrievalResult.Empty(RetrievalMode.None));

        var active = activeIds.ToHashSet();
        var activeBases = knowledgeBases.Where(kb => active.Contains(kb.Id)).ToList();
        var enabled = activeBases.SelectMany(kb => kb.Entries).Where(entry => entry.IsEnabled).Select(entry => entry.Id).ToHashSet();
        var titles = activeBases.SelectMany(kb => kb.Entries).Where(entry => entry.IsEnabled && KnowledgeEntryKinds.Of(entry) != KnowledgeEntryKinds.Resume)
            .Select(entry => entry.Title).ToList();
        var turns = recentTurns
            .Where(turn => !string.IsNullOrWhiteSpace(turn.Question))
            .OrderBy(turn => turn.CreatedAt).TakeLast(3)
            .Select(turn => new RagConversationTurn(turn.Question, turn.Answer ?? "")).ToList();
        var query = QueryContextualizer.Prepare(question, turns, role ?? "", titles);

        RetrievalResult result;
        try
        {
            result = await retriever.RetrieveAsync(query, active, enabled, (options ?? RetrievalOptions.Default) with { MaxContextTokens = budget.RetrievedKnowledge }, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception) { result = RetrievalResult.Empty(RetrievalMode.None); }   // answer without retrieved passages rather than fail
        return new KnowledgePromptContext(coreProfile, RagContextAssembler.Format(result.Chunks), result);
    }
}
