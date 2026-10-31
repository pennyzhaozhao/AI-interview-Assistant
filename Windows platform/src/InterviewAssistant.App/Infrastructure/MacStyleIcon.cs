using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace InterviewAssistant.Infrastructure;

/// <summary>Small vector icons matching the SF Symbols used by the macOS app.</summary>
public sealed class MacStyleIcon : Control
{
    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(
        nameof(Kind), typeof(string), typeof(MacStyleIcon),
        new FrameworkPropertyMetadata("sparkles", FrameworkPropertyMetadataOptions.AffectsRender));

    public string Kind
    {
        get => (string)GetValue(KindProperty);
        set => SetValue(KindProperty, value);
    }

    public MacStyleIcon()
    {
        Focusable = false;
        IsHitTestVisible = false;
        SnapsToDevicePixels = true;
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        var scale = Math.Min(ActualWidth, ActualHeight) / 24d;
        var offsetX = (ActualWidth - 24 * scale) / 2;
        var offsetY = (ActualHeight - 24 * scale) / 2;
        drawingContext.PushTransform(new TranslateTransform(offsetX, offsetY));
        drawingContext.PushTransform(new ScaleTransform(scale, scale));
        var brush = Foreground;
        var pen = new Pen(brush, 1.75) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        switch (Kind)
        {
            case "role": DrawRole(drawingContext, pen); break;
            case "company": DrawCompany(drawingContext, pen); break;
            case "director": DrawDirector(drawingContext, brush, pen); break;
            case "folder": DrawFolder(drawingContext, brush); break;
            case "clock": DrawClock(drawingContext, pen); break;
            case "sliders": DrawSliders(drawingContext, brush, pen); break;
            default: DrawSparkles(drawingContext, brush); break;
        }
        drawingContext.Pop();
        drawingContext.Pop();
    }

    private static void DrawSparkles(DrawingContext dc, Brush brush)
    {
        dc.DrawGeometry(brush, null, Geometry.Parse("M9,1 L11.15,7.1 L17,9.25 L11.15,11.4 L9,17.5 L6.85,11.4 L1,9.25 L6.85,7.1 Z"));
        dc.DrawGeometry(brush, null, Geometry.Parse("M18.5,12 L19.65,15.35 L23,16.5 L19.65,17.65 L18.5,21 L17.35,17.65 L14,16.5 L17.35,15.35 Z"));
        dc.DrawGeometry(brush, null, Geometry.Parse("M19,1 L19.7,3.3 L22,4 L19.7,4.7 L19,7 L18.3,4.7 L16,4 L18.3,3.3 Z"));
    }

    private static void DrawDirector(DrawingContext dc, Brush brush, Pen pen)
    {
        dc.DrawEllipse(brush, null, new Point(9, 6.1), 3.1, 3.1);
        dc.DrawGeometry(brush, null, Geometry.Parse("M3.6,20.5 C4.1,14.9 6.1,11.8 9,11.8 C11.9,11.8 13.9,14.9 14.4,20.5 Z"));
        dc.DrawGeometry(null, pen, Geometry.Parse("M15.2,7 C17.3,8.2 17.3,11.8 15.2,13 M18.2,4.5 C22.1,7 22.1,12.9 18.2,15.5"));
    }

    private static void DrawFolder(DrawingContext dc, Brush brush) =>
        dc.DrawGeometry(brush, null, Geometry.Parse("M2,5.2 C2,4 3,3 4.2,3 H9 L11.2,5.3 H19.8 C21,5.3 22,6.3 22,7.5 V18.5 C22,19.9 20.9,21 19.5,21 H4.5 C3.1,21 2,19.9 2,18.5 Z"));

    private static void DrawClock(DrawingContext dc, Pen pen)
    {
        dc.DrawEllipse(null, new Pen(pen.Brush, 2.2), new Point(12, 12), 9.2, 9.2);
        dc.DrawGeometry(null, new Pen(pen.Brush, 2.1) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, Geometry.Parse("M12,6.7 V12.2 L15.8,14.4"));
    }

    private static void DrawSliders(DrawingContext dc, Brush brush, Pen pen)
    {
        dc.DrawLine(pen, new Point(2, 6), new Point(22, 6));
        dc.DrawLine(pen, new Point(2, 12), new Point(22, 12));
        dc.DrawLine(pen, new Point(2, 18), new Point(22, 18));
        dc.DrawEllipse(brush, null, new Point(8, 6), 2.3, 2.3);
        dc.DrawEllipse(brush, null, new Point(16, 12), 2.3, 2.3);
        dc.DrawEllipse(brush, null, new Point(10.5, 18), 2.3, 2.3);
    }

    private static void DrawRole(DrawingContext dc, Pen pen)
    {
        dc.DrawRoundedRectangle(null, pen, new Rect(1.5, 3.5, 21, 17), 2.3, 2.3);
        dc.DrawEllipse(null, pen, new Point(7.2, 9.2), 2.2, 2.2);
        dc.DrawGeometry(null, pen, Geometry.Parse("M3.8,16 C4.2,13.3 5.4,12 7.2,12 C9,12 10.2,13.3 10.6,16"));
        dc.DrawLine(pen, new Point(13.5, 8), new Point(19.5, 8));
        dc.DrawLine(pen, new Point(13.5, 12), new Point(19.5, 12));
        dc.DrawLine(pen, new Point(13.5, 16), new Point(17.5, 16));
    }

    private static void DrawCompany(DrawingContext dc, Pen pen)
    {
        dc.DrawRoundedRectangle(null, pen, new Rect(3, 3, 10, 18), 1.2, 1.2);
        dc.DrawRoundedRectangle(null, pen, new Rect(13, 8, 8, 13), 1.2, 1.2);
        for (var y = 7d; y <= 15; y += 4)
        {
            dc.DrawLine(pen, new Point(6, y), new Point(7.5, y));
            dc.DrawLine(pen, new Point(9.5, y), new Point(11, y));
        }
        dc.DrawLine(pen, new Point(16, 12), new Point(18, 12));
        dc.DrawLine(pen, new Point(16, 16), new Point(18, 16));
        dc.DrawLine(pen, new Point(8, 21), new Point(8, 18));
        dc.DrawLine(pen, new Point(17, 21), new Point(17, 19));
    }
}
