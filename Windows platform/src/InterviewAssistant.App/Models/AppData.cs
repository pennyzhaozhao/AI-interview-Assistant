namespace InterviewAssistant.Models;

public sealed class AppData
{
    public int SchemaVersion { get; set; } = 1;
    public WorkspaceDraft Workspace { get; set; } = new();
    public AppPreferences Preferences { get; set; } = new();
    public Dictionary<string, ProviderSettings> ProviderSettings { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public List<KnowledgeBaseModel> KnowledgeBases { get; set; } = [];
    public List<InterviewSessionModel> Sessions { get; set; } = [];
}

public sealed class WorkspaceDraft
{
    public string Role { get; set; } = "";
    public string JobDescription { get; set; } = "";
    public string CompanyName { get; set; } = "";
    public string CompanyWebsite { get; set; } = "";
    public string CompanyNotes { get; set; } = "";
    public HashSet<Guid> ActiveKnowledgeBaseIds { get; set; } = [];
}

public sealed class AppPreferences
{
    public string Language { get; set; } = "en";
    public string Theme { get; set; } = "dark";
    public string Provider { get; set; } = AIProvider.DeepSeek.ToString();
    public string MockInterviewLanguage { get; set; } = "followApp";
    public string InterviewerLanguage { get; set; } = "followApp";
    public bool HidePrompterFromCapture { get; set; } = true;
    public bool HideTaskbarIconDuringInterview { get; set; }
    public string ScreenshotMode { get; set; } = "presetRegion";
    public string ScreenshotHotkey { get; set; } = "Ctrl+Shift+S";
    public double ScreenshotRegionX { get; set; }
    public double ScreenshotRegionY { get; set; }
    public double ScreenshotRegionWidth { get; set; }
    public double ScreenshotRegionHeight { get; set; }
    public string SpeechRecognitionEngine { get; set; } = "volcano";
    public string SpeechResourceId { get; set; } = "volc.seedasr.sauc.duration";
}

public sealed class ProviderSettings
{
    public string ApiUrl { get; set; } = "";
    public string Model { get; set; } = "";
}

public sealed class KnowledgeBaseModel
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.Now;
    public List<KnowledgeEntryModel> Entries { get; set; } = [];
}

public sealed class KnowledgeEntryModel
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string Content { get; set; } = "";
    public string Source { get; set; } = "manual";
    public bool IsEnabled { get; set; } = true;
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.Now;
}

public sealed class InterviewSessionModel
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string Role { get; set; } = "";
    public string Context { get; set; } = "";
    public List<Guid> ActiveKnowledgeBaseIds { get; set; } = [];
    public string Kind { get; set; } = "formal";
    public int OverallScore { get; set; }
    public string SummaryFeedback { get; set; } = "";
    public string StrengthsText { get; set; } = "";
    public string ImprovementsText { get; set; } = "";
    public DateTimeOffset StartedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset? EndedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.Now;
    public List<ConversationTurnModel> Turns { get; set; } = [];
}

public sealed class ConversationTurnModel
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Question { get; set; } = "";
    public string Answer { get; set; } = "";
    public string Category { get; set; } = "";
    public string Feedback { get; set; } = "";
    public string SuggestedAnswer { get; set; } = "";
    public int Score { get; set; }
    public string SpeakerLabel { get; set; } = "unknown";
    public string? ScreenshotPath { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
}

public enum AIProvider
{
    Ollama,
    DeepSeek,
    OpenAI,
    Claude,
    Gemini,
    Volcano
}

public sealed record ProviderDefinition(
    AIProvider Provider,
    string DisplayName,
    string DefaultUrl,
    string DefaultModel,
    IReadOnlyList<string> Models,
    bool RequiresApiKey)
{
    public override string ToString() => DisplayName;
}

public static class ProviderCatalog
{
    public static IReadOnlyList<ProviderDefinition> All { get; } =
    [
        new(AIProvider.Ollama, "Ollama local", "http://localhost:11434/v1", "qwen2.5:7b", ["qwen2.5:7b", "llama3.1:8b", "qwen2.5:14b"], false),
        new(AIProvider.DeepSeek, "DeepSeek", "https://api.deepseek.com", "deepseek-flash", ["deepseek-flash", "deepseek-v4-pro"], true),
        new(AIProvider.OpenAI, "OpenAI / ChatGPT", "https://api.openai.com/v1", "gpt-4.1-mini", ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o"], true),
        new(AIProvider.Claude, "Claude (Anthropic)", "https://api.anthropic.com/v1/messages", "claude-sonnet-4-5", ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"], true),
        new(AIProvider.Gemini, "Gemini", "https://generativelanguage.googleapis.com/v1beta", "gemini-2.0-flash", ["gemini-2.0-flash", "gemini-2.5-pro"], true),
        new(AIProvider.Volcano, "Volcano Ark", "https://ark.cn-beijing.volces.com/api/v3", "doubao-seed-1-8-251228", ["doubao-seed-1-8-251228", "doubao-seed-1-6-250615"], true)
    ];

    public static ProviderDefinition Get(AIProvider provider) => All.First(item => item.Provider == provider);
}

public sealed record AIConfig(AIProvider Provider, string ApiUrl, string ApiKey, string Model);
