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
    /// Question cards whose body is collapsed, and questions whose follow-ups are folded in the outline.
    private readonly HashSet<Guid> _collapsed = [];
    private readonly HashSet<Guid> _outlineFolded = [];
    /// Cards by question / follow-up id, for scrolling from the outline.
    private readonly Dictionary<Guid, FrameworkElement> _cards = [];

    public QuestionBankEditorWindow(string title, string content)
    {
        InitializeComponent();
        Resources["QuestionBankEditorTitle"] = LocalizationManager.Text("Edit Q&A Bank");
        Resources["QuestionBankEditorHint"] = LocalizationManager.Text("Create primary questions and answers, then add ordered follow-ups under each one.");
        Resources["BatchImportText"] = LocalizationManager.Text("Batch paste import");
        Resources["UploadQuestionFileText"] = LocalizationManager.Text("Upload question file");
        Resources["AddPrimaryQuestionText"] = "＋  " + LocalizationManager.Text("Add question");
        Resources["NoQuestionsText"] = LocalizationManager.Text("No questions yet");
        Resources["NoQuestionsHint"] = LocalizationManager.Text("Add a question or paste a batch for AI to organize.");
        Resources["OutlineText"] = LocalizationManager.Text("Outline");
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
        _cards.Clear();
        EmptyPanel.Visibility = _document.Questions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        OutlineBorder.Visibility = _document.Questions.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        QuestionScroller.Visibility = OutlineBorder.Visibility;
        foreach (var item in _document.Questions) QuestionPanel.Children.Add(BuildPrimaryCard(item));
        RenderOutline();
    }

    private static string TitleText(string question, string placeholderKey) =>
        string.IsNullOrWhiteSpace(question) ? LocalizationManager.Text(placeholderKey) : question.Trim().Replace("\r", " ").Replace("\n", " ");

    /// <summary>A card or outline title: the question itself, or a muted placeholder while it is empty.</summary>
    private void ApplyTitle(TextBlock block, string question, string placeholderKey)
    {
        block.Text = TitleText(question, placeholderKey);
        block.Foreground = Brush(string.IsNullOrWhiteSpace(question) ? "TextSecondaryBrush" : "TextPrimaryBrush");
    }

    /// <summary>Table of contents: questions, each with its follow-ups (foldable). Clicking scrolls to the card.</summary>
    private void RenderOutline()
    {
        OutlinePanel.Children.Clear();
        foreach (var item in _document.Questions)
        {
            var folded = _outlineFolded.Contains(item.Id);
            var row = new Grid { Margin = new Thickness(0, 1, 0, 1) };
            row.ColumnDefinitions.Add(new() { Width = new GridLength(24) });
            row.ColumnDefinitions.Add(new());
            if (item.FollowUps.Count > 0)
            {
                var toggle = new Button
                {
                    Content = new TextBlock { Text = folded ? "\uE76C" : "\uE70D", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 10, Foreground = Brush("TextSecondaryBrush") },
                    Background = Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = Cursors.Hand, Padding = new Thickness(0), Width = 22, Height = 26
                };
                toggle.Click += (_, _) => { if (!_outlineFolded.Remove(item.Id)) _outlineFolded.Add(item.Id); RenderOutline(); };
                row.Children.Add(toggle);
            }
            var title = OutlineEntry(item.Question, "New question", 13, FontWeights.SemiBold, new Thickness(2, 0, 0, 0), item.Id, item.Id);
            Grid.SetColumn(title, 1);
            row.Children.Add(title);
            OutlinePanel.Children.Add(row);
            if (folded) continue;
            foreach (var follow in item.FollowUps)
                OutlinePanel.Children.Add(OutlineEntry(follow.Question, "New follow-up", 12, FontWeights.Normal, new Thickness(32, 0, 0, 0), item.Id, follow.Id));
        }
    }

    private Button OutlineEntry(string question, string placeholderKey, double fontSize, FontWeight weight, Thickness margin, Guid parentId, Guid targetId)
    {
        var text = new TextBlock { FontSize = fontSize, FontWeight = weight, TextTrimming = TextTrimming.CharacterEllipsis };
        ApplyTitle(text, question, placeholderKey);
        var button = new Button
        {
            Content = text, Margin = margin, Padding = new Thickness(6, 5, 6, 5), HorizontalContentAlignment = HorizontalAlignment.Left,
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = Cursors.Hand, ToolTip = TitleText(question, placeholderKey)
        };
        button.Click += (_, _) =>
        {
            if (_collapsed.Remove(parentId)) RenderQuestions();
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, new Action(() =>
            {
                if (!_cards.TryGetValue(targetId, out var card)) return;
                var offset = card.TransformToAncestor(QuestionPanel).Transform(new Point(0, 0)).Y;
                QuestionScroller.ScrollToVerticalOffset(Math.Max(0, offset - 4));
            }));
        };
        return button;
    }

    private Border BuildPrimaryCard(QuestionBankPrimary item)
    {
        var isCollapsed = _collapsed.Contains(item.Id);
        var root = new StackPanel();
        // Header like macOS: chevron, the question itself as the title, then delete and drag at the far right.
        var header = new Grid { MinHeight = 44 };
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new());
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var chevron = new Button
        {
            Content = new TextBlock { Text = isCollapsed ? "\uE76C" : "\uE70D", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 13 },
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = Cursors.Hand, Width = 32, Height = 36, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center
        };
        chevron.Click += (_, _) => { if (!_collapsed.Remove(item.Id)) _collapsed.Add(item.Id); RenderQuestions(); };
        header.Children.Add(chevron);
        var title = new TextBlock { FontSize = 16, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        ApplyTitle(title, item.Question, "New question");
        Grid.SetColumn(title, 1); header.Children.Add(title);
        var removePrimary = IconButton("\uE74D", danger: true);
        removePrimary.Click += (_, _) => { _document.Questions.Remove(item); RenderQuestions(); };
        Grid.SetColumn(removePrimary, 2); header.Children.Add(removePrimary);
        var drag = new TextBlock { Text = "⋮⋮", FontSize = 19, Cursor = Cursors.SizeAll, Foreground = Brush("TextSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 2, 0), ToolTip = LocalizationManager.Text("Drag to reorder") };
        Grid.SetColumn(drag, 3); header.Children.Add(drag);
        root.Children.Add(header);

        if (!isCollapsed)
        {
            var body = new StackPanel { Margin = new Thickness(0, 18, 0, 0) };
            body.Children.Add(FieldRow("Question", item.Question, false, value =>
            {
                item.Question = value;
                ApplyTitle(title, value, "New question");
                RenderOutline();
            }));
            body.Children.Add(FieldRow("Answer", item.Answer, true, value => item.Answer = value));
            foreach (var follow in item.FollowUps) body.Children.Add(BuildFollowUpCard(item, follow));
            var addFollow = PillButton("＋  " + LocalizationManager.Text("Add follow-up"));
            addFollow.HorizontalAlignment = HorizontalAlignment.Left;
            addFollow.Margin = new Thickness(item.FollowUps.Count == 0 ? 0 : 54, 12, 0, 0);
            addFollow.Click += (_, _) => { item.FollowUps.Add(new()); _outlineFolded.Remove(item.Id); RenderQuestions(); };
            body.Children.Add(addFollow);
            root.Children.Add(body);
        }

        var card = new Border { Background = Brush("SurfaceBrush"), BorderBrush = Brush("BorderBrush"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(20), Padding = new Thickness(20, 14, 20, 20), Margin = new Thickness(0, 0, 0, 14), Child = root, AllowDrop = true, Tag = item.Id };
        _cards[item.Id] = card;
        drag.PreviewMouseLeftButtonDown += (_, e) => _dragStart = e.GetPosition(this);
        drag.PreviewMouseMove += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed && (e.GetPosition(this) - _dragStart).Length > 6) DragDrop.DoDragDrop(drag, new DataObject("QuestionBankPrimary", item.Id), DragDropEffects.Move); };
        card.DragOver += (_, e) => { if (e.Data.GetDataPresent("QuestionBankPrimary")) e.Effects = DragDropEffects.Move; e.Handled = true; };
        card.Drop += (_, e) => { if (e.Data.GetData("QuestionBankPrimary") is Guid id) MovePrimary(id, item.Id); };
        return card;
    }

    private Border BuildFollowUpCard(QuestionBankPrimary parent, QuestionBankFollowUp follow)
    {
        var root = new StackPanel();
        var followHeader = new Grid { MinHeight = 36, Margin = new Thickness(0, 0, 0, 10) };
        followHeader.ColumnDefinitions.Add(new()); followHeader.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); followHeader.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var title = new TextBlock { FontSize = 14.5, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        ApplyTitle(title, follow.Question, "New follow-up");
        followHeader.Children.Add(title);
        var remove = IconButton("\uE74D", danger: true); remove.Click += (_, _) => { parent.FollowUps.Remove(follow); RenderQuestions(); }; Grid.SetColumn(remove, 1); followHeader.Children.Add(remove);
        var drag = new TextBlock { Text = "⋮⋮", FontSize = 18, Cursor = Cursors.SizeAll, Foreground = Brush("TextSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 2, 0) }; Grid.SetColumn(drag, 2); followHeader.Children.Add(drag);
        root.Children.Add(followHeader);
        root.Children.Add(FieldRow("Follow-up question", follow.Question, false, value =>
        {
            follow.Question = value;
            ApplyTitle(title, value, "New follow-up");
            RenderOutline();
        }));
        root.Children.Add(FieldRow("Follow-up answer", follow.Answer, true, value => follow.Answer = value));
        var card = new Border { Background = Brush("InputBrush"), BorderBrush = Brush("BorderBrush"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16), Padding = new Thickness(16), Margin = new Thickness(54, 10, 0, 0), Child = root, AllowDrop = true };
        _cards[follow.Id] = card;
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
