using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InterviewAssistant.Services;

namespace InterviewAssistant.Windows;

public enum ScreenshotReviewAction { CaptureAnother, Analyze, Discard }

/// <summary>Visible equivalent of the macOS multi-shot recognized preview.</summary>
public sealed class ScreenshotReviewWindow : Window
{
    public ScreenshotReviewAction Action { get; private set; } = ScreenshotReviewAction.Discard;

    public ScreenshotReviewWindow(IReadOnlyList<(string Path, string Text)> segments)
    {
        Title = LocalizationManager.Text("Screenshot");
        Width = 680;
        Height = Math.Min(720, 250 + segments.Count * 170);
        MinWidth = 560;
        MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Background = new SolidColorBrush(Color.FromRgb(245, 247, 251));
        FontFamily = new FontFamily("Segoe UI Variable Text, SimSun, Segoe UI");

        var list = new StackPanel { Margin = new Thickness(22, 10, 22, 16) };
        list.Children.Add(new TextBlock
        {
            Text = LocalizationManager.Text("Recognized preview"),
            FontSize = 22,
            FontWeight = FontWeights.Bold,
            Foreground = new SolidColorBrush(Color.FromRgb(21, 33, 56)),
            Margin = new Thickness(0, 0, 0, 14)
        });

        for (var index = 0; index < segments.Count; index++)
        {
            var segment = segments[index];
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(segment.Path);
            image.DecodePixelWidth = 220;
            image.EndInit();
            image.Freeze();

            var row = new Grid { Margin = new Thickness(0, 0, 0, 12) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var thumbnail = new Border
            {
                CornerRadius = new CornerRadius(10),
                ClipToBounds = true,
                Background = Brushes.Black,
                Child = new Image { Source = image, Stretch = Stretch.Uniform, Height = 122 }
            };
            var text = new TextBlock
            {
                Text = string.IsNullOrWhiteSpace(segment.Text) ? LocalizationManager.Text("No readable text was found in this screenshot.") : segment.Text,
                TextWrapping = TextWrapping.Wrap,
                FontSize = 13,
                LineHeight = 20,
                Foreground = new SolidColorBrush(Color.FromRgb(43, 55, 77)),
                Margin = new Thickness(16, 6, 8, 6)
            };
            Grid.SetColumn(text, 1);
            row.Children.Add(thumbnail);
            row.Children.Add(text);
            list.Children.Add(new Border
            {
                Background = Brushes.White,
                BorderBrush = new SolidColorBrush(Color.FromRgb(224, 230, 240)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(14),
                Padding = new Thickness(12),
                Child = row
            });
        }

        var capture = ActionButton(LocalizationManager.Text("Capture another"), ScreenshotReviewAction.CaptureAnother, false);
        var discard = ActionButton(LocalizationManager.Text("Discard screenshots"), ScreenshotReviewAction.Discard, false);
        var analyze = ActionButton(LocalizationManager.Text("Finish and analyze"), ScreenshotReviewAction.Analyze, true);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(22, 8, 22, 18) };
        buttons.Children.Add(discard);
        buttons.Children.Add(capture);
        buttons.Children.Add(analyze);

        var root = new DockPanel();
        DockPanel.SetDock(buttons, Dock.Bottom);
        root.Children.Add(buttons);
        root.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = root;
    }

    private Button ActionButton(string label, ScreenshotReviewAction action, bool primary)
    {
        var button = new Button
        {
            Content = label,
            MinWidth = 118,
            Height = 42,
            Margin = new Thickness(8, 0, 0, 0),
            Padding = new Thickness(16, 0, 16, 0),
            FontWeight = FontWeights.SemiBold,
            Background = new SolidColorBrush(primary ? Color.FromRgb(52, 108, 255) : Color.FromRgb(234, 239, 247)),
            Foreground = new SolidColorBrush(primary ? Colors.White : Color.FromRgb(21, 33, 56)),
            BorderThickness = new Thickness(0)
        };
        button.Click += (_, _) => { Action = action; DialogResult = true; };
        return button;
    }
}
