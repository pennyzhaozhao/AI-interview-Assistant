using Microsoft.Win32;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using InterviewAssistant.Services;

namespace InterviewAssistant.Windows;

public partial class QuestionBankEditorWindow : Window
{
    private readonly QuestionBankDocument _document;
    private Point _dragStart;

    public QuestionBankEditorWindow(string title, string content)
    {
        InitializeComponent();
        Resources["QuestionBankEditorTitle"] = LocalizationManager.Text("Edit Q&A Bank");
        Resources["QuestionBankEditorHint"] = LocalizationManager.Text("Create primary questions and answers, then add ordered follow-ups under each one.");
        Resources["BatchImportText"] = LocalizationManager.Text("Batch paste import");
        Resources["UploadQuestionFileText"] = LocalizationManager.Text("Upload question file");
        Resources["AddPrimaryQuestionText"] = LocalizationManager.Text("Add primary question");
        Resources["NoQuestionsText"] = LocalizationManager.Text("No questions yet");
        Resources["NoQuestionsHint"] = LocalizationManager.Text("Add a primary question or paste a batch for AI to organize.");
        Resources["CancelText"] = LocalizationManager.Text("Cancel");
        Resources["SaveText"] = LocalizationManager.Text("Save");
        TitleBox.Text = title;
        _document = QuestionBankService.Decode(content);
        RenderQuestions();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; Save(); } };
    }

    public string EntryTitle => string.IsNullOrWhiteSpace(TitleBox.Text) ? LocalizationManager.Text("Interview Q&A Bank") : TitleBox.Text.Trim();
    public string EntryContent => QuestionBankService.Encode(CleanedDocument());

    private void RenderQuestions()
    {
        QuestionPanel.Children.Clear();
        EmptyPanel.Visibility = _document.Questions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        for (var index = 0; index < _document.Questions.Count; index++) QuestionPanel.Children.Add(BuildPrimaryCard(_document.Questions[index], index));
    }

    private Border BuildPrimaryCard(QuestionBankPrimary item, int index)
    {
        var expander = new Expander { IsExpanded = true };
        var header = new Grid { Cursor = Cursors.SizeAll };
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new()); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var drag = new TextBlock { Text = "⋮⋮", FontSize = 18, Foreground = Brush("TextSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
        header.Children.Add(drag);
        var title = new TextBlock { Text = string.IsNullOrWhiteSpace(item.Question) ? LocalizationManager.Text("Untitled primary question") : item.Question, FontSize = 15, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(title, 1); header.Children.Add(title);
        var count = new TextBlock { Text = string.Format(LocalizationManager.Text("{0} follow-ups"), item.FollowUps.Count), Foreground = Brush("TextSecondaryBrush"), FontSize = 12, Margin = new Thickness(10, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(count, 2); header.Children.Add(count);
        expander.Header = header;

        var body = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
        body.Children.Add(Label("Primary question"));
        var question = Input(item.Question, false); question.TextChanged += (_, _) => { item.Question = question.Text; title.Text = question.Text.Length == 0 ? LocalizationManager.Text("Untitled primary question") : question.Text; };
        body.Children.Add(question); body.Children.Add(Label("Answer"));
        var answer = Input(item.Answer, true); answer.TextChanged += (_, _) => item.Answer = answer.Text; body.Children.Add(answer);
        var followHeader = new Grid { Margin = new Thickness(0, 16, 0, 8) };
        followHeader.Children.Add(new TextBlock { Text = LocalizationManager.Text("Follow-ups"), FontSize = 15, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var addFollow = SmallButton(LocalizationManager.Text("Add follow-up")); addFollow.HorizontalAlignment = HorizontalAlignment.Right;
        addFollow.Click += (_, _) => { item.FollowUps.Add(new()); RenderQuestions(); };
        followHeader.Children.Add(addFollow); body.Children.Add(followHeader);
        for (var followIndex = 0; followIndex < item.FollowUps.Count; followIndex++) body.Children.Add(BuildFollowUpCard(item, item.FollowUps[followIndex], index, followIndex));
        expander.Content = body;

        var card = new Border { Background = Brush("SurfaceBrush"), BorderBrush = Brush("BorderBrush"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16), Padding = new Thickness(16), Margin = new Thickness(0, 0, 0, 12), Child = expander, AllowDrop = true, Tag = item.Id };
        header.PreviewMouseLeftButtonDown += (_, e) => _dragStart = e.GetPosition(this);
        header.PreviewMouseMove += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed && (e.GetPosition(this) - _dragStart).Length > 6) DragDrop.DoDragDrop(header, new DataObject("QuestionBankPrimary", item.Id), DragDropEffects.Move); };
        card.DragOver += (_, e) => { if (e.Data.GetDataPresent("QuestionBankPrimary")) e.Effects = DragDropEffects.Move; e.Handled = true; };
        card.Drop += (_, e) => { if (e.Data.GetData("QuestionBankPrimary") is Guid id) MovePrimary(id, item.Id); };
        return card;
    }

    private Border BuildFollowUpCard(QuestionBankPrimary parent, QuestionBankFollowUp follow, int parentIndex, int followIndex)
    {
        var grid = new Grid(); grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new()); grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var drag = new TextBlock { Text = "⋮⋮", FontSize = 17, Cursor = Cursors.SizeAll, Foreground = Brush("TextSecondaryBrush"), Margin = new Thickness(0, 4, 10, 0) };
        grid.Children.Add(drag);
        var fields = new StackPanel(); fields.Children.Add(new TextBlock { Text = $"{LocalizationManager.Text("Follow-up")} {parentIndex + 1}.{followIndex + 1}", FontSize = 12, Foreground = Brush("TextSecondaryBrush"), Margin = new Thickness(0, 0, 0, 7) });
        fields.Children.Add(Label("Follow-up question")); var question = Input(follow.Question, false); question.TextChanged += (_, _) => follow.Question = question.Text; fields.Children.Add(question);
        fields.Children.Add(Label("Follow-up answer")); var answer = Input(follow.Answer, true); answer.TextChanged += (_, _) => follow.Answer = answer.Text; fields.Children.Add(answer);
        Grid.SetColumn(fields, 1); grid.Children.Add(fields);
        var remove = SmallButton("×"); remove.Width = 34; remove.Foreground = Brush("DangerBrush"); remove.Margin = new Thickness(10, 0, 0, 0); remove.VerticalAlignment = VerticalAlignment.Top;
        remove.Click += (_, _) => { parent.FollowUps.Remove(follow); RenderQuestions(); }; Grid.SetColumn(remove, 2); grid.Children.Add(remove);
        var card = new Border { Background = Brush("InputBrush"), CornerRadius = new CornerRadius(13), Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 9), Child = grid, AllowDrop = true };
        drag.PreviewMouseLeftButtonDown += (_, e) => _dragStart = e.GetPosition(this);
        drag.PreviewMouseMove += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed && (e.GetPosition(this) - _dragStart).Length > 6) DragDrop.DoDragDrop(drag, new DataObject("QuestionBankFollowUp", $"{parent.Id}|{follow.Id}"), DragDropEffects.Move); };
        card.DragOver += (_, e) => { if (e.Data.GetDataPresent("QuestionBankFollowUp")) e.Effects = DragDropEffects.Move; e.Handled = true; };
        card.Drop += (_, e) => { if (e.Data.GetData("QuestionBankFollowUp") is string value) MoveFollowUp(value, parent.Id, follow.Id); };
        return card;
    }

    private TextBlock Label(string key) => new() { Text = LocalizationManager.Text(key), FontSize = 12, Foreground = Brush("TextSecondaryBrush"), Margin = new Thickness(2, 7, 0, 5) };
    private TextBox Input(string text, bool multiline)
    {
        var box = new TextBox { Text = text, TextWrapping = TextWrapping.Wrap, AcceptsReturn = multiline, MinHeight = multiline ? 84 : 40, VerticalContentAlignment = multiline ? VerticalAlignment.Top : VerticalAlignment.Center, Padding = new Thickness(11, 7, 11, 7), BorderThickness = new Thickness(1), BorderBrush = Brush("BorderBrush"), Background = Brush("InputBrush"), Foreground = Brush("TextPrimaryBrush") };
        if (multiline) box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        return box;
    }
    private Button SmallButton(string text) => new() { Content = text, Height = 34, Padding = new Thickness(12, 0, 12, 0), Style = (Style)FindResource("SecondaryButtonStyle") };
    private Brush Brush(string key) => (Brush)FindResource(key);

    private void MovePrimary(Guid source, Guid target)
    {
        var from = _document.Questions.FindIndex(item => item.Id == source); var to = _document.Questions.FindIndex(item => item.Id == target);
        if (from < 0 || to < 0 || from == to) return; var item = _document.Questions[from]; _document.Questions.RemoveAt(from); _document.Questions.Insert(to, item); RenderQuestions();
    }
    private void MoveFollowUp(string sourceValue, Guid targetParent, Guid target)
    {
        var parts = sourceValue.Split('|'); if (parts.Length != 2 || !Guid.TryParse(parts[0], out var sourceParent) || !Guid.TryParse(parts[1], out var source)) return;
        var fromParent = _document.Questions.FirstOrDefault(item => item.Id == sourceParent); var toParent = _document.Questions.FirstOrDefault(item => item.Id == targetParent); if (fromParent is null || toParent is null) return;
        var item = fromParent.FollowUps.FirstOrDefault(value => value.Id == source); var to = toParent.FollowUps.FindIndex(value => value.Id == target); if (item is null || to < 0) return;
        fromParent.FollowUps.Remove(item); toParent.FollowUps.Insert(Math.Min(to, toParent.FollowUps.Count), item); RenderQuestions();
    }

    private async void BatchImport_Click(object sender, RoutedEventArgs e)
    {
        var input = new QuestionBankImportWindow { Owner = this }; if (input.ShowDialog() != true) return; await ImportAsync(input.ImportText);
    }
    private async void Upload_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = LocalizationManager.Text("Upload question file"), Filter = "Text documents|*.txt;*.md;*.json;*.csv;*.docx;*.pdf|All files|*.*" };
        if (dialog.ShowDialog(this) != true) return;
        try { await ImportAsync(await DocumentTextImporter.ExtractTextAsync(dialog.FileName, 30_000)); }
        catch (Exception exception) { StatusText.Text = exception.Message; }
    }
    private async Task ImportAsync(string input)
    {
        if (string.IsNullOrWhiteSpace(input)) return;
        if (!KnowledgeAssistant.IsAIConfigured()) { StatusText.Text = LocalizationManager.Text("Set up an AI provider in Settings before using batch import."); return; }
        StatusText.Text = LocalizationManager.Text("Organizing questions with AI…"); IsEnabled = false;
        try { var imported = await QuestionBankService.ParseWithAIAsync(input); _document.Questions.AddRange(imported.Questions); RenderQuestions(); StatusText.Text = string.Format(LocalizationManager.Text("{0} primary questions imported."), imported.Questions.Count); }
        catch (Exception exception) { StatusText.Text = exception.Message; }
        finally { IsEnabled = true; }
    }
    private void AddPrimary_Click(object sender, RoutedEventArgs e) { _document.Questions.Add(new()); RenderQuestions(); }
    private QuestionBankDocument CleanedDocument()
    {
        _document.Questions = _document.Questions.Where(item => !string.IsNullOrWhiteSpace(item.Question)).ToList();
        foreach (var item in _document.Questions) { item.Question = item.Question.Trim(); item.Answer = item.Answer.Trim(); item.FollowUps = item.FollowUps.Where(follow => !string.IsNullOrWhiteSpace(follow.Question)).ToList(); foreach (var follow in item.FollowUps) { follow.Question = follow.Question.Trim(); follow.Answer = follow.Answer.Trim(); } }
        return _document;
    }
    private void Save() { _ = CleanedDocument(); DialogResult = true; }
    private void Save_Click(object sender, RoutedEventArgs e) => Save();
    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e) { if (e.ChangedButton == MouseButton.Left) DragMove(); }
}

internal sealed class QuestionBankImportWindow : Window
{
    private readonly TextBox _input;
    public string ImportText => _input.Text;
    public QuestionBankImportWindow()
    {
        Width = 680; Height = 520; MinWidth = 520; MinHeight = 380; WindowStartupLocation = WindowStartupLocation.CenterOwner; Title = LocalizationManager.Text("Batch paste import");
        var root = new Grid { Margin = new Thickness(22) }; root.RowDefinitions.Add(new() { Height = GridLength.Auto }); root.RowDefinitions.Add(new()); root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.Children.Add(new TextBlock { Text = LocalizationManager.Text("Paste questions and answers in any reasonable format. AI will identify primary questions, follow-ups, and their answers."), TextWrapping = TextWrapping.Wrap, FontSize = 14, Margin = new Thickness(0, 0, 0, 14) });
        _input = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(12) }; Grid.SetRow(_input, 1); root.Children.Add(_input);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) }; var cancel = new Button { Content = LocalizationManager.Text("Cancel"), MinWidth = 90, Height = 38 }; cancel.Click += (_, _) => DialogResult = false; var submit = new Button { Content = LocalizationManager.Text("Organize with AI"), MinWidth = 130, Height = 38, Margin = new Thickness(10, 0, 0, 0) }; submit.Click += (_, _) => { if (!string.IsNullOrWhiteSpace(_input.Text)) DialogResult = true; }; buttons.Children.Add(cancel); buttons.Children.Add(submit); Grid.SetRow(buttons, 2); root.Children.Add(buttons); Content = root; Loaded += (_, _) => _input.Focus();
    }
}
