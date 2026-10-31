using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using InterviewAssistant.Models;

namespace InterviewAssistant.Services;

/// <summary>
/// Port of the macOS WebsiteResearchService: fetch the company page (plus same-site scripts for
/// single-page apps), extract metadata / embedded JSON / visible text, then let the configured AI
/// write a company research note for "你对我们公司有什么了解？".
/// </summary>
public static class WebsiteResearchService
{
    private static readonly HttpClient Client = CreateClient();

    public static async Task<string> ResearchCompanyAsync(string input, AIConfig config, CancellationToken cancellationToken = default)
    {
        var url = NormalizedUrl(input);
        var html = await FetchRawTextAsync(url, 350_000, cancellationToken);
        var context = await WebsiteContextAsync(html, url, cancellationToken);
        if (context.Length == 0)
            throw new InvalidOperationException(LocalizationManager.Text("No content suitable for analysis was extracted from the company website."));
        return await SummarizeCompanyAsync(context, url, config, cancellationToken);
    }

    public static string NormalizedUrl(string input)
    {
        var clean = input.Trim();
        return clean.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || clean.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            ? clean
            : "https://" + clean;
    }

    private static HttpClient CreateClient()
    {
        var handler = new HttpClientHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            AllowAutoRedirect = true
        };
        var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
        // Same identity as the macOS app (URLSession also sends Accept / Accept-Language by default).
        client.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 InterviewAssistant/1.0");
        client.DefaultRequestHeaders.TryAddWithoutValidation("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
        client.DefaultRequestHeaders.TryAddWithoutValidation("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
        return client;
    }

    private static async Task<string> FetchRawTextAsync(string url, int maxCharacters, CancellationToken cancellationToken)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
            throw new InvalidOperationException(LocalizationManager.Text("Enter a valid company website first."));
        using var response = await Client.GetAsync(uri, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var code = (int)response.StatusCode;
            throw new HttpRequestException(code is 401 or 403 or 429 or 503
                ? string.Format(LocalizationManager.Text("WebsiteBlockedMessage"), code)
                : string.Format(LocalizationManager.Text("Source returned HTTP {0}"), code));
        }
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        var text = Encoding.UTF8.GetString(bytes);
        return text.Length > maxCharacters ? text[..maxCharacters] : text;
    }

    private static async Task<string> WebsiteContextAsync(string html, string baseUrl, CancellationToken cancellationToken)
    {
        var parts = new List<string>();
        var metadata = ExtractMetadata(html);
        if (metadata.Length > 0) parts.Add($"Metadata:\n{metadata}");
        var json = ExtractJsonScriptText(html);
        if (json.Length > 0) parts.Add($"Embedded JSON / app data:\n{json}");
        var visible = CleanHtmlText(html);
        if (visible.Length > 0) parts.Add($"Visible page text:\n{visible}");
        var scripts = await FetchScriptStringContextAsync(html, baseUrl, cancellationToken);
        if (scripts.Length > 0) parts.Add($"JavaScript text clues:\n{scripts}");
        return string.Join("\n\n---\n\n", parts).Trim();
    }

    private static async Task<string> SummarizeCompanyAsync(string context, string sourceUrl, AIConfig config, CancellationToken cancellationToken)
    {
        const string systemPrompt = """
            You are a company research analyst helping a candidate prepare for an interview.
            Write in Simplified Chinese. Use only the supplied website text. If a detail is uncertain, say it looks like or appears to be, not as a fact.
            The output should be useful for answering “你对我们公司有什么了解？” in an interview.
            Avoid generic website-summary language. Extract business model, target customers, services, market, proof points, and interview talking points.
            """;
        var question = $"""
            Source URL: {sourceUrl}

            Website text:
            {(context.Length > 24_000 ? context[..24_000] : context)}

            Please produce a concise but rich company research note with this structure:
            1. 一句话概括这家公司
            2. 目标客户 / 服务对象
            3. 主要业务或产品
            4. 关键卖点、数据或资源
            5. 面试中可以怎么回答“你对我们公司有什么了解”
            6. 候选人可以追问公司的 3 个问题
            """;
        var result = await AppServices.Current.AI.CompleteAsync(config, systemPrompt, question, 1200, cancellationToken);
        if (string.IsNullOrWhiteSpace(result))
            throw new InvalidOperationException(LocalizationManager.Text("The current AI provider did not return company information."));
        return result.Trim();
    }

    private static string ExtractMetadata(string html)
    {
        var lines = new List<string>();
        var title = FirstMatch(@"(?is)<title[^>]*>(.*?)</title>", html);
        if (title is not null) lines.Add("title: " + DecodeEntities(StripTags(title)));
        string[] patterns =
        [
            """(?is)<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["'][^>]*>""",
            """(?is)<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["'][^>]*>""",
            """(?is)<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)["'][^>]*>""",
            """(?is)<meta[^>]+name=["']keywords["'][^>]+content=["']([^"']+)["'][^>]*>"""
        ];
        foreach (var pattern in patterns) lines.AddRange(Matches(pattern, html).Select(DecodeEntities));
        return string.Join("\n", UniqueLines(lines));
    }

    private static string ExtractJsonScriptText(string html)
    {
        var scripts = Matches("""(?is)<script[^>]*type=["']application/json["'][^>]*>(.*?)</script>""", html)
            .Concat(Matches("""(?is)<script[^>]*id=["']__NEXT_DATA__["'][^>]*>(.*?)</script>""", html));
        var cleaned = scripts
            .Select(DecodeEntities)
            .Select(text => Regex.Replace(text, """["{}:,\\]+""", " "))
            .Select(NormalizeWhitespace)
            .Where(text => text.Length > 30);
        return Prefix(string.Join("\n", UniqueLines(cleaned)), 8_000);
    }

    private static string CleanHtmlText(string html)
    {
        var text = Regex.Replace(html, @"(?is)<script.*?</script>", " ");
        text = Regex.Replace(text, @"(?is)<style.*?</style>", " ");
        text = Regex.Replace(text, @"(?is)<svg.*?</svg>", " ");
        text = Regex.Replace(text, @"(?is)<[^>]+>", "\n");
        return Prefix(NormalizeWhitespace(DecodeEntities(text)), 8_000);
    }

    private static async Task<string> FetchScriptStringContextAsync(string html, string baseUrl, CancellationToken cancellationToken)
    {
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var baseUri)) return "";
        var sources = Matches("""(?is)<script[^>]+src=["']([^"']+\.js[^"']*)["'][^>]*>""", html)
            .Select(source => Uri.TryCreate(baseUri, source, out var absolute) ? absolute : null)
            .Where(uri => uri is not null && uri.Host == baseUri.Host)
            .Take(8)
            .ToList();
        var snippets = new List<string>();
        foreach (var uri in sources)
        {
            string text;
            try { text = await FetchRawTextAsync(uri!.AbsoluteUri, 80_000, cancellationToken); }
            catch { continue; }
            var strings = Matches("\"([^\"\\\\]{12,180})\"", text).Concat(Matches("'([^'\\\\]{12,180})'", text));
            snippets.AddRange(strings.Select(DecodeEntities).Select(NormalizeWhitespace).Where(IsUsefulScriptString).Take(80));
            if (snippets.Count > 180) break;
        }
        return Prefix(string.Join("\n", UniqueLines(snippets)), 10_000);
    }

    private static bool IsUsefulScriptString(string value)
    {
        var lower = value.ToLowerInvariant();
        if (value.Length < 12) return false;
        if (lower.Contains("function") || lower.Contains("webpack") || lower.Contains("chunk")) return false;
        if (lower.Contains(".css") || lower.Contains(".svg") || lower.Contains("http")) return false;
        return Regex.IsMatch(value, @"[A-Za-z一-鿿]");
    }

    private static IEnumerable<string> Matches(string pattern, string text) =>
        Regex.Matches(text, pattern).Where(match => match.Groups.Count > 1).Select(match => match.Groups[1].Value);

    private static string? FirstMatch(string pattern, string text) => Matches(pattern, text).FirstOrDefault();
    private static string StripTags(string text) => Regex.Replace(text, @"(?is)<[^>]+>", " ");
    private static string DecodeEntities(string text) => WebUtility.HtmlDecode(text);
    private static string NormalizeWhitespace(string text) => Regex.Replace(text, @"\s+", " ").Trim();
    private static string Prefix(string text, int count) => text.Length > count ? text[..count] : text;

    private static IEnumerable<string> UniqueLines(IEnumerable<string> lines)
    {
        var seen = new HashSet<string>();
        foreach (var line in lines)
        {
            var clean = line.Trim();
            if (clean.Length > 0 && seen.Add(clean)) yield return clean;
        }
    }
}
