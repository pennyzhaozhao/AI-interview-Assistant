using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace InterviewAssistant.Services;

public sealed class SupportFeedbackRecord
{
    public string Code { get; set; } = "";
    public string TrackingToken { get; set; } = "";
    public string Issue { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
    public string Status { get; set; } = "new";
    public DateTimeOffset UpdatedAt { get; set; }
    public bool HasLogs { get; set; }
    public bool HasImage { get; set; }
}

public sealed class SupportFeedbackImage
{
    public string FileName { get; set; } = "feedback-image.jpg";
    public string MimeType { get; set; } = "image/jpeg";
    public byte[] Data { get; set; } = [];
}

public static partial class SupportLogUploader
{
    public static readonly Uri Endpoint = new("https://interview-assistant-log-upload.zhaopeiyu1507288.workers.dev/v1/feedback");
    private static readonly string AppDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "InterviewAssistant");
    private static readonly string LogPath = Path.Combine(AppDirectory, "Logs", "startup.log");
    private static readonly string HistoryPath = Path.Combine(AppDirectory, "feedback-history.json");
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    public static async Task<SupportFeedbackRecord> SubmitFeedbackAsync(
        string issue,
        bool includeLogs,
        SupportFeedbackImage? image = null,
        CancellationToken cancellationToken = default)
    {
        var cleanIssue = issue.Trim();
        if (cleanIssue.Length == 0) throw new InvalidOperationException(LocalizationManager.Text("FeedbackIssueRequired"));
        if (cleanIssue.Length > 2_000) cleanIssue = cleanIssue[..2_000];
        var assembly = Assembly.GetEntryAssembly()?.GetName();
        var createdAt = DateTimeOffset.UtcNow;
        var payload = new
        {
            platform = "Windows",
            appVersion = assembly?.Version?.ToString() ?? "unknown",
            osVersion = Environment.OSVersion.VersionString,
            createdAt = createdAt.ToString("O"),
            issue = cleanIssue,
            includeLogs,
            logs = includeLogs ? Redact(ReadLogTail()) : "",
            image = image is null ? null : new
            {
                fileName = image.FileName,
                mimeType = image.MimeType,
                base64 = Convert.ToBase64String(image.Data)
            }
        };
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
        using var content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
        using var response = await client.PostAsync(Endpoint, content, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (response.StatusCode != System.Net.HttpStatusCode.Created)
            throw new InvalidOperationException($"Feedback service returned HTTP {(int)response.StatusCode}.");
        var result = JsonSerializer.Deserialize<UploadResponse>(body, JsonOptions)
            ?? throw new InvalidOperationException("Feedback service returned an invalid response.");
        if (string.IsNullOrWhiteSpace(result.Code) || string.IsNullOrWhiteSpace(result.TrackingToken))
            throw new InvalidOperationException("Feedback service returned an invalid response.");
        var record = new SupportFeedbackRecord
        {
            Code = result.Code,
            TrackingToken = result.TrackingToken,
            Issue = cleanIssue,
            CreatedAt = createdAt,
            Status = result.Status,
            UpdatedAt = DateTimeOffset.TryParse(result.UpdatedAt, out var updated) ? updated : createdAt,
            HasLogs = includeLogs,
            HasImage = result.HasImage || image is not null
        };
        var history = LoadHistory().Where(item => item.Code != record.Code).ToList();
        history.Insert(0, record);
        SaveHistory(history);
        return record;
    }

    public static List<SupportFeedbackRecord> LoadHistory()
    {
        try
        {
            if (!File.Exists(HistoryPath)) return [];
            return (JsonSerializer.Deserialize<List<SupportFeedbackRecord>>(File.ReadAllText(HistoryPath), JsonOptions) ?? [])
                .OrderByDescending(item => item.CreatedAt)
                .ToList();
        }
        catch { return []; }
    }

    public static async Task<List<SupportFeedbackRecord>> RefreshHistoryAsync(CancellationToken cancellationToken = default)
    {
        var history = LoadHistory();
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        foreach (var item in history)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, new Uri($"{Endpoint.AbsoluteUri}/{item.Code}"));
            request.Headers.TryAddWithoutValidation("X-Feedback-Token", item.TrackingToken);
            try
            {
                using var response = await client.SendAsync(request, cancellationToken);
                if (!response.IsSuccessStatusCode) continue;
                var body = await response.Content.ReadAsStringAsync(cancellationToken);
                var status = JsonSerializer.Deserialize<StatusResponse>(body, JsonOptions);
                if (status is null) continue;
                item.Status = status.Status;
                item.HasImage = status.HasImage || item.HasImage;
                if (DateTimeOffset.TryParse(status.UpdatedAt, out var updated)) item.UpdatedAt = updated;
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { }
            catch (HttpRequestException) { }
        }
        SaveHistory(history);
        return history;
    }

    public static SupportFeedbackImage PrepareImage(string path)
    {
        using var sourceStream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var decoder = BitmapDecoder.Create(sourceStream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var source = decoder.Frames.FirstOrDefault() ?? throw new InvalidOperationException("The selected image could not be read.");
        foreach (var maximumDimension in new[] { 1600d, 1280d, 1024d })
        {
            var scale = Math.Min(1d, maximumDimension / Math.Max(source.PixelWidth, source.PixelHeight));
            BitmapSource resized = scale < 1
                ? new TransformedBitmap(source, new ScaleTransform(scale, scale))
                : source;
            foreach (var quality in new[] { 82, 68, 52 })
            {
                var encoder = new JpegBitmapEncoder { QualityLevel = quality };
                encoder.Frames.Add(BitmapFrame.Create(resized));
                using var output = new MemoryStream();
                encoder.Save(output);
                if (output.Length <= 4 * 1024 * 1024)
                {
                    return new SupportFeedbackImage
                    {
                        FileName = Path.GetFileNameWithoutExtension(path) + ".jpg",
                        MimeType = "image/jpeg",
                        Data = output.ToArray()
                    };
                }
            }
        }
        throw new InvalidOperationException(LocalizationManager.Text("FeedbackImageTooLarge"));
    }

    private static void SaveHistory(IEnumerable<SupportFeedbackRecord> history)
    {
        Directory.CreateDirectory(AppDirectory);
        var retained = history.OrderByDescending(item => item.CreatedAt).Take(30).ToList();
        File.WriteAllText(HistoryPath, JsonSerializer.Serialize(retained, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static string ReadLogTail()
    {
        if (!File.Exists(LogPath)) return "No local diagnostic log was available.";
        const int maxBytes = 200_000;
        using var stream = new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var length = (int)Math.Min(stream.Length, maxBytes);
        stream.Seek(-length, SeekOrigin.End);
        var buffer = new byte[length];
        var total = 0;
        while (total < length)
        {
            var read = stream.Read(buffer, total, length - total);
            if (read == 0) break;
            total += read;
        }
        return Encoding.UTF8.GetString(buffer, 0, total);
    }

    private static string Redact(string value)
    {
        value = AuthorizationRegex().Replace(value, "$1<redacted>");
        value = SecretRegex().Replace(value, "$1<redacted>");
        value = ApiKeyRegex().Replace(value, "<redacted-api-key>");
        value = EmailRegex().Replace(value, "<redacted-email>");
        return UserPathRegex().Replace(value, "<user>");
    }

    private sealed class UploadResponse
    {
        public string Code { get; set; } = "";
        public string TrackingToken { get; set; } = "";
        public string Status { get; set; } = "new";
        public string UpdatedAt { get; set; } = "";
        public bool HasImage { get; set; }
    }

    private sealed class StatusResponse
    {
        public string Status { get; set; } = "new";
        public string UpdatedAt { get; set; } = "";
        public bool HasImage { get; set; }
    }

    [GeneratedRegex(@"(?i)(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s,;]+")]
    private static partial Regex AuthorizationRegex();
    [GeneratedRegex(@"(?i)((?:api[-_ ]?key|access[-_ ]?token|secret|password)\s*[:=]\s*)[^\s,;]+")]
    private static partial Regex SecretRegex();
    [GeneratedRegex(@"\bsk-[A-Za-z0-9_-]{12,}\b")]
    private static partial Regex ApiKeyRegex();
    [GeneratedRegex(@"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}")]
    private static partial Regex EmailRegex();
    [GeneratedRegex(@"(?i)(?:/Users/|[A-Z]:\\Users\\)([^/\\\s]+)")]
    private static partial Regex UserPathRegex();
}
