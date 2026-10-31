using System.Collections.ObjectModel;
using InterviewAssistant.Infrastructure;
using InterviewAssistant.Models;
using InterviewAssistant.Services;
using System.Windows.Input;

namespace InterviewAssistant.ViewModels;

public sealed class HistoryViewModel : PageViewModel
{
    private InterviewHistoryItem? _selectedSession;
    private string _searchText = "";
    private string _selectedKind = "formal";
    private bool _isSelectionMode;

    public HistoryViewModel() : base("History", "Review formal and mock interview sessions stored on this device.")
    {
        SetKindCommand = new RelayCommand<string>(kind => SelectedKind = kind);
        ToggleSelectionModeCommand = new RelayCommand(() => IsSelectionMode = !IsSelectionMode);
        SelectAllCommand = new RelayCommand(SelectAll);
        DeleteSelectedCommand = new RelayCommand(DeleteSelected);
        LocalizationManager.Instance.LanguageChanged += () =>
        {
            OnPropertyChanged(nameof(SelectionButtonText));
            Refresh();
        };
        AppServices.Current.DataStore.DataReset += Refresh;
        Refresh();
    }

    public ObservableCollection<InterviewHistoryItem> Sessions { get; } = [];
    public bool IsEmpty => Sessions.Count == 0;
    public ICommand SetKindCommand { get; }
    public ICommand ToggleSelectionModeCommand { get; }
    public ICommand SelectAllCommand { get; }
    public ICommand DeleteSelectedCommand { get; }
    public string SearchText { get => _searchText; set { if (SetProperty(ref _searchText, value)) Refresh(); } }
    public string SelectedKind { get => _selectedKind; set { if (SetProperty(ref _selectedKind, value)) Refresh(); } }
    public bool IsSelectionMode
    {
        get => _isSelectionMode;
        private set
        {
            if (!SetProperty(ref _isSelectionMode, value)) return;
            OnPropertyChanged(nameof(SelectionButtonText));
            if (!value) foreach (var item in Sessions) item.IsBulkSelected = false;
        }
    }
    public string SelectionButtonText => LocalizationManager.Text(IsSelectionMode ? "Cancel" : "Select");

    public InterviewHistoryItem? SelectedSession
    {
        get => _selectedSession;
        set => SetProperty(ref _selectedSession, value);
    }

    public void Refresh()
    {
        var selectedId = SelectedSession?.Id;
        Sessions.Clear();
        foreach (var session in AppServices.Current.DataStore.Data.Sessions
                     .Where(item => item.Kind == SelectedKind)
                     .Where(item => string.IsNullOrWhiteSpace(SearchText) || item.Role.Contains(SearchText, StringComparison.OrdinalIgnoreCase) || item.Title.Contains(SearchText, StringComparison.OrdinalIgnoreCase))
                     .OrderByDescending(item => item.StartedAt))
        {
            Sessions.Add(new InterviewHistoryItem(session));
        }
        SelectedSession = Sessions.FirstOrDefault(item => item.Id == selectedId) ?? Sessions.FirstOrDefault();
        OnPropertyChanged(nameof(IsEmpty));
    }

    private void DeleteSelected()
    {
        var selectedIds = Sessions.Where(item => item.IsBulkSelected).Select(item => item.Id).ToHashSet();
        if (selectedIds.Count == 0) return;
        AppServices.Current.DataStore.Data.Sessions.RemoveAll(item => selectedIds.Contains(item.Id));
        AppServices.Current.DataStore.ScheduleSave();
        IsSelectionMode = false;
        Refresh();
    }

    private void SelectAll()
    {
        if (!IsSelectionMode) return;
        var shouldSelect = Sessions.Any(item => !item.IsBulkSelected);
        foreach (var item in Sessions) item.IsBulkSelected = shouldSelect;
    }
}

public sealed class InterviewHistoryItem(InterviewSessionModel model) : ObservableObject
{
    private bool _isBulkSelected;
    private IReadOnlyList<HistoryTurnItem>? _turns;
    public InterviewSessionModel Model => model;
    public Guid Id => model.Id;
    public string Role => string.IsNullOrWhiteSpace(model.Role) ? model.Title : model.Role;

    /// <summary>Editable conversation title (macOS "Conversation title"); falls back to the role.</summary>
    public string Title
    {
        get => model.Title;
        set
        {
            if (model.Title == value) return;
            model.Title = value;
            model.UpdatedAt = DateTimeOffset.Now;
            AppServices.Current.DataStore.ScheduleSave();
            OnPropertyChanged();
            OnPropertyChanged(nameof(DisplayTitle));
        }
    }

    public string DisplayTitle => !string.IsNullOrWhiteSpace(model.Title) ? model.Title.Trim() : Role;
    public string StartedAtText => model.StartedAt.LocalDateTime.ToString("g");
    public int QuestionCount => model.Turns.Count;
    public string QuestionCountText => LocalizationManager.Instance.IsChinese
        ? $"{QuestionCount} 个问题"
        : $"{QuestionCount} {(QuestionCount == 1 ? "question" : "questions")}";
    public string Kind => LocalizationManager.Text(model.Kind == "mock" ? "Mock Interview" : "Formal Interview");
    public bool IsMock => model.Kind == "mock";
    public string ScoreText => $"{model.OverallScore}/100";
    public string StrengthsText => model.StrengthsText;
    public string ImprovementsText => model.ImprovementsText;
    public string Summary => string.IsNullOrWhiteSpace(model.SummaryFeedback) ? LocalizationManager.Text("No summary yet") : model.SummaryFeedback;
    public IReadOnlyList<HistoryTurnItem> Turns => _turns ??= model.Turns.OrderBy(turn => turn.CreatedAt).Select(turn => new HistoryTurnItem(turn)).ToList();
    public bool IsBulkSelected { get => _isBulkSelected; set => SetProperty(ref _isBulkSelected, value); }
}

public sealed class HistoryTurnItem(ConversationTurnModel model)
{
    private System.Windows.Media.ImageSource? _thumbnail;
    private bool _thumbnailLoaded;
    public ConversationTurnModel Model => model;
    public string Question => model.Question;
    public string Answer => model.Answer;
    public int Score => model.Score;
    public string Feedback => model.Feedback;
    public string SuggestedAnswer => model.SuggestedAnswer;
    public string Category => model.Category;
    public string? ScreenshotPath => !string.IsNullOrWhiteSpace(model.ScreenshotPath) && System.IO.File.Exists(model.ScreenshotPath) ? model.ScreenshotPath : null;
    public bool HasScreenshot => ScreenshotPath is not null;

    /// <summary>Downscaled, file-unlocked thumbnail of the captured screenshot.</summary>
    public System.Windows.Media.ImageSource? Thumbnail
    {
        get
        {
            if (_thumbnailLoaded) return _thumbnail;
            _thumbnailLoaded = true;
            if (ScreenshotPath is null) return null;
            try
            {
                var image = new System.Windows.Media.Imaging.BitmapImage();
                image.BeginInit();
                image.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
                image.DecodePixelWidth = 720;
                image.UriSource = new Uri(ScreenshotPath);
                image.EndInit();
                image.Freeze();
                _thumbnail = image;
            }
            catch { _thumbnail = null; }
            return _thumbnail;
        }
    }
}
