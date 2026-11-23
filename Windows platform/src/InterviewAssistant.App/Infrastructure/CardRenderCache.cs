using System.Windows;
using System.Windows.Media;

namespace InterviewAssistant.Infrastructure;

/// <summary>
/// DPI-aware bitmap caching for shadowed cards.
///
/// A plain <c>CacheMode="BitmapCache"</c> setter rasterizes at 96 DPI: on 125 %/150 % displays the
/// cached card (including its text) is scaled up and looks soft, and ClearType is switched off.
/// This renders the cache at the monitor's scale with ClearType kept, and refreshes it when the
/// window moves to a monitor with a different DPI.
/// </summary>
public static class CardRenderCache
{
    public static readonly DependencyProperty IsEnabledProperty = DependencyProperty.RegisterAttached(
        "IsEnabled", typeof(bool), typeof(CardRenderCache), new PropertyMetadata(false, OnIsEnabledChanged));

    private static readonly DependencyProperty SubscriptionProperty = DependencyProperty.RegisterAttached(
        "Subscription", typeof(DpiSubscription), typeof(CardRenderCache));

    /// <summary>The window an element listens to for DPI changes; removed again on Unloaded.</summary>
    private sealed record DpiSubscription(Window Window, DpiChangedEventHandler Handler);

    public static void SetIsEnabled(DependencyObject element, bool value) => element.SetValue(IsEnabledProperty, value);
    public static bool GetIsEnabled(DependencyObject element) => (bool)element.GetValue(IsEnabledProperty);

    private static void OnIsEnabledChanged(DependencyObject dependencyObject, DependencyPropertyChangedEventArgs args)
    {
        if (dependencyObject is not FrameworkElement element) return;
        if ((bool)args.NewValue)
        {
            element.Loaded += OnLoaded;
            element.Unloaded += OnUnloaded;
            if (element.IsLoaded) Attach(element);
        }
        else
        {
            element.Loaded -= OnLoaded;
            element.Unloaded -= OnUnloaded;
            Detach(element);
            element.ClearValue(UIElement.CacheModeProperty);
        }
    }

    private static void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement element) Attach(element);
    }

    private static void OnUnloaded(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement element) Detach(element);
    }

    private static void Attach(FrameworkElement element)
    {
        Apply(element);
        if (element.GetValue(SubscriptionProperty) is DpiSubscription || Window.GetWindow(element) is not { } window) return;
        DpiChangedEventHandler handler = (_, _) => Apply(element);
        window.DpiChanged += handler;
        element.SetValue(SubscriptionProperty, new DpiSubscription(window, handler));
    }

    private static void Detach(FrameworkElement element)
    {
        if (element.GetValue(SubscriptionProperty) is not DpiSubscription subscription) return;
        subscription.Window.DpiChanged -= subscription.Handler;
        element.ClearValue(SubscriptionProperty);
    }

    private static void Apply(FrameworkElement element)
    {
        var scale = VisualTreeHelper.GetDpi(element).DpiScaleX;
        if (element.CacheMode is BitmapCache { } existing && Math.Abs(existing.RenderAtScale - scale) < 0.01) return;
        element.CacheMode = new BitmapCache
        {
            RenderAtScale = scale,
            SnapsToDevicePixels = true,
            EnableClearType = true
        };
    }
}
