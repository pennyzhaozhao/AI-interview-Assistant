using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace InterviewAssistant.Infrastructure;

/// <summary>
/// Smooth wheel scrolling for page-level <see cref="ScrollViewer"/>s.
///
/// Motion is a critically damped spring (the "SmoothDamp" model): each wheel notch moves the
/// target, and the offset follows with continuous velocity, so consecutive notches never cause
/// a sudden jump in speed and the motion settles without overshoot.
///
/// Frame pacing follows WPF's own frame clock (<see cref="RenderingEventArgs.RenderingTime"/>),
/// ignores the duplicate callbacks WPF can raise within one frame, and on high-refresh displays
/// updates on every second frame with a steady cadence instead of a time threshold (a threshold
/// alternates between skipping one and two frames, which reads as stutter).
/// </summary>
public static class SmoothScrollBehavior
{
    /// <summary>Pixels per standard wheel notch (120 delta).</summary>
    private const double WheelDistanceFactor = 0.48;
    /// <summary>Approximate time for the offset to catch up with a wheel notch.</summary>
    private const double WheelSmoothTime = 0.14;
    /// <summary>Precision touchpads already deliver fine-grained deltas; follow them more tightly.</summary>
    private const double TouchpadSmoothTime = 0.06;
    /// <summary>Frame intervals shorter than this (≈ above 110 Hz) update on every second frame.</summary>
    private static readonly TimeSpan HighRefreshInterval = TimeSpan.FromMilliseconds(9);

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
            // Hit testing on the content is paused while animating; a background keeps the
            // viewer itself hit-testable so further wheel notches still reach it.
            if (viewer.Background is null) viewer.Background = Brushes.Transparent;
            viewer.PreviewMouseWheel += OnPreviewMouseWheel;
            viewer.ScrollChanged += OnScrollChanged;
            viewer.Unloaded += OnUnloaded;
        }
        else
        {
            viewer.PreviewMouseWheel -= OnPreviewMouseWheel;
            viewer.ScrollChanged -= OnScrollChanged;
            viewer.Unloaded -= OnUnloaded;
            if (viewer.GetValue(StateProperty) is ScrollState state) state.Stop();
            viewer.ClearValue(StateProperty);
        }
    }

    private static void OnUnloaded(object sender, RoutedEventArgs args)
    {
        if (sender is ScrollViewer viewer && viewer.GetValue(StateProperty) is ScrollState state) state.Stop();
    }

    private static void OnPreviewMouseWheel(object sender, MouseWheelEventArgs args)
    {
        if (sender is not ScrollViewer viewer || viewer.ScrollableHeight <= 0 || viewer.GetValue(StateProperty) is not ScrollState state) return;
        // Let nested scrollable content (multi-line text boxes, lists, code blocks) scroll first;
        // the page only takes over once the inner area has reached its top / bottom.
        if (InnerViewerCanScroll(args.OriginalSource as DependencyObject, viewer, args.Delta)) return;
        var isTouchpad = args.Delta % Mouse.MouseWheelDeltaForOneLine != 0;
        state.AddDelta(-args.Delta * WheelDistanceFactor, isTouchpad ? TouchpadSmoothTime : WheelSmoothTime);
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
        if (sender is not ScrollViewer viewer || viewer.GetValue(StateProperty) is not ScrollState state) return;
        if (args.VerticalChange != 0) state.OnExternalScroll();
        if (args.ExtentHeightChange != 0 || args.ViewportHeightChange != 0) state.ClampTarget();
    }

    private sealed class ScrollState(ScrollViewer viewer)
    {
        private double _target = viewer.VerticalOffset;
        /// <summary>Unrounded animated offset; the viewer itself is set to device-pixel-snapped values.</summary>
        private double _position = viewer.VerticalOffset;
        private double _velocity;
        private double _smoothTime = WheelSmoothTime;
        private TimeSpan _lastRenderingTime;
        private TimeSpan _lastFrameInterval;
        private bool _skipNextFrame;
        private double? _lastAppliedOffset;
        private UIElement? _hitTestSuspended;

        public bool IsAnimating { get; private set; }

        public void AddDelta(double delta, double smoothTime)
        {
            // Continue from wherever the current animation is heading, so quick notches accumulate.
            if (!IsAnimating)
            {
                _position = viewer.VerticalOffset;
                _target = _position;
                _velocity = 0;
            }
            _smoothTime = smoothTime;
            _target = Math.Clamp(_target + delta, 0, viewer.ScrollableHeight);
            Start();
        }

        public void OnExternalScroll()
        {
            // ScrollToVerticalOffset is applied during the next layout pass, so our own updates
            // arrive here later. Anything else (scrollbar drag, keyboard, BringIntoView) takes over.
            if (IsAnimating && _lastAppliedOffset is { } applied && Math.Abs(viewer.VerticalOffset - applied) < 1) return;
            Stop();
            _position = _target = viewer.VerticalOffset;
            _velocity = 0;
        }

        public void ClampTarget() => _target = Math.Clamp(_target, 0, viewer.ScrollableHeight);

        private void Start()
        {
            if (IsAnimating) return;
            IsAnimating = true;
            _lastAppliedOffset = null;
            _lastRenderingTime = TimeSpan.Zero;
            _lastFrameInterval = TimeSpan.Zero;
            _skipNextFrame = false;
            SuspendHitTesting();
            CompositionTarget.Rendering += OnRendering;
        }

        public void Stop()
        {
            if (!IsAnimating) return;
            CompositionTarget.Rendering -= OnRendering;
            IsAnimating = false;
            _velocity = 0;
            ResumeHitTesting();
        }

        private void OnRendering(object? sender, EventArgs args)
        {
            if (args is not RenderingEventArgs rendering) return;
            var now = rendering.RenderingTime;
            // WPF may raise Rendering more than once for the same frame.
            if (now == _lastRenderingTime) return;
            if (_lastRenderingTime == TimeSpan.Zero)
            {
                _lastRenderingTime = now;
                return;
            }

            var interval = now - _lastRenderingTime;
            if (_lastFrameInterval == TimeSpan.Zero || interval < _lastFrameInterval) _lastFrameInterval = interval;
            // On 120/144 Hz panels, update on every second frame: an even 60/72 Hz cadence keeps the
            // layout cost manageable without the irregular frame skipping of a time threshold.
            if (_lastFrameInterval < HighRefreshInterval)
            {
                _skipNextFrame = !_skipNextFrame;
                if (_skipNextFrame) return;
            }

            var seconds = Math.Clamp((now - _lastRenderingTime).TotalSeconds, 1d / 240d, 1d / 20d);
            _lastRenderingTime = now;
            Step(seconds);
        }

        /// <summary>Critically damped spring toward the target (Game Programming Gems 4, 1.10).</summary>
        private void Step(double deltaSeconds)
        {
            var omega = 2 / _smoothTime;
            var x = omega * deltaSeconds;
            var exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x);
            var change = _position - _target;
            var temp = (_velocity + omega * change) * deltaSeconds;
            _velocity = (_velocity - omega * temp) * exp;
            var next = _target + (change + temp) * exp;
            // Never overshoot past the target.
            if ((_target - _position > 0) == (next > _target))
            {
                next = _target;
                _velocity = 0;
            }
            _position = next;

            var settled = Math.Abs(_target - _position) < 0.25 && Math.Abs(_velocity) < 5;
            if (settled) _position = _target;
            ApplyOffset(settled ? _target : SnapToDevicePixel(_position));
            if (settled) Stop();
        }

        private void ApplyOffset(double offset)
        {
            if (_lastAppliedOffset is { } previous && Math.Abs(offset - previous) < 0.01) return;
            _lastAppliedOffset = offset;
            viewer.ScrollToVerticalOffset(offset);
        }

        /// <summary>
        /// Whole device pixels keep text and cached cards from being re-rasterized at a new
        /// sub-pixel phase on every frame, which shows up as shimmer and uneven motion.
        /// </summary>
        private double SnapToDevicePixel(double offset)
        {
            var scale = VisualTreeHelper.GetDpi(viewer).DpiScaleY;
            return scale > 0 ? Math.Round(offset * scale) / scale : Math.Round(offset);
        }

        /// <summary>
        /// While the page slides under a stationary cursor, hover states would flip on every card
        /// and button it passes, invalidating their cached bitmaps each time. Pause hit testing on
        /// the content for the duration of the animation, as browsers do while scrolling.
        /// </summary>
        private void SuspendHitTesting()
        {
            if (viewer.Content is not UIElement content || !content.IsHitTestVisible) return;
            if (Mouse.LeftButton == MouseButtonState.Pressed || Mouse.RightButton == MouseButtonState.Pressed) return;
            content.IsHitTestVisible = false;
            _hitTestSuspended = content;
        }

        private void ResumeHitTesting()
        {
            if (_hitTestSuspended is null) return;
            _hitTestSuspended.IsHitTestVisible = true;
            _hitTestSuspended = null;
        }
    }
}
