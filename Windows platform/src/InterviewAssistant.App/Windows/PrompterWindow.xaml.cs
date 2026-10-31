using System.ComponentModel;
using System.Text;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using InterviewAssistant.Infrastructure;
using InterviewAssistant.Models;
using InterviewAssistant.Services;
using InterviewAssistant.ViewModels;

namespace InterviewAssistant.Windows;

public partial class PrompterWindow : Window
{
    private const double ExpandedWidth = 600;
    private const double DefaultExpandedHeight = 240;
    private const double CompactWidth = 80;
    private const double CompactHeight = 37;
    private const double AnswerFontSize = 17;
    private const double MessageFontSize = 15;
    private readonly AppDataStore _store = AppServices.Current.DataStore;
    private readonly InterviewSessionModel _session;
    private readonly SpeechRecognitionService _speechRecognition = new();
    private readonly SemaphoreSlim _speechSubmissionGate = new(1, 1);
    private bool _isDirectorMode;
    private readonly DispatcherTimer _waveTimer;
    private readonly DispatcherTimer _modeToastTimer;
    private nint _windowHandle;
    private int _turnIndex = -1;
    private bool _isCompact;
    private PrompterAudioMode _audioMode = PrompterAudioMode.Microphone;
    private bool _isResizing;
    private double _expandedHeight = DefaultExpandedHeight;
    private double _resizeStartScreenY;
    private double _resizeStartHeight;
    private int _waveStep;
    private string _codeLanguage = "python";
    private bool _showingError;

    public PrompterWindow() : this(new InterviewSessionModel { Title = "Prompter preview", Role = "Interview preview" }, false) { }

    public PrompterWindow(bool directorMode) : this(
        new InterviewSessionModel { Title = directorMode ? "Director Mode" : "Prompter preview", Role = directorMode ? "Director Mode" : "Interview preview", Kind = directorMode ? "director" : "formal" },
        directorMode) { }

    public PrompterWindow(InterviewSessionModel session) : this(session, false) { }

    private PrompterWindow(InterviewSessionModel session, bool directorMode)
    {
        _session = session;
        _isDirectorMode = directorMode || string.Equals(session.Kind, "director", StringComparison.OrdinalIgnoreCase);
        InitializeComponent();
        Loaded += PrompterWindow_Loaded;
        SizeChanged += (_, _) => PositionAtTopCenter();
        _waveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
        _waveTimer.Tick += (_, _) => AnimateWaveform();
        _waveTimer.Start();
        _modeToastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _modeToastTimer.Tick += (_, _) =>
        {
            _modeToastTimer.Stop();
            ModeToast.Visibility = Visibility.Collapsed;
        };
        KnowledgeCountText.Text = session.ActiveKnowledgeBaseIds.Count.ToString();
        ApplyPrompterMode(refreshContent: false);
        _store.Changed += StoreChanged;
        _speechRecognition.Recognized += SpeechRecognition_Recognized;
        _speechRecognition.PartialRecognized += SpeechRecognition_PartialRecognized;
        _speechRecognition.StatusChanged += SpeechRecognition_StatusChanged;
        RefreshTurns(showLatest: true);
    }

    public bool CaptureExclusionApplied { get; private set; }
    public event Action? ScreenshotRequested;
    public event Action<PrompterAudioMode>? AudioInputChanged;
    public event Action<bool>? DirectorModeChanged;
    public event Action<string>? DirectorQuestionCaptured;

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        _windowHandle = new WindowInteropHelper(this).Handle;
        var extendedStyle = NativeMethods.GetWindowLong(_windowHandle, NativeMethods.GwlExStyle);
        _ = NativeMethods.SetWindowLong(_windowHandle, NativeMethods.GwlExStyle, extendedStyle | NativeMethods.WsExToolWindow | NativeMethods.WsExNoActivate);
        ApplyCaptureExclusion();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        _waveTimer.Stop();
        _modeToastTimer.Stop();
        _store.Changed -= StoreChanged;
        _speechRecognition.Recognized -= SpeechRecognition_Recognized;
        _speechRecognition.PartialRecognized -= SpeechRecognition_PartialRecognized;
        _speechRecognition.StatusChanged -= SpeechRecognition_StatusChanged;
        _speechRecognition.Dispose();
        if (_windowHandle != nint.Zero) _ = NativeMethods.SetWindowDisplayAffinity(_windowHandle, 0);
        if (_session.EndedAt is null && _session.Turns.Count > 0)
        {
            _session.EndedAt = DateTimeOffset.Now;
            _session.UpdatedAt = DateTimeOffset.Now;
            _store.ScheduleSave();
        }
        base.OnClosing(e);
    }

    public Task SubmitQuestionAsync(string question, CancellationToken cancellationToken = default) =>
        SubmitQuestionAsync(question, fromScreenshot: false, cancellationToken);

    private async Task SubmitQuestionAsync(string question, bool fromScreenshot, CancellationToken cancellationToken = default)
    {
        question = question.Trim();
        if (question.Length == 0) return;
        // Build prompts before the new turn is added so it is not part of "recent conversation".
        var (systemPrompt, userPrompt, maxTokens) = BuildPrompts(question, fromScreenshot);
        var turn = new ConversationTurnModel { Question = fromScreenshot && question.Length > 240 ? question[..240] : question, SpeakerLabel = "interviewer" };
        _session.Turns.Add(turn);
        _session.UpdatedAt = DateTimeOffset.Now;
        _turnIndex = _session.Turns.Count - 1;
        ShowPreparing(question);
        _store.ScheduleSave();
        try
        {
            var answer = await AppServices.Current.AI.CompleteAsync(CurrentAIConfig(), systemPrompt, userPrompt, maxTokens, cancellationToken);
            turn.Answer = InterviewPromptBuilder.DisplayableAnswer(answer, _codeLanguage);
            turn.SpeakerLabel = "assistant";
            _session.UpdatedAt = DateTimeOffset.Now;
            _store.ScheduleSave();
            Dispatcher.Invoke(() => RenderTurn(_turnIndex));
        }
        catch (OperationCanceledException)
        {
            Dispatcher.Invoke(() => ShowMessage(Localized("Answer generation was cancelled.", "回答生成已取消。"), true));
        }
        catch (Exception exception)
        {
            turn.Answer = InterviewPromptBuilder.IsChinese(AnswerLanguageCode())
                ? $"暂时无法生成回答建议，请稍后重试或截取更清晰的题目区域。\n\n{exception.Message}"
                : $"I could not generate a suggestion yet. Please try again or capture a clearer question area.\n\n{exception.Message}";
            _store.ScheduleSave();
            Dispatcher.Invoke(() => RenderTurn(_turnIndex));
        }
    }

    public void RefreshTurns(bool showLatest)
    {
        if (_session.Turns.Count == 0)
        {
            _turnIndex = -1;
            QuestionText.Text = _isDirectorMode
                ? Localized("Waiting for Host question...", "等待 Host 问题…")
                : Localized("Waiting for interview question...", "等待面试问题…");
            ShowPlaceholder(_isDirectorMode
                ? Localized("Waiting for answer", "等待回答")
                : Localized("Waiting for AI answer...", "等待 AI 回答…"));
            PreparingPanel.Visibility = Visibility.Collapsed;
            AnswerScroller.Visibility = Visibility.Visible;
            UpdateNavigationButtons();
            return;
        }
        if (showLatest || _turnIndex < 0 || _turnIndex >= _session.Turns.Count) _turnIndex = _session.Turns.Count - 1;
        RenderTurn(_turnIndex);
    }

    private void PrompterWindow_Loaded(object sender, RoutedEventArgs e)
    {
        foreach (var existing in Application.Current.Windows.OfType<PrompterWindow>().Where(window => !ReferenceEquals(window, this)).ToArray())
        {
            existing.Close();
        }
        PositionAtTopCenter();
        ApplyCaptureExclusion();
        Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, new Action(ApplyCaptureExclusion));
        if (_audioMode == PrompterAudioMode.Microphone) _ = StartMicrophoneRecognitionAsync();
        Opacity = 0;
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(240)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } });
    }

    private void ApplyCaptureExclusion()
    {
        if (_windowHandle == nint.Zero) return;
        var shouldExclude = _store.Data.Preferences.HidePrompterFromCapture;
        if (!shouldExclude)
        {
            _ = NativeMethods.SetWindowDisplayAffinity(_windowHandle, 0);
            CaptureExclusionApplied = false;
            return;
        }

        CaptureExclusionApplied = NativeMethods.SetWindowDisplayAffinity(_windowHandle, NativeMethods.WdaExcludeFromCapture)
            && NativeMethods.GetWindowDisplayAffinity(_windowHandle, out var affinity)
            && affinity == NativeMethods.WdaExcludeFromCapture;
        if (!CaptureExclusionApplied)
        {
            CaptureExclusionApplied = NativeMethods.SetWindowDisplayAffinity(_windowHandle, NativeMethods.WdaMonitor)
                && NativeMethods.GetWindowDisplayAffinity(_windowHandle, out affinity)
                && affinity == NativeMethods.WdaMonitor;
        }
    }

    private void StoreChanged()
    {
        if (Dispatcher.CheckAccess()) ApplyCaptureExclusion();
        else Dispatcher.BeginInvoke(new Action(ApplyCaptureExclusion));
    }

    private void PositionAtTopCenter()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + Math.Max(0, (area.Width - ActualWidth) / 2);
        Top = area.Top;
    }

    private void RenderTurn(int index)
    {
        if (index < 0 || index >= _session.Turns.Count) return;
        var turn = _session.Turns[index];
        QuestionText.Text = string.IsNullOrWhiteSpace(turn.Question) ? Localized("Interview question", "面试问题") : turn.Question;
        if (string.IsNullOrWhiteSpace(turn.Answer))
            ShowPlaceholder(_isDirectorMode ? Localized("Waiting for answer", "等待回答") : Localized("Waiting for AI answer...", "等待 AI 回答…"));
        else
            MarkdownAnswerRenderer.Render(AnswerContent, turn.Answer, (Brush)FindResource("IslandPrimary"), AnswerFontSize, (Style)FindResource("CodeScrollBarStyle"));
        _showingError = false;
        PreparingPanel.Visibility = Visibility.Collapsed;
        AnswerScroller.Visibility = Visibility.Visible;
        AnswerScroller.ScrollToTop();
        UpdateNavigationButtons();
    }

    private void ShowPreparing(string question)
    {
        Dispatcher.Invoke(() =>
        {
            QuestionText.Text = question;
            PreparingText.Text = Localized("Preparing answer suggestion...", "正在准备回答建议…");
            AnswerScroller.Visibility = Visibility.Collapsed;
            PreparingPanel.Visibility = Visibility.Visible;
            UpdateNavigationButtons();
        });
    }

    private void ShowMessage(string message, bool isError = false)
    {
        PreparingPanel.Visibility = Visibility.Collapsed;
        AnswerScroller.Visibility = Visibility.Visible;
        _showingError = isError;
        MarkdownAnswerRenderer.RenderPlain(AnswerContent, message, isError ? Brushes.IndianRed : (Brush)FindResource("IslandSecondary"), MessageFontSize);
        AnswerScroller.ScrollToTop();
    }

    private void ShowPlaceholder(string text)
    {
        _showingError = false;
        MarkdownAnswerRenderer.RenderPlain(AnswerContent, text, (Brush)FindResource("IslandSecondary"), AnswerFontSize);
    }

    private void UpdateNavigationButtons()
    {
        PreviousButton.IsEnabled = _turnIndex > 0;
        NextButton.IsEnabled = _turnIndex >= 0 && _turnIndex < _session.Turns.Count - 1;
    }

    private AIConfig CurrentAIConfig()
    {
        if (!Enum.TryParse<AIProvider>(_store.Data.Preferences.Provider, true, out var provider)) provider = AIProvider.DeepSeek;
        var settings = _store.GetProviderSettings(provider);
        var key = AppServices.Current.Credentials.Read(provider.ToString().ToLowerInvariant());
        return new AIConfig(provider, settings.ApiUrl, key, settings.Model);
    }

    private string AnswerLanguageCode() => InterviewPromptBuilder.AnswerLanguageCode(_store.Data.Preferences);

    /// <summary>Same prompt selection as the macOS ReceiverCoordinator (askAI / askScreenshotQuestion).</summary>
    private (string System, string User, int MaxTokens) BuildPrompts(string question, bool fromScreenshot)
    {
        var data = _store.Data;
        var language = AnswerLanguageCode();
        var context = InterviewPromptBuilder.BuildCandidateContext(_session, data.Workspace);
        var activeIds = _session.ActiveKnowledgeBaseIds.Count > 0 ? (IReadOnlyCollection<Guid>)_session.ActiveKnowledgeBaseIds : data.Workspace.ActiveKnowledgeBaseIds;
        var mockMemory = InterviewPromptBuilder.BuildMockTrainingMemory(data.Sessions);
        string system;
        string user;
        int maxTokens;
        if (fromScreenshot)
        {
            system = InterviewPromptBuilder.BuildStructuredTechnicalSystemPrompt(context, data.KnowledgeBases, activeIds);
            system = InterviewPromptBuilder.AppendMockMemory(system, mockMemory, screenshot: true);
            user = InterviewPromptBuilder.BuildQuestionPrompt(question, language, _codeLanguage);
            maxTokens = 1800;
        }
        else
        {
            system = InterviewPromptBuilder.BuildSystemPrompt(context, data.KnowledgeBases, activeIds, _session.Turns);
            system = InterviewPromptBuilder.AppendMockMemory(system, mockMemory, screenshot: false);
            // Coding questions asked by voice still need code in the chosen language.
            if (InterviewPromptBuilder.IsAlgorithmQuestion(question))
                system += $"\n\nIf the question asks you to write code, include complete runnable {_codeLanguage} code in a fenced markdown block that starts with ```{_codeLanguage}.";
            user = question;
            maxTokens = 900;
        }
        system += InterviewPromptBuilder.OutputLanguageMandate(language);
        if (!fromScreenshot) system = InterviewPromptBuilder.AppendCommonReference(system, question);
        return (system, user, maxTokens);
    }

    private string Localized(string english, string chinese) => _store.Data.Preferences.Language.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? chinese : english;

    private void AnimateWaveform()
    {
        if (_audioMode == PrompterAudioMode.Muted) return;
        _waveStep++;
        var bars = new[] { Wave1, Wave2, Wave3, Wave4, Wave5, Wave6 };
        var heights = new[] { 5d, 10d, 16d, 8d, 13d, 6d };
        for (var index = 0; index < bars.Length; index++) bars[index].Height = Math.Max(3, heights[index] * (0.55 + 0.45 * Math.Abs(Math.Sin((_waveStep + index * 1.7) * 0.55))));
    }

    private void SetWindowSize(double width, double height)
    {
        // Resizing a transparent layered WPF window with Width/Height animations leaves
        // stale compositor frames on some Windows/VM graphics drivers. Switch the native
        // surface atomically and only fade the child content.
        BeginAnimation(WidthProperty, null);
        BeginAnimation(HeightProperty, null);
        Width = width;
        Height = height;
        UpdateLayout();
        PositionAtTopCenter();
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isCompact) return;
        _isCompact = true;
        CodeLanguagePopup.IsOpen = false;
        ExpandedIsland.Visibility = Visibility.Collapsed;
        CompactIsland.Opacity = 0;
        SetWindowSize(CompactWidth, CompactHeight);
        CompactIsland.Visibility = Visibility.Visible;
        CompactIsland.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140)));
    }

    private void RestoreButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_isCompact) return;
        _isCompact = false;
        CompactIsland.Visibility = Visibility.Collapsed;
        SetWindowSize(ExpandedWidth, _expandedHeight);
        ExpandedIsland.Opacity = 0;
        ExpandedIsland.Visibility = Visibility.Visible;
        ExpandedIsland.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(170)));
    }
    private void PreviousButton_Click(object sender, RoutedEventArgs e) { if (_turnIndex > 0) RenderTurn(--_turnIndex); }
    private void NextButton_Click(object sender, RoutedEventArgs e) { if (_turnIndex < _session.Turns.Count - 1) RenderTurn(++_turnIndex); }
    private void ScreenshotButton_Click(object sender, RoutedEventArgs e)
    {
        _ = CaptureAndAnalyzeScreenshotAsync();
    }

    public async Task CaptureAndAnalyzeScreenshotAsync()
    {
        try
        {
            Rect region;
            if (_store.Data.Preferences.ScreenshotMode is "selectRegion" or "manualSelect")
            {
                var selector = new RegionSelectionWindow { Owner = Application.Current.MainWindow };
                if (selector.ShowDialog() != true) return;
                region = selector.SelectedRegion;
            }
            else
            {
                region = ScreenshotCaptureService.PresetRegion();
                if (region.Width < 24 || region.Height < 24)
                {
                    ShowMessage(Localized("Set a screenshot region in Settings first.", "请先在设置中设定截图区域。"), true);
                    return;
                }
            }

            QuestionText.Text = Localized("Reading screenshot…", "正在识别截图…");
            PreparingText.Text = Localized("Extracting the visible question and preparing an answer…", "正在提取可见题目并准备回答…");
            AnswerScroller.Visibility = Visibility.Collapsed;
            PreparingPanel.Visibility = Visibility.Visible;
            await Task.Delay(90);
            var path = ScreenshotCaptureService.Capture(region);
            ScreenshotRequested?.Invoke();
            string result;
            try
            {
                result = await WindowsOcrService.RecognizeAsync(path);
            }
            catch
            {
                result = "";
            }
            if (string.IsNullOrWhiteSpace(result))
            {
                // OCR found nothing: ask the vision model only to transcribe the question,
                // then answer it through the same prompt pipeline as OCR text.
                result = await AppServices.Current.AI.AnalyzeImageAsync(
                    CurrentAIConfig(),
                    path,
                    "Read the screenshot and return only the exact interview question or coding task visible in it. Do not answer it and do not add commentary.");
            }
            if (_isDirectorMode)
            {
                DirectorQuestionCaptured?.Invoke(result);
                return;
            }
            await SubmitQuestionAsync(result, fromScreenshot: true);
            if (_turnIndex >= 0 && _turnIndex < _session.Turns.Count)
            {
                _session.Turns[_turnIndex].ScreenshotPath = path;
                _store.ScheduleSave();
            }
        }
        catch (Exception exception)
        {
            ShowMessage(Localized("Screenshot analysis failed: ", "截图分析失败：") + exception.Message, true);
        }
    }

    public void ApplyDirectorPacket(DirectorPacket packet)
    {
        if (!_isDirectorMode && packet.Kind is not "state") return;
        Dispatcher.Invoke(() =>
        {
            if (packet.Kind == "question" && !string.IsNullOrWhiteSpace(packet.Text))
            {
                _session.Turns.Add(new ConversationTurnModel { Question = packet.Text, SpeakerLabel = "interviewer" });
                _turnIndex = _session.Turns.Count - 1;
                _session.UpdatedAt = DateTimeOffset.Now;
                _store.ScheduleSave();
                RenderTurn(_turnIndex);
            }
            else if (packet.Kind == "answer" && !string.IsNullOrWhiteSpace(packet.Text))
            {
                if (_turnIndex < 0 || _turnIndex >= _session.Turns.Count)
                {
                    _session.Turns.Add(new ConversationTurnModel { Question = Localized("Director response", "导演回答") });
                    _turnIndex = _session.Turns.Count - 1;
                }
                _session.Turns[_turnIndex].Answer = packet.Text;
                _session.Turns[_turnIndex].SpeakerLabel = "director";
                _session.UpdatedAt = DateTimeOffset.Now;
                _store.ScheduleSave();
                RenderTurn(_turnIndex);
            }
        });
    }

    private void AudioButton_Click(object sender, RoutedEventArgs e)
    {
        SetAudioMode(_audioMode switch
        {
            PrompterAudioMode.Microphone => PrompterAudioMode.SystemAudio,
            PrompterAudioMode.SystemAudio => PrompterAudioMode.Muted,
            _ => PrompterAudioMode.Microphone
        });
    }

    private void SetAudioMode(PrompterAudioMode mode)
    {
        _audioMode = mode;
        AudioIcon.Text = mode switch
        {
            PrompterAudioMode.SystemAudio => "\uE767",
            PrompterAudioMode.Muted => "\uE74F",
            _ => "\uE720"
        };
        AudioIcon.Foreground = (Brush)FindResource(mode == PrompterAudioMode.Muted ? "IslandSecondary" : "IslandYellow");
        AudioInputChanged?.Invoke(mode);
        if (mode != PrompterAudioMode.Muted) _ = _speechRecognition.StartAsync(SpeechLanguageCode(), mode == PrompterAudioMode.SystemAudio);
        else _speechRecognition.Stop();
        if (mode == PrompterAudioMode.Muted)
        {
            foreach (var bar in new[] { Wave1, Wave2, Wave3, Wave4, Wave5, Wave6 }) bar.Height = 3;
            // Drop a speech-connection error that was on screen; it no longer applies once muted.
            if (_showingError && PreparingPanel.Visibility != Visibility.Visible) RefreshTurns(showLatest: false);
        }
    }

    private void CodeButton_Click(object sender, RoutedEventArgs e)
    {
        if (CodeLanguagePopup.IsOpen)
        {
            CodeLanguagePopup.IsOpen = false;
            return;
        }
        CodeLanguageInput.Text = _codeLanguage;
        SetNoActivate(false);
        CodeLanguagePopup.IsOpen = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() =>
        {
            Activate();
            CodeLanguageInput.Focus();
            CodeLanguageInput.SelectAll();
        }));
    }

    private void CodeLanguage_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string language }) return;
        SaveCodeLanguage(language);
    }

    private void CodeLanguageSave_Click(object sender, RoutedEventArgs e) => SaveCodeLanguage(CodeLanguageInput.Text);

    private void CodeLanguageInput_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        SaveCodeLanguage(CodeLanguageInput.Text);
        e.Handled = true;
    }

    private void SaveCodeLanguage(string language)
    {
        language = language.Trim();
        if (language.Length == 0) language = "python";
        _codeLanguage = language;
        CodeLanguageText.Text = language;
        CodeLanguagePopup.IsOpen = false;
    }

    private void CodeLanguagePopup_Closed(object? sender, EventArgs e) => SetNoActivate(true);

    private void SetNoActivate(bool noActivate)
    {
        if (_windowHandle == nint.Zero) return;
        var style = NativeMethods.GetWindowLong(_windowHandle, NativeMethods.GwlExStyle) | NativeMethods.WsExToolWindow;
        style = noActivate ? style | NativeMethods.WsExNoActivate : style & ~NativeMethods.WsExNoActivate;
        _ = NativeMethods.SetWindowLong(_windowHandle, NativeMethods.GwlExStyle, style);
    }

    private void ModeButton_Click(object sender, RoutedEventArgs e)
    {
        CodeLanguagePopup.IsOpen = false;
        _isDirectorMode = !_isDirectorMode;
        _session.Kind = _isDirectorMode ? "director" : "formal";
        _session.UpdatedAt = DateTimeOffset.Now;
        _store.ScheduleSave();
        ApplyPrompterMode(refreshContent: true);
        ShowModeToast();
        DirectorModeChanged?.Invoke(_isDirectorMode);
    }

    private void ShowModeToast()
    {
        ModeToastText.Text = _isDirectorMode
            ? Localized("User switched to Director mode", "用户已切换至导演模式")
            : Localized("User switched to AI mode", "用户已切换至 AI 模式");
        ModeToast.Opacity = 0;
        ModeToast.Visibility = Visibility.Visible;
        ModeToast.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140)));
        _modeToastTimer.Stop();
        _modeToastTimer.Start();
    }

    private void ApplyPrompterMode(bool refreshContent)
    {
        AiOnlyTools.Visibility = _isDirectorMode ? Visibility.Collapsed : Visibility.Visible;
        AiKnowledgeButton.Visibility = _isDirectorMode ? Visibility.Collapsed : Visibility.Visible;
        ModeButton.ToolTip = _isDirectorMode
            ? Localized("Switch to AI mode", "切换到 AI 模式")
            : Localized("Switch to Director mode", "切换到导演模式");
        if (_audioMode == PrompterAudioMode.Muted) _speechRecognition.Stop();
        else if (IsLoaded) _ = _speechRecognition.StartAsync(SpeechLanguageCode(), _audioMode == PrompterAudioMode.SystemAudio);
        if (refreshContent) RefreshTurns(showLatest: true);
    }

    private string SpeechLanguageCode()
    {
        var configured = _store.Data.Preferences.InterviewerLanguage;
        if (!configured.Equals("followApp", StringComparison.OrdinalIgnoreCase)) return configured;
        return _store.Data.Preferences.Language.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-Hans" : "en";
    }

    private Task<bool> StartMicrophoneRecognitionAsync() => _speechRecognition.StartAsync(SpeechLanguageCode());

    private async void SpeechRecognition_Recognized(string text)
    {
        if (_audioMode == PrompterAudioMode.Muted || !_speechSubmissionGate.Wait(0)) return;
        if (_isDirectorMode)
        {
            try { DirectorQuestionCaptured?.Invoke(text); }
            finally { _speechSubmissionGate.Release(); }
            return;
        }
        try { await SubmitQuestionAsync(text); }
        finally { _speechSubmissionGate.Release(); }
    }

    private void SpeechRecognition_PartialRecognized(string text)
    {
        if (_audioMode == PrompterAudioMode.Muted) return;
        Dispatcher.BeginInvoke(new Action(() => QuestionText.Text = text));
    }

    private void SpeechRecognition_StatusChanged(string status)
    {
        if (!status.Contains("could not", StringComparison.OrdinalIgnoreCase) && !status.Contains("No Windows", StringComparison.OrdinalIgnoreCase)) return;
        Dispatcher.BeginInvoke(new Action(() =>
        {
            // A connection that times out after the user switched to mute is irrelevant; don't cover the answer with it.
            if (_audioMode == PrompterAudioMode.Muted) return;
            ShowMessage(status, true);
        }));
    }

    private void KnowledgeButton_Click(object sender, RoutedEventArgs e)
    {
        if (Application.Current.MainWindow?.DataContext is MainViewModel mainViewModel) mainViewModel.NavigateTo("Knowledge Base");
        Application.Current.MainWindow?.Show();
        Application.Current.MainWindow?.Activate();
    }

    private void ResizeHandle_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _isResizing = true; _resizeStartScreenY = PointToScreen(e.GetPosition(this)).Y; _resizeStartHeight = ActualHeight; Mouse.Capture((IInputElement)sender); e.Handled = true;
    }

    private void ResizeHandle_MouseMove(object sender, MouseEventArgs e)
    {
        if (!_isResizing || e.LeftButton != MouseButtonState.Pressed) return;
        _expandedHeight = Math.Clamp(_resizeStartHeight + PointToScreen(e.GetPosition(this)).Y - _resizeStartScreenY, 180, 520); Height = _expandedHeight;
    }

    private void ResizeHandle_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) { _isResizing = false; Mouse.Capture(null); e.Handled = true; }
    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}

public enum PrompterAudioMode
{
    Microphone,
    SystemAudio,
    Muted
}
