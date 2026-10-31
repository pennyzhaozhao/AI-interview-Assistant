using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace InterviewAssistant.Infrastructure;

/// <summary>
/// Renders an AI answer (Markdown) into WPF elements for the prompter island.
/// Mirrors the macOS AnswerRenderer / MarkdownTextView / CodeBlockView:
/// headings, paragraphs, bullet / numbered lists, quotes, dividers, inline **bold** / *italic* / `code`,
/// and fenced code blocks drawn as a white card with line numbers, syntax colours and a copy button.
/// </summary>
public static class MarkdownAnswerRenderer
{
    private static readonly FontFamily CodeFont = new("Cascadia Mono, Consolas, Courier New");
    private static readonly FontFamily IconFont = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    private static readonly Regex InlinePattern = new(
        @"(\*\*(?<bold>.+?)\*\*|__(?<bold2>.+?)__|`(?<code>[^`]+)`|(?<![\w*])\*(?<italic>[^*\s](?:[^*]*[^*\s])?)\*(?![\w*])|\[(?<link>[^\]]+)\]\([^)]+\))",
        RegexOptions.Compiled);

    private static readonly Regex OrderedItemPattern = new(@"^(?<marker>\d{1,3}[.)])\s+(?<text>.+)$", RegexOptions.Compiled);

    public static void Render(Panel target, string markdown, Brush foreground, double fontSize, Style? codeScrollBarStyle = null)
    {
        target.Children.Clear();
        foreach (var block in SplitCodeFences(markdown ?? ""))
        {
            if (block.IsCode)
            {
                var code = block.Text.Trim('\r', '\n');
                if (code.Trim().Length > 0) target.Children.Add(CreateCodeBlock(code, block.Language, codeScrollBarStyle));
            }
            else
            {
                AddMarkdownText(target, block.Text, foreground, fontSize);
            }
        }
        if (target.Children.Count > 0 && target.Children[^1] is FrameworkElement last) last.Margin = new Thickness(last.Margin.Left, last.Margin.Top, last.Margin.Right, 4);
    }

    /// <summary>Plain (non-markdown) message such as a status or error line.</summary>
    public static void RenderPlain(Panel target, string text, Brush foreground, double fontSize)
    {
        target.Children.Clear();
        target.Children.Add(new TextBlock
        {
            Text = text,
            Foreground = foreground,
            FontSize = fontSize,
            FontWeight = FontWeights.SemiBold,
            LineHeight = Math.Round(fontSize * 1.45),
            TextWrapping = TextWrapping.Wrap
        });
    }

    // ───────────────────────── block parsing ─────────────────────────

    private sealed record Block(bool IsCode, string Text, string Language);

    private static IEnumerable<Block> SplitCodeFences(string markdown)
    {
        var lines = markdown.Replace("\r\n", "\n").Split('\n');
        var buffer = new StringBuilder();
        var inCode = false;
        var language = "";
        foreach (var line in lines)
        {
            var trimmed = line.TrimStart();
            if (trimmed.StartsWith("```") || trimmed.StartsWith("~~~"))
            {
                if (!inCode)
                {
                    if (buffer.Length > 0) yield return new Block(false, buffer.ToString(), "");
                    buffer.Clear();
                    inCode = true;
                    language = trimmed[3..].Trim();
                }
                else
                {
                    yield return new Block(true, buffer.ToString(), language);
                    buffer.Clear();
                    inCode = false;
                    language = "";
                }
                continue;
            }
            buffer.Append(line).Append('\n');
        }
        // An unterminated fence (e.g. truncated answer) is still shown as code.
        if (buffer.Length > 0) yield return new Block(inCode, buffer.ToString(), language);
    }

    private static void AddMarkdownText(Panel target, string text, Brush foreground, double fontSize)
    {
        var paragraph = new List<string>();
        var spacing = Math.Round(fontSize * 0.5);

        void FlushParagraph()
        {
            if (paragraph.Count == 0) return;
            var block = CreateTextBlock(foreground, fontSize, FontWeights.SemiBold);
            for (var index = 0; index < paragraph.Count; index++)
            {
                if (index > 0) block.Inlines.Add(new LineBreak());
                AddInlines(block.Inlines, paragraph[index], foreground, fontSize);
            }
            block.Margin = new Thickness(0, 0, 0, spacing);
            target.Children.Add(block);
            paragraph.Clear();
        }

        foreach (var rawLine in text.Split('\n'))
        {
            var trimmed = rawLine.Trim();
            if (trimmed.Length == 0) { FlushParagraph(); continue; }

            var hashes = trimmed.TakeWhile(character => character == '#').Count();
            if (hashes is >= 1 and <= 6 && trimmed.Length > hashes && trimmed[hashes] == ' ')
            {
                FlushParagraph();
                var size = fontSize * (hashes switch { 1 => 1.32, 2 => 1.22, 3 => 1.12, _ => 1.05 });
                var heading = CreateTextBlock(foreground, size, FontWeights.Bold);
                AddInlines(heading.Inlines, trimmed[(hashes + 1)..].Trim(), foreground, size);
                heading.Margin = new Thickness(0, target.Children.Count == 0 ? 0 : 4, 0, spacing);
                target.Children.Add(heading);
                continue;
            }

            if (trimmed is "---" or "***" or "___")
            {
                FlushParagraph();
                target.Children.Add(new Border { Height = 1, Background = WithOpacity(foreground, 0.22), Margin = new Thickness(0, 4, 0, spacing + 4) });
                continue;
            }

            if (trimmed.StartsWith("> ") || trimmed == ">")
            {
                FlushParagraph();
                var quoteText = CreateTextBlock(WithOpacity(foreground, 0.82), fontSize, FontWeights.Medium);
                quoteText.FontStyle = FontStyles.Italic;
                AddInlines(quoteText.Inlines, trimmed.TrimStart('>').Trim(), WithOpacity(foreground, 0.82), fontSize);
                target.Children.Add(new Border
                {
                    BorderBrush = WithOpacity(foreground, 0.45),
                    BorderThickness = new Thickness(3, 0, 0, 0),
                    Padding = new Thickness(10, 0, 0, 0),
                    Margin = new Thickness(0, 0, 0, spacing),
                    Child = quoteText
                });
                continue;
            }

            if (trimmed.Length > 2 && trimmed[0] is '-' or '*' or '+' && trimmed[1] == ' ')
            {
                FlushParagraph();
                var indent = (rawLine.Length - rawLine.TrimStart().Length) >= 2 ? fontSize : 0;
                target.Children.Add(CreateListItem("•", trimmed[2..].Trim(), foreground, fontSize, spacing, indent));
                continue;
            }

            var ordered = OrderedItemPattern.Match(trimmed);
            if (ordered.Success)
            {
                FlushParagraph();
                target.Children.Add(CreateListItem(ordered.Groups["marker"].Value, ordered.Groups["text"].Value, foreground, fontSize, spacing, 0));
                continue;
            }

            paragraph.Add(trimmed);
        }
        FlushParagraph();
    }

    private static UIElement CreateListItem(string marker, string text, Brush foreground, double fontSize, double spacing, double indent)
    {
        var grid = new Grid { Margin = new Thickness(indent, 0, 0, Math.Round(spacing * 0.6)) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(fontSize * 1.25, marker.Length * fontSize * 0.62)) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var markerBlock = CreateTextBlock(WithOpacity(foreground, 0.82), fontSize, FontWeights.Bold);
        markerBlock.Text = marker;
        markerBlock.TextWrapping = TextWrapping.NoWrap;
        var body = CreateTextBlock(foreground, fontSize, FontWeights.SemiBold);
        AddInlines(body.Inlines, text, foreground, fontSize);
        Grid.SetColumn(body, 1);
        grid.Children.Add(markerBlock);
        grid.Children.Add(body);
        return grid;
    }

    private static TextBlock CreateTextBlock(Brush foreground, double fontSize, FontWeight weight) => new()
    {
        Foreground = foreground,
        FontSize = fontSize,
        FontWeight = weight,
        LineHeight = Math.Round(fontSize * 1.45),
        LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
        TextWrapping = TextWrapping.Wrap
    };

    private static void AddInlines(InlineCollection inlines, string text, Brush foreground, double fontSize)
    {
        var position = 0;
        foreach (Match match in InlinePattern.Matches(text))
        {
            if (match.Index > position) inlines.Add(new Run(text[position..match.Index]));
            if (match.Groups["bold"].Success || match.Groups["bold2"].Success)
            {
                var inner = match.Groups["bold"].Success ? match.Groups["bold"].Value : match.Groups["bold2"].Value;
                var bold = new Bold();
                AddInlines(bold.Inlines, inner, foreground, fontSize);
                inlines.Add(bold);
            }
            else if (match.Groups["code"].Success)
            {
                inlines.Add(new Run(" " + match.Groups["code"].Value + " ")
                {
                    FontFamily = CodeFont,
                    FontSize = Math.Max(11, fontSize * 0.86),
                    FontWeight = FontWeights.Normal,
                    Background = new SolidColorBrush(Color.FromArgb(0x2E, 0xFF, 0xFF, 0xFF)),
                    Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0xE5, 0x8F))
                });
            }
            else if (match.Groups["italic"].Success)
            {
                var italic = new Italic();
                AddInlines(italic.Inlines, match.Groups["italic"].Value, foreground, fontSize);
                inlines.Add(italic);
            }
            else if (match.Groups["link"].Success)
            {
                inlines.Add(new Run(match.Groups["link"].Value) { TextDecorations = TextDecorations.Underline });
            }
            position = match.Index + match.Length;
        }
        if (position < text.Length) inlines.Add(new Run(text[position..]));
    }

    private static Brush WithOpacity(Brush brush, double opacity)
    {
        var clone = brush.CloneCurrentValue();
        clone.Opacity = brush.Opacity * opacity;
        clone.Freeze();
        return clone;
    }

    // ───────────────────────── code block ─────────────────────────

    private const double CodeFontSize = 13;
    private const double CodeLineHeight = 21;

    private static UIElement CreateCodeBlock(string code, string language, Style? scrollBarStyle)
    {
        var lines = code.Replace("\r\n", "\n").Split('\n');

        var numbers = new TextBlock
        {
            FontFamily = CodeFont,
            FontSize = CodeFontSize,
            LineHeight = CodeLineHeight,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            Foreground = new SolidColorBrush(Color.FromArgb(0x33, 0, 0, 0)),
            TextAlignment = TextAlignment.Right,
            TextWrapping = TextWrapping.NoWrap,
            MinWidth = 28,
            Margin = new Thickness(0, 0, 16, 0),
            Text = string.Join("\n", Enumerable.Range(1, lines.Length))
        };

        var codeText = new TextBlock
        {
            FontFamily = CodeFont,
            FontSize = CodeFontSize,
            LineHeight = CodeLineHeight,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            Foreground = new SolidColorBrush(Color.FromRgb(0x22, 0x22, 0x22)),
            TextWrapping = TextWrapping.NoWrap
        };
        for (var index = 0; index < lines.Length; index++)
        {
            if (index > 0) codeText.Inlines.Add(new LineBreak());
            SyntaxHighlighter.AppendLine(codeText.Inlines, lines[index].Replace("\t", "    "));
        }

        var content = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(18, 18, 58, 18) };
        content.Children.Add(numbers);
        content.Children.Add(codeText);

        var scroller = new ScrollViewer
        {
            Content = content,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            MaxHeight = 230,
            Focusable = false
        };
        // The app-wide ScrollBar style is vertical-only, so the code block uses its own thin style.
        if (scrollBarStyle is not null) scroller.Resources.Add(typeof(ScrollBar), scrollBarStyle);
        scroller.PreviewMouseWheel += ForwardWheelAtEdges;

        var copyIcon = new TextBlock
        {
            Text = "\uE8C8",
            FontFamily = IconFont,
            FontSize = 15,
            Foreground = new SolidColorBrush(Color.FromArgb(0x61, 0, 0, 0)),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.NoWrap
        };
        var copyButton = new Button
        {
            Width = 34,
            Height = 34,
            Margin = new Thickness(0, 12, 12, 0),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Cursor = Cursors.Hand,
            Focusable = false,
            ToolTip = "Copy",
            Content = copyIcon,
            Template = CreateCopyButtonTemplate()
        };
        var resetTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        resetTimer.Tick += (_, _) =>
        {
            resetTimer.Stop();
            copyIcon.Text = "\uE8C8";
            copyIcon.Foreground = new SolidColorBrush(Color.FromArgb(0x61, 0, 0, 0));
        };
        copyButton.Click += (_, _) =>
        {
            try { Clipboard.SetText(code); }
            catch { return; }
            copyIcon.Text = "\uE73E";
            copyIcon.Foreground = new SolidColorBrush(Color.FromRgb(0x20, 0xB2, 0x5A));
            resetTimer.Stop();
            resetTimer.Start();
        };

        var grid = new Grid();
        grid.Children.Add(scroller);
        grid.Children.Add(copyButton);

        return new Border
        {
            Background = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(0xE4, 0xE4, 0xE4)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(18),
            Margin = new Thickness(0, 2, 0, 12),
            Padding = new Thickness(0),
            ClipToBounds = true,
            Child = grid
        };
    }

    /// <summary>Let the outer answer scroller take over once the code block hits its top/bottom.</summary>
    private static void ForwardWheelAtEdges(object sender, MouseWheelEventArgs e)
    {
        if (sender is not ScrollViewer scroller) return;
        var atTop = scroller.VerticalOffset <= 0;
        var atBottom = scroller.VerticalOffset >= scroller.ScrollableHeight - 0.5;
        if (scroller.ScrollableHeight > 0 && !(e.Delta > 0 && atTop) && !(e.Delta < 0 && atBottom)) return;
        e.Handled = true;
        var parent = VisualTreeHelper.GetParent(scroller) as UIElement;
        parent?.RaiseEvent(new MouseWheelEventArgs(e.MouseDevice, e.Timestamp, e.Delta) { RoutedEvent = UIElement.MouseWheelEvent, Source = scroller });
    }

    private static ControlTemplate CreateCopyButtonTemplate()
    {
        var border = new FrameworkElementFactory(typeof(Border), "Root");
        border.SetValue(Border.BackgroundProperty, new SolidColorBrush(Color.FromArgb(0xF5, 0xFF, 0xFF, 0xFF)));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(8));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, new SolidColorBrush(Color.FromRgb(0xF0, 0xF0, 0xF0)), "Root"));
        template.Triggers.Add(hover);
        return template;
    }
}

/// <summary>Same lightweight regex highlighter as the macOS CodeBlockView.</summary>
internal static class SyntaxHighlighter
{
    private static readonly Regex TokenPattern = new(
        @"(?<string>""(?:\\.|[^""\\])*""?|'(?:\\.|[^'\\])*'?)" +
        @"|(?<comment>//.*|#.*|--\s.*)" +
        @"|(?<keyword>\b(?:class|def|func|function|return|if|else|elif|for|while|do|switch|case|break|continue|let|var|val|const|public|private|protected|static|import|from|in|not|and|or|try|catch|except|finally|throw|throws|raise|new|int|long|double|float|bool|boolean|char|string|void|auto|struct|enum|interface|extends|implements|async|await|yield|lambda|with|as|pass|true|false|True|False|null|nil|None|self|this|using|namespace|package|include)\b)" +
        @"|(?<number>\b\d+(?:\.\d+)?\b)" +
        @"|(?<call>\b[A-Za-z_]\w*(?=\s*\())",
        RegexOptions.Compiled);

    private static readonly Brush StringBrush = Frozen(0x0A, 0x61, 0xD8);
    private static readonly Brush CommentBrush = Frozen(0x8B, 0x94, 0x9E);
    private static readonly Brush KeywordBrush = Frozen(0xE3, 0x55, 0x4A);
    private static readonly Brush NumberBrush = Frozen(0x2F, 0x81, 0xF7);
    private static readonly Brush CallBrush = Frozen(0x1A, 0x8F, 0x5C);

    public static void AppendLine(InlineCollection inlines, string line)
    {
        if (line.Length == 0) { inlines.Add(new Run(" ")); return; }
        var position = 0;
        foreach (Match match in TokenPattern.Matches(line))
        {
            if (match.Index > position) inlines.Add(new Run(line[position..match.Index]));
            var brush = match.Groups["string"].Success ? StringBrush
                : match.Groups["comment"].Success ? CommentBrush
                : match.Groups["keyword"].Success ? KeywordBrush
                : match.Groups["number"].Success ? NumberBrush
                : CallBrush;
            var run = new Run(match.Value) { Foreground = brush };
            if (match.Groups["comment"].Success) run.FontStyle = FontStyles.Italic;
            inlines.Add(run);
            position = match.Index + match.Length;
        }
        if (position < line.Length) inlines.Add(new Run(line[position..]));
    }

    private static Brush Frozen(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }
}
