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
        using var stream = entry.Open();
        var document = XDocument.Load(stream);
        XNamespace word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
        return string.Join(Environment.NewLine, document.Descendants(word + "p")
            .Select(paragraph => string.Concat(paragraph.Descendants(word + "t").Select(node => node.Value)))
            .Where(value => !string.IsNullOrWhiteSpace(value)));
    }

    private static string ExtractPdf(string path)
    {
        using var document = PdfDocument.Open(path);
        var builder = new StringBuilder();
        foreach (var page in document.GetPages())
        {
            if (builder.Length > 0) builder.AppendLine().AppendLine();
            builder.Append(page.Text);
            if (builder.Length >= 20_000) break;
        }
        return builder.ToString();
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
