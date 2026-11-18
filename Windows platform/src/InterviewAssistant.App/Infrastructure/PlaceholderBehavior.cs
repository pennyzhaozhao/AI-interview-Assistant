using System.Windows;

namespace InterviewAssistant.Infrastructure;

public static class PlaceholderBehavior
{
    public static readonly DependencyProperty PlaceholderProperty = DependencyProperty.RegisterAttached(
        "Placeholder", typeof(string), typeof(PlaceholderBehavior), new PropertyMetadata(string.Empty));

    public static void SetPlaceholder(DependencyObject element, string value) => element.SetValue(PlaceholderProperty, value);
    public static string GetPlaceholder(DependencyObject element) => (string)element.GetValue(PlaceholderProperty);
}
