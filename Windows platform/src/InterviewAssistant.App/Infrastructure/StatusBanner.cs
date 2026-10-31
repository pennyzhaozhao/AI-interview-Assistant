using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace InterviewAssistant.Infrastructure;

public enum StatusKind
{
    None,
    Info,
    Testing,
    Success,
    Error
}

/// <summary>
/// Connection status pill used on the API configuration page — mirrors the macOS
/// connectionStatus(): tinted rounded banner with a check / warning icon, and a spinner while testing.
/// </summary>
public sealed class StatusBanner : Border
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(StatusBanner), new PropertyMetadata("", (d, _) => ((StatusBanner)d).Refresh()));

    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(
        nameof(Kind), typeof(StatusKind), typeof(StatusBanner), new PropertyMetadata(StatusKind.None, (d, _) => ((StatusBanner)d).Refresh()));

    private static readonly Color Green = Color.FromRgb(0x2E, 0x9E, 0x55);
    private static readonly Color Red = Color.FromRgb(0xDC, 0x3B, 0x3B);

    private readonly TextBlock _icon = new()
    {
        FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
        FontSize = 16,
        VerticalAlignment = VerticalAlignment.Center,
        TextWrapping = TextWrapping.NoWrap,
        Margin = new Thickness(0, 0, 10, 0)
    };

    private readonly ActivitySpinner _spinner = new()
    {
        Width = 16,
        Height = 16,
        SpokeThickness = 1.8,
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(0, 0, 10, 0)
    };

    private readonly TextBlock _text = new()
    {
        FontSize = 13.5,
        FontWeight = FontWeights.Medium,
        TextWrapping = TextWrapping.Wrap,
        VerticalAlignment = VerticalAlignment.Center
    };

    public StatusBanner()
    {
        CornerRadius = new CornerRadius(14);
        Padding = new Thickness(14, 11, 14, 11);
        Margin = new Thickness(0, 14, 0, 0);
        var row = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(_icon, Dock.Left);
        DockPanel.SetDock(_spinner, Dock.Left);
        row.Children.Add(_spinner);
        row.Children.Add(_icon);
        row.Children.Add(_text);
        Child = row;
        Refresh();
    }

    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public StatusKind Kind { get => (StatusKind)GetValue(KindProperty); set => SetValue(KindProperty, value); }

    private void Refresh()
    {
        var text = (Text ?? "").Replace("✅", "").Trim();
        Visibility = string.IsNullOrEmpty(text) || Kind == StatusKind.None ? Visibility.Collapsed : Visibility.Visible;
        _text.Text = text;
        _spinner.Visibility = Kind == StatusKind.Testing ? Visibility.Visible : Visibility.Collapsed;
        _icon.Visibility = Kind == StatusKind.Testing ? Visibility.Collapsed : Visibility.Visible;

        switch (Kind)
        {
            case StatusKind.Success:
                Apply(Green, "");
                break;
            case StatusKind.Error:
                Apply(Red, "");
                break;
            default:
                // Info / testing follow the current theme.
                SetResourceReference(BackgroundProperty, "InputBrush");
                _text.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
                _icon.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
                _spinner.SetResourceReference(ActivitySpinner.SpokeBrushProperty, "TextSecondaryBrush");
                _icon.Text = "";
                break;
        }
    }

    private void Apply(Color color, string glyph)
    {
        Background = new SolidColorBrush(Color.FromArgb(0x1F, color.R, color.G, color.B));
        var foreground = new SolidColorBrush(color);
        _text.Foreground = foreground;
        _icon.Foreground = foreground;
        _icon.Text = glyph;
    }
}
