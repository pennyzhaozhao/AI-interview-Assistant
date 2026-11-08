using System.Text.RegularExpressions;

namespace InterviewAssistant.Rag;

public sealed record RagConversationTurn(string Question, string Answer);

/// <summary>The prepared retrieval query: text for the embedding model and weighted keyword terms.</summary>
public sealed record RetrievalQuery(string SemanticText, IReadOnlyDictionary<string, double> KeywordWeights, string? Topic, bool IsFollowUp)
{
    public static RetrievalQuery Empty { get; } = new("", new Dictionary<string, double>(), null, false);
    public bool IsEmpty => SemanticText.Length == 0 && KeywordWeights.Count == 0;
}

/// <summary>
/// Deterministic, local query contextualization for live interviews (no extra LLM call).
/// "How did you solve it?" after a question about the monitoring dashboard becomes a query that also carries the
/// dashboard project and the previous question; a question that names its own topic is left alone, so an earlier
/// project does not leak into an unrelated new question.
/// </summary>
public static class QueryContextualizer
{
    private const int MaxQuestionCharacters = 1_500;
    private const int MaxContextCharacters = 300;
    private const int TurnsToScan = 3;

    private static readonly Regex EnglishFollowUp = new(
        @"\b(it|that|this|those|these|them|there|the project|the challenge|the result|more detail|more details|elaborate|tell me more|go deeper|dig deeper|how did you|what did you|why did you|what was the|what were the|and then|what happened|follow[- ]?up|example of that)\b",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex ChineseFollowUp = new(
        @"(它|这个|那个|这件事|这部分|那部分|该项目|这个项目|那个项目|具体|展开|详细|细节|深入|怎么解决|如何解决|怎么做的|怎么实现|如何实现|遇到.{0,6}(困难|问题|挑战)|最大的(挑战|困难|难点)|难点|结果呢|然后呢|为什么这么|为什么这样|还有呢|举个例子|当时)",
        RegexOptions.Compiled);
    private static readonly HashSet<string> GenericTitles = new(StringComparer.OrdinalIgnoreCase)
    {
        "note", "notes", "main content", "笔记", "主要内容", "resume", "简历", "material", "资料", "readme"
    };

    public static RetrievalQuery Prepare(string question, IReadOnlyList<RagConversationTurn> recentTurns, string role, IReadOnlyCollection<string> knownTitles)
    {
        var current = Truncate(question.Trim(), MaxQuestionCharacters);
        if (current.Length == 0) return RetrievalQuery.Empty;
        var weights = new Dictionary<string, double>(StringComparer.Ordinal);
        AddTerms(weights, current, 1.0);
        var currentTermCount = weights.Count;

        var titles = knownTitles.Where(title => title.Trim().Length >= 2 && !GenericTitles.Contains(title.Trim())).Distinct().ToList();
        var mentionsOwnTopic = titles.Any(title => Mentions(current, title));
        var hasCue = EnglishFollowUp.IsMatch(current) || ChineseFollowUp.IsMatch(current);
        var turns = recentTurns.Where(turn => !string.IsNullOrWhiteSpace(turn.Question)).TakeLast(TurnsToScan).ToList();
        // A follow-up refers back ("it", "这个", "具体说说") or is too short to stand alone; a question that names
        // its own project or carries many content terms is treated as a new topic.
        var isFollowUp = turns.Count > 0 && !mentionsOwnTopic && (hasCue && currentTermCount <= 8 || currentTermCount <= 2);

        var semantic = current;
        string? topic = null;
        if (isFollowUp)
        {
            for (var index = turns.Count - 1; index >= 0 && topic is null; index--)
            {
                var turn = turns[index];
                topic = titles.FirstOrDefault(title => Mentions(turn.Question, title))
                     ?? titles.FirstOrDefault(title => Mentions(turn.Answer, title));
            }
            var previousQuestion = Truncate(turns[^1].Question.Trim(), MaxContextCharacters);
            if (topic is not null)
            {
                semantic += "\n" + topic;
                AddTerms(weights, topic, 1.0);
            }
            semantic += "\n" + previousQuestion;
            AddTerms(weights, previousQuestion, 0.5);
            if (topic is null && turns[^1].Answer.Trim().Length > 0)
            {
                // No known project named: the previous answer's opening still says what "it" was.
                var answerStart = Truncate(turns[^1].Answer.Trim(), 160);
                semantic += "\n" + answerStart;
                AddTerms(weights, answerStart, 0.3);
            }
        }
        else if (currentTermCount <= 3 && role.Trim().Length > 0)
        {
            // Generic questions ("Why should we hire you?"): the target role can re-rank keyword matches, but never
            // qualifies a passage on its own (see KnowledgeRetrievalService.QualifyingWeight) and is not embedded,
            // so an unrelated question does not pull in role-flavoured filler.
            AddTerms(weights, role, 0.3);
        }
        return new RetrievalQuery(semantic, weights, topic, isFollowUp);
    }

    /// <summary>True when <paramref name="text"/> names <paramref name="title"/> (whole title, or all of its distinctive terms).</summary>
    internal static bool Mentions(string text, string title)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        var cleanTitle = title.Trim();
        if (text.Contains(cleanTitle, StringComparison.OrdinalIgnoreCase)) return true;
        var titleTerms = LexicalAnalyzer.Terms(cleanTitle).Distinct().ToList();
        if (titleTerms.Count == 0 || titleTerms.Count > 4) return false;
        var textTerms = LexicalAnalyzer.Terms(text).ToHashSet(StringComparer.Ordinal);
        return titleTerms.All(textTerms.Contains) && titleTerms.Any(term => term.Length >= 3 || TextUtilities.IsCjk(term[0]));
    }

    private static void AddTerms(Dictionary<string, double> weights, string text, double weight)
    {
        foreach (var term in LexicalAnalyzer.Terms(text))
            weights[term] = Math.Max(weights.GetValueOrDefault(term), weight);
    }

    private static string Truncate(string text, int length) => text.Length <= length ? text : text[..length];
}
