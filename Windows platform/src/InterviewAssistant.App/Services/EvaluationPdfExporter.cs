using System.IO;
using System.Net;
using System.Text;
using System.Windows;
using InterviewAssistant.Models;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace InterviewAssistant.Services;

/// <summary>
/// Exports a mock interview evaluation as PDF — same sections as the macOS writeMockEvaluationPDF
/// (title, date / role / overall score, evaluation, strengths, improvements, per-question review).
/// The report is laid out as HTML and printed to PDF by WebView2 (Edge), which handles CJK text.
/// </summary>
public static class EvaluationPdfExporter
{
    public static string SuggestedFileName(InterviewSessionModel session)
    {
        var title = string.IsNullOrWhiteSpace(session.Title) ? session.Role : session.Title;
        var invalid = Path.GetInvalidFileNameChars().Concat("/\\?%*|\"<>:").ToHashSet();
        var safe = new string((title ?? "").Select(character => invalid.Contains(character) ? '-' : character).ToArray()).Trim(' ', '-');
        return $"{(safe.Length == 0 ? "mock-interview" : safe)}-evaluation.pdf";
    }

    public static async Task ExportAsync(InterviewSessionModel session, string path)
    {
        var html = BuildHtml(session);
        // WebView2 needs a real HWND; host it in a tiny off-screen, non-activating window.
        var host = new Window
        {
            Width = 900,
            Height = 700,
            Left = -20000,
            Top = -20000,
            WindowStyle = WindowStyle.None,
            ShowInTaskbar = false,
            ShowActivated = false,
            AllowsTransparency = false
        };
        var webView = new WebView2
        {
            CreationProperties = new CoreWebView2CreationProperties
            {
                UserDataFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "InterviewAssistant", "WebView2")
            }
        };
        host.Content = webView;
        try
        {
            host.Show();
            await webView.EnsureCoreWebView2Async();
            var loaded = new TaskCompletionSource<bool>();
            webView.CoreWebView2.NavigationCompleted += (_, args) => loaded.TrySetResult(args.IsSuccess);
            webView.CoreWebView2.NavigateToString(html);
            if (!await loaded.Task) throw new InvalidOperationException(LocalizationManager.Text("PDF export failed."));

            var settings = webView.CoreWebView2.Environment.CreatePrintSettings();
            settings.Orientation = CoreWebView2PrintOrientation.Portrait;
            settings.PageWidth = 8.5;
            settings.PageHeight = 11;
            settings.MarginTop = settings.MarginBottom = 0.6;
            settings.MarginLeft = settings.MarginRight = 0.65;
            settings.ShouldPrintBackgrounds = true;
            settings.ShouldPrintHeaderAndFooter = false;
            if (!await webView.CoreWebView2.PrintToPdfAsync(path, settings))
                throw new InvalidOperationException(LocalizationManager.Text("PDF export failed."));
        }
        catch (WebView2RuntimeNotFoundException)
        {
            throw new InvalidOperationException(LocalizationManager.Text("WebView2RuntimeMissing"));
        }
        finally
        {
            webView.Dispose();
            host.Close();
        }
    }

    private static string BuildHtml(InterviewSessionModel session)
    {
        static string E(string? text) => WebUtility.HtmlEncode(text ?? "").Replace("\n", "<br>");
        static string Fallback(string? text) => string.IsNullOrWhiteSpace(text) ? LocalizationManager.Text("No feedback yet.") : text.Trim();
        string T(string key) => E(LocalizationManager.Text(key));
        var role = string.IsNullOrWhiteSpace(session.Role) ? session.Title : session.Role;

        var body = new StringBuilder();
        body.Append($"<h1>{T("Mock Interview Evaluation")}</h1>");
        body.Append($"<p class='muted'>{T("Created At")}: {E(session.StartedAt.LocalDateTime.ToString("g"))}<br>{T("Job Role")}: {E(role)}<br>{T("Overall Score")}: {session.OverallScore}</p>");
        body.Append($"<h2>{T("Interview Evaluation")}</h2><p>{E(Fallback(session.SummaryFeedback))}</p>");
        body.Append($"<h2>{T("Strengths")}</h2><p>{E(Fallback(session.StrengthsText))}</p>");
        body.Append($"<h2>{T("Improvement Suggestions")}</h2><p>{E(Fallback(session.ImprovementsText))}</p>");
        body.Append($"<h2>{T("Question Review")}</h2>");
        var index = 0;
        foreach (var turn in session.Turns.OrderBy(turn => turn.CreatedAt))
        {
            index++;
            var category = string.IsNullOrWhiteSpace(turn.Category) ? LocalizationManager.Text("Question") : turn.Category;
            var score = turn.Score > 0 ? $"&nbsp;&nbsp;{turn.Score} {T("Score")}" : "";
            body.Append("<section>");
            body.Append($"<h3>{index}. {E(category)}{score}</h3>");
            body.Append($"<p>{E(turn.Question)}</p>");
            body.Append($"<div class='label'>{T("Your Answer")}</div><p>{E(Fallback(turn.Answer))}</p>");
            body.Append($"<div class='label'>{T("AI Improvement Suggestion")}</div><p>{E(Fallback(turn.Feedback))}</p>");
            if (!string.IsNullOrWhiteSpace(turn.SuggestedAnswer))
                body.Append($"<div class='label'>{T("Suggested Answer")}</div><p>{E(turn.SuggestedAnswer)}</p>");
            body.Append("</section>");
        }

        return $$"""
            <!doctype html>
            <html><head><meta charset="utf-8">
            <style>
              body { font-family: "Segoe UI", "Microsoft YaHei UI", "Microsoft YaHei", sans-serif; color: #111827; font-size: 11pt; line-height: 1.55; margin: 0; }
              h1 { font-size: 24pt; margin: 0 0 8pt; }
              h2 { font-size: 16pt; margin: 18pt 0 6pt; }
              h3 { font-size: 13pt; margin: 14pt 0 4pt; }
              p { margin: 0 0 8pt; }
              .muted, .label { color: #6b7280; font-size: 10pt; }
              .label { margin-top: 6pt; }
              section { page-break-inside: avoid; border-top: 1px solid #e5e7eb; padding-top: 4pt; }
            </style></head>
            <body>{{body}}</body></html>
            """;
    }
}
