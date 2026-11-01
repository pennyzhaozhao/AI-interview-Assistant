using System.Collections.ObjectModel;
using System.Windows.Input;
using System.Windows.Data;
using System.ComponentModel;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text.RegularExpressions;
using InterviewAssistant.Infrastructure;
using InterviewAssistant.Models;
using InterviewAssistant.Services;

namespace InterviewAssistant.ViewModels;

public sealed class KnowledgeViewModel : PageViewModel
{
    private readonly AppDataStore _store = AppServices.Current.DataStore;
    private KnowledgeBaseItemViewModel? _selectedKnowledgeBase;
    private string _searchText = "";
    private string _sourceUrl = "";
    private string _saveStatus = "";
    private bool _isSelectionMode;
    private bool _isImportingSource;
    private static readonly HttpClient WebClient = new() { Timeout = TimeSpan.FromSeconds(20) };

    public KnowledgeViewModel() : base("Knowledge Base", "Give Interview AI the context it needs to answer like you.")
    {
        KnowledgeBases = new ObservableCollection<KnowledgeBaseItemViewModel>(
            _store.Data.KnowledgeBases
                .OrderByDescending(item => item.UpdatedAt)
                .Select(item => new KnowledgeBaseItemViewModel(item, _store)));
        NewKnowledgeBaseCommand = new RelayCommand(NewKnowledgeBase);
        DeleteKnowledgeBaseCommand = new RelayCommand<KnowledgeBaseItemViewModel>(DeleteKnowledgeBase);
        ToggleSelectionModeCommand = new RelayCommand(ToggleSelectionMode);
        SelectAllCommand = new RelayCommand(SelectAll);
        DeleteSelectedCommand = new RelayCommand(DeleteSelected);
        ImportSourceCommand = new AsyncRelayCommand(ImportSourceAsync, () => SelectedKnowledgeBase is not null && !IsImportingSource);
        DuplicateKnowledgeBaseCommand = new RelayCommand<KnowledgeBaseItemViewModel>(DuplicateKnowledgeBase);
        KnowledgeBasesView = CollectionViewSource.GetDefaultView(KnowledgeBases);
        KnowledgeBasesView.Filter = item => item is KnowledgeBaseItemViewModel knowledge &&
            (string.IsNullOrWhiteSpace(SearchText) || knowledge.Name.Contains(SearchText, StringComparison.OrdinalIgnoreCase) || knowledge.Description.Contains(SearchText, StringComparison.OrdinalIgnoreCase));
        SelectedKnowledgeBase = KnowledgeBases.FirstOrDefault();
        LocalizationManager.Instance.LanguageChanged += () =>
        {
            OnPropertyChanged(nameof(SelectionButtonText));
            foreach (var item in KnowledgeBases) item.RefreshLanguage();
        };
        _store.DataReset += Reload;
    }

    public ObservableCollection<KnowledgeBaseItemViewModel> KnowledgeBases { get; }
    public ICommand NewKnowledgeBaseCommand { get; }
    public ICommand DeleteKnowledgeBaseCommand { get; }
    public ICommand ImportSourceCommand { get; }
    public ICommand ToggleSelectionModeCommand { get; }
    public ICommand SelectAllCommand { get; }
    public ICommand DeleteSelectedCommand { get; }
    public ICommand DuplicateKnowledgeBaseCommand { get; }
    public ICollectionView KnowledgeBasesView { get; }
    public bool IsEmpty => KnowledgeBases.Count == 0;
    public bool HasKnowledgeBases => !IsEmpty;
    public bool IsSelectionMode
    {
        get => _isSelectionMode;
        private set
        {
            if (!SetProperty(ref _isSelectionMode, value)) return;
            OnPropertyChanged(nameof(SelectionButtonText));
            if (!value)
            {
                foreach (var item in KnowledgeBases) item.IsBulkSelected = false;
            }
        }
    }
    public string SelectionButtonText => LocalizationManager.Text(IsSelectionMode ? "Cancel" : "Select");

    public string SearchText
    {
        get => _searchText;
        set { if (SetProperty(ref _searchText, value)) KnowledgeBasesView.Refresh(); }
    }

    public string SourceUrl
    {
        get => _sourceUrl;
        set => SetProperty(ref _sourceUrl, value);
    }

    public string SaveStatus
    {
        get => _saveStatus;
        private set => SetProperty(ref _saveStatus, value);
    }

    public bool IsImportingSource
    {
        get => _isImportingSource;
        private set
        {
            if (!SetProperty(ref _isImportingSource, value)) return;
            (ImportSourceCommand as AsyncRelayCommand)?.NotifyCanExecuteChanged();
        }
    }

    public KnowledgeBaseItemViewModel? SelectedKnowledgeBase
    {
        get => _selectedKnowledgeBase;
        set
        {
            if (!SetProperty(ref _selectedKnowledgeBase, value)) return;
            (ImportSourceCommand as AsyncRelayCommand)?.NotifyCanExecuteChanged();
            SaveStatus = "";
        }
    }

    /// <summary>Copies a whole knowledge base (resume, skills, projects, materials, instructions) as an independent copy.</summary>
    public void DuplicateKnowledgeBase(KnowledgeBaseItemViewModel source)
    {
        var suffix = LocalizationManager.Instance.IsChinese ? " 副本" : " copy";
        var model = new KnowledgeBaseModel
        {
            Name = source.Name + suffix,
            Description = source.Description,
            Skills = source.Model.Skills.ToList(),
            CustomInstructions = source.Model.CustomInstructions,
            Entries = source.Model.Entries.Select(KnowledgeEntryKinds.Clone).ToList()
        };
        var index = _store.Data.KnowledgeBases.IndexOf(source.Model);
        _store.Data.KnowledgeBases.Insert(Math.Max(0, index), model);
        var item = new KnowledgeBaseItemViewModel(model, _store);
        KnowledgeBases.Insert(Math.Max(0, KnowledgeBases.IndexOf(source)), item);
        SelectedKnowledgeBase = item;
        _store.ScheduleSave();
        NotifyCollectionState();
        SaveStatus = LocalizationManager.Instance.IsChinese ? $"已复制为「{model.Name}」" : $"Duplicated as “{model.Name}”";
    }

    /// <summary>Other knowledge bases an item can be copied to.</summary>
    public IEnumerable<KnowledgeBaseItemViewModel> CopyTargets(KnowledgeBaseItemViewModel? exclude) =>
        KnowledgeBases.Where(item => !ReferenceEquals(item, exclude));

    /// <summary>Copies one resume / project / material into another knowledge base (independent copy).</summary>
    public void CopyEntryTo(KnowledgeEntryViewModel entry, KnowledgeBaseItemViewModel target)
    {
        var copy = KnowledgeEntryKinds.Clone(entry.Model);
        target.AddEntryModel(copy);
        if (copy.Kind == KnowledgeEntryKinds.Resume && SelectedKnowledgeBase is { } current)
            target.MergeSkills(current.Skills);
        SaveStatus = LocalizationManager.Instance.IsChinese ? $"已复制到「{target.Name}」" : $"Copied to “{target.Name}”";
    }

    private void Reload()
    {
        KnowledgeBases.Clear();
        foreach (var model in _store.Data.KnowledgeBases.OrderByDescending(item => item.UpdatedAt))
        {
            KnowledgeBases.Add(new KnowledgeBaseItemViewModel(model, _store));
        }
        SelectedKnowledgeBase = KnowledgeBases.FirstOrDefault();
        IsSelectionMode = false;
        KnowledgeBasesView.Refresh();
        NotifyCollectionState();
    }

    private void NewKnowledgeBase()
    {
        var model = new KnowledgeBaseModel { Name = "Untitled knowledge base", Description = "" };
        _store.Data.KnowledgeBases.Insert(0, model);
        _store.Data.Workspace.ActiveKnowledgeBaseIds.Add(model.Id);
        var item = new KnowledgeBaseItemViewModel(model, _store);
        KnowledgeBases.Insert(0, item);
        SelectedKnowledgeBase = item;
        _store.ScheduleSave();
        NotifyCollectionState();
    }

    private void DeleteKnowledgeBase(KnowledgeBaseItemViewModel knowledgeBase)
    {
        var index = KnowledgeBases.IndexOf(knowledgeBase);
        _store.Data.KnowledgeBases.Remove(knowledgeBase.Model);
        _store.Data.Workspace.ActiveKnowledgeBaseIds.Remove(knowledgeBase.Id);
        KnowledgeBases.Remove(knowledgeBase);
        SelectedKnowledgeBase = KnowledgeBases.Count == 0 ? null : KnowledgeBases[Math.Clamp(index, 0, KnowledgeBases.Count - 1)];
        _store.ScheduleSave();
        NotifyCollectionState();
    }

    public void AddManualEntry(string title, string content) =>
        SelectedKnowledgeBase?.AddEntry(title, content, "manual");

    private async Task ImportSourceAsync()
    {
        var value = SourceUrl.Trim();
        if (SelectedKnowledgeBase is null || value.Length == 0) return;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
        {
            SaveStatus = LocalizationManager.Instance.IsChinese ? "请输入有效的 HTTP 或 HTTPS 地址。" : "Enter a valid HTTP or HTTPS URL.";
            return;
        }
        if (GitHubProjectImporter.IsGitHubUrl(value))
        {
            // GitHub links belong in the Projects section.
            SourceUrl = "";
            SaveStatus = LocalizationManager.Instance.IsChinese ? "检测到 GitHub 链接，已添加到「项目」。" : "GitHub link detected — added to Projects.";
            await SelectedKnowledgeBase.ImportProjectsAsync(value);
            return;
        }
        IsImportingSource = true;
        SaveStatus = LocalizationManager.Instance.IsChinese ? "正在下载并解析网页正文…" : "Downloading and parsing the webpage…";
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.UserAgent.ParseAdd("Mozilla/5.0 InterviewAssistant/1.1");
            using var response = await WebClient.SendAsync(request);
            response.EnsureSuccessStatusCode();
            var html = await response.Content.ReadAsStringAsync();
            var title = ExtractHtmlTitle(html);
            if (string.IsNullOrWhiteSpace(title)) title = uri.Host;
            var content = ExtractReadableText(html);
            if (content.Length < 30) throw new InvalidDataException("The page did not contain readable text.");
            SelectedKnowledgeBase.AddEntry(title, content, value);
            SourceUrl = "";
            SaveStatus = LocalizationManager.Instance.IsChinese ? "网页正文已导入。" : "Webpage text imported.";
        }
        catch (Exception exception)
        {
            SaveStatus = (LocalizationManager.Instance.IsChinese ? "网页导入失败：" : "Web import failed: ") + exception.Message;
        }
        finally
        {
            IsImportingSource = false;
        }
    }

    private static string ExtractHtmlTitle(string html)
    {
        var match = Regex.Match(html, @"<title\b[^>]*>(.*?)</title>", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        return match.Success ? NormalizeHtmlText(match.Groups[1].Value) : "";
    }

    private static string ExtractReadableText(string html)
    {
        var text = Regex.Replace(html, @"<(script|style|noscript|svg|nav|footer|header)\b[^>]*>.*?</\1>", " ", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        text = Regex.Replace(text, @"<(br|p|div|li|h[1-6]|tr)\b[^>]*>", "\n", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"<[^>]+>", " ", RegexOptions.Singleline);
        text = NormalizeHtmlText(text);
        text = Regex.Replace(text, @"[ \t]+", " ");
        text = Regex.Replace(text, @"\s*\n\s*", "\n");
        text = Regex.Replace(text, @"\n{3,}", "\n\n").Trim();
        return text.Length > 60000 ? text[..60000] : text;
    }

    private static string NormalizeHtmlText(string value) => WebUtility.HtmlDecode(value).Replace('\u00A0', ' ').Trim();

    public void AddFile(string fileName, string content, string source) =>
        SelectedKnowledgeBase?.AddEntry(fileName, content, source);

    public void FocusKnowledgeBase(Guid? id)
    {
        IsSelectionMode = false;
        if (id is not null)
        {
            SelectedKnowledgeBase = KnowledgeBases.FirstOrDefault(item => item.Id == id) ?? KnowledgeBases.FirstOrDefault();
        }
        else
        {
            SelectedKnowledgeBase ??= KnowledgeBases.FirstOrDefault();
        }
    }

    private void ToggleSelectionMode()
    {
        if (IsEmpty && !IsSelectionMode) return;
        IsSelectionMode = !IsSelectionMode;
    }

    private void SelectAll()
    {
        if (!IsSelectionMode) return;
        var visible = KnowledgeBasesView.Cast<KnowledgeBaseItemViewModel>().ToList();
        var shouldSelect = visible.Any(item => !item.IsBulkSelected);
        foreach (var item in visible) item.IsBulkSelected = shouldSelect;
    }

    private void DeleteSelected()
    {
        var selected = KnowledgeBases.Where(item => item.IsBulkSelected).ToList();
        foreach (var item in selected) DeleteKnowledgeBase(item);
        if (IsEmpty) IsSelectionMode = false;
    }

    private void NotifyCollectionState()
    {
        OnPropertyChanged(nameof(IsEmpty));
        OnPropertyChanged(nameof(HasKnowledgeBases));
    }
}

/// <summary>
/// One knowledge base (usually one target role), organised as: resume, skills, GitHub projects,
/// other materials, and custom instructions. Every change is saved automatically.
/// </summary>
public sealed class KnowledgeBaseItemViewModel : ObservableObject
{
    public const int InstructionsLimit = 2000;
    private readonly AppDataStore _store;
    private bool _isBulkSelected;
    private KnowledgeEntryViewModel? _resume;
    private bool _isResumeBusy;
    private string _resumeStatus = "";
    private bool _isProjectBusy;
    private string _projectStatus = "";
    private string _projectUrl = "";
    private string _newSkill = "";
    private bool _isSkillsBusy;

    public KnowledgeBaseItemViewModel(KnowledgeBaseModel model, AppDataStore store)
    {
        Model = model;
        _store = store;
        // Classify entries saved by older versions once, so the sections stay stable.
        foreach (var entry in model.Entries.Where(entry => string.IsNullOrWhiteSpace(entry.Kind))) entry.Kind = KnowledgeEntryKinds.Of(entry);
        Projects = [];
        Materials = [];
        Skills = new ObservableCollection<string>(model.Skills);
        foreach (var entry in model.Entries) Attach(entry);
        ToggleActiveCommand = new RelayCommand(() => IsActive = !IsActive);
        AddSkillCommand = new RelayCommand(AddSkillFromInput);
        RemoveSkillCommand = new RelayCommand<string>(RemoveSkill);
    }

    public KnowledgeBaseModel Model { get; }
    public Guid Id => Model.Id;
    public ObservableCollection<KnowledgeEntryViewModel> Projects { get; }
    public ObservableCollection<KnowledgeEntryViewModel> Materials { get; }
    public ObservableCollection<string> Skills { get; }
    public ICommand ToggleActiveCommand { get; }
    public ICommand AddSkillCommand { get; }
    public ICommand RemoveSkillCommand { get; }

    public KnowledgeEntryViewModel? Resume
    {
        get => _resume;
        private set
        {
            if (!SetProperty(ref _resume, value)) return;
            OnPropertyChanged(nameof(HasResume));
            OnPropertyChanged(nameof(ResumeBadge));
            RefreshCounts();
        }
    }

    public bool HasResume => Resume is not null;
    public int EntryCount => Model.Entries.Count;
    public string UpdatedAtText => Model.UpdatedAt.ToString("d MMM yyyy");
    public bool IsBulkSelected { get => _isBulkSelected; set => SetProperty(ref _isBulkSelected, value); }
    public string ActiveStateText => LocalizationManager.Text(IsActive ? "Enabled" : "Off");

    // Section badges and the list-card summary.
    public string ResumeBadge => LocalizationManager.Text(HasResume ? "Uploaded" : "Not uploaded");
    public string SkillsBadge => Skills.Count.ToString();
    public string ProjectsBadge => Projects.Count.ToString();
    public string MaterialsBadge => Materials.Count.ToString();
    public string InstructionsCounter => $"{CustomInstructions.Length} / {InstructionsLimit}";
    public string CardSummaryText
    {
        get
        {
            var chinese = LocalizationManager.Instance.IsChinese;
            var parts = new List<string>();
            if (HasResume) parts.Add(chinese ? "简历 ✓" : "Resume ✓");
            if (Projects.Count > 0) parts.Add(chinese ? $"{Projects.Count} 个项目" : $"{Projects.Count} project{(Projects.Count == 1 ? "" : "s")}");
            if (Materials.Count > 0) parts.Add(chinese ? $"{Materials.Count} 份资料" : $"{Materials.Count} material{(Materials.Count == 1 ? "" : "s")}");
            if (Skills.Count > 0) parts.Add(chinese ? $"{Skills.Count} 项技能" : $"{Skills.Count} skill{(Skills.Count == 1 ? "" : "s")}");
            return parts.Count == 0 ? (chinese ? "空知识库" : "Empty") : string.Join(" · ", parts);
        }
    }

    public bool IsResumeBusy { get => _isResumeBusy; private set => SetProperty(ref _isResumeBusy, value); }
    public string ResumeStatus { get => _resumeStatus; private set => SetProperty(ref _resumeStatus, value); }
    public bool IsProjectBusy { get => _isProjectBusy; private set => SetProperty(ref _isProjectBusy, value); }
    public string ProjectStatus { get => _projectStatus; private set => SetProperty(ref _projectStatus, value); }
    public string ProjectUrl { get => _projectUrl; set => SetProperty(ref _projectUrl, value); }
    public string NewSkill { get => _newSkill; set => SetProperty(ref _newSkill, value); }
    public bool IsSkillsBusy { get => _isSkillsBusy; private set => SetProperty(ref _isSkillsBusy, value); }

    public string Name
    {
        get => Model.Name;
        set { if (Model.Name == value) return; Model.Name = value; Touch(); OnPropertyChanged(); }
    }

    public string Description
    {
        get => Model.Description;
        set { if (Model.Description == value) return; Model.Description = value; Touch(); OnPropertyChanged(); }
    }

    public string CustomInstructions
    {
        get => Model.CustomInstructions;
        set
        {
            value ??= "";
            if (value.Length > InstructionsLimit) value = value[..InstructionsLimit];
            if (Model.CustomInstructions == value) return;
            Model.CustomInstructions = value;
            Touch();
            OnPropertyChanged();
            OnPropertyChanged(nameof(InstructionsCounter));
        }
    }

    public bool IsActive
    {
        get => _store.Data.Workspace.ActiveKnowledgeBaseIds.Contains(Model.Id);
        set
        {
            if (IsActive == value) return;
            if (value) _store.Data.Workspace.ActiveKnowledgeBaseIds.Add(Model.Id);
            else _store.Data.Workspace.ActiveKnowledgeBaseIds.Remove(Model.Id);
            _store.ScheduleSave();
            OnPropertyChanged();
            OnPropertyChanged(nameof(ActiveStateText));
        }
    }

    public void RefreshLanguage()
    {
        OnPropertyChanged(nameof(ActiveStateText));
        OnPropertyChanged(nameof(ResumeBadge));
        RefreshCounts();
        foreach (var entry in Projects.Concat(Materials)) entry.RefreshLanguage();
        Resume?.RefreshLanguage();
    }

    // ───────────── resume ─────────────

    /// <summary>Upload flow: extract text → AI Markdown (original) → AI summary + skills.</summary>
    public async Task ImportResumeAsync(string path)
    {
        if (IsResumeBusy) return;
        IsResumeBusy = true;
        ResumeStatus = LocalizationManager.Text("Reading resume…");
        try
        {
            var raw = await DocumentTextImporter.ExtractTextAsync(path, 40_000);
            if (string.IsNullOrWhiteSpace(raw)) throw new InvalidOperationException(LocalizationManager.Text("No readable text was found in this file."));
            string markdown;
            ResumeStatus = LocalizationManager.Text("Converting resume to Markdown…");
            try { markdown = await KnowledgeAssistant.ResumeToMarkdownAsync(raw); }
            catch { markdown = raw; }
            if (markdown.Trim().Length < 40) markdown = raw;

            var entry = new KnowledgeEntryModel
            {
                Title = Path.GetFileNameWithoutExtension(path),
                Content = markdown,
                Source = $"resume:{Path.GetFileName(path)}",
                Kind = KnowledgeEntryKinds.Resume
            };
            SetResume(entry);
            await DigestResumeCoreAsync(mergeSkills: true);
        }
        catch (Exception exception)
        {
            ResumeStatus = (LocalizationManager.Instance.IsChinese ? "简历导入失败：" : "Resume import failed: ") + exception.Message;
        }
        finally
        {
            IsResumeBusy = false;
        }
    }

    /// <summary>After the Markdown original is edited: regenerate the summary (skills are left as the user set them).</summary>
    public async Task UpdateResumeOriginalAsync(string title, string markdown)
    {
        if (Resume is null) return;
        Resume.Title = string.IsNullOrWhiteSpace(title) ? Resume.Title : title.Trim();
        Resume.Content = markdown;
        if (IsResumeBusy) return;
        IsResumeBusy = true;
        try { await DigestResumeCoreAsync(mergeSkills: false); }
        finally { IsResumeBusy = false; }
    }

    public async Task RegenerateResumeSummaryAsync()
    {
        if (Resume is null || IsResumeBusy) return;
        IsResumeBusy = true;
        try { await DigestResumeCoreAsync(mergeSkills: false); }
        finally { IsResumeBusy = false; }
    }

    /// <summary>"Extract from resume" in the skills section: adds skills not already listed.</summary>
    public async Task ExtractSkillsFromResumeAsync()
    {
        if (Resume is null || IsSkillsBusy) return;
        IsSkillsBusy = true;
        ResumeStatus = LocalizationManager.Text("Extracting skills from the resume…");
        try
        {
            var digest = await KnowledgeAssistant.DigestResumeAsync(Resume.Content);
            var added = MergeSkills(digest.Skills);
            ResumeStatus = string.Format(LocalizationManager.Text("{0} new skills added."), added);
        }
        catch (Exception exception)
        {
            ResumeStatus = (LocalizationManager.Instance.IsChinese ? "技能提取失败：" : "Skill extraction failed: ") + exception.Message;
        }
        finally
        {
            IsSkillsBusy = false;
        }
    }

    private async Task DigestResumeCoreAsync(bool mergeSkills)
    {
        if (Resume is null) return;
        ResumeStatus = LocalizationManager.Text("Generating AI summary…");
        try
        {
            var digest = await KnowledgeAssistant.DigestResumeAsync(Resume.Content);
            Resume.Summary = digest.Summary;
            var added = mergeSkills ? MergeSkills(digest.Skills) : 0;
            ResumeStatus = mergeSkills && added > 0
                ? string.Format(LocalizationManager.Text("Resume processed. {0} skills extracted."), added)
                : LocalizationManager.Text("AI summary updated.");
        }
        catch (Exception exception)
        {
            ResumeStatus = (LocalizationManager.Instance.IsChinese ? "AI 摘要生成失败（原文已保存，可稍后重新生成）：" : "AI summary failed (the original is saved; regenerate later): ") + exception.Message;
        }
    }

    public void SetResume(KnowledgeEntryModel entry)
    {
        entry.Kind = KnowledgeEntryKinds.Resume;
        var previous = Model.Entries.FirstOrDefault(item => KnowledgeEntryKinds.Of(item) == KnowledgeEntryKinds.Resume);
        if (previous is not null) Model.Entries.Remove(previous);
        Model.Entries.Add(entry);
        Resume = CreateEntryViewModel(entry);
        Touch();
    }

    public void DeleteResume()
    {
        if (Resume is null) return;
        RemoveEntry(Resume.Model);
        ResumeStatus = "";
    }

    // ───────────── skills ─────────────

    private void AddSkillFromInput()
    {
        var parts = NewSkill.Split([',', '，', '、', ';', '；', '\n'], StringSplitOptions.RemoveEmptyEntries);
        MergeSkills(parts);
        NewSkill = "";
    }

    private void RemoveSkill(string skill)
    {
        if (!Skills.Remove(skill)) return;
        Model.Skills.Remove(skill);
        Touch();
        RefreshCounts();
    }

    public int MergeSkills(IEnumerable<string> skills)
    {
        var added = 0;
        foreach (var skill in KnowledgeAssistant.NormalizeSkills(skills))
        {
            if (Skills.Any(existing => existing.Equals(skill, StringComparison.OrdinalIgnoreCase))) continue;
            Skills.Add(skill);
            Model.Skills.Add(skill);
            added++;
        }
        if (added > 0) { Touch(); RefreshCounts(); }
        return added;
    }

    // ───────────── projects ─────────────

    /// <summary>Adds a repository (or a profile's recent repositories) with an AI one-line summary each.</summary>
    public async Task ImportProjectsAsync(string? url = null)
    {
        url = (url ?? ProjectUrl).Trim();
        if (url.Length == 0 || IsProjectBusy) return;
        if (!GitHubProjectImporter.IsGitHubUrl(url))
        {
            ProjectStatus = LocalizationManager.Text("Enter a valid GitHub link.");
            return;
        }
        IsProjectBusy = true;
        ProjectStatus = LocalizationManager.Text("Reading the repository from GitHub…");
        try
        {
            var projects = await GitHubProjectImporter.FetchAsync(url);
            var added = new List<KnowledgeEntryViewModel>();
            foreach (var project in projects)
            {
                if (Model.Entries.Any(entry => entry.Source.TrimEnd('/').Equals(project.Url.TrimEnd('/'), StringComparison.OrdinalIgnoreCase))) continue;
                var entry = new KnowledgeEntryModel
                {
                    Title = project.Name,
                    Source = project.Url,
                    Kind = KnowledgeEntryKinds.Project,
                    Content = GitHubProjectImporter.BuildContent(project),
                    Meta = GitHubProjectImporter.BuildMeta(project),
                    Summary = project.Description
                };
                added.Add(AddEntryModel(entry));
            }
            ProjectUrl = "";
            if (added.Count == 0)
            {
                ProjectStatus = LocalizationManager.Text("These projects are already in this knowledge base.");
                return;
            }
            ProjectStatus = LocalizationManager.Text("Generating project summaries…");
            foreach (var project in added)
            {
                try
                {
                    var readme = project.Content;
                    var summary = await KnowledgeAssistant.SummarizeProjectAsync(project.Title, readme, project.Summary);
                    if (summary.Length > 0) project.Summary = summary;
                }
                catch { /* keep the GitHub description as the summary */ }
            }
            ProjectStatus = string.Format(LocalizationManager.Text("{0} projects added."), added.Count);
        }
        catch (Exception exception)
        {
            ProjectStatus = (LocalizationManager.Instance.IsChinese ? "项目导入失败：" : "Project import failed: ") + exception.Message;
        }
        finally
        {
            IsProjectBusy = false;
        }
    }

    // ───────────── generic entries ─────────────

    public KnowledgeEntryViewModel AddEntry(string title, string content, string source, string kind = KnowledgeEntryKinds.Material) =>
        AddEntryModel(new KnowledgeEntryModel { Title = title, Content = content, Source = source, Kind = kind });

    /// <summary>Adds an entry model (also used for copies from other knowledge bases).</summary>
    public KnowledgeEntryViewModel AddEntryModel(KnowledgeEntryModel entry)
    {
        if (KnowledgeEntryKinds.Of(entry) == KnowledgeEntryKinds.Resume)
        {
            SetResume(entry);
            return Resume!;
        }
        Model.Entries.Add(entry);
        var viewModel = Attach(entry)!;
        Touch();
        return viewModel;
    }

    private KnowledgeEntryViewModel? Attach(KnowledgeEntryModel entry)
    {
        var viewModel = CreateEntryViewModel(entry);
        switch (KnowledgeEntryKinds.Of(entry))
        {
            case KnowledgeEntryKinds.Resume:
                if (Resume is null) Resume = viewModel;
                break;
            case KnowledgeEntryKinds.Project:
                Projects.Add(viewModel);
                break;
            default:
                Materials.Add(viewModel);
                break;
        }
        RefreshCounts();
        return viewModel;
    }

    private KnowledgeEntryViewModel CreateEntryViewModel(KnowledgeEntryModel entry) =>
        new(entry, Touch, () => RemoveEntry(entry));

    public void RemoveEntry(KnowledgeEntryModel entry)
    {
        Model.Entries.Remove(entry);
        if (Resume?.Model == entry) Resume = null;
        var project = Projects.FirstOrDefault(item => item.Model == entry);
        if (project is not null) Projects.Remove(project);
        var material = Materials.FirstOrDefault(item => item.Model == entry);
        if (material is not null) Materials.Remove(material);
        Touch();
        RefreshCounts();
    }

    private void RefreshCounts()
    {
        OnPropertyChanged(nameof(EntryCount));
        OnPropertyChanged(nameof(SkillsBadge));
        OnPropertyChanged(nameof(ProjectsBadge));
        OnPropertyChanged(nameof(MaterialsBadge));
        OnPropertyChanged(nameof(CardSummaryText));
        OnPropertyChanged(nameof(ResumeBadge));
    }

    private void Touch()
    {
        Model.UpdatedAt = DateTimeOffset.Now;
        _store.ScheduleSave();
        OnPropertyChanged(nameof(UpdatedAtText));
    }
}

public sealed class KnowledgeEntryViewModel(KnowledgeEntryModel model, Action onChanged, Action onDelete) : ObservableObject
{
    public KnowledgeEntryModel Model => model;
    public Guid Id => model.Id;
    public string Kind => KnowledgeEntryKinds.Of(model);
    public string Source => model.Source;
    public string Meta => model.Meta;
    public bool HasMeta => model.Meta.Length > 0;

    public string SourceLabel => model.Source switch
    {
        "manual" => LocalizationManager.Text("Note"),
        var source when source.StartsWith("pdf:", StringComparison.OrdinalIgnoreCase) => LocalizationManager.Text("PDF source"),
        var source when source.StartsWith("file:", StringComparison.OrdinalIgnoreCase) => Path.GetFileName(source[5..]),
        var source when source.StartsWith("resume:", StringComparison.OrdinalIgnoreCase) => source[7..],
        _ => model.Source
    };

    /// <summary>Segoe Fluent glyph for the material type.</summary>
    public string TypeGlyph => model.Source switch
    {
        "manual" => "",
        var source when source.StartsWith("pdf:", StringComparison.OrdinalIgnoreCase) => "",
        var source when source.StartsWith("http", StringComparison.OrdinalIgnoreCase) => "",
        _ => ""
    };

    /// <summary>Copied original PDF ("pdf:&lt;path&gt;", same convention as macOS), when available.</summary>
    public string? PdfPath => model.Source.StartsWith("pdf:", StringComparison.OrdinalIgnoreCase) ? model.Source[4..] : null;
    public string? Url => model.Source.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? model.Source : null;

    public string ContentPreview
    {
        get
        {
            var value = model.Content.Trim();
            return value.Length <= 420 ? value : value[..420].TrimEnd() + "…";
        }
    }

    public bool HasSummary => model.Summary.Trim().Length > 0;
    /// <summary>What the card shows: the AI summary when there is one, otherwise the beginning of the text.</summary>
    public string DisplayText => HasSummary ? model.Summary.Trim() : ContentPreview;

    public ICommand DeleteCommand { get; } = new RelayCommand(onDelete);

    public void RefreshLanguage() => OnPropertyChanged(nameof(SourceLabel));

    public string Title
    {
        get => model.Title;
        set
        {
            if (model.Title == value) return;
            model.Title = value;
            Changed();
            OnPropertyChanged();
        }
    }

    public string Content
    {
        get => model.Content;
        set
        {
            if (model.Content == value) return;
            model.Content = value;
            Changed();
            OnPropertyChanged();
            OnPropertyChanged(nameof(ContentPreview));
            OnPropertyChanged(nameof(DisplayText));
        }
    }

    public string Summary
    {
        get => model.Summary;
        set
        {
            if (model.Summary == value) return;
            model.Summary = value ?? "";
            Changed();
            OnPropertyChanged();
            OnPropertyChanged(nameof(HasSummary));
            OnPropertyChanged(nameof(DisplayText));
        }
    }

    public bool IsEnabled
    {
        get => model.IsEnabled;
        set
        {
            if (model.IsEnabled == value) return;
            model.IsEnabled = value;
            onChanged();
            OnPropertyChanged();
        }
    }

    private void Changed()
    {
        model.UpdatedAt = DateTimeOffset.Now;
        onChanged();
    }
}
