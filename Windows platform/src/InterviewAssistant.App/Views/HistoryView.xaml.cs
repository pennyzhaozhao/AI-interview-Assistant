using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
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

    private static T? FindAncestor<T>(DependencyObject? current) where T : DependencyObject
    {
        while (current is not null && current is not T) current = VisualTreeHelper.GetParent(current);
        return current as T;
    }
}
