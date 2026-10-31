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
    string? DownloadUrl = null);

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
            var downloadUrl = FindWindowsAsset(root) ?? releaseUrl;
            var updateAvailable = CompareVersions(latest, current) > 0;
            var status = updateAvailable
                ? string.Format(LocalizationManager.Text("Version {0} is available"), latest)
                : string.Format(LocalizationManager.Text("InterviewAssistant {0} is the latest version."), current);
            return new UpdateCheckResult(true, updateAvailable, current, latest, status, notes, downloadUrl);
        }
        catch (Exception exception)
        {
            return new UpdateCheckResult(
                false,
                false,
                current,
                string.Empty,
                $"{LocalizationManager.Text("Unable to Check for Updates")} {exception.Message}");
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
        return client;
    }

    private static string? FindWindowsAsset(JsonElement release)
    {
        if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array)
            return null;
        foreach (var asset in assets.EnumerateArray())
        {
            var name = asset.TryGetProperty("name", out var nameValue)
                ? nameValue.GetString()?.ToLowerInvariant()
                : null;
            if (name is null || !(name.EndsWith(".msix") || name.EndsWith(".msi") || name.EndsWith(".exe")))
                continue;
            if (asset.TryGetProperty("browser_download_url", out var url)) return url.GetString();
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
