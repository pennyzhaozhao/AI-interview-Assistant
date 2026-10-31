using System;
using System.Linq;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace InterviewAssistant.Services;

public static class ThemeManager
{
    private static readonly Dictionary<bool, ResourceDictionary> Cache = new();

    public static void Apply(string theme, bool animate = false)
    {
        if (Application.Current is null) return;
        var useLight = string.Equals(theme, "light", StringComparison.OrdinalIgnoreCase);

        // Cross-fade: freeze the current frame in an adorner, swap the theme underneath it in one
        // pass, then fade the snapshot out. Only a single bitmap is animated, so the switch stays
        // smooth instead of re-rendering the whole (re-styled) window on every animation frame.
        CrossFadeAdorner? snapshot = null;
        if (animate && Application.Current.MainWindow is { IsLoaded: true, Content: UIElement root } window)
            snapshot = CrossFadeAdorner.TryCreate(window, root);

        SwapDictionary(useLight);

        snapshot?.FadeOut(TimeSpan.FromMilliseconds(260));
    }

    private static void SwapDictionary(bool useLight)
    {
        var dictionaries = Application.Current.Resources.MergedDictionaries;
        var oldTheme = dictionaries.FirstOrDefault(item => item.Source?.OriginalString.EndsWith("Theme.xaml", StringComparison.OrdinalIgnoreCase) == true);
        if (!Cache.TryGetValue(useLight, out var newTheme))
        {
            newTheme = new ResourceDictionary { Source = new Uri(useLight ? "Themes/LightTheme.xaml" : "Themes/DarkTheme.xaml", UriKind.Relative) };
            Cache[useLight] = newTheme;
        }
        if (ReferenceEquals(oldTheme, newTheme)) return;
        if (oldTheme is null) dictionaries.Insert(0, newTheme);
        else dictionaries[dictionaries.IndexOf(oldTheme)] = newTheme;
    }

    private sealed class CrossFadeAdorner : Adorner
    {
        private readonly ImageSource _image;
        private readonly AdornerLayer _layer;

        private CrossFadeAdorner(UIElement adorned, AdornerLayer layer, ImageSource image) : base(adorned)
        {
            _layer = layer;
            _image = image;
            IsHitTestVisible = false;
        }

        public static CrossFadeAdorner? TryCreate(Window window, UIElement root)
        {
            try
            {
                var layer = AdornerLayer.GetAdornerLayer(root);
                var size = root.RenderSize;
                if (layer is null || size.Width < 1 || size.Height < 1) return null;
                var dpi = VisualTreeHelper.GetDpi(window);
                var bitmap = new RenderTargetBitmap(
                    (int)Math.Ceiling(size.Width * dpi.DpiScaleX),
                    (int)Math.Ceiling(size.Height * dpi.DpiScaleY),
                    dpi.PixelsPerInchX,
                    dpi.PixelsPerInchY,
                    PixelFormats.Pbgra32);
                bitmap.Render(root);
                bitmap.Freeze();
                var adorner = new CrossFadeAdorner(root, layer, bitmap);
                layer.Add(adorner);
                return adorner;
            }
            catch
            {
                return null;
            }
        }

        public void FadeOut(TimeSpan duration)
        {
            var animation = new DoubleAnimation(1, 0, duration)
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut },
                BeginTime = TimeSpan.FromMilliseconds(16)
            };
            Timeline.SetDesiredFrameRate(animation, 60);
            animation.Completed += (_, _) => _layer.Remove(this);
            BeginAnimation(OpacityProperty, animation);
        }

        protected override void OnRender(DrawingContext drawingContext) =>
            drawingContext.DrawImage(_image, new Rect(AdornedElement.RenderSize));
    }
}
