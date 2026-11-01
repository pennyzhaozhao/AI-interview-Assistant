using System.ComponentModel;
using System.Text;
using System.Windows;
using System.Windows.Controls;
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
    private double _answerFontSize = 17;
    private const double MessageFontSize = 15;
    private readonly AppDataStore _store = AppServices.Current.DataStore;
    private readonly InterviewSessionModel _session;
    private readonly SpeechRecognitionService _speechRecognition = new();
    private readonly SemaphoreSlim _speechSubmissionGate = new(1, 1);
    private bool _isDirectorMode;
    private readonly DispatcherTimer _waveTimer;
    private readonly DispatcherTimer _modeToastTimer;
    private readonly DispatcherTimer _speechDebounceTimer;
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
    private string _pendingSpeechQuestion = "";
    private CancellationTokenSource? _answerCancellation;
    private DateTimeOffset _lastStreamPaint = DateTimeOffset.MinValue;
    private readonly List<(string Path, string Text)> _screenshotSegments = [];
    private bool _screenshotBusy;
    private bool _autoScroll;
    private bool _aiEnabled = true;

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
        _speechDebounceTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(650) };
        _speechDebounceTimer.Tick += async (_, _) =>
        {
            _speechDebounceTimer.Stop();
            var question = _pendingSpeechQuestion.Trim();
            _pendingSpeechQuestion = "";
            if (question.Length > 0) await SubmitRecognizedQuestionAsync(question);
        };
        KnowledgeCountText.Text = session.ActiveKnowledgeBaseIds.Count.ToString();
        ApplyPrompterMode(refreshContent: false);
        _store.Changed += StoreChanged;
        _speechRecognition.Recognized += SpeechRecognition_Recognized;
        _speechRecognition.PartialRecognized += SpeechRecognition_PartialRecognized;
        _speechRecognition.StatusChanged += SpeechRecognition_StatusChanged;
        // Like macOS: when a voice is selected in Settings › Voices, the candidate's own speech is ignored.
        _speechRecognition.FilterCandidateVoice = true;
        _speechRecognition.CandidateSpeechDetected += SpeechRecognition_CandidateSpeechDetected;
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
        _speechDebounceTimer.Stop();
        _answerCancellation?.Cancel();
        _answerCancellation?.Dispose();
        _store.Changed -= StoreChanged;
        _speechRecognition.Recognized -= SpeechRecognition_Recognized;
        _speechRecognition.PartialRecognized -= SpeechRecognition_PartialRecognized;
        _speechRecognition.StatusChanged -= SpeechRecognition_StatusChanged;
        _speechRecognition.CandidateSpeechDetected -= SpeechRecognition_CandidateSpeechDetected;
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
        var turnIndex = _turnIndex;
        ShowPreparing(question);
        _store.ScheduleSave();
        _answerCancellation?.Cancel();
        _answerCancellation?.Dispose();
        _answerCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var requestCancellation = _answerCancellation;
        var answerToken = requestCancellation.Token;
        try
        {
            var answer = await AppServices.Current.AI.StreamAsync(CurrentAIConfig(), systemPrompt, userPrompt, partial =>
            {
                if (DateTimeOffset.UtcNow - _lastStreamPaint < TimeSpan.FromMilliseconds(55)) return;
                _lastStreamPaint = DateTimeOffset.UtcNow;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (_turnIndex != turnIndex) return;
                    turn.Answer = InterviewPromptBuilder.DisplayableAnswer(partial, _codeLanguage);
                    QuestionText.Text = turn.Question;
                    PreparingPanel.Visibility = Visibility.Collapsed;
                    AnswerScroller.Visibility = Visibility.Visible;
                    MarkdownAnswerRenderer.Render(AnswerContent, turn.Answer, (Brush)FindResource("IslandPrimary"), _answerFontSize, (Style)FindResource("CodeScrollBarStyle"));
                    if (_autoScroll) AnswerScroller.ScrollToEnd();
                }));
            }, maxTokens, answerToken);
            turn.Answer = InterviewPromptBuilder.DisplayableAnswer(answer, _codeLanguage);
            turn.SpeakerLabel = "assistant";
            _session.UpdatedAt = DateTimeOffset.Now;
            _store.ScheduleSave();
            Dispatcher.Invoke(() => { if (_turnIndex == turnIndex) RenderTurn(turnIndex); });
        }
        catch (OperationCanceledException)
        {
            if (ReferenceEquals(_answerCancellation, requestCancellation))
                Dispatcher.Invoke(() => ShowMessage(Localized("Answer generation was cancelled.", "回答生成已取消。"), true));
        }
        catch (Exception exception)
        {
            turn.Answer = InterviewPromptBuilder.IsChinese(AnswerLanguageCode())
                ? $"暂时无法生成回答建议，请稍后重试或截取更清晰的题目区域。\n\n{exception.Message}"
                : $"I could not generate a suggestion yet. Please try again or capture a clearer question area.\n\n{exception.Message}";
            _store.ScheduleSave();
            Dispatcher.Invoke(() => { if (_turnIndex == turnIndex) RenderTurn(turnIndex); });
        }
        finally
        {
            if (ReferenceEquals(_answerCancellation, requestCancellation)) _answerCancellation = null;
            requestCancellation.Dispose();
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
            MarkdownAnswerRenderer.Render(AnswerContent, turn.Answer, (Brush)FindResource("IslandPrimary"), _answerFontSize, (Style)FindResource("CodeScrollBarStyle"));
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
        MarkdownAnswerRenderer.RenderPlain(AnswerContent, text, (Brush)FindResource("IslandSecondary"), _answerFontSize);
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
        system = InterviewPromptBuilder.AppendCustomInstructions(system, data.KnowledgeBases, activeIds);
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
    private async void ScreenshotButton_Click(object sender, RoutedEventArgs e)
    {
        await CaptureScreenshotSegmentAsync();
    }

    private async Task CaptureScreenshotSegmentAsync()
    {
        if (_screenshotBusy) return;
        _screenshotBusy = true;
        try
        {
            var path = await CaptureScreenshotImageAsync();
            if (path is null) return;
            _screenshotSegments.Add((path, ""));
            ShowScreenshotSessionControls();
        }
        catch (Exception exception) { ShowMessage(Localized("Screenshot analysis failed: ", "截图分析失败：") + exception.Message, true); }
        finally { _screenshotBusy = false; }
    }

    private void ShowScreenshotSessionMenu()
    {
        var menu = new ContextMenu { PlacementTarget = ScreenshotButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        var count = new MenuItem { Header = Localized($"Captured {_screenshotSegments.Count} screenshot(s)", $"已截取 {_screenshotSegments.Count} 张"), IsEnabled = false };
        var more = new MenuItem { Header = Localized("Capture another", "继续截图") };
        more.Click += async (_, _) => await CaptureScreenshotSegmentAsync();
        var finish = new MenuItem { Header = Localized("Finish and analyze", "完成并分析"), FontWeight = FontWeights.SemiBold };
        finish.Click += async (_, _) => await FinishScreenshotSessionAsync();
        var clear = new MenuItem { Header = Localized("Discard screenshots", "放弃这些截图") };
        clear.Click += (_, _) => { _screenshotSegments.Clear(); RefreshTurns(showLatest: true); };
        menu.Items.Add(count); menu.Items.Add(new Separator()); menu.Items.Add(more); menu.Items.Add(finish); menu.Items.Add(clear);
        menu.IsOpen = true;
    }

    private async Task FinishScreenshotSessionAsync()
    {
        if (_screenshotSegments.Count == 0 || _screenshotBusy) return;
        _screenshotBusy = true;
        ScreenshotSessionPanel.Visibility = Visibility.Collapsed;
        QuestionText.Text = Localized("Reading screenshot…", "正在识别截图…");
        PreparingText.Text = Localized("Extracting the visible question…", "正在提取可见题目…");
        AnswerScroller.Visibility = Visibility.Collapsed;
        PreparingPanel.Visibility = Visibility.Visible;
        var captured = _screenshotSegments.ToArray();
        var recognized = new List<(string Path, string Text)>();
        try
        {
            foreach (var segment in captured)
            {
                var text = await RecognizeScreenshotAsync(segment.Path);
                recognized.Add((segment.Path, text));
            }
        }
        catch (Exception exception)
        {
            ShowMessage(Localized("Screenshot analysis failed: ", "截图分析失败：") + exception.Message, true);
            ShowScreenshotSessionControls();
            _screenshotBusy = false;
            return;
        }
        var segments = recognized.ToArray();
        _screenshotSegments.Clear();
        _screenshotBusy = false;
        var question = string.Join("\n\n", segments.Select((item, index) => $"[Screenshot {index + 1}]\n{item.Text}"));
        if (_isDirectorMode) { DirectorQuestionCaptured?.Invoke(question); return; }
        await SubmitQuestionAsync(question, fromScreenshot: true);
        if (_turnIndex >= 0 && _turnIndex < _session.Turns.Count)
        {
            _session.Turns[_turnIndex].ScreenshotPath = segments[0].Path;
            _session.Turns[_turnIndex].ScreenshotPaths = segments.Select(item => item.Path).ToList();
            _store.ScheduleSave();
        }
    }

    public async Task CaptureAndAnalyzeScreenshotAsync()
    {
        // Keep toolbar clicks and the global shortcut on the same visible multi-shot flow.
        await CaptureScreenshotSegmentAsync();
    }

    private async Task<string?> CaptureScreenshotImageAsync()
    {
        Rect region;
        if (_store.Data.Preferences.ScreenshotMode is "selectRegion" or "manualSelect")
        {
            var selector = new RegionSelectionWindow { Owner = Application.Current.MainWindow };
            if (selector.ShowDialog() != true) return null;
            region = selector.SelectedRegion;
        }
        else
        {
            region = ScreenshotCaptureService.PresetRegion();
            if (region.Width < 24 || region.Height < 24)
            {
                ShowMessage(Localized("Set a screenshot region in Settings first.", "请先在设置中设定截图区域。"), true);
                return null;
            }
        }
        // Let the translucent selection window leave the compositor before copying pixels.
        await Task.Delay(140);
        var path = ScreenshotCaptureService.Capture(region);
        ScreenshotRequested?.Invoke();
        return path;
    }

    private async Task<string> RecognizeScreenshotAsync(string path)
    {
        var ocrTask = WindowsOcrService.RecognizeAsync(path);
        var ocr = "";
        if (await Task.WhenAny(ocrTask, Task.Delay(TimeSpan.FromSeconds(6))) == ocrTask)
        {
            try { ocr = await ocrTask; } catch { }
        }

        var language = InterviewPromptBuilder.IsChinese(AnswerLanguageCode()) ? "Simplified Chinese" : "English";
        var instruction = $"""
            Transcribe the complete question shown in this screenshot, including its question stem and every visible answer option.
            Return only the faithfully reconstructed question text; do not answer it, summarize it, describe the image, or infer that it is a skills checklist.
            Preserve option labels such as A, B, C and D. Prefer the image whenever the OCR hint is incomplete.
            The later answer will be written in {language}.

            OCR hint (may be incomplete or wrong):
            {ocr}
            """;
        var result = "";
        using (var visionTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(18)))
        {
            try { result = await AppServices.Current.AI.AnalyzeImageAsync(CurrentAIConfig(), path, instruction, visionTimeout.Token); }
            catch { result = ""; }
        }
        result = string.IsNullOrWhiteSpace(result) ? ocr : result.Trim();
        if (string.IsNullOrWhiteSpace(result))
            throw new TimeoutException(Localized("No readable question was found within 24 seconds. Try a smaller, clearer region.", "24 秒内未识别到清晰题目，请缩小截图范围后重试。"));
        return result;
    }

    private void ShowScreenshotSessionControls()
    {
        ScreenshotCountText.Text = Localized(
            $"Captured {_screenshotSegments.Count} screenshot(s)",
            $"获取{_screenshotSegments.Count}张截图");
        ScreenshotSessionPanel.Visibility = Visibility.Visible;
        PreparingPanel.Visibility = Visibility.Collapsed;
        AnswerScroller.Visibility = Visibility.Visible;
    }

    private async void ScreenshotAddButton_Click(object sender, RoutedEventArgs e) => await CaptureScreenshotSegmentAsync();
    private async void ScreenshotFinishButton_Click(object sender, RoutedEventArgs e) => await FinishScreenshotSessionAsync();
    private void ScreenshotDiscardButton_Click(object sender, RoutedEventArgs e)
    {
        if (_screenshotBusy) return;
        _screenshotSegments.Clear();
        ScreenshotSessionPanel.Visibility = Visibility.Collapsed;
        RefreshTurns(showLatest: true);
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

    private void SpeechRecognition_Recognized(string text)
    {
        if (_audioMode == PrompterAudioMode.Muted) return;
        if (_isDirectorMode)
        {
            DirectorQuestionCaptured?.Invoke(text);
            return;
        }
        if (LooksLikeAnswerEcho(text)) return;
        _pendingSpeechQuestion = MergeSpeechFragments(_pendingSpeechQuestion, text);
        _speechDebounceTimer.Stop();
        _speechDebounceTimer.Start();
    }

    private async Task SubmitRecognizedQuestionAsync(string text)
    {
        if (!_speechSubmissionGate.Wait(0)) return;
        try
        {
            if (_aiEnabled) await SubmitQuestionAsync(text);
            else
            {
                _session.Turns.Add(new ConversationTurnModel { Question = text, SpeakerLabel = "interviewer" });
                _turnIndex = _session.Turns.Count - 1;
                _store.ScheduleSave();
                RefreshTurns(showLatest: true);
            }
        }
        finally { _speechSubmissionGate.Release(); }
    }

    private bool LooksLikeAnswerEcho(string text)
    {
        if (_turnIndex < 0 || _turnIndex >= _session.Turns.Count) return false;
        var answer = _session.Turns[_turnIndex].Answer;
        var candidate = NormalizeSpeech(text);
        var source = NormalizeSpeech(answer);
        if (candidate.Length < 8 || source.Length < 12) return false;
        if (source.Contains(candidate, StringComparison.OrdinalIgnoreCase)) return true;
        var pieces = candidate.Chunk(Math.Max(4, candidate.Length / 3)).Select(chars => new string(chars)).ToArray();
        return pieces.Length > 0 && pieces.Count(piece => source.Contains(piece, StringComparison.OrdinalIgnoreCase)) >= Math.Max(1, pieces.Length - 1);
    }

    private static string MergeSpeechFragments(string existing, string next)
    {
        existing = existing.Trim();
        next = next.Trim();
        if (existing.Length == 0) return next;
        if (existing.Contains(next, StringComparison.OrdinalIgnoreCase)) return existing;
        if (next.Contains(existing, StringComparison.OrdinalIgnoreCase)) return next;
        var maxOverlap = Math.Min(existing.Length, next.Length);
        for (var length = maxOverlap; length >= 2; length--)
        {
            if (existing.EndsWith(next[..length], StringComparison.OrdinalIgnoreCase)) return existing + next[length..];
        }
        return existing + (NeedsSpeechSeparator(existing, next) ? " " : "") + next;
    }

    private static bool NeedsSpeechSeparator(string left, string right) =>
        left.Length > 0 && right.Length > 0 && left[^1] <= 127 && right[0] <= 127;

    private static string NormalizeSpeech(string value) =>
        new(value.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());

    private void SpeechRecognition_CandidateSpeechDetected(string text)
    {
        if (_audioMode == PrompterAudioMode.Muted) return;
        Dispatcher.BeginInvoke(new Action(() => QuestionText.Text = Localized("🙋 You are answering", "🙋 你在作答")));
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
        var menu = new ContextMenu { PlacementTarget = AiKnowledgeButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        foreach (var knowledgeBase in _store.Data.KnowledgeBases)
        {
            var item = new MenuItem { Header = knowledgeBase.Name, IsCheckable = true, IsChecked = _session.ActiveKnowledgeBaseIds.Contains(knowledgeBase.Id), StaysOpenOnClick = true };
            item.Click += (_, _) =>
            {
                if (item.IsChecked && !_session.ActiveKnowledgeBaseIds.Contains(knowledgeBase.Id)) _session.ActiveKnowledgeBaseIds.Add(knowledgeBase.Id);
                else if (!item.IsChecked) _session.ActiveKnowledgeBaseIds.Remove(knowledgeBase.Id);
                KnowledgeCountText.Text = _session.ActiveKnowledgeBaseIds.Count.ToString();
                _store.ScheduleSave();
            };
            menu.Items.Add(item);
        }
        if (menu.Items.Count > 0) menu.Items.Add(new Separator());
        var manage = new MenuItem { Header = Localized("Manage knowledge bases…", "管理知识库…") };
        manage.Click += (_, _) =>
        {
            if (Application.Current.MainWindow?.DataContext is MainViewModel mainViewModel) mainViewModel.NavigateTo("Knowledge Base");
            Application.Current.MainWindow?.Show(); Application.Current.MainWindow?.Activate();
        };
        menu.Items.Add(manage);
        menu.IsOpen = true;
    }

    private void MoreButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = MoreButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        var smaller = new MenuItem { Header = Localized("Smaller text", "缩小字体") };
        smaller.Click += (_, _) => { _answerFontSize = Math.Max(12, _answerFontSize - 1); RefreshTurns(false); };
        var larger = new MenuItem { Header = Localized("Larger text", "放大字体") };
        larger.Click += (_, _) => { _answerFontSize = Math.Min(28, _answerFontSize + 1); RefreshTurns(false); };
        var auto = new MenuItem { Header = Localized("Auto-scroll", "自动滚动"), IsCheckable = true, IsChecked = _autoScroll };
        auto.Click += (_, _) => _autoScroll = auto.IsChecked;
        var ai = new MenuItem { Header = Localized("AI answers enabled", "启用 AI 回答"), IsCheckable = true, IsChecked = _aiEnabled };
        ai.Click += (_, _) => _aiEnabled = ai.IsChecked;
        var pin = new MenuItem { Header = Localized("Always on top", "始终置顶"), IsCheckable = true, IsChecked = Topmost };
        pin.Click += (_, _) => Topmost = pin.IsChecked;
        var copy = new MenuItem { Header = Localized("Copy current answer", "复制当前回答"), IsEnabled = _turnIndex >= 0 && _turnIndex < _session.Turns.Count };
        copy.Click += (_, _) => { if (_turnIndex >= 0 && _turnIndex < _session.Turns.Count) Clipboard.SetText(_session.Turns[_turnIndex].Answer ?? ""); };
        var history = new MenuItem { Header = Localized("Open history", "打开历史记录") };
        history.Click += (_, _) => { if (Application.Current.MainWindow?.DataContext is MainViewModel vm) vm.NavigateTo("History"); Application.Current.MainWindow?.Show(); Application.Current.MainWindow?.Activate(); };
        menu.Items.Add(smaller); menu.Items.Add(larger); menu.Items.Add(auto); menu.Items.Add(ai); menu.Items.Add(pin); menu.Items.Add(new Separator()); menu.Items.Add(copy); menu.Items.Add(history);
        menu.IsOpen = true;
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
