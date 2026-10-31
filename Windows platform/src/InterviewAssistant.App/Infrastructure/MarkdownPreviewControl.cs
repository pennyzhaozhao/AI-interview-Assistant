using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace InterviewAssistant.Infrastructure;

public sealed class MarkdownPreviewControl : StackPanel
{
    public static readonly DependencyProperty MarkdownProperty = DependencyProperty.Register(
        nameof(Markdown), typeof(string), typeof(MarkdownPreviewControl),
        new PropertyMetadata("", (dependencyObject, _) => { if (dependencyObject is MarkdownPreviewControl control) control.Refresh(); }));

    public string Markdown
    {
        get => (string)GetValue(MarkdownProperty);
        set => SetValue(MarkdownProperty, value);
    }

    public MarkdownPreviewControl() => Loaded += (_, _) => Refresh();

    private void Refresh()
    {
        var brush = Application.Current?.TryFindResource("TextPrimaryBrush") as Brush ?? Brushes.Black;
        MarkdownAnswerRenderer.Render(this, Markdown ?? "", brush, 14);
    }
}
