using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows;

namespace InterviewAssistant.Services;

public static class ScreenshotCaptureService
{
    public static string Capture(Rect region)
    {
        if (region.Width < 2 || region.Height < 2) throw new InvalidOperationException("Select a valid screenshot region first.");
        var width = Math.Max(2, (int)Math.Round(region.Width));
        var height = Math.Max(2, (int)Math.Round(region.Height));
        using var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.CopyFromScreen((int)Math.Round(region.X), (int)Math.Round(region.Y), 0, 0, new System.Drawing.Size(width, height), CopyPixelOperation.SourceCopy);
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
        return new Rect(value.ScreenshotRegionX, value.ScreenshotRegionY, value.ScreenshotRegionWidth, value.ScreenshotRegionHeight);
    }
}
