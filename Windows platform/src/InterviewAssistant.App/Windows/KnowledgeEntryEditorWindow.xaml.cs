using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using InterviewAssistant.Infrastructure;
using InterviewAssistant.Services;

namespace InterviewAssistant.Windows;

public partial class KnowledgeEntryEditorWindow : Window
{
    /// <param name="summary">Pass a value (even empty) to edit a project: shows the project description field.</param>
    public KnowledgeEntryEditorWindow(string title, string content, bool isNew, string? pdfPath = null, string? hint = null, string? summary = null)
    {
        InitializeComponent();
        if (!string.IsNullOrWhiteSpace(hint)) DialogHint.Text = hint;
        var isProject = summary is not null;
        DialogTitle.Text = LocalizationManager.Text(isNew ? "Add Main Content" : isProject ? "Edit Project" : "Edit Source");
        TitleBox.Text = title;
        if (isProject)
        {
            TitleLabel.Text = LocalizationManager.Text("Project name");
            SummaryPanel.Visibility = Visibility.Visible;
            SummaryBox.Text = summary;
            ContentLabel.Text = LocalizationManager.Text("Project details (README)");
        }
        // Stored notes use "\n"; keep that so macOS and Windows see the same text.
        ContentBox.Text = content.Replace("\r\n", "\n");
        ContentBox.TextChanged += (_, _) => UpdateCharacterCount();
        UpdateCharacterCount();
        BuildFormatButtons();
        // macOS: PDF sources show the original pages (read-only); other sources show the text editor.
        if (!string.IsNullOrWhiteSpace(pdfPath) && System.IO.File.Exists(pdfPath))
        {
            ContentLabel.Text = LocalizationManager.Text("PDF Preview");
            EditorFrame.Visibility = Visibility.Collapsed;
            FormatBar.Visibility = Visibility.Collapsed;
            ShortcutHint.Visibility = Visibility.Collapsed;
            CharacterCount.Visibility = Visibility.Collapsed;
            PdfFrame.Visibility = Visibility.Visible;
            Loaded += async (_, _) => await PdfPreview.LoadAsync(pdfPath);
        }
        Loaded += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(title) || PdfFrame.Visibility == Visibility.Visible) TitleBox.Focus();
            else ContentBox.TextArea.Focus();
        };
        // Ctrl+S saves, as in Typora.
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) { e.Handled = true; Save_Click(this, new RoutedEventArgs()); }
        };
    }

    public string EntryTitle => TitleBox.Text.Trim();
    public string EntryContent => ContentBox.Text.Replace("\r\n", "\n");
    public string EntrySummary => SummaryBox.Text.Trim();

    private void UpdateCharacterCount() =>
        CharacterCount.Text = string.Format(LocalizationManager.Text("{0} characters"), ContentBox.Document.TextLength);

    private void BuildFormatButtons()
    {
        void Add(string glyphOrText, bool isGlyph, string tooltipKey, string shortcut, MarkdownFormatAction action)
        {
            var label = new TextBlock { Text = glyphOrText, FontSize = isGlyph ? 14 : 12.5, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            if (isGlyph) label.Style = (Style)FindResource("FluentIconStyle");
            var button = new Button
            {
                Content = label,
                Width = 34,
                Height = 30,
                Margin = new Thickness(1),
                ToolTip = $"{LocalizationManager.Text(tooltipKey)}  {shortcut}",
                Style = (Style)FindResource("IconButtonStyle"),
                Background = System.Windows.Media.Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Focusable = false
            };
            button.Click += (_, _) => ContentBox.Apply(action);
            FormatButtons.Children.Add(button);
        }
        void Separator() => FormatButtons.Children.Add(new Border { Width = 1, Height = 18, Margin = new Thickness(5, 6, 5, 6), Background = (System.Windows.Media.Brush)FindResource("BorderBrush") });

        Add("", true, "Bold", "Ctrl+B", new(MarkdownFormatKind.Bold));
        Add("", true, "Italic", "Ctrl+I", new(MarkdownFormatKind.Italic));
        Add("", true, "Underline", "Ctrl+U", new(MarkdownFormatKind.Underline));
        Add("S̶", false, "Strikethrough", "Alt+Shift+5", new(MarkdownFormatKind.Strikethrough));
        Add("</>", false, "Inline code", "Ctrl+Shift+`", new(MarkdownFormatKind.InlineCode));
        Add("", true, "Link", "Ctrl+K", new(MarkdownFormatKind.Link));
        Separator();
        Add("H1", false, "Heading 1", "Ctrl+1", new(MarkdownFormatKind.Heading, 1));
        Add("H2", false, "Heading 2", "Ctrl+2", new(MarkdownFormatKind.Heading, 2));
        Add("H3", false, "Heading 3", "Ctrl+3", new(MarkdownFormatKind.Heading, 3));
        Separator();
        Add("❝", false, "Quote", "Ctrl+Shift+Q", new(MarkdownFormatKind.Quote));
        Add("", true, "Bulleted list", "Ctrl+Shift+]", new(MarkdownFormatKind.BulletList));
        Add("1.", false, "Numbered list", "Ctrl+Shift+[", new(MarkdownFormatKind.OrderedList));
        Add("{ }", false, "Code block", "Ctrl+Shift+K", new(MarkdownFormatKind.CodeBlock));
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(TitleBox.Text)) TitleBox.Text = LocalizationManager.Text("Main Content");
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left) DragMove();
    }
}
