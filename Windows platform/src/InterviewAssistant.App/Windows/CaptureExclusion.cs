using System.IO;
using System.Runtime.InteropServices;
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
