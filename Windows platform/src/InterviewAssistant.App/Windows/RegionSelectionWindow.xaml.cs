using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace InterviewAssistant.Windows;

public partial class RegionSelectionWindow : Window
{
    private Point _start;
    private bool _dragging;

    public RegionSelectionWindow()
    {
        InitializeComponent();
        Left = SystemParameters.VirtualScreenLeft;
        Top = SystemParameters.VirtualScreenTop;
        Width = SystemParameters.VirtualScreenWidth;
        Height = SystemParameters.VirtualScreenHeight;
        Loaded += (_, _) => Focus();
    }

    public Rect SelectedRegion { get; private set; }

    private void Window_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _start = e.GetPosition(this);
        _dragging = true;
        SelectionBorder.Visibility = Visibility.Visible;
        CaptureMouse();
        UpdateSelection(_start);
    }

    private void Window_MouseMove(object sender, MouseEventArgs e)
    {
        if (_dragging) UpdateSelection(e.GetPosition(this));
    }

    private void Window_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        ReleaseMouseCapture();
        UpdateSelection(e.GetPosition(this));
        if (SelectedRegion.Width >= 24 && SelectedRegion.Height >= 24) DialogResult = true;
    }

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) DialogResult = false;
    }

    private void UpdateSelection(Point current)
    {
        var left = Math.Min(_start.X, current.X);
        var top = Math.Min(_start.Y, current.Y);
        var width = Math.Abs(current.X - _start.X);
        var height = Math.Abs(current.Y - _start.Y);
        Canvas.SetLeft(SelectionBorder, left);
        Canvas.SetTop(SelectionBorder, top);
        SelectionBorder.Width = width;
        SelectionBorder.Height = height;
        // WPF lays out in device-independent units, while Graphics.CopyFromScreen
        // expects physical desktop pixels. PointToScreen performs the DPI conversion
        // (including Windows display scaling) and prevents shifted/cropped captures.
        var screenTopLeft = PointToScreen(new Point(left, top));
        var screenBottomRight = PointToScreen(new Point(left + width, top + height));
        SelectedRegion = new Rect(
            Math.Min(screenTopLeft.X, screenBottomRight.X),
            Math.Min(screenTopLeft.Y, screenBottomRight.Y),
            Math.Abs(screenBottomRight.X - screenTopLeft.X),
            Math.Abs(screenBottomRight.Y - screenTopLeft.Y));
    }
}
