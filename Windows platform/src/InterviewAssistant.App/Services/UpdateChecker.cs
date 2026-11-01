using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;

namespace InterviewAssistant.Services;

public sealed record UpdateCheckResult(
    bool Succeeded,
    bool UpdateAvailable,
    string CurrentVersion,
    string LatestVersion,
    string Status,
    string? ReleaseNotes = null,
    string? DownloadUrl = null,
    string Title = "",
    string Message = "",
    UpdateAsset? Asset = null);

/// <summary>The Windows .exe attached to a release (downloaded and installed in-app).</summary>
public sealed record UpdateAsset(string Name, string Url, long Size, string? Sha256);

public static class UpdateChecker
{
    private const string LatestReleaseEndpoint =
        "https://api.github.com/repos/pennyzhaozhao/AI-interview-Assistant/releases/latest";

    private static readonly HttpClient Client = CreateClient();

    public static string CurrentVersion
    {
        get
        {
            var assembly = Assembly.GetExecutingAssembly();
            var informational = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
                .InformationalVersion.Split('+')[0];
            return string.IsNullOrWhiteSpace(informational)
                ? assembly.GetName().Version?.ToString(3) ?? "1.0.0"
                : informational;
        }
    }

    public static string BuildNumber =>
        Assembly.GetExecutingAssembly().GetName().Version?.Revision.ToString() ?? "0";

    public static async Task<UpdateCheckResult> CheckAsync(CancellationToken cancellationToken = default)
    {
        var current = CurrentVersion;
        try
        {
            using var response = await Client.GetAsync(LatestReleaseEndpoint, cancellationToken);
            response.EnsureSuccessStatusCode();
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
            var root = document.RootElement;
            var tag = root.GetProperty("tag_name").GetString() ?? "0";
            var latest = tag.Trim().TrimStart('v', 'V');
            var releaseUrl = root.TryGetProperty("html_url", out var html)
                ? html.GetString()
                : null;
            var notes = root.TryGetProperty("body", out var body) ? body.GetString() : null;
            var asset = FindWindowsAsset(root);
            var downloadUrl = asset?.Url ?? releaseUrl;
            var updateAvailable = CompareVersions(latest, current) > 0;
            // Same wording as the macOS UpdateChecker alert.
            var title = updateAvailable
                ? string.Format(LocalizationManager.Text("Version {0} is available"), latest)
                : LocalizationManager.Text("You're up to date");
            var trimmedNotes = notes?.Trim() ?? "";
            var message = updateAvailable
                ? (trimmedNotes.Length == 0 ? LocalizationManager.Text("A newer version is ready to download.") : trimmedNotes.Length > 1600 ? trimmedNotes[..1600] : trimmedNotes)
                : string.Format(LocalizationManager.Text("InterviewAssistant {0} is the latest version."), current);
            var status = updateAvailable ? title : message;
            return new UpdateCheckResult(true, updateAvailable, current, latest, status, notes, downloadUrl, title, message, asset);
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"Update check failed: {exception}");
            var title = LocalizationManager.Text("Unable to Check for Updates");
            return new UpdateCheckResult(
                false,
                false,
                current,
                string.Empty,
                title,
                Title: title,
                Message: LocalizationManager.Text("Check your internet connection and try again."));
        }
    }

    public static void OpenDownload(UpdateCheckResult result)
    {
        if (string.IsNullOrWhiteSpace(result.DownloadUrl)) return;
        Process.Start(new ProcessStartInfo(result.DownloadUrl) { UseShellExecute = true });
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(12) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("InterviewAssistant", CurrentVersion));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        client.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");
        client.DefaultRequestHeaders.CacheControl = new CacheControlHeaderValue { NoCache = true };
        return client;
    }

    private static UpdateAsset? FindWindowsAsset(JsonElement release)
    {
        if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array)
            return null;
        foreach (var asset in assets.EnumerateArray())
        {
            var name = asset.TryGetProperty("name", out var nameValue) ? nameValue.GetString() : null;
            if (name is null || !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) continue;
            if (!asset.TryGetProperty("browser_download_url", out var url) || url.GetString() is not { } link) continue;
            var size = asset.TryGetProperty("size", out var sizeValue) && sizeValue.TryGetInt64(out var bytes) ? bytes : 0;
            // GitHub publishes "digest": "sha256:<hex>" for release assets.
            string? sha256 = null;
            if (asset.TryGetProperty("digest", out var digest) && digest.GetString() is { } value
                && value.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
                sha256 = value["sha256:".Length..].Trim().ToLowerInvariant();
            return new UpdateAsset(name, link, size, sha256);
        }
        return null;
    }

    private static int CompareVersions(string left, string right)
    {
        var a = ParseVersion(left);
        var b = ParseVersion(right);
        var count = Math.Max(a.Length, b.Length);
        for (var index = 0; index < count; index++)
        {
            var av = index < a.Length ? a[index] : 0;
            var bv = index < b.Length ? b[index] : 0;
            if (av != bv) return av.CompareTo(bv);
        }
        return 0;
    }

    private static int[] ParseVersion(string value) => value
        .Trim().TrimStart('v', 'V')
        .Split('.', StringSplitOptions.RemoveEmptyEntries)
        .Select(part => new string(part.TakeWhile(char.IsDigit).ToArray()))
        .Select(part => int.TryParse(part, out var number) ? number : 0)
        .ToArray();
}
