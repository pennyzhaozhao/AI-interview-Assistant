using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using InterviewAssistant.Services;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace InterviewAssistant.Infrastructure;

/// <summary>
/// Scrollable page-by-page preview of the original PDF (macOS PDFPagesPreview), rendered with the
/// built-in Windows.Data.Pdf API — no external viewer or extra dependency.
/// </summary>
public sealed class PdfPagesView : ScrollViewer
{
    private const int MaxPages = 80;
    private readonly StackPanel _pages = new() { Margin = new Thickness(18) };
    private readonly TextBlock _status = new() { FontSize = 13, Margin = new Thickness(4), TextWrapping = TextWrapping.Wrap };

    public PdfPagesView()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        _status.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        _pages.Children.Add(_status);
        Content = _pages;
    }

    public async Task LoadAsync(string path)
    {
        _status.Text = LocalizationManager.Text("Loading PDF…");
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
            var document = await PdfDocument.LoadFromFileAsync(file);
            _pages.Children.Clear();
            var count = (int)Math.Min(document.PageCount, MaxPages);
            for (uint index = 0; index < count; index++)
            {
                using var page = document.GetPage(index);
                using var stream = new InMemoryRandomAccessStream();
                await page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = 1100 });
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.StreamSource = stream.AsStream();
                bitmap.EndInit();
                bitmap.Freeze();
                _pages.Children.Add(new Border
                {
                    Background = Brushes.White,
                    Margin = new Thickness(0, 0, 0, 14),
                    Effect = new DropShadowEffect { BlurRadius = 10, ShadowDepth = 2, Direction = 270, Opacity = 0.18 },
                    Child = new Image { Source = bitmap, Stretch = Stretch.Uniform }
                });
            }
            if (document.PageCount > MaxPages)
            {
                _status.Text = string.Format(LocalizationManager.Text("Showing the first {0} pages."), MaxPages);
                _pages.Children.Add(_status);
            }
        }
        catch (Exception exception)
        {
            _pages.Children.Clear();
            _status.Text = $"{LocalizationManager.Text("The original PDF file is not available. Re-import this PDF to enable preview.")}\n{exception.Message}";
            _pages.Children.Add(_status);
        }
    }
}
