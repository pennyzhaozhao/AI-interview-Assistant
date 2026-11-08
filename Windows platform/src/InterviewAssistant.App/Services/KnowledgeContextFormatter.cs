using System.Text;
using System.Text.RegularExpressions;
using InterviewAssistant.Models;
using InterviewAssistant.Rag;

namespace InterviewAssistant.Services;

/// <summary>
/// Structured views of the knowledge bases. Interview prompts no longer receive the whole knowledge base:
/// they get <see cref="CoreProfile"/> (a short, always-present profile) plus passages retrieved for the
/// current question (see <see cref="RagPromptContext"/>). <see cref="Build"/> keeps the legacy full-text view
/// for compatibility; it is not used for LLM requests.
/// </summary>
public static class KnowledgeContextFormatter
{
    /// <summary>
    /// Compact candidate profile: resume summary (or the start of the resume), skills and a one-line list of
    /// projects for each active knowledge base, within <paramref name="maxTokens"/>. Detailed resume text,
    /// READMEs and materials are reached through retrieval instead.
    /// </summary>
    public static string CoreProfile(IEnumerable<KnowledgeBaseModel> knowledgeBases, IReadOnlyCollection<Guid> activeIds, int maxTokens = 450)
    {
        var active = knowledgeBases.Where(item => activeIds.Contains(item.Id)).ToList();
        if (active.Count == 0) return "";
        var perBase = Math.Max(120, maxTokens / active.Count);
        var blocks = new List<string>();
        foreach (var kb in active)
        {
            var builder = new StringBuilder();
            builder.AppendLine($"[{kb.Name}]");
            var entries = kb.Entries.Where(entry => entry.IsEnabled).ToList();
            var resume = entries.FirstOrDefault(entry => KnowledgeEntryKinds.Of(entry) == KnowledgeEntryKinds.Resume);
            if (resume is not null)
            {
                var summary = resume.Summary.Trim();
                builder.AppendLine("Profile: " + (summary.Length > 0 ? summary : PromptTokenBudget.Fit(resume.Content, perBase / 2)));
            }
            var skills = NormalizeSkills(kb.Skills).Take(25).ToList();
            if (skills.Count > 0) builder.AppendLine("Skills: " + string.Join(", ", skills));
            var projects = entries.Where(entry => KnowledgeEntryKinds.Of(entry) == KnowledgeEntryKinds.Project).ToList();
            if (projects.Count > 0)
            {
                builder.AppendLine("Projects:");
                foreach (var project in projects)
                {
                    var line = FirstSentence(project.Summary.Length > 0 ? project.Summary : project.Content, 160);
                    builder.AppendLine($"- {project.Title}{(project.Meta.Length > 0 ? $" ({project.Meta})" : "")}{(line.Length > 0 ? ": " + line : "")}");
                }
            }
            var materials = entries.Where(entry => KnowledgeEntryKinds.Of(entry) == KnowledgeEntryKinds.Material).Select(entry => entry.Title).Where(title => title.Trim().Length > 0).Take(12).ToList();
            if (materials.Count > 0) builder.AppendLine("Other materials: " + string.Join("; ", materials));
            if (builder.Length > kb.Name.Length + 6) blocks.Add(PromptTokenBudget.Fit(builder.ToString().Trim(), perBase));
        }
        return PromptTokenBudget.Fit(string.Join("\n\n", blocks), maxTokens);
    }

    /// <summary>Snapshot of every knowledge entry for the local index (all knowledge bases; filtering happens at query time).</summary>
    public static List<RagDocument> ToRagDocuments(IEnumerable<KnowledgeBaseModel> knowledgeBases) =>
        knowledgeBases.SelectMany(kb => kb.Entries.Select(entry => new RagDocument(
            kb.Id, kb.Name, entry.Id, entry.Title ?? "", KnowledgeEntryKinds.Of(entry), entry.Source ?? "", entry.Summary ?? "",
            entry.Meta ?? "", entry.Content ?? "", entry.IsEnabled))).ToList();

    /// <summary>
    /// Legacy full-text view of the active knowledge bases (resume, skills, projects, materials), truncated to
    /// <paramref name="limit"/> characters. Kept for compatibility; interview prompts use retrieval instead.
    /// </summary>
    public static string Build(IEnumerable<KnowledgeBaseModel> knowledgeBases, IReadOnlyCollection<Guid> activeIds, int limit = 24_000)
    {
        var blocks = new List<string>();
        foreach (var kb in knowledgeBases.Where(item => activeIds.Contains(item.Id)))
        {
            var builder = new StringBuilder();
            builder.AppendLine($"[{kb.Name}]");
            var entries = kb.Entries.Where(entry => entry.IsEnabled).ToList();
            var resume = entries.FirstOrDefault(entry => KnowledgeEntryKinds.Of(entry) == KnowledgeEntryKinds.Resume);
            if (resume is not null)
            {
                if (!string.IsNullOrWhiteSpace(resume.Summary)) builder.AppendLine("Resume summary:").AppendLine(resume.Summary.Trim()).AppendLine();
                if (!string.IsNullOrWhiteSpace(resume.Content)) builder.AppendLine("Resume (full text, use for specific details and numbers):").AppendLine(resume.Content.Trim()).AppendLine();
            }
            if (kb.Skills.Count > 0) builder.AppendLine("Skills: " + string.Join(", ", kb.Skills)).AppendLine();
            var projects = entries.Where(entry => KnowledgeEntryKinds.Of(entry) == KnowledgeEntryKinds.Project).ToList();
            if (projects.Count > 0)
            {
                builder.AppendLine("Projects:");
                foreach (var project in projects)
                {
                    builder.AppendLine($"- {project.Title}{(project.Meta.Length > 0 ? $" ({project.Meta})" : "")}: {project.Summary}");
                    if (project.Content.Length > 0) builder.AppendLine("  Details: " + Truncate(project.Content.Replace("\n", " "), 2500));
                }
                builder.AppendLine();
            }
            foreach (var material in entries.Where(entry => KnowledgeEntryKinds.Of(entry) == KnowledgeEntryKinds.Material && !string.IsNullOrWhiteSpace(entry.Content)))
                builder.AppendLine($"{material.Title}:").AppendLine(material.Content.Trim()).AppendLine();
            if (builder.Length > kb.Name.Length + 6) blocks.Add(builder.ToString().Trim());
        }
        return Truncate(string.Join("\n\n", blocks), limit);
    }

    /// <summary>Custom instructions from the active knowledge bases, combined.</summary>
    public static string Instructions(IEnumerable<KnowledgeBaseModel> knowledgeBases, IReadOnlyCollection<Guid> activeIds) =>
        string.Join("\n", knowledgeBases
            .Where(item => activeIds.Contains(item.Id) && !string.IsNullOrWhiteSpace(item.CustomInstructions))
            .Select(item => item.CustomInstructions.Trim()));

    public static IReadOnlyList<string> Skills(IEnumerable<KnowledgeBaseModel> knowledgeBases, IReadOnlyCollection<Guid> activeIds) =>
        NormalizeSkills(knowledgeBases.Where(item => activeIds.Contains(item.Id)).SelectMany(item => item.Skills));

    public static List<string> NormalizeSkills(IEnumerable<string> skills)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();
        foreach (var skill in skills)
        {
            var clean = Regex.Replace(skill ?? "", @"\s+", " ").Trim().Trim('-', '•', '·', ',', '，', '、');
            if (clean.Length == 0 || clean.Length > 40) continue;
            if (seen.Add(clean)) result.Add(clean);
        }
        return result;
    }

    private static string FirstSentence(string text, int maxCharacters)
    {
        var value = Regex.Replace(text ?? "", @"\s+", " ").Trim();
        var end = value.IndexOfAny(['。', '！', '？', '.', '!', '?']);
        if (end > 0 && end < maxCharacters) return value[..(end + 1)];
        return value.Length <= maxCharacters ? value : value[..maxCharacters].TrimEnd() + "…";
    }

    private static string Truncate(string text, int length) => text.Length <= length ? text : text[..length];
}
