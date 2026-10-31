using System.ComponentModel;
using System.IO;
using System.Speech.Synthesis;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using InterviewAssistant.Models;
using InterviewAssistant.Services;

namespace InterviewAssistant.Windows;

public partial class MockInterviewWindow : Window
{
    private readonly MockInterviewLaunchConfig _config;
    private readonly AppDataStore _store = AppServices.Current.DataStore;
    private readonly SpeechRecognitionService _speech = new();
    private readonly SpeechSynthesizer _speaker = new();
    private readonly CancellationTokenSource _cancellation = new();
    private List<MockQuestionDraft> _questions = [];
    private InterviewSessionModel? _session;
    private int _currentIndex;
    private bool _isRecording;

    public MockInterviewWindow(MockInterviewLaunchConfig config)
    {
        _config = config;
        InitializeComponent();
        Loaded += async (_, _) => await StartInterviewAsync();
        _speech.Recognized += Speech_Recognized;
        _speech.PartialRecognized += text => Dispatcher.BeginInvoke(new Action(() => SpeechStatusText.Text = text));
        _speech.StatusChanged += text => Dispatcher.BeginInvoke(new Action(() => SpeechStatusText.Text = text));
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        _cancellation.Cancel();
        _speech.Dispose();
        try { _speaker.SpeakAsyncCancelAll(); _speaker.Dispose(); } catch { }
        if (_session is { EndedAt: null })
        {
            _session.EndedAt = DateTimeOffset.Now;
            _session.UpdatedAt = DateTimeOffset.Now;
            _store.ScheduleSave();
        }
        base.OnClosing(e);
    }

    private async Task StartInterviewAsync()
    {
        SetVisiblePanel(LoadingPanel);
        try
        {
            var context = BuildContext();
            try
            {
                _questions = await GenerateQuestionsAsync(context, _cancellation.Token);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                _questions = FallbackQuestions();
                SpeechStatusText.Text = exception.Message;
            }
            if (_questions.Count == 0) _questions = FallbackQuestions();
            _session = new InterviewSessionModel
            {
                Title = $"{LocalizationManager.Text("Mock Interview")} - {_config.Role}",
                Role = _config.Role,
                Context = context,
                ActiveKnowledgeBaseIds = _config.ActiveKnowledgeBaseIds.ToList(),
                Kind = "mock"
            };
            _store.Data.Sessions.Add(_session);
            _store.ScheduleSave();
            _currentIndex = 0;
            ShowCurrentQuestion();
            SetVisiblePanel(InterviewPanel);
            SpeakCurrentQuestion();
        }
        catch (OperationCanceledException) { }
        catch (Exception exception)
        {
            ErrorText.Text = exception.Message;
            SetVisiblePanel(ErrorPanel);
        }
    }

    private async Task<List<MockQuestionDraft>> GenerateQuestionsAsync(string context, CancellationToken cancellationToken)
    {
        var language = OutputLanguage();
        var prompt = $$"""
            Generate {{_config.QuestionCount}} realistic interview questions for a mock interview.
            Role: {{_config.Role}}
            Job description: {{_config.JobDescription}}
            Interviewer language: {{language}}
            Include behavioral, project deep-dive, and role-specific questions. Use the candidate context for personal questions.
            Return strict JSON only: {"questions":[{"category":"Project Deep Dive","question":"..."}]}

            Context:
            {{context}}
            """;
        var raw = await AppServices.Current.AI.CompleteAsync(CurrentAIConfig(), $"You are a realistic interviewer. Return valid JSON only in {language}.", prompt, 1800, cancellationToken);
        var decoded = JsonSerializer.Deserialize<MockQuestionEnvelope>(ExtractJson(raw), JsonOptions);
        return decoded?.Questions?.Where(item => !string.IsNullOrWhiteSpace(item.Question)).Take(_config.QuestionCount).ToList() ?? [];
    }

    private void ShowCurrentQuestion()
    {
        var question = _questions[_currentIndex];
        ProgressText.Text = $"{LocalizationManager.Text("Question")} {_currentIndex + 1} / {_questions.Count}";
        ProgressPercentText.Text = $"{(_currentIndex + 1) * 100 / _questions.Count}%";
        InterviewProgress.Value = (double)(_currentIndex + 1) / _questions.Count;
        QuestionText.Text = question.Question;
        CategoryText.Text = question.Category;
        CategoryBadge.Visibility = string.IsNullOrWhiteSpace(question.Category) ? Visibility.Collapsed : Visibility.Visible;
        AnswerBox.Text = "";
        SubmitButtonText.Text = _currentIndex == _questions.Count - 1
            ? LocalizationManager.Text("Submit Interview")
            : LocalizationManager.Text("Submit Answer");
        SpeechStatusText.Text = LocalizationManager.Text("Ready to record");
    }

    private async void RecordButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isRecording)
        {
            StopRecording();
            return;
        }
        _speaker.SpeakAsyncCancelAll();
        _isRecording = await _speech.StartAsync(SpeechLanguageCode());
        UpdateRecordButton();
    }

    private void StopRecording()
    {
        _speech.Stop();
        _isRecording = false;
        UpdateRecordButton();
    }

    private void UpdateRecordButton()
    {
        RecordButtonText.Text = LocalizationManager.Text(_isRecording ? "Stop Recording" : "Start Recording");
        RecordIcon.Text = _isRecording ? "\uE71A" : "\uE720";
    }

    private void Speech_Recognized(string text)
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            var clean = text.Trim();
            if (clean.Length == 0) return;
            AnswerBox.Text = string.IsNullOrWhiteSpace(AnswerBox.Text) ? clean : $"{AnswerBox.Text.TrimEnd()} {clean}";
            AnswerBox.CaretIndex = AnswerBox.Text.Length;
            AnswerBox.ScrollToEnd();
            SpeechStatusText.Text = LocalizationManager.Text("Speech recognized");
        }));
    }

    private async void SubmitAnswer_Click(object sender, RoutedEventArgs e)
    {
        if (_session is null) return;
        StopRecording();
        var answer = AnswerBox.Text.Trim();
        if (answer.Length == 0)
        {
            SpeechStatusText.Text = LocalizationManager.Text("Record or type an answer first.");
            return;
        }
        var question = _questions[_currentIndex];
        _session.Turns.Add(new ConversationTurnModel { Question = question.Question, Category = question.Category, Answer = answer, SpeakerLabel = "candidate" });
        _session.UpdatedAt = DateTimeOffset.Now;
        _store.ScheduleSave();
        if (_currentIndex < _questions.Count - 1)
        {
            _currentIndex++;
            ShowCurrentQuestion();
            SpeakCurrentQuestion();
            return;
        }
        SetVisiblePanel(EvaluatingPanel);
        await EvaluateAsync();
    }

    private async Task EvaluateAsync()
    {
        if (_session is null) return;
        try
        {
            var interview = string.Join("\n\n", _session.Turns.Select((turn, index) => $"Q{index + 1} [{turn.Category}] {turn.Question}\nAnswer: {turn.Answer}"));
            var prompt = $$"""
                Evaluate this mock interview for role "{{_session.Role}}" in {{OutputLanguage()}}.
                Give specific coaching based on the candidate's actual answers. Return strict JSON only:
                {"overallScore":76,"summary":"...","strengths":["..."],"improvements":["..."],"questions":[{"index":1,"score":80,"feedback":"...","suggestedAnswer":"..."}]}
                Include one questions item for every question.

                Interview:
                {{interview}}

                Context:
                {{_session.Context}}
                """;
            var raw = await AppServices.Current.AI.CompleteAsync(CurrentAIConfig(), "You are a senior interview coach. Return valid JSON only.", prompt, 3600, _cancellation.Token);
            ApplyEvaluation(raw);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            ApplyFallbackEvaluation(exception.Message);
        }
        _session.EndedAt = DateTimeOffset.Now;
        _session.UpdatedAt = DateTimeOffset.Now;
        await _store.SaveAsync();
        ShowResults();
    }

    private void ApplyEvaluation(string raw)
    {
        if (_session is null) return;
        var evaluation = JsonSerializer.Deserialize<MockEvaluation>(ExtractJson(raw), JsonOptions)
            ?? throw new InvalidDataException("The evaluation response was not valid JSON.");
        _session.OverallScore = Math.Clamp(evaluation.OverallScore, 0, 100);
        _session.SummaryFeedback = evaluation.Summary ?? "";
        _session.StrengthsText = BulletList(evaluation.Strengths);
        _session.ImprovementsText = BulletList(evaluation.Improvements);
        foreach (var item in evaluation.Questions ?? [])
        {
            var index = item.Index - 1;
            if (index < 0 || index >= _session.Turns.Count) continue;
            _session.Turns[index].Score = Math.Clamp(item.Score, 0, 100);
            _session.Turns[index].Feedback = item.Feedback ?? "";
            _session.Turns[index].SuggestedAnswer = item.SuggestedAnswer ?? "";
        }
        FillMissingEvaluation();
    }

    private void ApplyFallbackEvaluation(string error)
    {
        if (_session is null) return;
        var scores = _session.Turns.Select(turn => turn.Answer.Length switch { < 30 => 48, < 100 => 64, _ => 74 }).ToArray();
        _session.OverallScore = scores.Length == 0 ? 0 : (int)scores.Average();
        _session.SummaryFeedback = $"{LocalizationManager.Text("Evaluation complete.")} {error}";
        _session.StrengthsText = "• " + LocalizationManager.Text("Completed the mock interview with recorded answers.");
        _session.ImprovementsText = "• " + LocalizationManager.Text("Use the STAR structure and add concrete evidence to every answer.");
        for (var index = 0; index < _session.Turns.Count; index++)
        {
            _session.Turns[index].Score = scores[index];
            _session.Turns[index].Feedback = LocalizationManager.Text("Add clearer context, your specific actions, and measurable results.");
            _session.Turns[index].SuggestedAnswer = LocalizationManager.Text("Rewrite this answer with Situation, Task, Action, and Result, then connect it to the target role.");
        }
    }

    private void FillMissingEvaluation()
    {
        if (_session is null) return;
        if (string.IsNullOrWhiteSpace(_session.SummaryFeedback)) _session.SummaryFeedback = LocalizationManager.Text("Evaluation complete.");
        if (string.IsNullOrWhiteSpace(_session.StrengthsText)) _session.StrengthsText = "• " + LocalizationManager.Text("Completed the mock interview with recorded answers.");
        if (string.IsNullOrWhiteSpace(_session.ImprovementsText)) _session.ImprovementsText = "• " + LocalizationManager.Text("Use the STAR structure and add concrete evidence to every answer.");
        foreach (var turn in _session.Turns)
        {
            if (turn.Score <= 0) turn.Score = turn.Answer.Length < 60 ? 55 : 70;
            if (string.IsNullOrWhiteSpace(turn.Feedback)) turn.Feedback = LocalizationManager.Text("Add clearer context, your specific actions, and measurable results.");
            if (string.IsNullOrWhiteSpace(turn.SuggestedAnswer)) turn.SuggestedAnswer = LocalizationManager.Text("Rewrite this answer with Situation, Task, Action, and Result, then connect it to the target role.");
        }
    }

    private void ShowResults()
    {
        if (_session is null) return;
        ScoreText.Text = _session.OverallScore.ToString();
        SummaryText.Text = _session.SummaryFeedback;
        StrengthsText.Text = _session.StrengthsText;
        ImprovementsText.Text = _session.ImprovementsText;
        ReviewList.ItemsSource = _session.Turns;
        SetVisiblePanel(ResultsPanel);
    }

    private void SpeakCurrentQuestion()
    {
        try
        {
            _speaker.SpeakAsyncCancelAll();
            _speaker.Rate = 0;
            var language = SpeechLanguageCode() == "zh-Hans" ? "zh-CN" : "en-US";
            var voice = _speaker.GetInstalledVoices()
                .FirstOrDefault(item => item.Enabled && item.VoiceInfo.Culture.Name.Equals(language, StringComparison.OrdinalIgnoreCase));
            if (voice is not null) _speaker.SelectVoice(voice.VoiceInfo.Name);
            _speaker.SpeakAsync(_questions[_currentIndex].Question);
        }
        catch (Exception exception) { SpeechStatusText.Text = exception.Message; }
    }

    private string BuildContext()
    {
        var kb = _store.Data.KnowledgeBases
            .Where(item => _config.ActiveKnowledgeBaseIds.Contains(item.Id))
            .SelectMany(item => item.Entries.Where(entry => entry.IsEnabled))
            .Select(entry => $"【{entry.Title}】\n{entry.Content}");
        var text = $"Target role: {_config.Role}\n\nJob description:\n{_config.JobDescription}\n\nCandidate knowledge base:\n{string.Join("\n\n", kb)}";
        return text.Length > 16000 ? text[..16000] : text;
    }

    private List<MockQuestionDraft> FallbackQuestions()
    {
        var role = _config.Role;
        if (OutputLanguage() == "Simplified Chinese")
        {
            return new List<MockQuestionDraft>
            {
                new("自我介绍", $"请介绍一下你自己，并说明为什么对 {role} 这个岗位感兴趣。"),
                new("项目经历", "请介绍一个与你申请岗位最相关的项目，以及你在其中承担的具体工作。"),
                new("问题解决", "请讲述一个你遇到的困难问题，以及你是如何解决它的。"),
                new("团队协作", "请分享一次你处理团队分歧或沟通冲突的经历。"),
                new("岗位理解", $"如果你入职成为 {role}，前九十天会优先完成哪些事情？"),
                new("自我反思", "你目前正在主动改善的一项职业弱点是什么？"),
                new("影响力", "请讲述一次你在没有正式职权的情况下推动他人达成目标的经历。"),
                new("优先级", "当多个紧急任务同时出现时，你如何判断优先级并保证交付质量？"),
                new("学习能力", $"请分享一次你快速学习新知识并将它应用到 {role} 相关工作中的经历。"),
                new("职业动机", "你为什么想离开目前的岗位，以及你希望下一份工作带来什么？")
            }.Take(_config.QuestionCount).ToList();
        }
        return new List<MockQuestionDraft>
        {
            new("Introduction", $"Please introduce yourself and explain why you are interested in the {role} role."),
            new("Experience", "Tell me about the most relevant project you have completed."),
            new("Problem Solving", "Describe a difficult problem you faced and how you solved it."),
            new("Collaboration", "Tell me about a time you handled disagreement in a team."),
            new("Role Specific", $"What would be your priorities in your first 90 days as a {role}?"),
            new("Reflection", "What is one professional weakness you are actively improving?"),
            new("Influence", "Tell me about a time you influenced others without formal authority."),
            new("Prioritization", "How do you prioritize when several urgent tasks arrive at the same time?"),
            new("Learning", $"Describe a time you quickly learned something new and applied it to work relevant to {role}."),
            new("Motivation", "Why are you considering leaving your current role, and what are you looking for next?")
        }.Take(_config.QuestionCount).ToList();
    }

    private AIConfig CurrentAIConfig()
    {
        if (!Enum.TryParse<AIProvider>(_store.Data.Preferences.Provider, true, out var provider)) provider = AIProvider.DeepSeek;
        var settings = _store.GetProviderSettings(provider);
        var key = AppServices.Current.Credentials.Read(provider.ToString().ToLowerInvariant());
        return new AIConfig(provider, settings.ApiUrl, key, settings.Model);
    }

    private string OutputLanguage()
    {
        var language = _config.Language.Equals("followApp", StringComparison.OrdinalIgnoreCase) ? _store.Data.Preferences.Language : _config.Language;
        return language.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "Simplified Chinese" : "English";
    }

    private string SpeechLanguageCode() => OutputLanguage() == "Simplified Chinese" ? "zh-Hans" : "en";

    private static string ExtractJson(string raw)
    {
        var first = raw.IndexOf('{');
        var last = raw.LastIndexOf('}');
        return first >= 0 && last > first ? raw[first..(last + 1)] : raw.Trim();
    }

    private static string BulletList(IEnumerable<string>? values) => string.Join("\n", (values ?? []).Where(value => !string.IsNullOrWhiteSpace(value)).Select(value => $"• {value.Trim()}"));

    private void SetVisiblePanel(UIElement panel)
    {
        foreach (var item in new UIElement[] { LoadingPanel, InterviewPanel, EvaluatingPanel, ResultsPanel, ErrorPanel }) item.Visibility = ReferenceEquals(item, panel) ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ClearAnswer_Click(object sender, RoutedEventArgs e) => AnswerBox.Clear();
    private void ReplayQuestion_Click(object sender, RoutedEventArgs e) => SpeakCurrentQuestion();
    private async void RetryButton_Click(object sender, RoutedEventArgs e) => await StartInterviewAsync();
    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e) { if (e.LeftButton == MouseButtonState.Pressed) DragMove(); }

    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private sealed record MockQuestionDraft(string Category, string Question);
    private sealed record MockQuestionEnvelope(List<MockQuestionDraft>? Questions);
    private sealed record MockEvaluation(int OverallScore, string? Summary, List<string>? Strengths, List<string>? Improvements, List<MockQuestionEvaluation>? Questions);
    private sealed record MockQuestionEvaluation(int Index, int Score, string? Feedback, string? SuggestedAnswer);
}
