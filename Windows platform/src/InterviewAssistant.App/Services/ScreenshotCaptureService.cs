using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;

namespace InterviewAssistant.Services;

public static class ScreenshotCaptureService
{
    public static string Capture(Rect region)
    {
        if (region.Width < 2 || region.Height < 2) throw new InvalidOperationException("Select a valid screenshot region first.");
        var desktop = PhysicalVirtualScreen();
        var clipped = Rect.Intersect(region, desktop);
        if (clipped.Width < 2 || clipped.Height < 2)
            throw new InvalidOperationException("The screenshot region is outside the visible desktop. Set the region again.");
        var width = Math.Max(2, (int)Math.Round(clipped.Width));
        var height = Math.Max(2, (int)Math.Round(clipped.Height));
        using var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.CopyFromScreen((int)Math.Round(clipped.X), (int)Math.Round(clipped.Y), 0, 0, new System.Drawing.Size(width, height), CopyPixelOperation.SourceCopy);
        }
        var directory = Path.Combine(AppServices.Current.DataStore.DataDirectory, "Screenshots");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, $"screenshot-{DateTime.Now:yyyyMMdd-HHmmss-fff}.png");
        bitmap.Save(path, ImageFormat.Png);
        return path;
    }

    public static Rect PresetRegion()
    {
        var value = AppServices.Current.DataStore.Data.Preferences;
        var scale = value.ScreenshotRegionUsesPhysicalPixels ? 1.0 : GetDpiForSystem() / 96.0;
        return new Rect(
            value.ScreenshotRegionX * scale,
            value.ScreenshotRegionY * scale,
            value.ScreenshotRegionWidth * scale,
            value.ScreenshotRegionHeight * scale);
    }

    private static Rect PhysicalVirtualScreen() => new(
        GetSystemMetrics(76),
        GetSystemMetrics(77),
        GetSystemMetrics(78),
        GetSystemMetrics(79));

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();
}
