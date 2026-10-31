using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using InterviewAssistant.Services;
namespace InterviewAssistant.Views;
public partial class KnowledgeView : UserControl
{
    public KnowledgeView() => InitializeComponent();

    private void KnowledgeList_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (DataContext is not ViewModels.KnowledgeViewModel { IsSelectionMode: true }) return;
        if (FindAncestor<Button>(e.OriginalSource as DependencyObject) is not null) return;
        var container = FindAncestor<ListBoxItem>(e.OriginalSource as DependencyObject);
        if (container?.DataContext is not ViewModels.KnowledgeBaseItemViewModel item) return;
        item.IsBulkSelected = !item.IsBulkSelected;
        e.Handled = true;
    }

    private static T? FindAncestor<T>(DependencyObject? current) where T : DependencyObject
    {
        while (current is not null && current is not T) current = VisualTreeHelper.GetParent(current);
        return current as T;
    }

    private void AddMainContent_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not ViewModels.KnowledgeViewModel { SelectedKnowledgeBase: not null } viewModel) return;
        var dialog = new Windows.KnowledgeEntryEditorWindow(LocalizationManager.Text("Main Content"), "", isNew: true)
        {
            Owner = Window.GetWindow(this)
        };
        if (dialog.ShowDialog() == true)
        {
            viewModel.AddManualEntry(dialog.EntryTitle, dialog.EntryContent);
        }
    }

    private void EditEntry_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: ViewModels.KnowledgeEntryViewModel entry }) return;
        var dialog = new Windows.KnowledgeEntryEditorWindow(entry.Title, entry.Content, isNew: false, pdfPath: entry.PdfPath)
        {
            Owner = Window.GetWindow(this)
        };
        if (dialog.ShowDialog() == true)
        {
            entry.Title = dialog.EntryTitle;
            entry.Content = dialog.EntryContent;
        }
    }

    private async void UploadFile_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not ViewModels.KnowledgeViewModel viewModel) return;
        var dialog = new OpenFileDialog
        {
            Title = "Import interview material",
            Filter = "Supported documents|*.pdf;*.txt;*.md;*.json;*.csv;*.html;*.htm;*.rtf;*.docx|Text files|*.txt;*.md;*.json;*.csv|All files|*.*"
        };
        if (dialog.ShowDialog() != true) return;
        try
        {
            var content = await DocumentTextImporter.ExtractTextAsync(dialog.FileName);
            if (string.IsNullOrWhiteSpace(content)) throw new InvalidDataException("The selected file did not contain readable text.");
            var source = $"file:{dialog.FileName}";
            if (string.Equals(Path.GetExtension(dialog.FileName), ".pdf", StringComparison.OrdinalIgnoreCase))
            {
                // Like macOS storeImportedPDF: keep the original so the source editor can preview it.
                var directory = Path.Combine(AppServices.Current.DataStore.DataDirectory, "ImportedPDFs");
                Directory.CreateDirectory(directory);
                var stored = Path.Combine(directory, $"{Guid.NewGuid()}.pdf");
                File.Copy(dialog.FileName, stored, overwrite: true);
                source = $"pdf:{stored}";
            }
            viewModel.AddFile(Path.GetFileName(dialog.FileName), content, source);
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.Message, "Import failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
