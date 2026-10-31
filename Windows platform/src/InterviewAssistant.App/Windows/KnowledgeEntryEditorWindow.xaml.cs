using System.Windows;
using System.Windows.Input;
using InterviewAssistant.Services;

namespace InterviewAssistant.Windows;

public partial class KnowledgeEntryEditorWindow : Window
{
    public KnowledgeEntryEditorWindow(string title, string content, bool isNew, string? pdfPath = null)
    {
        InitializeComponent();
        DialogTitle.Text = LocalizationManager.Text(isNew ? "Add Main Content" : "Edit Source");
        TitleBox.Text = title;
        ContentBox.Text = content;
        // macOS: PDF sources show the original pages (read-only); other sources show the text editor.
        if (!string.IsNullOrWhiteSpace(pdfPath) && System.IO.File.Exists(pdfPath))
        {
            ContentLabel.Text = LocalizationManager.Text("PDF Preview");
            ContentBox.Visibility = Visibility.Collapsed;
            PdfFrame.Visibility = Visibility.Visible;
            Loaded += async (_, _) => await PdfPreview.LoadAsync(pdfPath);
        }
        Loaded += (_, _) => (string.IsNullOrWhiteSpace(title) || PdfFrame.Visibility == Visibility.Visible ? TitleBox : ContentBox).Focus();
    }

    public string EntryTitle => TitleBox.Text.Trim();
    public string EntryContent => ContentBox.Text;

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
