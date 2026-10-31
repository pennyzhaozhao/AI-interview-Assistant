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
        SaveKnowledgeBaseCommand = new AsyncRelayCommand(SaveKnowledgeBaseAsync, () => SelectedKnowledgeBase is not null);
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
    public ICommand SaveKnowledgeBaseCommand { get; }
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
            (SaveKnowledgeBaseCommand as AsyncRelayCommand)?.NotifyCanExecuteChanged();
            SaveStatus = "";
        }
    }

    private async Task SaveKnowledgeBaseAsync()
    {
        if (SelectedKnowledgeBase is null) return;
        SaveStatus = LocalizationManager.Text("Saving…");
        await _store.SaveAsync();
        SaveStatus = LocalizationManager.Text("Saved");
        await Task.Delay(1400);
        if (SaveStatus == LocalizationManager.Text("Saved")) SaveStatus = "";
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
            await _store.SaveAsync();
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

public sealed class KnowledgeBaseItemViewModel : ObservableObject
{
    private readonly AppDataStore _store;
    private bool _isBulkSelected;

    public KnowledgeBaseItemViewModel(KnowledgeBaseModel model, AppDataStore store)
    {
        Model = model;
        _store = store;
        Entries = new ObservableCollection<KnowledgeEntryViewModel>(model.Entries.Select(CreateEntryViewModel));
        ToggleActiveCommand = new RelayCommand(() => IsActive = !IsActive);
    }

    public KnowledgeBaseModel Model { get; }
    public Guid Id => Model.Id;
    public ObservableCollection<KnowledgeEntryViewModel> Entries { get; }
    public int EntryCount => Entries.Count;
    public string UpdatedAtText => Model.UpdatedAt.ToString("d MMM yyyy");
    public string EntryCountText => LocalizationManager.Instance.IsChinese
        ? $"{EntryCount} 个文件"
        : $"{EntryCount} {(EntryCount == 1 ? "file" : "files")}";
    public string EnabledEntryCountText => LocalizationManager.Instance.IsChinese
        ? $"已启用 {Entries.Count(item => item.IsEnabled)}/{EntryCount}"
        : $"{Entries.Count(item => item.IsEnabled)}/{EntryCount} enabled";
    public ICommand ToggleActiveCommand { get; }
    public bool IsBulkSelected { get => _isBulkSelected; set => SetProperty(ref _isBulkSelected, value); }
    public string ActiveStateText => LocalizationManager.Text(IsActive ? "Enabled" : "Off");
    public void RefreshLanguage()
    {
        OnPropertyChanged(nameof(ActiveStateText));
        OnPropertyChanged(nameof(EntryCountText));
        OnPropertyChanged(nameof(EnabledEntryCountText));
    }

    public string Name
    {
        get => Model.Name;
        set
        {
            if (Model.Name == value) return;
            Model.Name = value;
            Touch();
            OnPropertyChanged();
        }
    }

    public string Description
    {
        get => Model.Description;
        set
        {
            if (Model.Description == value) return;
            Model.Description = value;
            Touch();
            OnPropertyChanged();
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

    public void AddEntry()
    {
        AddEntry("Main Content", "", "manual");
    }

    public void AddEntry(string title, string content, string source)
    {
        var model = new KnowledgeEntryModel { Title = title, Content = content, Source = source };
        Model.Entries.Add(model);
        Entries.Add(CreateEntryViewModel(model));
        Touch();
        OnPropertyChanged(nameof(EntryCount));
        OnPropertyChanged(nameof(EntryCountText));
        OnPropertyChanged(nameof(EnabledEntryCountText));
    }

    private KnowledgeEntryViewModel CreateEntryViewModel(KnowledgeEntryModel entry) =>
        new(entry, () => { Touch(); OnPropertyChanged(nameof(EnabledEntryCountText)); }, () => RemoveEntry(entry));

    private void RemoveEntry(KnowledgeEntryModel entry)
    {
        Model.Entries.Remove(entry);
        var viewModel = Entries.FirstOrDefault(item => item.Id == entry.Id);
        if (viewModel is not null) Entries.Remove(viewModel);
        Touch();
        OnPropertyChanged(nameof(EntryCount));
        OnPropertyChanged(nameof(EntryCountText));
        OnPropertyChanged(nameof(EnabledEntryCountText));
    }

    private void Touch()
    {
        Model.UpdatedAt = DateTimeOffset.Now;
        _store.ScheduleSave();
    }
}

public sealed class KnowledgeEntryViewModel(KnowledgeEntryModel model, Action onChanged, Action onDelete) : ObservableObject
{
    public Guid Id => model.Id;
    public string SourceLabel => model.Source == "manual" ? "Manual source" : model.Source;
    public string ContentPreview
    {
        get
        {
            var value = model.Content.Trim();
            return value.Length <= 420 ? value : value[..420].TrimEnd() + "…";
        }
    }
    public ICommand DeleteCommand { get; } = new RelayCommand(onDelete);

    public string Title
    {
        get => model.Title;
        set
        {
            if (model.Title == value) return;
            model.Title = value;
            model.UpdatedAt = DateTimeOffset.Now;
            onChanged();
            OnPropertyChanged();
            OnPropertyChanged(nameof(ContentPreview));
        }
    }

    public string Content
    {
        get => model.Content;
        set
        {
            if (model.Content == value) return;
            model.Content = value;
            model.UpdatedAt = DateTimeOffset.Now;
            onChanged();
            OnPropertyChanged();
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
}
