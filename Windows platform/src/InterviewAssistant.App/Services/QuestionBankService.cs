using System.IO;
using System.Text;
using System.Text.Json;
using InterviewAssistant.Models;

namespace InterviewAssistant.Services;

public sealed class QuestionBankDocument
{
    public int Version { get; set; } = 1;
    public List<QuestionBankPrimary> Questions { get; set; } = [];
}

public sealed class QuestionBankPrimary
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Question { get; set; } = "";
    public string Answer { get; set; } = "";
    public List<QuestionBankFollowUp> FollowUps { get; set; } = [];
}

public sealed class QuestionBankFollowUp
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Question { get; set; } = "";
    public string Answer { get; set; } = "";
}

public static class QuestionBankService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true, PropertyNameCaseInsensitive = true };

    public static QuestionBankDocument Decode(string? content)
    {
        try { return JsonSerializer.Deserialize<QuestionBankDocument>(content ?? "", JsonOptions) ?? new(); }
        catch { return new(); }
    }

    public static string Encode(QuestionBankDocument value) => JsonSerializer.Serialize(value, JsonOptions);

    public static string SearchableText(string? content)
    {
        var builder = new StringBuilder();
        var document = Decode(content);
        for (var index = 0; index < document.Questions.Count; index++)
        {
            var item = document.Questions[index];
            builder.AppendLine($"Primary question {index + 1}: {item.Question}");
            builder.AppendLine($"Answer: {item.Answer}");
            for (var followIndex = 0; followIndex < item.FollowUps.Count; followIndex++)
            {
                var follow = item.FollowUps[followIndex];
                builder.AppendLine($"Follow-up {index + 1}.{followIndex + 1}: {follow.Question}");
                builder.AppendLine($"Follow-up answer: {follow.Answer}");
            }
            builder.AppendLine();
        }
        return builder.ToString().Trim();
    }

#if !QUESTION_BANK_CORE_ONLY
    public static string PreviewText(string? content)
    {
        var items = Decode(content).Questions.Take(3).Select(item => $"Q: {item.Question}\nA: {item.Answer}").ToList();
        return items.Count == 0 ? LocalizationManager.Text("No questions yet") : string.Join("\n\n", items);
    }

    public static async Task<QuestionBankDocument> ParseWithAIAsync(string rawText, CancellationToken cancellationToken = default)
    {
        const string system = """
            You structure interview preparation notes into a two-level question bank. Return valid JSON only:
            {"questions":[{"question":"main question","answer":"answer","followUps":[{"question":"follow-up","answer":"answer"}]}]}
            Preserve the user's language and facts. Identify main questions, their answers, and any follow-up questions with answers.
            Do not invent missing answers; use an empty string. Keep the original order. Do not return Markdown or code fences.
            """;
        var input = rawText.Length > 30_000 ? rawText[..30_000] : rawText;
        var raw = await AppServices.Current.AI.CompleteAsync(AIConfigProvider.Current(), system, input, 5000, cancellationToken);
        var json = ExtractJson(raw);
        using var parsed = JsonDocument.Parse(json);
        if (!parsed.RootElement.TryGetProperty("questions", out var items) || items.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException(LocalizationManager.Text("The AI did not return a valid question bank."));
        var result = new QuestionBankDocument();
        foreach (var item in items.EnumerateArray())
        {
            var question = Text(item, "question");
            if (question.Length == 0) continue;
            var primary = new QuestionBankPrimary { Question = question, Answer = Text(item, "answer") };
            if (item.TryGetProperty("followUps", out var followUps) && followUps.ValueKind == JsonValueKind.Array)
            {
                foreach (var follow in followUps.EnumerateArray())
                {
                    var followQuestion = Text(follow, "question");
                    if (followQuestion.Length > 0) primary.FollowUps.Add(new QuestionBankFollowUp { Question = followQuestion, Answer = Text(follow, "answer") });
                }
            }
            result.Questions.Add(primary);
        }
        if (result.Questions.Count == 0) throw new InvalidDataException(LocalizationManager.Text("No questions were found in the imported text."));
        return result;
    }

    private static string Text(JsonElement item, string name) =>
        item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() ?? "" : "";

    private static string ExtractJson(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.StartsWith("```"))
        {
            var firstNewline = trimmed.IndexOf('\n');
            var lastFence = trimmed.LastIndexOf("```", StringComparison.Ordinal);
            if (firstNewline >= 0 && lastFence > firstNewline) trimmed = trimmed[(firstNewline + 1)..lastFence].Trim();
        }
        var start = trimmed.IndexOf('{');
        var end = trimmed.LastIndexOf('}');
        return start >= 0 && end > start ? trimmed[start..(end + 1)] : trimmed;
    }
#endif
}
