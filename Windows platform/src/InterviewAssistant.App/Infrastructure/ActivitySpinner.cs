using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace InterviewAssistant.Infrastructure;

/// <summary>
/// macOS-style "spoked" activity indicator. The spokes fade behind the leading spoke and the
/// whole wheel ticks one spoke at a time, matching the native NSProgressIndicator look.
/// </summary>
public sealed class ActivitySpinner : FrameworkElement
{
    public static readonly DependencyProperty SpokeBrushProperty = DependencyProperty.Register(
        nameof(SpokeBrush), typeof(Brush), typeof(ActivitySpinner),
        new FrameworkPropertyMetadata(Brushes.Gray, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty SpokeCountProperty = DependencyProperty.Register(
        nameof(SpokeCount), typeof(int), typeof(ActivitySpinner),
        new FrameworkPropertyMetadata(12, FrameworkPropertyMetadataOptions.AffectsRender, (d, _) => ((ActivitySpinner)d).UpdateInterval()));

    public static readonly DependencyProperty SpokeThicknessProperty = DependencyProperty.Register(
        nameof(SpokeThickness), typeof(double), typeof(ActivitySpinner),
        new FrameworkPropertyMetadata(2.6, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty InnerRadiusRatioProperty = DependencyProperty.Register(
        nameof(InnerRadiusRatio), typeof(double), typeof(ActivitySpinner),
        new FrameworkPropertyMetadata(0.48, FrameworkPropertyMetadataOptions.AffectsRender));

    /// <summary>Seconds for a full revolution.</summary>
    public static readonly DependencyProperty PeriodProperty = DependencyProperty.Register(
        nameof(Period), typeof(double), typeof(ActivitySpinner),
        new FrameworkPropertyMetadata(0.9, (d, _) => ((ActivitySpinner)d).UpdateInterval()));

    private readonly RotateTransform _rotation = new();
    private readonly DispatcherTimer _timer = new(DispatcherPriority.Render);

    public ActivitySpinner()
    {
        RenderTransform = _rotation;
        RenderTransformOrigin = new Point(0.5, 0.5);
        SnapsToDevicePixels = false;
        IsHitTestVisible = false;
        UpdateInterval();
        _timer.Tick += (_, _) => _rotation.Angle = (_rotation.Angle + 360.0 / Math.Max(3, SpokeCount)) % 360;
        Loaded += (_, _) => UpdateRunning();
        Unloaded += (_, _) => _timer.Stop();
        IsVisibleChanged += (_, _) => UpdateRunning();
    }

    public Brush SpokeBrush { get => (Brush)GetValue(SpokeBrushProperty); set => SetValue(SpokeBrushProperty, value); }
    public int SpokeCount { get => (int)GetValue(SpokeCountProperty); set => SetValue(SpokeCountProperty, value); }
    public double SpokeThickness { get => (double)GetValue(SpokeThicknessProperty); set => SetValue(SpokeThicknessProperty, value); }
    public double InnerRadiusRatio { get => (double)GetValue(InnerRadiusRatioProperty); set => SetValue(InnerRadiusRatioProperty, value); }
    public double Period { get => (double)GetValue(PeriodProperty); set => SetValue(PeriodProperty, value); }

    private void UpdateInterval() =>
        _timer.Interval = TimeSpan.FromSeconds(Math.Max(0.2, Period) / Math.Max(3, SpokeCount));

    private void UpdateRunning()
    {
        if (IsLoaded && IsVisible) _timer.Start();
        else _timer.Stop();
    }

    protected override Size MeasureOverride(Size availableSize) => new(
        double.IsNaN(Width) ? 24 : Width,
        double.IsNaN(Height) ? 24 : Height);

    protected override void OnRender(DrawingContext drawingContext)
    {
        var count = Math.Max(3, SpokeCount);
        var thickness = SpokeThickness;
        var center = new Point(RenderSize.Width / 2, RenderSize.Height / 2);
        var outer = Math.Max(1, Math.Min(RenderSize.Width, RenderSize.Height) / 2 - thickness / 2);
        var inner = outer * Math.Clamp(InnerRadiusRatio, 0.05, 0.95);
        var pen = new Pen(SpokeBrush, thickness) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        pen.Freeze();

        for (var index = 0; index < count; index++)
        {
            // index 0 is the leading (brightest) spoke; the rest trail behind it counter-clockwise.
            var radians = (-index * 360.0 / count - 90) * Math.PI / 180;
            var cos = Math.Cos(radians);
            var sin = Math.Sin(radians);
            drawingContext.PushOpacity(Math.Max(0.16, 1 - index * (0.9 / count)));
            drawingContext.DrawLine(pen,
                new Point(center.X + cos * inner, center.Y + sin * inner),
                new Point(center.X + cos * outer, center.Y + sin * outer));
            drawingContext.Pop();
        }
    }
}
