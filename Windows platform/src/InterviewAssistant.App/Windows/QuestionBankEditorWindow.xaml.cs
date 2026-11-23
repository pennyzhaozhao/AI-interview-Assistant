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
        var expander = new Expander { IsExpanded = true, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var header = new Grid { MinHeight = 44 };
        header.ColumnDefinitions.Add(new());
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var titleStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titleStack.Children.Add(new TextBlock { Text = $"{LocalizationManager.Text("Primary question")} {index + 1}", FontSize = 16, FontWeight = FontWeights.SemiBold });
        var preview = new TextBlock { Text = item.Question, FontSize = 12.5, Foreground = Brush("TextSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 520, Margin = new Thickness(0, 3, 0, 0) };
        titleStack.Children.Add(preview);
        header.Children.Add(titleStack);
        var addFollow = PillButton("＋  " + LocalizationManager.Text("Add follow-up"));
        addFollow.Margin = new Thickness(12, 0, 8, 0);
        addFollow.Click += (_, _) => { item.FollowUps.Add(new()); RenderQuestions(); };
        Grid.SetColumn(addFollow, 1); header.Children.Add(addFollow);
        var removePrimary = IconButton("\uE74D", danger: true);
        removePrimary.Click += (_, _) => { _document.Questions.Remove(item); RenderQuestions(); };
        Grid.SetColumn(removePrimary, 2); header.Children.Add(removePrimary);
        var drag = new TextBlock { Text = "⋮⋮", FontSize = 19, Cursor = Cursors.SizeAll, Foreground = Brush("TextSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 2, 0), ToolTip = LocalizationManager.Text("Drag to reorder") };
        Grid.SetColumn(drag, 3); header.Children.Add(drag);
        expander.Header = header;

        var body = new StackPanel { Margin = new Thickness(0, 18, 0, 0) };
        body.Children.Add(FieldRow("Primary question", item.Question, false, value => { item.Question = value; preview.Text = value; }));
        body.Children.Add(FieldRow("Answer", item.Answer, true, value => item.Answer = value));
        for (var followIndex = 0; followIndex < item.FollowUps.Count; followIndex++) body.Children.Add(BuildFollowUpCard(item, item.FollowUps[followIndex], index, followIndex));
        if (item.FollowUps.Count == 0)
        {
            var emptyFollow = PillButton("＋  " + LocalizationManager.Text("Add follow-up"));
            emptyFollow.HorizontalAlignment = HorizontalAlignment.Left;
            emptyFollow.Margin = new Thickness(136, 8, 0, 0);
            emptyFollow.Click += (_, _) => { item.FollowUps.Add(new()); RenderQuestions(); };
            body.Children.Add(emptyFollow);
        }
        expander.Content = body;

        var card = new Border { Background = Brush("SurfaceBrush"), BorderBrush = Brush("BorderBrush"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(20), Padding = new Thickness(20, 14, 20, 20), Margin = new Thickness(0, 0, 0, 14), Child = expander, AllowDrop = true, Tag = item.Id };
        drag.PreviewMouseLeftButtonDown += (_, e) => _dragStart = e.GetPosition(this);
        drag.PreviewMouseMove += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed && (e.GetPosition(this) - _dragStart).Length > 6) DragDrop.DoDragDrop(drag, new DataObject("QuestionBankPrimary", item.Id), DragDropEffects.Move); };
        card.DragOver += (_, e) => { if (e.Data.GetDataPresent("QuestionBankPrimary")) e.Effects = DragDropEffects.Move; e.Handled = true; };
        card.Drop += (_, e) => { if (e.Data.GetData("QuestionBankPrimary") is Guid id) MovePrimary(id, item.Id); };
        return card;
    }

    private Border BuildFollowUpCard(QuestionBankPrimary parent, QuestionBankFollowUp follow, int parentIndex, int followIndex)
    {
        var root = new StackPanel();
        var followHeader = new Grid { MinHeight = 36, Margin = new Thickness(0, 0, 0, 10) };
        followHeader.ColumnDefinitions.Add(new()); followHeader.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); followHeader.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        followHeader.Children.Add(new TextBlock { Text = $"{LocalizationManager.Text("Follow-up")} {parentIndex + 1}.{followIndex + 1}", FontSize = 14.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var remove = IconButton("\uE74D", danger: true); remove.Click += (_, _) => { parent.FollowUps.Remove(follow); RenderQuestions(); }; Grid.SetColumn(remove, 1); followHeader.Children.Add(remove);
        var drag = new TextBlock { Text = "⋮⋮", FontSize = 18, Cursor = Cursors.SizeAll, Foreground = Brush("TextSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 2, 0) }; Grid.SetColumn(drag, 2); followHeader.Children.Add(drag);
        root.Children.Add(followHeader);
        root.Children.Add(FieldRow("Follow-up question", follow.Question, false, value => follow.Question = value));
        root.Children.Add(FieldRow("Follow-up answer", follow.Answer, true, value => follow.Answer = value));
        var card = new Border { Background = Brush("InputBrush"), BorderBrush = Brush("BorderBrush"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16), Padding = new Thickness(16), Margin = new Thickness(54, 10, 0, 0), Child = root, AllowDrop = true };
        drag.PreviewMouseLeftButtonDown += (_, e) => _dragStart = e.GetPosition(this);
        drag.PreviewMouseMove += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed && (e.GetPosition(this) - _dragStart).Length > 6) DragDrop.DoDragDrop(drag, new DataObject("QuestionBankFollowUp", $"{parent.Id}|{follow.Id}"), DragDropEffects.Move); };
        card.DragOver += (_, e) => { if (e.Data.GetDataPresent("QuestionBankFollowUp")) e.Effects = DragDropEffects.Move; e.Handled = true; };
        card.Drop += (_, e) => { if (e.Data.GetData("QuestionBankFollowUp") is string value) MoveFollowUp(value, parent.Id, follow.Id); };
        return card;
    }

    private Grid FieldRow(string labelKey, string text, bool multiline, Action<string> changed)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(124) }); row.ColumnDefinitions.Add(new());
        var label = new TextBlock { Text = LocalizationManager.Text(labelKey), FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Brush("TextSecondaryBrush"), Margin = new Thickness(4, 10, 14, 0), VerticalAlignment = VerticalAlignment.Top };
        row.Children.Add(label);
        var box = new TextBox { Text = text, TextWrapping = TextWrapping.Wrap, AcceptsReturn = multiline, MinHeight = multiline ? 92 : 42, VerticalContentAlignment = multiline ? VerticalAlignment.Top : VerticalAlignment.Center, Padding = new Thickness(13, 9, 13, 9), BorderThickness = new Thickness(0), Background = Brushes.Transparent, Foreground = Brush("TextPrimaryBrush") };
        if (multiline) box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        box.TextChanged += (_, _) => changed(box.Text);
        var frame = new Border { Background = Brush("BackgroundBrush"), BorderBrush = Brush("BorderBrush"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(13), Child = box };
        Grid.SetColumn(frame, 1); row.Children.Add(frame);
        return row;
    }
    private Button PillButton(string text) => new() { Content = text, Height = 36, Padding = new Thickness(14, 0, 14, 0), Style = (Style)FindResource("SecondaryButtonStyle"), VerticalAlignment = VerticalAlignment.Center };
    private Button IconButton(string glyph, bool danger = false)
    {
        var button = new Button { Width = 36, Height = 36, Padding = new Thickness(0), Style = (Style)FindResource(danger ? "DangerIconButtonStyle" : "IconButtonStyle"), VerticalAlignment = VerticalAlignment.Center };
        button.Content = new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 15, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        return button;
    }
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
