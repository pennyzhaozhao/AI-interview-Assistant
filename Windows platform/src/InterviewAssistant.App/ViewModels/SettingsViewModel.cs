using System.Collections.ObjectModel;
using System.Net.WebSockets;
using System.Speech.Recognition;
using System.Windows.Input;
using InterviewAssistant.Infrastructure;
using InterviewAssistant.Models;
using InterviewAssistant.Services;

namespace InterviewAssistant.ViewModels;

public sealed class SettingsViewModel : PageViewModel
{
    private readonly AppDataStore _store = AppServices.Current.DataStore;
    private readonly WindowsCredentialStore _credentials = AppServices.Current.Credentials;
    private ProviderDefinition _selectedProvider = ProviderCatalog.Get(AIProvider.DeepSeek);
    private string _selectedModel = "";
    private string _apiUrl = "";
    private string _apiKey = "";
    private bool _hidePrompterFromCapture = true;
    private bool _hideTaskbarIconDuringInterview;
    private string _language = "English";
    private string _theme = "Dark";
    private string _mockInterviewLanguageCode = "followApp";
    private string _interviewerLanguageCode = "followApp";
    private bool _refreshingSpeechLanguages;
    private string _screenshotMode = "Preset region";
    private string _screenshotHotkey = "Ctrl+Shift+S";
    private string _speechRecognitionEngine = "";
    private string _speechAppId = "";
    private string _speechAccessToken = "";
    private string _speechResourceId = "volc.seedasr.sauc.duration";
    private string _speechStatus = "";
    private bool _isTesting;
    private bool _isTestingSpeech;
    private string _status = "";
    private StatusKind _statusKind;
    private StatusKind _speechStatusKind;

    public SettingsViewModel() : base("Settings", "Configure AI, speech, privacy and appearance.")
    {
        Providers = new ObservableCollection<ProviderDefinition>(ProviderCatalog.All);
        Models = [];
        SpeechRecognitionEngines = [];
        SaveCommand = new AsyncRelayCommand(SaveAsync);
        TestConnectionCommand = new AsyncRelayCommand(TestConnectionAsync, () => !IsTesting);
        TestSpeechConnectionCommand = new AsyncRelayCommand(TestSpeechConnectionAsync, () => !IsTestingSpeech);
        SaveSpeechCommand = new AsyncRelayCommand(SaveSpeechAsync);

        if (Enum.TryParse<AIProvider>(_store.Data.Preferences.Provider, out var provider))
        {
            _selectedProvider = ProviderCatalog.Get(provider);
        }
        LoadSelectedProvider();
        _hidePrompterFromCapture = _store.Data.Preferences.HidePrompterFromCapture;
        _hideTaskbarIconDuringInterview = _store.Data.Preferences.HideTaskbarIconDuringInterview;
        _language = DecodeLanguage(_store.Data.Preferences.Language);
        _theme = DecodeTheme(_store.Data.Preferences.Theme);
        _mockInterviewLanguageCode = NormalizeSpeechLanguage(_store.Data.Preferences.MockInterviewLanguage);
        _interviewerLanguageCode = NormalizeSpeechLanguage(_store.Data.Preferences.InterviewerLanguage);
        RefreshSpeechLanguages();
        _screenshotMode = DecodeScreenshotMode(_store.Data.Preferences.ScreenshotMode);
        _screenshotHotkey = _store.Data.Preferences.ScreenshotHotkey;
        RefreshSpeechRecognitionEngines(_store.Data.Preferences.SpeechRecognitionEngine);
        _speechResourceId = _store.Data.Preferences.SpeechResourceId;
        _speechAppId = _credentials.Read("speech-app-id");
        _speechAccessToken = _credentials.Read("speech-access-token");
        LocalizationManager.Instance.LanguageChanged += () =>
        {
            OnPropertyChanged(nameof(ScreenshotRegionStatus));
            OnPropertyChanged(nameof(ScreenshotRegionActionText));
            OnPropertyChanged(nameof(ScreenshotPermissionStatus));
            var engine = SpeechRecognitionEngineId;
            RefreshSpeechRecognitionEngines(engine);
            RefreshSpeechLanguages();
        };
    }

    public ObservableCollection<ProviderDefinition> Providers { get; }
    public ObservableCollection<string> Models { get; }
    public ICommand SaveCommand { get; }
    public ICommand TestConnectionCommand { get; }
    public ICommand TestSpeechConnectionCommand { get; }
    public ICommand SaveSpeechCommand { get; }
    public IReadOnlyList<string> Languages { get; } = ["English", "简体中文"];
    public IReadOnlyList<string> Themes { get; } = ["Dark", "Light"];
    /// <summary>Display names, localized like the macOS MockInterviewLanguage titles. Order matches SpeechLanguageCodes.</summary>
    public ObservableCollection<string> SpeechLanguages { get; } = [];
    private static readonly string[] SpeechLanguageCodes = ["followApp", "zh-Hans", "en"];
    public IReadOnlyList<string> ScreenshotModes { get; } = ["Preset region", "Select region each time"];
    public ObservableCollection<string> SpeechRecognitionEngines { get; }
    public IReadOnlyList<string> SpeechResourceIds { get; } =
    [
        "volc.seedasr.sauc.duration",
        "volc.seedasr.sauc.concurrent",
        "volc.bigasr.sauc.duration"
    ];
    public string DataDirectory => _store.DataDirectory;

    public async Task ChangeDataDirectoryAsync(string directory)
    {
        await _store.ChangeDataDirectoryAsync(directory);
        OnPropertyChanged(nameof(DataDirectory));
        Status = "Data copied. The new storage location is active.";
    }

    public string Language
    {
        get => _language;
        set
        {
            if (!SetProperty(ref _language, value)) return;
            var storedValue = value == "简体中文" ? "zh-Hans" : "en";
            SavePreference(p => p.Language = storedValue);
            LocalizationManager.Apply(storedValue);
        }
    }

    public string Theme
    {
        get => _theme;
        set
        {
            if (!SetProperty(ref _theme, value)) return;
            var storedValue = value.ToLowerInvariant();
            SavePreference(p => p.Theme = storedValue);
            ThemeManager.Apply(storedValue, animate: true);
        }
    }

    public string MockInterviewLanguage
    {
        get => SpeechLanguageName(_mockInterviewLanguageCode);
        set
        {
            var code = SpeechLanguageCode(value);
            if (code is null || code == _mockInterviewLanguageCode) return;
            _mockInterviewLanguageCode = code;
            OnPropertyChanged();
            SavePreference(p => p.MockInterviewLanguage = code);
        }
    }

    public string InterviewerLanguage
    {
        get => SpeechLanguageName(_interviewerLanguageCode);
        set
        {
            var code = SpeechLanguageCode(value);
            if (code is null || code == _interviewerLanguageCode) return;
            _interviewerLanguageCode = code;
            OnPropertyChanged();
            SavePreference(p => p.InterviewerLanguage = code);
        }
    }

    private void RefreshSpeechLanguages()
    {
        _refreshingSpeechLanguages = true;
        var chinese = LocalizationManager.Instance.IsChinese;
        string[] names = chinese ? ["跟随 App 语言", "中文", "English"] : ["Follow App Language", "Chinese", "English"];
        if (!SpeechLanguages.SequenceEqual(names))
        {
            SpeechLanguages.Clear();
            foreach (var name in names) SpeechLanguages.Add(name);
        }
        _refreshingSpeechLanguages = false;
        OnPropertyChanged(nameof(MockInterviewLanguage));
        OnPropertyChanged(nameof(InterviewerLanguage));
    }

    private string SpeechLanguageName(string code)
    {
        var index = Array.IndexOf(SpeechLanguageCodes, code);
        return index >= 0 && index < SpeechLanguages.Count ? SpeechLanguages[index] : SpeechLanguages.FirstOrDefault() ?? "";
    }

    private string? SpeechLanguageCode(string? name)
    {
        // While the list is being rebuilt the ComboBox briefly reports null; never persist that.
        if (_refreshingSpeechLanguages || string.IsNullOrEmpty(name)) return null;
        var index = SpeechLanguages.IndexOf(name);
        return index >= 0 ? SpeechLanguageCodes[index] : null;
    }

    private static string NormalizeSpeechLanguage(string? value) => value switch
    {
        "en" => "en",
        "zh-Hans" or "zh-CN" or "zh" => "zh-Hans",
        _ => "followApp"
    };

    public string ScreenshotMode
    {
        get => _screenshotMode;
        set
        {
            if (!SetProperty(ref _screenshotMode, value)) return;
            SavePreference(p => p.ScreenshotMode = EncodeScreenshotMode(value));
            OnPropertyChanged(nameof(IsPresetRegion));
            OnPropertyChanged(nameof(IsManualRegion));
        }
    }

    public bool IsPresetRegion
    {
        get => ScreenshotMode == "Preset region";
        set { if (value) ScreenshotMode = "Preset region"; }
    }

    public bool IsManualRegion
    {
        get => ScreenshotMode == "Select region each time";
        set { if (value) ScreenshotMode = "Select region each time"; }
    }

    public bool HasScreenshotRegion => _store.Data.Preferences.ScreenshotRegionWidth >= 24 && _store.Data.Preferences.ScreenshotRegionHeight >= 24;
    public string ScreenshotRegionStatus => LocalizationManager.Text(HasScreenshotRegion ? "Screenshot region set" : "Screenshot region not set");
    public string ScreenshotRegionActionText => LocalizationManager.Text(HasScreenshotRegion ? "Reset" : "Set Region");
    public string ScreenshotPermissionStatus => LocalizationManager.Text("Screen capture is available");

    public void SetScreenshotRegion(System.Windows.Rect region)
    {
        SavePreference(preferences =>
        {
            preferences.ScreenshotRegionX = region.X;
            preferences.ScreenshotRegionY = region.Y;
            preferences.ScreenshotRegionWidth = region.Width;
            preferences.ScreenshotRegionHeight = region.Height;
            preferences.ScreenshotRegionUsesPhysicalPixels = true;
        });
        OnPropertyChanged(nameof(HasScreenshotRegion));
        OnPropertyChanged(nameof(ScreenshotRegionStatus));
        OnPropertyChanged(nameof(ScreenshotRegionActionText));
    }

    public void ClearScreenshotRegion()
    {
        SavePreference(preferences =>
        {
            preferences.ScreenshotRegionX = 0;
            preferences.ScreenshotRegionY = 0;
            preferences.ScreenshotRegionWidth = 0;
            preferences.ScreenshotRegionHeight = 0;
            preferences.ScreenshotRegionUsesPhysicalPixels = true;
        });
        OnPropertyChanged(nameof(HasScreenshotRegion));
        OnPropertyChanged(nameof(ScreenshotRegionStatus));
        OnPropertyChanged(nameof(ScreenshotRegionActionText));
    }

    public string ScreenshotHotkey
    {
        get => _screenshotHotkey;
        set { if (SetProperty(ref _screenshotHotkey, value)) SavePreference(p => p.ScreenshotHotkey = value); }
    }

    public bool HideTaskbarIconDuringInterview
    {
        get => _hideTaskbarIconDuringInterview;
        set { if (SetProperty(ref _hideTaskbarIconDuringInterview, value)) SavePreference(p => p.HideTaskbarIconDuringInterview = value); }
    }

    public string SpeechRecognitionEngine
    {
        get => _speechRecognitionEngine;
        set { if (SetProperty(ref _speechRecognitionEngine, value)) SavePreference(p => p.SpeechRecognitionEngine = SpeechRecognitionEngineId); }
    }
    private string SpeechRecognitionEngineId => _speechRecognitionEngine.StartsWith("Windows", StringComparison.OrdinalIgnoreCase) ? "windows" : "volcano";

    public string SpeechAppId { get => _speechAppId; set => SetProperty(ref _speechAppId, value); }
    public string SpeechAccessToken { get => _speechAccessToken; set => SetProperty(ref _speechAccessToken, value); }
    public string SpeechResourceId { get => _speechResourceId; set => SetProperty(ref _speechResourceId, value); }
    public string SpeechStatus
    {
        get => _speechStatus;
        private set => SetProperty(ref _speechStatus, value);
    }

    public StatusKind SpeechStatusKind
    {
        get => _speechStatusKind;
        private set => SetProperty(ref _speechStatusKind, value);
    }

    public bool IsTestingSpeech
    {
        get => _isTestingSpeech;
        private set { if (SetProperty(ref _isTestingSpeech, value)) CommandManager.InvalidateRequerySuggested(); }
    }

    public StatusKind StatusKind
    {
        get => _statusKind;
        private set => SetProperty(ref _statusKind, value);
    }

    private void SetSpeechStatus(string text, StatusKind kind)
    {
        SpeechStatus = text;
        SpeechStatusKind = kind;
    }

    private void SetStatus(string text, StatusKind kind)
    {
        Status = text;
        StatusKind = kind;
    }

    public ProviderDefinition SelectedProvider
    {
        get => _selectedProvider;
        set
        {
            if (value is null || !SetProperty(ref _selectedProvider, value)) return;
            _store.Data.Preferences.Provider = value.Provider.ToString();
            LoadSelectedProvider();
            _store.ScheduleSave();
        }
    }

    public string SelectedModel
    {
        get => _selectedModel;
        set => SetProperty(ref _selectedModel, value);
    }

    public string ApiUrl
    {
        get => _apiUrl;
        set => SetProperty(ref _apiUrl, value);
    }

    public string ApiKey
    {
        get => _apiKey;
        set => SetProperty(ref _apiKey, value);
    }

    public bool HidePrompterFromCapture
    {
        get => _hidePrompterFromCapture;
        set
        {
            if (!SetProperty(ref _hidePrompterFromCapture, value)) return;
            _store.Data.Preferences.HidePrompterFromCapture = value;
            _store.ScheduleSave();
        }
    }

    public bool IsTesting
    {
        get => _isTesting;
        private set { if (SetProperty(ref _isTesting, value)) CommandManager.InvalidateRequerySuggested(); }
    }

    public string Status
    {
        get => _status;
        private set => SetProperty(ref _status, value);
    }

    public async Task ClearLocalDataAsync()
    {
        _store.Data.Workspace = new WorkspaceDraft();
        _store.Data.KnowledgeBases.Clear();
        _store.Data.Sessions.Clear();
        await _store.SaveAsync();
        _store.NotifyDataReset();
        Status = "Local interview data was cleared.";
    }

    private void LoadSelectedProvider()
    {
        var settings = _store.GetProviderSettings(SelectedProvider.Provider);
        Models.Clear();
        foreach (var model in SelectedProvider.Models) Models.Add(model);
        _selectedModel = string.IsNullOrWhiteSpace(settings.Model) ? SelectedProvider.DefaultModel : settings.Model;
        _apiUrl = string.IsNullOrWhiteSpace(settings.ApiUrl) ? SelectedProvider.DefaultUrl : settings.ApiUrl;
        _apiKey = _credentials.Read(SelectedProvider.Provider.ToString().ToLowerInvariant());
        OnPropertyChanged(nameof(SelectedModel));
        OnPropertyChanged(nameof(ApiUrl));
        OnPropertyChanged(nameof(ApiKey));
    }

    private async Task SaveAsync()
    {
        PersistFields();
        await _store.SaveAsync();
        SetStatus(LocalizationManager.Instance.IsChinese ? "设置已保存在本机。" : "Settings saved on this device.", StatusKind.Success);
    }

    private async Task TestConnectionAsync()
    {
        IsTesting = true;
        var chinese = LocalizationManager.Instance.IsChinese;
        SetStatus(chinese ? "正在测试连接…" : "Testing connection…", StatusKind.Testing);
        try
        {
            PersistFields();
            await AppServices.Current.AI.TestConnectionAsync(CurrentConfig());
            SetStatus(chinese ? $"{SelectedProvider.DisplayName} 连接成功。" : $"{SelectedProvider.DisplayName} connection successful.", StatusKind.Success);
        }
        catch (Exception exception)
        {
            SetStatus((chinese ? "连接失败：" : "Connection failed: ") + exception.Message, StatusKind.Error);
        }
        finally
        {
            IsTesting = false;
        }
    }

    private void PersistFields()
    {
        var settings = _store.GetProviderSettings(SelectedProvider.Provider);
        settings.ApiUrl = ApiUrl.Trim();
        settings.Model = SelectedModel.Trim();
        _store.Data.Preferences.Provider = SelectedProvider.Provider.ToString();
        _credentials.Write(SelectedProvider.Provider.ToString().ToLowerInvariant(), ApiKey.Trim());
        _store.ScheduleSave(TimeSpan.Zero);
    }

    private async Task SaveSpeechAsync()
    {
        _store.Data.Preferences.SpeechResourceId = SpeechResourceId.Trim();
        _credentials.Write("speech-app-id", SpeechAppId.Trim());
        _credentials.Write("speech-access-token", SpeechAccessToken.Trim());
        await _store.SaveAsync();
        var chinese = LocalizationManager.Instance.IsChinese;
        SetSpeechStatus(SpeechRecognitionEngineId == "windows"
            ? (chinese ? "已选择 Windows 本地语音识别。" : "Windows speech recognition selected.")
            : (chinese ? "语音识别凭证已安全保存。" : "Speech recognition credentials saved securely."), StatusKind.Success);
    }

    private async Task TestSpeechConnectionAsync()
    {
        IsTestingSpeech = true;
        try { await TestSpeechConnectionCoreAsync(); }
        finally { IsTestingSpeech = false; }
    }

    private async Task TestSpeechConnectionCoreAsync()
    {
        var chinese = LocalizationManager.Instance.IsChinese;
        await SaveSpeechAsync();
        SetSpeechStatus(chinese ? "正在测试连接…" : "Testing connection…", StatusKind.Testing);

        if (SpeechRecognitionEngineId == "windows")
        {
            var available = System.Speech.Recognition.SpeechRecognitionEngine.InstalledRecognizers().Count > 0;
            if (available) SetSpeechStatus(chinese ? "Windows 本地语音识别可用。" : "Windows on-device speech recognition is available.", StatusKind.Success);
            else SetSpeechStatus(chinese ? "未找到 Windows 语音识别语言包，请先在系统设置中安装。" : "No Windows speech recognizer is installed. Install a speech language in Windows Settings first.", StatusKind.Error);
            return;
        }

        var appId = SpeechAppId.Trim();
        var accessToken = SpeechAccessToken.Trim();
        var resourceId = SpeechResourceId.Trim();
        if (string.IsNullOrWhiteSpace(appId) || string.IsNullOrWhiteSpace(accessToken) || string.IsNullOrWhiteSpace(resourceId))
        {
            SetSpeechStatus(chinese
                ? "请先填写豆包语音 App ID、Access Token 并选择识别模型。"
                : "Enter the Doubao Voice App ID, Access Token, and recognition model first.", StatusKind.Error);
            return;
        }

        try
        {
            await DoubaoSpeechRecognitionService.TestConnectionAsync(appId, accessToken, resourceId, CancellationToken.None);
            SetSpeechStatus(chinese ? "豆包语音连接成功。" : "Doubao Voice connection successful.", StatusKind.Success);
        }
        catch (Exception exception)
        {
            SetSpeechStatus(chinese
                ? $"豆包语音连接失败：{DoubaoSpeechRecognitionService.FriendlyError(exception)}"
                : $"Doubao Voice connection failed: {DoubaoSpeechRecognitionService.FriendlyError(exception)}", StatusKind.Error);
        }
    }

    private void SavePreference(Action<AppPreferences> update)
    {
        update(_store.Data.Preferences);
        _store.ScheduleSave();
    }

    private void RefreshSpeechRecognitionEngines(string selectedId)
    {
        var chinese = LocalizationManager.Instance.IsChinese;
        SpeechRecognitionEngines.Clear();
        SpeechRecognitionEngines.Add(chinese ? "豆包流式语音识别 2.0" : "Doubao streaming speech 2.0");
        SpeechRecognitionEngines.Add(chinese ? "Windows 本地语音识别" : "Windows on-device speech");
        _speechRecognitionEngine = selectedId == "windows" ? SpeechRecognitionEngines[1] : SpeechRecognitionEngines[0];
        OnPropertyChanged(nameof(SpeechRecognitionEngine));
    }

    private static string DecodeLanguage(string value) => value.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "简体中文" : "English";
    private static string DecodeTheme(string value) => value.ToLowerInvariant() switch { "light" => "Light", "system" => "System", _ => "Dark" };
    private static string DecodeScreenshotMode(string value) => value is "selectRegion" or "manualSelect" ? "Select region each time" : "Preset region";
    private static string EncodeScreenshotMode(string value) => value == "Select region each time" ? "manualSelect" : "presetRegion";

    private AIConfig CurrentConfig() => new(SelectedProvider.Provider, ApiUrl.Trim(), ApiKey.Trim(), SelectedModel.Trim());
}
