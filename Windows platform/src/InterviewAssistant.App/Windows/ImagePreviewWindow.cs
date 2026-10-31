using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace InterviewAssistant.Windows;

/// <summary>Full-size screenshot viewer (macOS history "Double-click to view image"). Esc or click outside closes.</summary>
public sealed class ImagePreviewWindow : Window
{
    public ImagePreviewWindow(string path)
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = new SolidColorBrush(Color.FromArgb(0xD8, 0x05, 0x08, 0x10));
        WindowState = WindowState.Maximized;
        ShowInTaskbar = false;
        ShowActivated = true;
        Topmost = true;

        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.UriSource = new Uri(path);
        image.EndInit();
        image.Freeze();

        var picture = new Image { Source = image, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, Cursor = Cursors.Arrow };
        var frame = new Border
        {
            Child = picture,
            CornerRadius = new CornerRadius(14),
            ClipToBounds = true,
            Margin = new Thickness(48),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        frame.MouseLeftButtonDown += (_, e) => e.Handled = true;

        var close = new Button
        {
            Content = new TextBlock { Text = "×", FontFamily = new FontFamily("Segoe UI Variable Text, SimSun, Segoe UI"), FontSize = 28, FontWeight = FontWeights.Light, Foreground = Brushes.White },
            Width = 48,
            Height = 48,
            Margin = new Thickness(20),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Cursor = Cursors.Hand,
            Background = new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(0)
        };
        close.Click += (_, _) => Close();

        var root = new Grid { Background = Brushes.Transparent };
        root.Children.Add(frame);
        root.Children.Add(close);
        root.MouseLeftButtonDown += (_, _) => Close();
        Content = root;
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { e.Handled = true; Close(); } };
        MouseRightButtonDown += (_, e) => { e.Handled = true; Close(); };
        Loaded += (_, _) => { Activate(); Focus(); };
    }
}
