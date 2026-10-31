using System.Collections.ObjectModel;
using System.Windows.Input;
using InterviewAssistant.Infrastructure;
using InterviewAssistant.Models;
using InterviewAssistant.Services;

namespace InterviewAssistant.ViewModels;

public sealed class MainViewModel : ObservableObject
{
    private NavigationItemViewModel? _selectedItem;
    private PageViewModel? _currentPage;
    private bool _isSidebarCollapsed;
    private readonly HistoryViewModel _history;
    private readonly HomeViewModel _home;

    public MainViewModel()
    {
        var home = new HomeViewModel();
        _home = home;
        var history = new HistoryViewModel();
        _history = history;
        var knowledge = new KnowledgeViewModel();
        home.InterviewStarted += session =>
        {
            history.Refresh();
            InterviewStarted?.Invoke(session);
        };
        home.MockInterviewRequested += config => MockInterviewRequested?.Invoke(config);
        home.MockInterviewOptionsRequested += () => MockInterviewOptionsRequested?.Invoke();
        NavigationItems =
        [
            new("Interview", "\uE734", home),
            new("Director Mode", "\uE716", new DirectorViewModel()),
            new("Knowledge Base", "\uE8B7", knowledge),
            new("History", "\uE81C", history),
            new("Settings", "\uE713", new SettingsViewModel())
        ];

        home.KnowledgeSelectionRequested += () =>
        {
            SelectedItem = NavigationItems.First(item => ReferenceEquals(item.Page, knowledge));
            knowledge.FocusKnowledgeBase(home.PreferredKnowledgeBaseId);
        };
        LocalizationManager.Instance.LanguageChanged += () =>
        {
            foreach (var item in NavigationItems) item.RefreshLanguage();
        };

        NavigateCommand = new RelayCommand<NavigationItemViewModel>(Navigate);
        ToggleSidebarCommand = new RelayCommand(() => IsSidebarCollapsed = !IsSidebarCollapsed);
        SelectedItem = NavigationItems[0];
    }

    public ObservableCollection<NavigationItemViewModel> NavigationItems { get; }
    public ICommand NavigateCommand { get; }
    public ICommand ToggleSidebarCommand { get; }
    public event Action<InterviewSessionModel>? InterviewStarted;
    public event Action<MockInterviewLaunchConfig>? MockInterviewRequested;
    public event Action? MockInterviewOptionsRequested;
    public void StartMockInterview(int questionCount) => _home.PrepareMockInterview(questionCount);
    public void RefreshHistory() => _history.Refresh();

    public NavigationItemViewModel? SelectedItem
    {
        get => _selectedItem;
        private set
        {
            if (!SetProperty(ref _selectedItem, value)) return;
            CurrentPage = value?.Page;
            foreach (var item in NavigationItems)
            {
                item.IsSelected = ReferenceEquals(item, value);
            }
        }
    }

    public PageViewModel? CurrentPage
    {
        get => _currentPage;
        private set => SetProperty(ref _currentPage, value);
    }

    public bool IsSidebarCollapsed
    {
        get => _isSidebarCollapsed;
        set
        {
            if (SetProperty(ref _isSidebarCollapsed, value))
            {
                OnPropertyChanged(nameof(SidebarWidth));
                OnPropertyChanged(nameof(BrandVisibility));
            }
        }
    }

    public double SidebarWidth => IsSidebarCollapsed ? 76 : 280;
    public System.Windows.Visibility BrandVisibility => IsSidebarCollapsed
        ? System.Windows.Visibility.Collapsed
        : System.Windows.Visibility.Visible;

    private void Navigate(NavigationItemViewModel item) => SelectedItem = item;

    public void NavigateTo(string? title)
    {
        var item = NavigationItems.FirstOrDefault(candidate =>
            string.Equals(candidate.Title, title, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(candidate.Key, title, StringComparison.OrdinalIgnoreCase));
        if (item is not null) SelectedItem = item;
    }
}

public sealed class NavigationItemViewModel(string title, string icon, PageViewModel page) : ObservableObject
{
    private bool _isSelected;

    public string Key { get; } = title;
    public string Title => LocalizationManager.Text(Key);
    public string Icon { get; } = icon;
    public PageViewModel Page { get; } = page;

    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }

    public void RefreshLanguage() => OnPropertyChanged(nameof(Title));
}
