using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using ICSharpCode.AvalonEdit;
using ICSharpCode.AvalonEdit.Document;
using ICSharpCode.AvalonEdit.Rendering;

namespace InterviewAssistant.Infrastructure;

public enum MarkdownFormatKind
{
    Bold, Italic, Underline, Strikethrough, InlineCode, Link, Heading, Quote, BulletList, OrderedList, CodeBlock
}

/// <summary>A formatting command; <see cref="Level"/> is the heading level (0 = plain paragraph).</summary>
public readonly record struct MarkdownFormatAction(MarkdownFormatKind Kind, int Level = 0);

/// <summary>
/// Pure text transformations behind the Markdown shortcuts and toolbar. Mirrors macOS
/// <c>MarkdownEditing</c> in MarkdownTextEditor.swift so both apps format the same way.
/// </summary>
public static class MarkdownEditing
{
    public readonly record struct Edit(int Start, int Length, string Replacement, int SelectionStart, int SelectionLength);

    public static Edit Compute(MarkdownFormatAction action, string text, int selectionStart, int selectionLength) => action.Kind switch
    {
        MarkdownFormatKind.Bold => Wrap(text, selectionStart, selectionLength, "**", "**"),
        MarkdownFormatKind.Italic => Wrap(text, selectionStart, selectionLength, "*", "*"),
        MarkdownFormatKind.Underline => Wrap(text, selectionStart, selectionLength, "<u>", "</u>"),
        MarkdownFormatKind.Strikethrough => Wrap(text, selectionStart, selectionLength, "~~", "~~"),
        MarkdownFormatKind.InlineCode => Wrap(text, selectionStart, selectionLength, "`", "`"),
        MarkdownFormatKind.Link => Link(text, selectionStart, selectionLength),
        MarkdownFormatKind.Heading => Heading(text, selectionStart, selectionLength, action.Level),
        MarkdownFormatKind.Quote => TogglePrefix(text, selectionStart, selectionLength, "> ", new Regex(@"^>\s?")),
        MarkdownFormatKind.BulletList => TogglePrefix(text, selectionStart, selectionLength, "- ", new Regex(@"^\s*[-*+]\s+")),
        MarkdownFormatKind.OrderedList => OrderedList(text, selectionStart, selectionLength),
        _ => CodeBlock(text, selectionStart, selectionLength)
    };

    /// <summary>Wraps the selection in markers, or removes them when it is already wrapped.</summary>
    private static Edit Wrap(string text, int start, int length, string open, string close)
    {
        var selected = text.Substring(start, length);
        if (start >= open.Length && start + length + close.Length <= text.Length
            && string.CompareOrdinal(text, start - open.Length, open, 0, open.Length) == 0
            && string.CompareOrdinal(text, start + length, close, 0, close.Length) == 0)
        {
            var outerStart = start - open.Length;
            return new Edit(outerStart, length + open.Length + close.Length, selected, outerStart, length);
        }
        if (selected.Length >= open.Length + close.Length && selected.StartsWith(open, StringComparison.Ordinal) && selected.EndsWith(close, StringComparison.Ordinal))
        {
            var inner = selected[open.Length..^close.Length];
            return new Edit(start, length, inner, start, inner.Length);
        }
        return new Edit(start, length, open + selected + close, start + open.Length, length);
    }

    private static Edit Link(string text, int start, int length)
    {
        const string placeholder = "https://";
        var selected = text.Substring(start, length);
        if (selected.Length == 0) return new Edit(start, 0, $"[]({placeholder})", start + 1, 0);
        return new Edit(start, length, $"[{selected}]({placeholder})", start + selected.Length + 3, placeholder.Length);
    }

    /// <summary>Start and end (including the line break) of every line touched by the selection.</summary>
    private static (int Start, int End) LineRange(string text, int start, int length)
    {
        var lineStart = start == 0 ? 0 : text.LastIndexOf('\n', start - 1) + 1;
        var last = length > 0 ? start + length - 1 : start;
        var newline = last < text.Length ? text.IndexOf('\n', last) : -1;
        return (lineStart, newline < 0 ? text.Length : newline + 1);
    }

    /// <summary>Applies <paramref name="transform"/> to each touched line (line breaks preserved) and selects the result.</summary>
    private static Edit TransformLines(string text, int start, int length, Func<List<string>, List<string>> transform)
    {
        var (lineStart, lineEnd) = LineRange(text, start, length);
        var block = text[lineStart..lineEnd];
        var rawLines = block.Split('\n');
        var lines = new List<string>();
        var endings = new List<string>();
        for (var index = 0; index < rawLines.Length; index++)
        {
            var line = rawLines[index];
            var isLast = index == rawLines.Length - 1;
            if (isLast && line.Length == 0 && block.EndsWith('\n')) break;
            var ending = isLast ? "" : "\n";
            if (line.EndsWith('\r')) { line = line[..^1]; ending = "\r" + ending; }
            lines.Add(line);
            endings.Add(ending);
        }
        var transformed = transform(lines);
        var replacement = string.Concat(transformed.Select((line, index) => line + endings[index]));
        var visible = replacement.TrimEnd('\n', '\r');
        return length == 0 && lines.Count == 1
            ? new Edit(lineStart, lineEnd - lineStart, replacement, lineStart + visible.Length, 0)
            : new Edit(lineStart, lineEnd - lineStart, replacement, lineStart, visible.Length);
    }

    private static Edit Heading(string text, int start, int length, int level) =>
        TransformLines(text, start, length, lines => lines.Select(line =>
        {
            var current = line.TakeWhile(character => character == '#').Count();
            var body = current > 0 ? line[current..].TrimStart(' ', '\t') : line;
            // The same level again turns the heading back into a paragraph (Typora behaviour).
            if (level == 0 || current == level) return body;
            return new string('#', level) + " " + body;
        }).ToList());

    private static Edit TogglePrefix(string text, int start, int length, string prefix, Regex pattern) =>
        TransformLines(text, start, length, lines =>
        {
            var nonEmpty = lines.Where(line => !string.IsNullOrWhiteSpace(line)).ToList();
            var allHave = nonEmpty.Count > 0 && nonEmpty.All(pattern.IsMatch);
            return lines.Select(line =>
            {
                if (allHave) return pattern.Replace(line, "", 1);
                if (string.IsNullOrWhiteSpace(line) && lines.Count > 1) return line;
                return prefix + line;
            }).ToList();
        });

    private static readonly Regex OrderedPattern = new(@"^\s*\d+[.)]\s+");
    private static readonly Regex BulletPattern = new(@"^\s*[-*+]\s+");

    private static Edit OrderedList(string text, int start, int length) =>
        TransformLines(text, start, length, lines =>
        {
            var nonEmpty = lines.Where(line => !string.IsNullOrWhiteSpace(line)).ToList();
            var allHave = nonEmpty.Count > 0 && nonEmpty.All(OrderedPattern.IsMatch);
            var number = 0;
            return lines.Select(line =>
            {
                if (allHave) return OrderedPattern.Replace(line, "", 1);
                if (string.IsNullOrWhiteSpace(line) && lines.Count > 1) return line;
                number++;
                return $"{number}. " + BulletPattern.Replace(line, "", 1);
            }).ToList();
        });

    private static Edit CodeBlock(string text, int start, int length)
    {
        var (lineStart, lineEnd) = LineRange(text, start, length);
        var block = text[lineStart..lineEnd];
        var trailing = block.EndsWith("\r\n", StringComparison.Ordinal) ? "\r\n" : block.EndsWith('\n') ? "\n" : "";
        var body = block[..^trailing.Length];
        var newline = trailing.Length > 0 ? trailing : (text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n");
        var fence = "```" + newline;
        if (string.IsNullOrWhiteSpace(body))
            return new Edit(lineStart, lineEnd - lineStart, fence + newline + "```" + trailing, lineStart + fence.Length, 0);
        return new Edit(lineStart, lineEnd - lineStart, fence + body + newline + "```" + trailing, lineStart + fence.Length, body.Length);
    }

    /// <summary>Typora's Windows shortcuts.</summary>
    public static MarkdownFormatAction? ActionFor(Key key, ModifierKeys modifiers)
    {
        var ctrl = modifiers.HasFlag(ModifierKeys.Control);
        var shift = modifiers.HasFlag(ModifierKeys.Shift);
        var alt = modifiers.HasFlag(ModifierKeys.Alt);
        if (alt && shift && !ctrl && key == Key.D5) return new(MarkdownFormatKind.Strikethrough);
        if (!ctrl || alt) return null;
        if (shift)
        {
            return key switch
            {
                Key.OemTilde => new(MarkdownFormatKind.InlineCode),
                Key.Q => new(MarkdownFormatKind.Quote),
                Key.OemOpenBrackets => new(MarkdownFormatKind.OrderedList),
                Key.OemCloseBrackets => new(MarkdownFormatKind.BulletList),
                Key.K => new(MarkdownFormatKind.CodeBlock),
                _ => null
            };
        }
        return key switch
        {
            Key.B => new(MarkdownFormatKind.Bold),
            Key.I => new(MarkdownFormatKind.Italic),
            Key.U => new(MarkdownFormatKind.Underline),
            Key.K => new(MarkdownFormatKind.Link),
            >= Key.D0 and <= Key.D6 => new(MarkdownFormatKind.Heading, key - Key.D0),
            >= Key.NumPad0 and <= Key.NumPad6 => new(MarkdownFormatKind.Heading, key - Key.NumPad0),
            _ => null
        };
    }
}

/// <summary>
/// Markdown note editor with Typora-style live styling: headings, bold, italic, code, quotes, lists and
/// links are rendered in place; the syntax characters are faint on the line being edited and hidden on
/// the others. Built on AvalonEdit, which also handles very long notes smoothly.
/// </summary>
public sealed class MarkdownEditor : TextEditor
{
    private readonly MarkdownColorizer _colorizer = new();
    private int _activeLine = -1;

    public MarkdownEditor()
    {
        WordWrap = true;
        ShowLineNumbers = false;
        FontSize = MarkdownColorizer.BodySize;
        FontFamily = new FontFamily("Segoe UI, Microsoft YaHei UI");
        Background = Brushes.Transparent;
        HorizontalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Disabled;
        VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto;
        Options.EnableHyperlinks = false;
        Options.EnableEmailHyperlinks = false;
        Options.EnableRectangularSelection = false;
        Options.HighlightCurrentLine = false;
        SetResourceReference(ForegroundProperty, "TextPrimaryBrush");
        TextArea.TextView.LineTransformers.Add(_colorizer);
        TextArea.Margin = new Thickness(4, 6, 4, 6);
        TextArea.SelectionCornerRadius = 2;

        TextChanged += (_, _) => { _colorizer.UpdateCodeBlocks(Document); TextArea.TextView.Redraw(); };
        TextArea.Caret.PositionChanged += (_, _) => UpdateActiveLine();
        TextArea.PreviewKeyDown += OnPreviewKeyDown;
        Loaded += (_, _) => { _colorizer.UpdateCodeBlocks(Document); UpdateActiveLine(force: true); };
    }

    public void Apply(MarkdownFormatAction action)
    {
        var text = Document.Text;
        var edit = MarkdownEditing.Compute(action, text, SelectionStart, SelectionLength);
        using (Document.RunUpdate())   // one undo step (Ctrl+Z)
        {
            Document.Replace(edit.Start, edit.Length, edit.Replacement);
        }
        Select(edit.SelectionStart, edit.SelectionLength);
        TextArea.Focus();
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (MarkdownEditing.ActionFor(key, Keyboard.Modifiers) is not { } action) return;
        e.Handled = true;
        Apply(action);
    }

    private void UpdateActiveLine(bool force = false)
    {
        var line = TextArea.Caret.Line;
        if (!force && line == _activeLine) return;
        _activeLine = line;
        _colorizer.ActiveLine = line;
        TextArea.TextView.Redraw();
    }
}

internal sealed class MarkdownColorizer : DocumentColorizingTransformer
{
    public const double BodySize = 15;
    private static readonly double[] HeadingSizes = [26, 22, 19, 17, 16, 15];

    private static readonly Regex Heading = new(@"^(#{1,6})[ \t]+", RegexOptions.Compiled);
    private static readonly Regex Quote = new(@"^>[ \t]?", RegexOptions.Compiled);
    private static readonly Regex ListMarker = new(@"^[ \t]*([-*+]|\d+[.)])[ \t]+", RegexOptions.Compiled);
    private static readonly Regex Rule = new(@"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$", RegexOptions.Compiled);
    private static readonly Regex InlineCode = new(@"`[^`\n]+`", RegexOptions.Compiled);
    private static readonly Regex Bold = new(@"(\*\*|__)(?=\S)(.+?)(?<=\S)\1", RegexOptions.Compiled);
    // "*斜体*" works next to Chinese text; "_" needs word boundaries so snake_case is left alone.
    private static readonly Regex StarItalic = new(@"(?<![*\\])(\*)(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?!\*)", RegexOptions.Compiled);
    private static readonly Regex UnderscoreItalic = new(@"(?<![\w\\])(_)(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?!\w)", RegexOptions.Compiled);
    private static readonly Regex Strike = new(@"~~(?=\S)(.+?)(?<=\S)~~", RegexOptions.Compiled);
    private static readonly Regex Underline = new(@"<u>(.+?)</u>", RegexOptions.Compiled);
    private static readonly Regex Link = new(@"(?<!!)\[([^\]\n]+)\]\(([^)\s]+)\)", RegexOptions.Compiled);

    /// <summary>Line numbers (1-based) inside fenced code blocks; fence lines are marked true.</summary>
    private readonly Dictionary<int, bool> _codeLines = [];
    public int ActiveLine { get; set; } = -1;

    public void UpdateCodeBlocks(TextDocument document)
    {
        _codeLines.Clear();
        var open = false;
        foreach (var line in document.Lines)
        {
            var content = document.GetText(line).Trim();
            var isFence = content.StartsWith("```", StringComparison.Ordinal) || content.StartsWith("~~~", StringComparison.Ordinal);
            if (isFence) { _codeLines[line.LineNumber] = true; open = !open; continue; }
            if (open) _codeLines[line.LineNumber] = false;
        }
    }

    private static Brush Resource(string key, Brush fallback) =>
        Application.Current?.TryFindResource(key) as Brush ?? fallback;

    protected override void ColorizeLine(DocumentLine line)
    {
        if (line.Length == 0) return;
        var text = CurrentContext.Document.GetText(line);
        var offset = line.Offset;
        var muted = Resource("TextSecondaryBrush", Brushes.Gray);
        var accent = Resource("PrimaryBrush", Brushes.RoyalBlue);
        var codeBackground = Resource("ButtonBrush", Brushes.WhiteSmoke);
        var mono = new FontFamily("Cascadia Mono, Consolas, Microsoft YaHei UI");

        if (_codeLines.TryGetValue(line.LineNumber, out var isFence))
        {
            Change(offset, offset + line.Length, element =>
            {
                element.TextRunProperties.SetTypeface(WithFamily(element, mono));
                element.TextRunProperties.SetFontRenderingEmSize(BodySize - 1);
                element.TextRunProperties.SetBackgroundBrush(codeBackground);
                if (isFence) element.TextRunProperties.SetForegroundBrush(muted);
            });
            return;
        }

        var isActive = line.LineNumber == ActiveLine;
        var syntax = new List<(int Start, int Length)>();

        if (Heading.Match(text) is { Success: true } heading)
        {
            var size = HeadingSizes[heading.Groups[1].Length - 1];
            Change(offset, offset + line.Length, element =>
            {
                element.TextRunProperties.SetFontRenderingEmSize(size);
                element.TextRunProperties.SetTypeface(WithWeight(element, FontWeights.Bold));
            });
            syntax.Add((0, heading.Length));
        }
        else if (Quote.Match(text) is { Success: true } quote)
        {
            Change(offset, offset + line.Length, element => element.TextRunProperties.SetForegroundBrush(muted));
            syntax.Add((0, quote.Length));
        }
        else if (ListMarker.Match(text) is { Success: true } list)
        {
            var marker = list.Groups[1];
            Change(offset + marker.Index, offset + marker.Index + marker.Length, element =>
            {
                element.TextRunProperties.SetForegroundBrush(accent);
                element.TextRunProperties.SetTypeface(WithWeight(element, FontWeights.SemiBold));
            });
        }
        else if (Rule.IsMatch(text))
        {
            Change(offset, offset + line.Length, element => element.TextRunProperties.SetForegroundBrush(muted));
        }

        var codeSpans = InlineCode.Matches(text).Select(match => (match.Index, match.Length)).ToList();
        bool Protected(Match match) => codeSpans.Any(span => match.Index < span.Index + span.Length && span.Index < match.Index + match.Length);
        foreach (var (index, length) in codeSpans)
        {
            Change(offset + index, offset + index + length, element =>
            {
                element.TextRunProperties.SetTypeface(WithFamily(element, mono));
                element.TextRunProperties.SetBackgroundBrush(codeBackground);
            });
            syntax.Add((index, 1));
            syntax.Add((index + length - 1, 1));
        }
        foreach (Match match in Bold.Matches(text))
        {
            if (Protected(match)) continue;
            var inner = match.Groups[2];
            Change(offset + inner.Index, offset + inner.Index + inner.Length, element => element.TextRunProperties.SetTypeface(WithWeight(element, FontWeights.Bold)));
            syntax.Add((match.Index, 2));
            syntax.Add((match.Index + match.Length - 2, 2));
        }
        foreach (var match in StarItalic.Matches(text).Concat(UnderscoreItalic.Matches(text)))
        {
            if (Protected(match)) continue;
            var inner = match.Groups[2];
            Change(offset + inner.Index, offset + inner.Index + inner.Length, element => element.TextRunProperties.SetTypeface(WithStyle(element, FontStyles.Italic)));
            syntax.Add((match.Index, 1));
            syntax.Add((match.Index + match.Length - 1, 1));
        }
        foreach (Match match in Strike.Matches(text))
        {
            if (Protected(match)) continue;
            var inner = match.Groups[1];
            Change(offset + inner.Index, offset + inner.Index + inner.Length, element => element.TextRunProperties.SetTextDecorations(TextDecorations.Strikethrough));
            syntax.Add((match.Index, 2));
            syntax.Add((match.Index + match.Length - 2, 2));
        }
        foreach (Match match in Underline.Matches(text))
        {
            if (Protected(match)) continue;
            var inner = match.Groups[1];
            Change(offset + inner.Index, offset + inner.Index + inner.Length, element => element.TextRunProperties.SetTextDecorations(TextDecorations.Underline));
            syntax.Add((match.Index, 3));
            syntax.Add((match.Index + match.Length - 4, 4));
        }
        foreach (Match match in Link.Matches(text))
        {
            if (Protected(match)) continue;
            var label = match.Groups[1];
            Change(offset + label.Index, offset + label.Index + label.Length, element =>
            {
                element.TextRunProperties.SetForegroundBrush(accent);
                element.TextRunProperties.SetTextDecorations(TextDecorations.Underline);
            });
            syntax.Add((match.Index, 1));
            var labelEnd = label.Index + label.Length;
            syntax.Add((labelEnd, match.Index + match.Length - labelEnd));
        }

        foreach (var (start, length) in syntax)
        {
            if (length <= 0 || start + length > line.Length) continue;
            if (isActive)
            {
                Change(offset + start, offset + start + length, element => element.TextRunProperties.SetForegroundBrush(muted));
            }
            else
            {
                // Hidden like Typora: a 1px transparent run instead of the syntax characters.
                Change(offset + start, offset + start + length, element =>
                {
                    element.TextRunProperties.SetForegroundBrush(Brushes.Transparent);
                    element.TextRunProperties.SetBackgroundBrush(null);
                    element.TextRunProperties.SetTextDecorations(null);
                    element.TextRunProperties.SetFontRenderingEmSize(1);
                });
            }
        }
    }

    private void Change(int start, int end, Action<VisualLineElement> action)
    {
        if (end > start) ChangeLinePart(start, end, action);
    }

    private static Typeface WithWeight(VisualLineElement element, FontWeight weight)
    {
        var typeface = element.TextRunProperties.Typeface;
        return new Typeface(typeface.FontFamily, typeface.Style, weight, typeface.Stretch);
    }

    private static Typeface WithStyle(VisualLineElement element, FontStyle style)
    {
        var typeface = element.TextRunProperties.Typeface;
        return new Typeface(typeface.FontFamily, style, typeface.Weight, typeface.Stretch);
    }

    private static Typeface WithFamily(VisualLineElement element, FontFamily family)
    {
        var typeface = element.TextRunProperties.Typeface;
        return new Typeface(family, typeface.Style, typeface.Weight, typeface.Stretch);
    }
}
