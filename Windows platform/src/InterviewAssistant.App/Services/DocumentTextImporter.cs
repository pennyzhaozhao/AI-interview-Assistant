using System.IO;
using System.IO.Compression;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Xml.Linq;
using UglyToad.PdfPig;

namespace InterviewAssistant.Services;

public static class DocumentTextImporter
{
    public static async Task<string> ExtractTextAsync(string path, int maxCharacters = 20_000)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();
        string text = extension switch
        {
            ".pdf" => ExtractPdf(path),
            ".docx" => ExtractDocx(path),
            ".rtf" => ExtractRtf(path),
            ".html" or ".htm" => ExtractHtml(await File.ReadAllTextAsync(path)),
            _ => await File.ReadAllTextAsync(path)
        };

        text = text.Replace("\0", "").Trim();
        return text.Length <= maxCharacters ? text : text[..maxCharacters].TrimEnd();
    }

    private static string ExtractDocx(string path)
    {
        using var archive = ZipFile.OpenRead(path);
        var entry = archive.GetEntry("word/document.xml") ?? throw new InvalidDataException("This Word document has no readable text.");
        string text;
        using (var stream = entry.Open())
        {
            var document = XDocument.Load(stream);
            XNamespace word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
            text = string.Join(Environment.NewLine, document.Descendants(word + "p")
                .Select(paragraph => string.Concat(paragraph.Descendants(word + "t").Select(node => node.Value)))
                .Where(value => !string.IsNullOrWhiteSpace(value)));
        }

        // Hyperlinks (e.g. a "GitHub" label in a resume) keep their address in the relationships part.
        var links = new List<(string Text, string Url)>();
        if (archive.GetEntry("word/_rels/document.xml.rels") is { } rels)
        {
            try
            {
                using var stream = rels.Open();
                var document = XDocument.Load(stream);
                foreach (var relationship in document.Root?.Elements() ?? [])
                {
                    var type = (string?)relationship.Attribute("Type") ?? "";
                    var target = (string?)relationship.Attribute("Target") ?? "";
                    if (type.EndsWith("/hyperlink", StringComparison.Ordinal)) links.Add(("", target));
                }
            }
            catch { /* links are optional */ }
        }
        return AppendLinks(text, links);
    }

    private static string ExtractPdf(string path)
    {
        using var document = PdfDocument.Open(path);
        var builder = new StringBuilder();
        var links = new List<(string Text, string Url)>();
        foreach (var page in document.GetPages())
        {
            if (builder.Length > 0) builder.AppendLine().AppendLine();
            builder.Append(page.Text);
            try
            {
                foreach (var link in page.GetHyperlinks()) links.Add((link.Text ?? "", link.Uri ?? ""));
            }
            catch { /* links are optional */ }
            if (builder.Length >= 20_000) break;
        }
        return AppendLinks(builder.ToString(), links);
    }

    /// <summary>
    /// Adds web links that are clickable in the document but not visible in its text
    /// (e.g. "GitHub" or "Demo" labels), so AI can find project links in resumes.
    /// </summary>
    private static string AppendLinks(string text, IEnumerable<(string Text, string Url)> links)
    {
        var lines = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (label, url) in links)
        {
            var clean = url.Trim();
            if (!clean.StartsWith("http://", StringComparison.OrdinalIgnoreCase) && !clean.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) continue;
            if (!seen.Add(clean.TrimEnd('/')) || text.Contains(clean.TrimEnd('/'), StringComparison.OrdinalIgnoreCase)) continue;
            var caption = Regex.Replace(label ?? "", @"\s+", " ").Trim();
            lines.Add(caption.Length > 0 && caption.Length <= 60 ? $"- {caption}: {clean}" : $"- {clean}");
        }
        return lines.Count == 0 ? text : $"{text.TrimEnd()}{Environment.NewLine}{Environment.NewLine}Links:{Environment.NewLine}{string.Join(Environment.NewLine, lines)}";
    }

    private static string ExtractRtf(string path)
    {
        var box = new RichTextBox();
        var range = new TextRange(box.Document.ContentStart, box.Document.ContentEnd);
        using var stream = File.OpenRead(path);
        range.Load(stream, DataFormats.Rtf);
        return range.Text;
    }

    private static string ExtractHtml(string html)
    {
        html = Regex.Replace(html, "<(script|style)[^>]*>[\\s\\S]*?</\\1>", " ", RegexOptions.IgnoreCase);
        return WebUtility.HtmlDecode(Regex.Replace(html, "<[^>]+>", " "));
    }
}
