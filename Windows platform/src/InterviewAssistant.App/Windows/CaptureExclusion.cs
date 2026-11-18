using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace InterviewAssistant.Windows;

internal enum CaptureExclusionResult
{
    Disabled,
    Excluded,
    BlackBoxFallback,
    Failed,
}

/// <summary>
/// Applies SetWindowDisplayAffinity and records a diagnostic line for every attempt, so that
/// "the prompter still shows up when sharing" reports can be diagnosed from the user's log file.
/// </summary>
internal static class CaptureExclusion
{
    private static readonly object LogGate = new();
    private static string? _lastLoggedLine;

    internal static string LogPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "InterviewAssistant",
        "Logs",
        "capture-exclusion.log");

    private static bool? _layeredWindowsSupported;

    private static string LayeredUnsupportedFlagPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "InterviewAssistant",
        "Logs",
        "layered-capture-unsupported.flag");

    /// <summary>
    /// On some Windows 10 machines SetWindowDisplayAffinity fails with ERROR_NOT_ENOUGH_MEMORY (8) for
    /// layered windows (WPF AllowsTransparency="True"). Returns false when that is the case here, so the
    /// prompter can fall back to a non-layered window whose transparency comes from DWM instead.
    /// Must be called on the UI thread.
    /// </summary>
    internal static bool LayeredWindowsSupported
    {
        get
        {
            if (_layeredWindowsSupported is bool known) return known;
            try
            {
                _layeredWindowsSupported = !File.Exists(LayeredUnsupportedFlagPath) && ProbeLayeredWindow();
            }
            catch
            {
                _layeredWindowsSupported = true;
            }
            return _layeredWindowsSupported.Value;
        }
    }

    internal static void MarkLayeredWindowsUnsupported()
    {
        _layeredWindowsSupported = false;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LayeredUnsupportedFlagPath)!);
            File.WriteAllText(LayeredUnsupportedFlagPath, DateTimeOffset.Now.ToString("O"));
        }
        catch
        {
            // Still applies for this session.
        }
    }

    private static bool ProbeLayeredWindow()
    {
        var probe = new Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            ShowActivated = false,
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -32000,
            Top = -32000,
            Width = 1,
            Height = 1,
        };
        try
        {
            probe.Show();
            var handle = new WindowInteropHelper(probe).Handle;
            var ok = NativeMethods.SetWindowDisplayAffinity(handle, NativeMethods.WdaExcludeFromCapture);
            var error = ok ? 0 : Marshal.GetLastWin32Error();
            if (ok) _ = NativeMethods.SetWindowDisplayAffinity(handle, 0);
            WriteLogLine($"probe=LayeredWindow | ok={ok} | setError={error} | os={Environment.OSVersion.Version}");
            return ok;
        }
        finally
        {
            probe.Close();
        }
    }

    /// <summary>
    /// Per-pixel transparency for a non-layered window: DWM composites the client area with its alpha
    /// channel, so the window looks exactly like the layered version (anti-aliased corners, translucent
    /// background) while SetWindowDisplayAffinity works. Returns false if DWM refused, in which case the
    /// caller clips the window with a rounded region instead.
    /// </summary>
    internal static bool EnableDwmTransparency(nint windowHandle)
    {
        if (HwndSource.FromHwnd(windowHandle) is { CompositionTarget: { } target }) target.BackgroundColor = Colors.Transparent;
        var margins = new NativeMethods.DwmMargins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        var hr = NativeMethods.DwmExtendFrameIntoClientArea(windowHandle, ref margins);
        WriteLogLine($"dwmTransparency hr=0x{hr:X8}");
        return hr >= 0;
    }

    /// <summary>Clips a window to a rounded rectangle (fallback when DWM transparency is unavailable).</summary>
    internal static void ApplyRoundedRegion(nint windowHandle, double widthDip, double heightDip, double radiusDip, double dpiScale)
    {
        if (windowHandle == nint.Zero || widthDip <= 0 || heightDip <= 0) return;
        var width = (int)Math.Round(widthDip * dpiScale);
        var height = (int)Math.Round(heightDip * dpiScale);
        var diameter = (int)Math.Round(Math.Min(radiusDip * 2, Math.Min(widthDip, heightDip)) * dpiScale);
        var region = NativeMethods.CreateRoundRectRgn(0, 0, width + 1, height + 1, diameter, diameter);
        if (region == nint.Zero) return;
        // On success the system owns the region; delete it only if SetWindowRgn failed.
        if (NativeMethods.SetWindowRgn(windowHandle, region, true) == 0) NativeMethods.DeleteObject(region);
    }

    /// <summary>
    /// Hides a helper window (screenshot region selector, image preview, …) from screen sharing the same way as the
    /// prompter. Call before Show(): in compatibility mode the window must be created non-layered.
    /// </summary>
    internal static void Protect(Window window, string windowName)
    {
        var exclude = InterviewAssistant.Services.AppServices.Current.DataStore.Data.Preferences.HidePrompterFromCapture;
        if (!exclude) return;
        if (window.AllowsTransparency && !LayeredWindowsSupported) window.AllowsTransparency = false;
        window.SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (!window.AllowsTransparency) EnableDwmTransparency(handle);
            _ = Apply(handle, true, windowName);
        };
    }

    internal static CaptureExclusionResult Apply(nint windowHandle, bool exclude, string windowName)
    {
        if (windowHandle == nint.Zero) return CaptureExclusionResult.Failed;
        if (!exclude)
        {
            _ = NativeMethods.SetWindowDisplayAffinity(windowHandle, 0);
            return CaptureExclusionResult.Disabled;
        }

        var setOk = NativeMethods.SetWindowDisplayAffinity(windowHandle, NativeMethods.WdaExcludeFromCapture);
        var setError = setOk ? 0 : Marshal.GetLastWin32Error();
        var getOk = NativeMethods.GetWindowDisplayAffinity(windowHandle, out var affinity);
        var result = setOk && getOk && affinity == NativeMethods.WdaExcludeFromCapture
            ? CaptureExclusionResult.Excluded
            : CaptureExclusionResult.Failed;

        var fallbackError = 0;
        if (result == CaptureExclusionResult.Failed)
        {
            var fallbackOk = NativeMethods.SetWindowDisplayAffinity(windowHandle, NativeMethods.WdaMonitor);
            fallbackError = fallbackOk ? 0 : Marshal.GetLastWin32Error();
            if (fallbackOk && NativeMethods.GetWindowDisplayAffinity(windowHandle, out affinity) && affinity == NativeMethods.WdaMonitor)
                result = CaptureExclusionResult.BlackBoxFallback;
        }

        Log(windowHandle, windowName, result, setError, fallbackError, affinity);
        return result;
    }

    private static void Log(nint windowHandle, string windowName, CaptureExclusionResult result, int setError, int fallbackError, uint affinity)
    {
        try
        {
            var exStyle = NativeMethods.GetWindowLong(windowHandle, NativeMethods.GwlExStyle);
            var line = string.Join(" | ",
                $"window={windowName}",
                $"result={result}",
                $"affinity=0x{affinity:X}",
                $"setError={setError}",
                $"fallbackError={fallbackError}",
                $"os={Environment.OSVersion.Version}",
                $"remoteSession={NativeMethods.GetSystemMetrics(NativeMethods.SmRemoteSession) != 0}",
                $"renderTier={RenderCapability.Tier >> 16}",
                $"exStyle=0x{exStyle:X8}",
                $"layered={(exStyle & NativeMethods.WsExLayered) != 0}");
            lock (LogGate)
            {
                // Show/re-apply happens often; only write when something actually changed.
                if (line == _lastLoggedLine) return;
                _lastLoggedLine = line;
            }
            WriteLogLine(line);
        }
        catch
        {
            // Diagnostics must never break the prompter.
        }
    }

    private static void WriteLogLine(string line)
    {
        try
        {
            lock (LogGate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
                if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 256 * 1024) File.Delete(LogPath);
                File.AppendAllText(LogPath, $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz} | {line}{Environment.NewLine}");
            }
        }
        catch
        {
            // Diagnostics must never break the prompter.
        }
    }
}
