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

    /// <summary>Per-pixel transparency for a non-layered window: composite through DWM instead of UpdateLayeredWindow.</summary>
    internal static void EnableDwmTransparency(nint windowHandle)
    {
        if (HwndSource.FromHwnd(windowHandle) is { CompositionTarget: { } target }) target.BackgroundColor = Colors.Transparent;
        var margins = new NativeMethods.DwmMargins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        _ = NativeMethods.DwmExtendFrameIntoClientArea(windowHandle, ref margins);
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
