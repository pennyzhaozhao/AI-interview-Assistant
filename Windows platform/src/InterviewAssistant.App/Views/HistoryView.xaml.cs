using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using InterviewAssistant.Services;
using Microsoft.Win32;
namespace InterviewAssistant.Views;
public partial class HistoryView : UserControl
{
    public HistoryView() => InitializeComponent();

    private void HistoryList_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (DataContext is not ViewModels.HistoryViewModel { IsSelectionMode: true }) return;
        var container = FindAncestor<ListBoxItem>(e.OriginalSource as DependencyObject);
        if (container?.DataContext is not ViewModels.InterviewHistoryItem item) return;
        item.IsBulkSelected = !item.IsBulkSelected;
        e.Handled = true;
    }

    private void Screenshot_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount < 2 || sender is not FrameworkElement { DataContext: ViewModels.HistoryTurnItem { ScreenshotPath: string path } }) return;
        e.Handled = true;
        try { _ = new Windows.ImagePreviewWindow(path) { Owner = Window.GetWindow(this) }.ShowDialog(); }
        catch (Exception exception) { Windows.AppDialog.Show(Window.GetWindow(this), LocalizationManager.Text("Screenshot"), exception.Message, Windows.DialogTone.Warning); }
    }

    private async void ExportPdf_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not ViewModels.HistoryViewModel { SelectedSession: { } item }) return;
        var dialog = new SaveFileDialog
        {
            Filter = "PDF|*.pdf",
            FileName = EvaluationPdfExporter.SuggestedFileName(item.Model),
            AddExtension = true,
            DefaultExt = ".pdf"
        };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        var button = sender as Button;
        if (button is not null) button.IsEnabled = false;
        try
        {
            await EvaluationPdfExporter.ExportAsync(item.Model, dialog.FileName);
            if (Windows.AppDialog.Show(Window.GetWindow(this), LocalizationManager.Text("PDF exported"), dialog.FileName, Windows.DialogTone.Success,
                    LocalizationManager.Text("Open"), LocalizationManager.Text("Close")))
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(dialog.FileName) { UseShellExecute = true });
        }
        catch (Exception exception)
        {
            Windows.AppDialog.Show(Window.GetWindow(this), LocalizationManager.Text("PDF export failed."), exception.Message, Windows.DialogTone.Warning);
        }
        finally
        {
            if (button is not null) button.IsEnabled = true;
        }
    }

    private static T? FindAncestor<T>(DependencyObject? current) where T : DependencyObject
    {
        while (current is not null && current is not T) current = VisualTreeHelper.GetParent(current);
        return current as T;
    }
}
