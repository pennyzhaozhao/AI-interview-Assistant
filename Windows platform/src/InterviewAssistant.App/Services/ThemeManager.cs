using System;
using System.Linq;
using System.Windows;
using System.Windows.Media.Animation;

namespace InterviewAssistant.Services;

public static class ThemeManager
{
    public static void Apply(string theme, bool animate = false)
    {
        if (Application.Current is null) return;
        var useLight = string.Equals(theme, "light", StringComparison.OrdinalIgnoreCase);
        var dictionaries = Application.Current.Resources.MergedDictionaries;
        var oldTheme = dictionaries.FirstOrDefault(item => item.Source?.OriginalString.EndsWith("Theme.xaml", StringComparison.OrdinalIgnoreCase) == true);
        var source = new Uri(useLight ? "Themes/LightTheme.xaml" : "Themes/DarkTheme.xaml", UriKind.Relative);
        var newTheme = new ResourceDictionary { Source = source };

        if (oldTheme is null) dictionaries.Insert(0, newTheme);
        else dictionaries[dictionaries.IndexOf(oldTheme)] = newTheme;

        if (!animate || Application.Current.MainWindow is not Window window) return;
        window.BeginAnimation(
            UIElement.OpacityProperty,
            new DoubleAnimation(0.94, 1, TimeSpan.FromMilliseconds(220))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            });
    }

}
