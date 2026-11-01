using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using InterviewAssistant.Models;

namespace InterviewAssistant.Services;

public static class AIConfigProvider
{
    /// <summary>The provider / model / key last saved in Settings › API Configuration.</summary>
    public static AIConfig Current()
    {
        var store = AppServices.Current.DataStore;
        if (!Enum.TryParse<AIProvider>(store.Data.Preferences.Provider, true, out var provider)) provider = AIProvider.DeepSeek;
        var settings = store.GetProviderSettings(provider);
        var key = AppServices.Current.Credentials.Read(provider.ToString().ToLowerInvariant());
        return new AIConfig(provider, settings.ApiUrl, key, settings.Model);
    }
}

/// <summary>AI processing for knowledge bases: resume → Markdown + summary + skills, and project summaries.</summary>
public static class KnowledgeAssistant
{
    public sealed record ResumeDigest(string Summary, IReadOnlyList<string> Skills, IReadOnlyList<ResumeProject> Projects);

    /// <summary>A project the resume links to (GitHub repository, demo site, app page…).</summary>
    public sealed record ResumeProject(string Name, string Url, string Description);

    /// <summary>Turns text extracted from a PDF / Word resume into clean Markdown, keeping every fact.</summary>
    public static async Task<string> ResumeToMarkdownAsync(string rawText, CancellationToken cancellationToken = default)
    {
        const string system = """
            You convert resume text extracted from PDF or Word files into clean Markdown.
            Keep every fact exactly: names, dates, companies, schools, numbers, metrics, links, and wording.
            Do not summarize, translate, add, or invent anything. Fix only broken line wraps and bullet characters.
            Use "# Name", "## Section" headings and "-" bullets. Output Markdown only, with no code fences.
            """;
        var markdown = await AppServices.Current.AI.CompleteAsync(AIConfigProvider.Current(), system, Truncate(rawText, 24_000), 4000, cancellationToken);
        return StripFences(markdown);
    }

    /// <summary>Short profile summary plus a skills list, generated from the resume Markdown.</summary>
    public static async Task<ResumeDigest> DigestResumeAsync(string markdown, CancellationToken cancellationToken = default)
    {
        // Summary and skills follow the resume's own language, not the app language:
        // an English resume gets an English summary, a Chinese resume a Chinese one.
        var language = DetectLanguage(markdown);
        var system = $$"""
            You prepare interview context from a candidate's resume. Return valid JSON only:
            {"summary":"...","skills":["...","..."],"projects":[{"name":"...","url":"https://...","description":"..."}]}
            - summary: 120-220 words, written in {{language}} — the same language as the resume (keep technical terms, company and school names as written).
              Cover role focus, strongest achievements with their real numbers, education, work history, core technologies, certifications.
              Use only facts from the resume; never invent.
            - skills: 8-20 concise skill names actually supported by the resume (languages, frameworks, tools, methods, domains),
              most relevant first, no duplicates, each at most 4 words. Write each skill the way the resume writes it
              (technical terms keep their usual English form); do not translate skills into another language.
            - projects: every project in the resume that has its own link (GitHub repository, live demo, app store page, paper, website).
              name: the project name as written; url: the exact link from the resume (never invent or complete a link);
              description: one sentence in {{language}} from the resume text. Do not include personal profile links
              (LinkedIn, personal homepage, email, a GitHub profile without a repository). Use [] when there are none.
            """;
        var raw = await AppServices.Current.AI.CompleteAsync(AIConfigProvider.Current(), system, Truncate(markdown, 24_000), 1500, cancellationToken);
        using var document = JsonDocument.Parse(ExtractJson(raw));
        var root = document.RootElement;
        var summary = root.TryGetProperty("summary", out var s) && s.ValueKind == JsonValueKind.String ? s.GetString() ?? "" : "";
        var skills = root.TryGetProperty("skills", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.String).Select(item => item.GetString()!.Trim()).Where(item => item.Length > 0).ToList()
            : [];
        if (summary.Trim().Length == 0) throw new InvalidOperationException(LocalizationManager.Text("The AI did not return a summary."));
        var projects = new List<ResumeProject>();
        if (root.TryGetProperty("projects", out var projectList) && projectList.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in projectList.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.Object))
            {
                string Field(string name) => item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() ?? "" : "";
                var url = Field("url");
                // Only links that really appear in the resume.
                if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) continue;
                if (!markdown.Contains(url.TrimEnd('/'), StringComparison.OrdinalIgnoreCase)) continue;
                projects.Add(new ResumeProject(Field("name"), url, Field("description")));
            }
        }
        // Any GitHub repository link the model missed.
        foreach (var url in FindGitHubRepositoryLinks(markdown))
            if (!projects.Any(project => SameUrl(project.Url, url))) projects.Add(new ResumeProject("", url, ""));
        return new ResumeDigest(summary.Trim(), NormalizeSkills(skills), projects);
    }

    /// <summary>github.com/owner/repo links in the text (profile-only links are left out).</summary>
    public static List<string> FindGitHubRepositoryLinks(string text)
    {
        var result = new List<string>();
        foreach (Match match in Regex.Matches(text, @"(?:https?://)?(?:www\.)?github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)", RegexOptions.IgnoreCase))
        {
            var owner = match.Groups[1].Value;
            var repo = match.Groups[2].Value.TrimEnd('.', ',', ')');
            if (repo.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) repo = repo[..^4];
            if (repo.Length == 0 || owner is "orgs" or "topics" or "features" or "about" or "sponsors") continue;
            var url = $"https://github.com/{owner}/{repo}";
            if (!result.Any(existing => SameUrl(existing, url))) result.Add(url);
        }
        return result;
    }

    public static bool SameUrl(string left, string right) =>
        string.Equals(NormalizeUrl(left), NormalizeUrl(right), StringComparison.OrdinalIgnoreCase);

    private static string NormalizeUrl(string url)
    {
        var value = url.Trim().TrimEnd('/');
        foreach (var prefix in new[] { "https://", "http://" })
            if (value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) value = value[prefix.Length..];
        if (value.StartsWith("www.", StringComparison.OrdinalIgnoreCase)) value = value[4..];
        return value;
    }

    /// <summary>"Save original only": tidy extracted text locally (no AI).</summary>
    public static string CleanResumeText(string raw)
    {
        var text = raw.Replace("\r\n", "\n").Replace('\r', '\n').Replace('\t', ' ');
        text = Regex.Replace(text, @"[ \u00A0]+\n", "\n");
        text = Regex.Replace(text, @"\n{3,}", "\n\n");
        text = Regex.Replace(text, @"^[ \t]*[•●▪◦·]\s*", "- ", RegexOptions.Multiline);
        return text.Trim();
    }

    /// <summary>True when an AI provider is set up (Ollama needs no key).</summary>
    public static bool IsAIConfigured()
    {
        var config = AIConfigProvider.Current();
        return config.Provider == AIProvider.Ollama || config.ApiKey.Trim().Length > 0;
    }

    /// <summary>One or two sentences describing a GitHub project for interview use.</summary>
    public static async Task<string> SummarizeProjectAsync(string name, string readme, string description, CancellationToken cancellationToken = default)
    {
        // Follow the README's language, like resume summaries follow the resume.
        var language = DetectLanguage($"{description}\n{readme}");
        var system = $"""
            You summarize a candidate's GitHub project for interview preparation.
            Write 1-2 sentences in {language} (the language of the README): what it does, the main technical approach or stack, and any concrete result or scale mentioned.
            Use only the supplied text. Output plain text only.
            """;
        var question = $"Repository: {name}\nDescription: {description}\n\nREADME:\n{Truncate(readme, 12_000)}";
        return (await AppServices.Current.AI.CompleteAsync(AIConfigProvider.Current(), system, question, 400, cancellationToken)).Trim();
    }

    /// <summary>
    /// "Simplified Chinese" when CJK characters make up a meaningful share of the text, otherwise "English".
    /// Falls back to the app language when the text has too few letters to tell.
    /// </summary>
    public static string DetectLanguage(string text)
    {
        var sample = text.Length > 20_000 ? text[..20_000] : text;
        int cjk = 0, latin = 0;
        foreach (var character in sample)
        {
            if (character is >= '\u4E00' and <= '\u9FFF' or >= '\u3400' and <= '\u4DBF') cjk++;
            else if (character is >= 'A' and <= 'Z' or >= 'a' and <= 'z') latin++;
        }
        if (cjk + latin < 40) return LocalizationManager.Instance.IsChinese ? "Simplified Chinese" : "English";
        // One Chinese character carries roughly as much as a short English word (~4 letters).
        return cjk * 4 >= latin * 0.6 ? "Simplified Chinese" : "English";
    }

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

    /// <summary>Heuristic used to offer "set as resume" when a file is uploaded as general material.</summary>
    public static bool LooksLikeResume(string fileName, string text)
    {
        var name = fileName.ToLowerInvariant();
        if (name.Contains("resume") || name.Contains("cv") || name.Contains("简历") || name.Contains("履历")) return true;
        var lower = text.Length > 4000 ? text[..4000].ToLowerInvariant() : text.ToLowerInvariant();
        string[] markers = ["education", "experience", "skills", "教育", "工作经历", "实习经历", "项目经历", "专业技能"];
        return markers.Count(lower.Contains) >= 3;
    }

    private static string StripFences(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.StartsWith("```"))
        {
            var firstBreak = trimmed.IndexOf('\n');
            trimmed = firstBreak > 0 ? trimmed[(firstBreak + 1)..] : trimmed;
            if (trimmed.EndsWith("```")) trimmed = trimmed[..^3];
        }
        return trimmed.Trim();
    }

    private static string ExtractJson(string raw)
    {
        var first = raw.IndexOf('{');
        var last = raw.LastIndexOf('}');
        return first >= 0 && last > first ? raw[first..(last + 1)] : raw.Trim();
    }

    private static string Truncate(string text, int length) => text.Length <= length ? text : text[..length];
}

/// <summary>Imports public GitHub repositories (README + metadata) as knowledge-base projects.</summary>
public static class GitHubProjectImporter
{
    public sealed record ProjectInfo(string Name, string Url, string Description, string Language, int Stars, string Readme);

    private static readonly HttpClient Client = CreateClient();

    public static bool IsGitHubUrl(string value) =>
        Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri) && uri.Host.EndsWith("github.com", StringComparison.OrdinalIgnoreCase);

    /// <summary>A repository link returns one project; a profile link returns the owner's most recent non-fork repositories.</summary>
    public static async Task<List<ProjectInfo>> FetchAsync(string url, int profileLimit = 6, CancellationToken cancellationToken = default)
    {
        if (!Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri)) throw new InvalidOperationException(LocalizationManager.Text("Enter a valid GitHub link."));
        var parts = uri.AbsolutePath.Trim('/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) throw new InvalidOperationException(LocalizationManager.Text("Enter a valid GitHub link."));
        if (parts.Length == 1)
        {
            using var reposResponse = await Client.GetAsync($"https://api.github.com/users/{parts[0]}/repos?sort=pushed&per_page=30", cancellationToken);
            EnsureOk(reposResponse);
            using var reposDocument = JsonDocument.Parse(await reposResponse.Content.ReadAsStringAsync(cancellationToken));
            var names = reposDocument.RootElement.EnumerateArray()
                .Where(repo => !(repo.TryGetProperty("fork", out var fork) && fork.GetBoolean()))
                .Select(repo => repo.GetProperty("name").GetString()!)
                .Take(profileLimit)
                .ToList();
            var projects = new List<ProjectInfo>();
            foreach (var name in names) projects.Add(await FetchRepositoryAsync(parts[0], name, cancellationToken));
            return projects;
        }
        var repoName = parts[1].EndsWith(".git", StringComparison.OrdinalIgnoreCase) ? parts[1][..^4] : parts[1];
        return [await FetchRepositoryAsync(parts[0], repoName, cancellationToken)];
    }

    private static async Task<ProjectInfo> FetchRepositoryAsync(string owner, string repo, CancellationToken cancellationToken)
    {
        using var response = await Client.GetAsync($"https://api.github.com/repos/{owner}/{repo}", cancellationToken);
        EnsureOk(response);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
        var root = document.RootElement;
        string Text(string name) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
        var stars = root.TryGetProperty("stargazers_count", out var starValue) && starValue.ValueKind == JsonValueKind.Number ? starValue.GetInt32() : 0;

        var readme = "";
        using (var request = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{owner}/{repo}/readme"))
        {
            request.Headers.Accept.Clear();
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github.raw"));
            using var readmeResponse = await Client.SendAsync(request, cancellationToken);
            if (readmeResponse.IsSuccessStatusCode) readme = await readmeResponse.Content.ReadAsStringAsync(cancellationToken);
        }
        if (readme.Length > 30_000) readme = readme[..30_000];
        return new ProjectInfo(Text("name") is { Length: > 0 } name ? name : repo, Text("html_url") is { Length: > 0 } html ? html : $"https://github.com/{owner}/{repo}",
            Text("description"), Text("language"), stars, readme);
    }

    public static string BuildContent(ProjectInfo project)
    {
        var builder = new StringBuilder();
        builder.AppendLine($"Repository: {project.Url}");
        if (project.Description.Length > 0) builder.AppendLine($"Description: {project.Description}");
        if (project.Language.Length > 0) builder.AppendLine($"Main language: {project.Language}");
        if (project.Readme.Length > 0) builder.AppendLine().AppendLine(project.Readme);
        return builder.ToString().Trim();
    }

    public static string BuildMeta(ProjectInfo project)
    {
        var parts = new List<string>();
        if (project.Language.Length > 0) parts.Add(project.Language);
        if (project.Stars > 0) parts.Add($"★ {project.Stars}");
        return string.Join(" · ", parts);
    }

    private static void EnsureOk(HttpResponseMessage response)
    {
        if (response.IsSuccessStatusCode) return;
        throw new HttpRequestException((int)response.StatusCode switch
        {
            404 => LocalizationManager.Text("GitHub repository not found or not public."),
            403 or 429 => LocalizationManager.Text("GitHub rate limit reached. Try again in a few minutes."),
            var code => $"GitHub HTTP {code}"
        });
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("InterviewAssistant");
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }
}

/// <summary>Builds the knowledge-base section of interview prompts from the structured knowledge bases.</summary>
public static class KnowledgeContextFormatter
{
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
                    builder.AppendLine($"- {project.Title}{(project.Meta.Length > 0 ? $" ({project.Meta})" : "")}: {(project.Summary.Length > 0 ? project.Summary : "")}");
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
        KnowledgeAssistant.NormalizeSkills(knowledgeBases.Where(item => activeIds.Contains(item.Id)).SelectMany(item => item.Skills));

    private static string Truncate(string text, int length) => text.Length <= length ? text : text[..length];
}
