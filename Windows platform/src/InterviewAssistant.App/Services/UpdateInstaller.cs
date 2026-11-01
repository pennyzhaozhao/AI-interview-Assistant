using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace InterviewAssistant.Services;

/// <summary>
/// In-app update for the single-file exe: downloads the new exe next to the running one,
/// swaps the files (a running exe can be renamed, not deleted) and restarts.
/// The exe keeps its path, so Start menu / taskbar pins keep working.
/// </summary>
public static class UpdateInstaller
{
    public const string UpdatedArgument = "--updated-from";

    private static readonly HttpClient Client = CreateClient();

    private static string? CurrentExePath
    {
        get
        {
            var path = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(path) || !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return null;
            // A debug run through dotnet.exe cannot replace itself.
            return Path.GetFileNameWithoutExtension(path).Equals("dotnet", StringComparison.OrdinalIgnoreCase) ? null : path;
        }
    }

    /// <summary>True when the release has an exe and the app folder is writable.</summary>
    public static bool CanInstall(UpdateCheckResult result)
    {
        if (result.Asset is null || CurrentExePath is not { } exe) return false;
        try
        {
            var probe = Path.Combine(Path.GetDirectoryName(exe)!, $".write-test-{Guid.NewGuid():N}");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Downloads, verifies and swaps in the new exe. Reports (received, total) bytes.</summary>
    public static async Task InstallAsync(UpdateAsset asset, IProgress<(long Received, long Total)> progress, CancellationToken cancellationToken)
    {
        var exe = CurrentExePath ?? throw new InvalidOperationException("The running app cannot be replaced.");
        var newPath = exe + ".new";
        var oldPath = exe + ".old";
        TryDelete(newPath);
        try
        {
            using (var response = await Client.GetAsync(asset.Url, HttpCompletionOption.ResponseHeadersRead, cancellationToken))
            {
                response.EnsureSuccessStatusCode();
                var total = response.Content.Headers.ContentLength ?? asset.Size;
                await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
                await using var target = new FileStream(newPath, FileMode.Create, FileAccess.Write, FileShare.None, 81920, useAsync: true);
                var buffer = new byte[81920];
                long received = 0;
                var lastReport = Stopwatch.StartNew();
                int read;
                while ((read = await source.ReadAsync(buffer, cancellationToken)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                    received += read;
                    if (lastReport.ElapsedMilliseconds >= 80)
                    {
                        progress.Report((received, total));
                        lastReport.Restart();
                    }
                }
                progress.Report((received, total));
            }

            Verify(newPath, asset);

            TryDelete(oldPath);
            File.Move(exe, oldPath);
            try
            {
                File.Move(newPath, exe);
            }
            catch
            {
                File.Move(oldPath, exe);
                throw;
            }
        }
        catch
        {
            TryDelete(newPath);
            throw;
        }
    }

    /// <summary>Starts the new exe and closes this instance.</summary>
    public static async Task RestartAsync(string previousVersion)
    {
        if (CurrentExePath is not { } exe) return;
        try { await AppServices.Current.DataStore.SaveAsync(); } catch { }
        Process.Start(new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(exe)!,
            ArgumentList = { UpdatedArgument, previousVersion }
        });
        System.Windows.Application.Current.Shutdown();
    }

    /// <summary>Removes the previous exe left by an update (the old process may still be exiting).</summary>
    public static async Task CleanupAsync()
    {
        if (CurrentExePath is not { } exe) return;
        var oldPath = exe + ".old";
        TryDelete(exe + ".new");
        for (var attempt = 0; attempt < 10 && File.Exists(oldPath); attempt++)
        {
            if (TryDelete(oldPath)) return;
            await Task.Delay(1000);
        }
    }

    /// <summary>The version the app was updated from, when launched by <see cref="RestartAsync"/>.</summary>
    public static string? UpdatedFrom(string[] args)
    {
        var index = Array.IndexOf(args, UpdatedArgument);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    private static void Verify(string path, UpdateAsset asset)
    {
        var info = new FileInfo(path);
        if (asset.Size > 0 && info.Length != asset.Size)
            throw new InvalidDataException(LocalizationManager.Text("The download is incomplete. Try again."));
        using (var stream = File.OpenRead(path))
        {
            if (stream.ReadByte() != 'M' || stream.ReadByte() != 'Z')
                throw new InvalidDataException(LocalizationManager.Text("The downloaded file is not a valid app."));
        }
        if (asset.Sha256 is { Length: > 0 } expected)
        {
            using var stream = File.OpenRead(path);
            var actual = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
            if (actual != expected)
                throw new InvalidDataException(LocalizationManager.Text("The download could not be verified. Try again."));
        }
    }

    private static bool TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("InterviewAssistant", UpdateChecker.CurrentVersion));
        return client;
    }
}
