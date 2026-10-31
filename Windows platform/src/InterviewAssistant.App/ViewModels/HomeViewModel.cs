using System.Net;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Windows.Input;
using InterviewAssistant.Infrastructure;
using InterviewAssistant.Models;
using InterviewAssistant.Services;

namespace InterviewAssistant.ViewModels;

public sealed class HomeViewModel : PageViewModel
{
    private string _role = "";
    private string _jobDescription = "";
    private string _company = "";
    private string _companyWebsite = "";
    private string _companyNotes = "";
    private string _statusMessage = "Ready when you are.";
    private readonly AppDataStore _store;

    public HomeViewModel() : base("Interview AI", "Practice smarter. Ace your next interview.")
    {
        _store = AppServices.Current.DataStore;
        var draft = _store.Data.Workspace;
        _role = draft.Role;
        _jobDescription = draft.JobDescription;
        _company = draft.CompanyName;
        _companyWebsite = draft.CompanyWebsite;
        _companyNotes = draft.CompanyNotes;
        _store.Changed += RefreshKnowledgeSummary;
        _store.DataReset += ReloadWorkspace;
        LocalizationManager.Instance.LanguageChanged += RefreshKnowledgeSummary;
        StartInterviewCommand = new RelayCommand(StartInterview);
        MockInterviewCommand = new RelayCommand(() => MockInterviewOptionsRequested?.Invoke());
        ParseWebsiteCommand = new AsyncRelayCommand(ParseWebsiteAsync, () => !IsParsingWebsite);
        ChooseKnowledgeCommand = new RelayCommand(() => KnowledgeSelectionRequested?.Invoke());
    }

    public string Role
    {
        get => _role;
        set
        {
            if (!SetProperty(ref _role, value)) return;
            _store.Data.Workspace.Role = value;
            _store.ScheduleSave();
        }
    }

    public string JobDescription
    {
        get => _jobDescription;
        set
        {
            if (!SetProperty(ref _jobDescription, value)) return;
            _store.Data.Workspace.JobDescription = value;
            _store.ScheduleSave();
        }
    }

    public string Company
    {
        get => _company;
        set
        {
            if (!SetProperty(ref _company, value)) return;
            _store.Data.Workspace.CompanyName = value;
            _store.ScheduleSave();
        }
    }

    public string CompanyWebsite
    {
        get => _companyWebsite;
        set
        {
            if (!SetProperty(ref _companyWebsite, value)) return;
            _store.Data.Workspace.CompanyWebsite = value;
            _store.ScheduleSave();
        }
    }

    public string CompanyNotes
    {
        get => _companyNotes;
        set
        {
            if (!SetProperty(ref _companyNotes, value)) return;
            _store.Data.Workspace.CompanyNotes = value;
            _store.ScheduleSave();
        }
    }

    public int ActiveKnowledgeBaseCount => _store.Data.Workspace.ActiveKnowledgeBaseIds.Count;
    public Guid? PreferredKnowledgeBaseId => _store.Data.KnowledgeBases
        .FirstOrDefault(item => _store.Data.Workspace.ActiveKnowledgeBaseIds.Contains(item.Id))?.Id;
    public string KnowledgeCountText => LocalizationManager.Instance.IsChinese
        ? $"{ActiveKnowledgeBaseCount} 个知识库"
        : $"{ActiveKnowledgeBaseCount} {(ActiveKnowledgeBaseCount == 1 ? "knowledge base" : "knowledge bases")}";
    public string KnowledgePickerTitle => ActiveKnowledgeBaseCount == 0
        ? LocalizationManager.Text("Choose Knowledge")
        : _store.Data.KnowledgeBases.FirstOrDefault(item => _store.Data.Workspace.ActiveKnowledgeBaseIds.Contains(item.Id))?.Name ?? KnowledgeCountText;

    public string StatusMessage
    {
        get => _statusMessage;
        private set => SetProperty(ref _statusMessage, value);
    }

    public ICommand StartInterviewCommand { get; }
    public ICommand MockInterviewCommand { get; }
    public ICommand ParseWebsiteCommand { get; }
    public ICommand ChooseKnowledgeCommand { get; }
    public event Action<InterviewSessionModel>? InterviewStarted;
    public event Action<MockInterviewLaunchConfig>? MockInterviewRequested;
    public event Action? MockInterviewOptionsRequested;
    public event Action? KnowledgeSelectionRequested;

    private void RefreshKnowledgeSummary()
    {
        OnPropertyChanged(nameof(ActiveKnowledgeBaseCount));
        OnPropertyChanged(nameof(KnowledgeCountText));
        OnPropertyChanged(nameof(KnowledgePickerTitle));
    }

    private void ReloadWorkspace()
    {
        var draft = _store.Data.Workspace;
        _role = draft.Role;
        _jobDescription = draft.JobDescription;
        _company = draft.CompanyName;
        _companyWebsite = draft.CompanyWebsite;
        _companyNotes = draft.CompanyNotes;
        OnPropertyChanged(nameof(Role));
        OnPropertyChanged(nameof(JobDescription));
        OnPropertyChanged(nameof(Company));
        OnPropertyChanged(nameof(CompanyWebsite));
        OnPropertyChanged(nameof(CompanyNotes));
        RefreshKnowledgeSummary();
    }

    public void PrepareMockInterview(int questionCount)
    {
        StatusMessage = LocalizationManager.Text("Generating mock interview questions…");
        MockInterviewRequested?.Invoke(new MockInterviewLaunchConfig(
            string.IsNullOrWhiteSpace(Role)
                ? (LocalizationManager.Instance.IsChinese ? "通用面试" : "General Interview")
                : Role.Trim(),
            JobDescription.Trim(),
            _store.Data.Workspace.ActiveKnowledgeBaseIds.ToArray(),
            _store.Data.Preferences.MockInterviewLanguage,
            Math.Clamp(questionCount, 3, 10)));
    }

    private bool _isParsingWebsite;

    public bool IsParsingWebsite
    {
        get => _isParsingWebsite;
        private set { if (SetProperty(ref _isParsingWebsite, value)) CommandManager.InvalidateRequerySuggested(); }
    }

    /// <summary>Same flow as the macOS SetupView.parseCompanyWebsite(): AI research summary appended to the notes.</summary>
    private async Task ParseWebsiteAsync()
    {
        var input = CompanyWebsite.Trim();
        if (input.Length == 0 || IsParsingWebsite)
        {
            if (input.Length == 0) StatusMessage = LocalizationManager.Text("Enter a valid company website first.");
            return;
        }
        IsParsingWebsite = true;
        StatusMessage = LocalizationManager.Text("Parsing the company website and generating a research summary...");
        try
        {
            var summary = await WebsiteResearchService.ResearchCompanyAsync(input, CurrentAIConfig());
            var block = $"{LocalizationManager.Text("Website research summary (please review manually):")}\n{summary}";
            var existing = CompanyNotes.Trim();
            CompanyNotes = existing.Length == 0 ? block : $"{existing}\n\n{block}";
            StatusMessage = LocalizationManager.Text("Company research summary generated. Please review it quickly before the interview.");
        }
        catch (Exception exception)
        {
            StatusMessage = string.Format(LocalizationManager.Text("Parsing failed: {0}. You can fill in the company notes manually."), exception.Message.TrimEnd('.', '。'));
        }
        finally
        {
            IsParsingWebsite = false;
        }
    }

    private AIConfig CurrentAIConfig()
    {
        if (!Enum.TryParse<AIProvider>(_store.Data.Preferences.Provider, true, out var provider)) provider = AIProvider.DeepSeek;
        var settings = _store.GetProviderSettings(provider);
        var key = AppServices.Current.Credentials.Read(provider.ToString().ToLowerInvariant());
        return new AIConfig(provider, settings.ApiUrl, key, settings.Model);
    }

    private void StartInterview()
    {
        var session = _store.CreateFormalSession();
        StatusMessage = string.IsNullOrWhiteSpace(Role)
            ? LocalizationManager.Text("Interview workspace is ready.")
            : string.Format(LocalizationManager.Text("Interview workspace for {0} is ready."), Role.Trim());
        InterviewStarted?.Invoke(session);
    }
}
