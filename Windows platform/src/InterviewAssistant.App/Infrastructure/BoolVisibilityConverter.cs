using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace InterviewAssistant.Infrastructure;

/// <summary>true → Visible, false/null → Collapsed. Set Invert to flip.</summary>
public sealed class BoolVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var flag = value switch
        {
            bool boolean => boolean,
            string text => text.Length > 0,
            null => false,
            _ => true
        };
        return flag ^ Invert ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is Visibility visibility && (visibility == Visibility.Visible) ^ Invert;
}
