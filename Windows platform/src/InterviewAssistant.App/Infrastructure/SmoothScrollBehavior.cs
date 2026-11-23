using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace InterviewAssistant.Infrastructure;

public static class SmoothScrollBehavior
{
    private const double WheelDistanceFactor = 0.48;
    private const double ResponsePerSecond = 13.0;
    private static readonly TimeSpan MinimumFrameInterval = TimeSpan.FromMilliseconds(15);

    public static readonly DependencyProperty IsEnabledProperty = DependencyProperty.RegisterAttached(
        "IsEnabled", typeof(bool), typeof(SmoothScrollBehavior), new PropertyMetadata(false, OnIsEnabledChanged));

    private static readonly DependencyProperty StateProperty = DependencyProperty.RegisterAttached(
        "State", typeof(ScrollState), typeof(SmoothScrollBehavior));

    public static void SetIsEnabled(DependencyObject element, bool value) => element.SetValue(IsEnabledProperty, value);
    public static bool GetIsEnabled(DependencyObject element) => (bool)element.GetValue(IsEnabledProperty);

    private static void OnIsEnabledChanged(DependencyObject dependencyObject, DependencyPropertyChangedEventArgs args)
    {
        if (dependencyObject is not ScrollViewer viewer) return;
        if ((bool)args.NewValue)
        {
            viewer.SetValue(StateProperty, new ScrollState(viewer));
            viewer.PreviewMouseWheel += OnPreviewMouseWheel;
            viewer.ScrollChanged += OnScrollChanged;
        }
        else
        {
            viewer.PreviewMouseWheel -= OnPreviewMouseWheel;
            viewer.ScrollChanged -= OnScrollChanged;
            if (viewer.GetValue(StateProperty) is ScrollState state) state.Stop();
            viewer.ClearValue(StateProperty);
        }
    }

    private static void OnPreviewMouseWheel(object sender, MouseWheelEventArgs args)
    {
        if (sender is not ScrollViewer viewer || viewer.ScrollableHeight <= 0 || viewer.GetValue(StateProperty) is not ScrollState state) return;
        // Let nested scrollable content (multi-line text boxes, lists, code blocks) scroll first;
        // the page only takes over once the inner area has reached its top / bottom.
        if (InnerViewerCanScroll(args.OriginalSource as DependencyObject, viewer, args.Delta)) return;
        state.Target = Math.Clamp(state.Target - args.Delta * WheelDistanceFactor, 0, viewer.ScrollableHeight);
        state.Start();
        args.Handled = true;
    }

    private static bool InnerViewerCanScroll(DependencyObject? source, ScrollViewer outer, int delta)
    {
        for (var current = source; current is not null && !ReferenceEquals(current, outer); current = Parent(current))
        {
            if (current is not ScrollViewer inner || inner.ScrollableHeight <= 0) continue;
            if (delta > 0 && inner.VerticalOffset > 0) return true;
            if (delta < 0 && inner.VerticalOffset < inner.ScrollableHeight - 0.5) return true;
        }
        return false;
    }

    private static DependencyObject? Parent(DependencyObject element) =>
        element is Visual or System.Windows.Media.Media3D.Visual3D
            ? VisualTreeHelper.GetParent(element) ?? LogicalTreeHelper.GetParent(element)
            : LogicalTreeHelper.GetParent(element);

    private static void OnScrollChanged(object sender, ScrollChangedEventArgs args)
    {
        if (sender is ScrollViewer viewer && viewer.GetValue(StateProperty) is ScrollState { IsAnimating: false } state && args.VerticalChange != 0)
        {
            state.Target = viewer.VerticalOffset;
        }
    }

    private sealed class ScrollState
    {
        private readonly ScrollViewer _viewer;
        private readonly Stopwatch _clock = new();
        private TimeSpan _lastFrame;

        public ScrollState(ScrollViewer viewer)
        {
            _viewer = viewer;
            Target = viewer.VerticalOffset;
        }

        public double Target { get; set; }
        public bool IsAnimating { get; private set; }

        public void Start()
        {
            if (IsAnimating) return;
            IsAnimating = true;
            _clock.Restart();
            _lastFrame = TimeSpan.Zero;
            CompositionTarget.Rendering += OnRendering;
        }

        public void Stop()
        {
            if (!IsAnimating) return;
            CompositionTarget.Rendering -= OnRendering;
            IsAnimating = false;
            _clock.Stop();
        }

        private void OnRendering(object? sender, EventArgs args)
        {
            var now = _clock.Elapsed;
            // CompositionTarget follows the monitor refresh rate. On 120/144 Hz
            // displays, scrolling a complex settings page at that same rate can
            // force far more WPF layout passes than the UI thread can sustain.
            // A steady ~60 Hz update is visually smoother than irregular dropped
            // frames, while elapsed-time interpolation keeps the speed consistent.
            if (_lastFrame != TimeSpan.Zero && now - _lastFrame < MinimumFrameInterval) return;
            var seconds = Math.Clamp((now - _lastFrame).TotalSeconds, 1d / 120d, 1d / 20d);
            _lastFrame = now;
            var difference = Target - _viewer.VerticalOffset;
            if (Math.Abs(difference) < 0.35)
            {
                _viewer.ScrollToVerticalOffset(Target);
                Stop();
                return;
            }

            var progress = 1 - Math.Exp(-seconds * ResponsePerSecond);
            var next = _viewer.VerticalOffset + difference * progress;
            if (Math.Abs(next - _viewer.VerticalOffset) >= 0.1)
            {
                _viewer.ScrollToVerticalOffset(next);
            }
        }
    }
}
