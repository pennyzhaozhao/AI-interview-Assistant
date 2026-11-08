using System.Text;
using System.Text.RegularExpressions;

namespace InterviewAssistant.Rag;

public sealed record ChunkerOptions(int TargetTokens = 350, int MaxTokens = 450, int OverlapTokens = 60)
{
    public static ChunkerOptions Default { get; } = new();
}

/// <summary>
/// Paragraph- and sentence-aware chunking with Markdown heading tracking, code-block preservation, Q&amp;A pairing and
/// a token-based overlap. Deterministic and independent of the embedding model, so chunk IDs stay stable and match
/// the macOS port (KnowledgeChunker.swift).
/// </summary>
public static class KnowledgeChunker
{
    /// <summary>Bump when the chunking rules change: every entry is then re-chunked once.</summary>
    public const string Version = "chunker-v1";

    private sealed record Unit(string Text, int Tokens, string Section, bool IsQuestionAnswer, int Group);

    private static readonly Regex HeadingLine = new(@"^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$", RegexOptions.Compiled);
    private static readonly Regex NumberedQuestion = new(@"^(q|问题|题)?\s*\d{1,3}\s*[\.、:：\)]", RegexOptions.Compiled);
    private static readonly string[] QuestionPrefixes = ["q:", "q：", "q.", "question:", "问：", "问:", "问题：", "问题:", "面试题"];
    private static readonly string[] AnswerPrefixes = ["a:", "a：", "answer:", "答：", "答:", "回答：", "回答:"];

    /// <summary>Hash of everything that affects the chunks of an entry (content, title, summary, kind, chunker version).</summary>
    public static string ContentHash(RagDocument document) => TextUtilities.Sha256Hex(string.Join("\u001F",
        Version, document.Kind, document.Title, document.Summary, document.Meta, document.Source, TextUtilities.NormalizeNewlines(document.Content)));

    /// <summary>Stable, collision-resistant chunk ID: hash(entry ID, content hash, chunk index).</summary>
    public static string ChunkId(Guid entryId, string contentHash, int index) =>
        TextUtilities.Sha256Hex($"{entryId:D}|{contentHash}|{index}")[..32];

    public static IReadOnlyList<RagChunk> Chunk(RagDocument document, ChunkerOptions? options = null)
    {
        options ??= ChunkerOptions.Default;
        var hash = ContentHash(document);
        var texts = new List<(string Section, string Text, bool IsQa)>();

        // Projects and resumes: the summary is its own passage so "tell me about <project>" finds it directly.
        var summary = document.Summary.Trim();
        if (document.Kind == RagKinds.Project)
        {
            var header = new StringBuilder($"Project: {document.Title}");
            if (document.Meta.Trim().Length > 0) header.Append($" ({document.Meta.Trim()})");
            if (summary.Length > 0) header.Append('\n').Append(summary);
            if (document.Source.StartsWith("http", StringComparison.OrdinalIgnoreCase)) header.Append('\n').Append(document.Source);
            texts.Add(("Overview", header.ToString(), false));
        }
        else if (document.Kind == RagKinds.Resume && summary.Length > 0)
        {
            texts.Add(("Summary", summary, false));
        }

        foreach (var (section, text, isQa) in SplitContent(document.Content, options)) texts.Add((section, text, isQa));

        var chunks = new List<RagChunk>(texts.Count);
        for (var index = 0; index < texts.Count; index++)
        {
            var (section, text, isQa) = texts[index];
            chunks.Add(new RagChunk(ChunkId(document.EntryId, hash, index), document.KnowledgeBaseId, document.EntryId, document.Title,
                document.Kind, document.Source, index, section, text, hash, isQa));
        }
        return chunks;
    }

    internal static List<(string Section, string Text, bool IsQa)> SplitContent(string content, ChunkerOptions options)
    {
        var text = TextUtilities.NormalizeNewlines(content).Trim();
        var result = new List<(string, string, bool)>();
        if (text.Length == 0) return result;
        if (TokenEstimator.Estimate(text) <= options.TargetTokens)
        {
            // Short content stays one passage (keeps a Q&A note or a small README intact).
            var units = Blocks(text).ToList();
            var section = units.FirstOrDefault(unit => unit.Section.Length > 0)?.Section ?? "";
            result.Add((section, text, units.Count > 0 && units.All(unit => unit.IsQuestionAnswer)));
            return result;
        }

        // 1. Blocks (paragraphs, code, Q&A pairs); blocks longer than MaxTokens become sentence units.
        var pieces = new List<Unit>();
        foreach (var block in Blocks(text))
        {
            if (block.Tokens <= options.MaxTokens) { pieces.Add(block); continue; }
            // A long Q&A keeps its question at the start of every part so each part still matches the question.
            var question = block.IsQuestionAnswer ? FirstLine(block.Text) : null;
            var budget = question is null ? options.MaxTokens : Math.Max(options.MaxTokens - TokenEstimator.Estimate(question), options.MaxTokens / 2);
            var parts = PackSentences(SplitSentences(block.Text, budget).Where(sentence => sentence != question), budget);
            foreach (var part in parts)
            {
                var unitText = question is not null ? question + "\n" + part : part;
                pieces.Add(new Unit(unitText, TokenEstimator.Estimate(unitText), block.Section, block.IsQuestionAnswer, block.Group));
            }
        }

        // 2. Pack units into passages of about TargetTokens. A Q&A pair is never mixed with other content; prose
        //    passages that continue the same section start with the last sentences of the previous one (overlap).
        var current = new List<Unit>();
        var currentTokens = 0;
        void Flush()
        {
            if (current.Count == 0) return;
            var chunkText = string.Join("\n\n", current.Select(unit => unit.Text)).Trim();
            if (chunkText.Length > 0) result.Add((current[0].Section, chunkText, current.All(unit => unit.IsQuestionAnswer)));
            current.Clear();
            currentTokens = 0;
        }

        foreach (var unit in pieces)
        {
            if (current.Count > 0)
            {
                var last = current[^1];
                var crossesQa = (unit.IsQuestionAnswer || last.IsQuestionAnswer) && unit.Group != last.Group;
                var sectionChanged = unit.Section != last.Section && currentTokens >= options.TargetTokens / 3;
                var full = currentTokens + unit.Tokens > options.TargetTokens;
                if (crossesQa || sectionChanged || full)
                {
                    var overlap = !crossesQa && !sectionChanged && !unit.IsQuestionAnswer && !last.IsQuestionAnswer
                        ? TailSentences(string.Join("\n\n", current.Select(item => item.Text)), options.OverlapTokens)
                        : "";
                    Flush();
                    if (overlap.Length > 0)
                    {
                        current.Add(new Unit(overlap, TokenEstimator.Estimate(overlap), unit.Section, false, -1));
                        currentTokens = current[0].Tokens;
                    }
                }
            }
            current.Add(unit);
            currentTokens += unit.Tokens;
        }
        Flush();
        return result;
    }

    /// <summary>The last whole sentences of <paramref name="text"/> that fit in <paramref name="maxTokens"/>.</summary>
    internal static string TailSentences(string text, int maxTokens)
    {
        var sentences = SplitSentences(text, maxTokens).ToList();
        var tail = new List<string>();
        var tokens = 0;
        for (var index = sentences.Count - 1; index >= 0; index--)
        {
            var count = TokenEstimator.Estimate(sentences[index]);
            if (tokens + count > maxTokens) break;
            tail.Insert(0, sentences[index]);
            tokens += count;
        }
        return tail.Count == sentences.Count ? "" : string.Join(" ", tail);
    }

    private static List<string> PackSentences(IEnumerable<string> sentences, int maxTokens)
    {
        var parts = new List<string>();
        var buffer = new StringBuilder();
        var tokens = 0;
        foreach (var sentence in sentences)
        {
            var count = TokenEstimator.Estimate(sentence);
            if (buffer.Length > 0 && tokens + count > maxTokens) { parts.Add(buffer.ToString()); buffer.Clear(); tokens = 0; }
            if (buffer.Length > 0) buffer.Append(' ');
            buffer.Append(sentence);
            tokens += count;
        }
        if (buffer.Length > 0) parts.Add(buffer.ToString());
        return parts;
    }

    /// <summary>Paragraphs, fenced code blocks and Q&amp;A pairs, each tagged with the nearest Markdown heading.</summary>
    private static IEnumerable<Unit> Blocks(string text)
    {
        var section = "";
        var lines = text.Split('\n');
        var buffer = new List<string>();
        var bufferIsQa = false;
        var inCode = false;
        var group = 0;

        IEnumerable<Unit> FlushBuffer()
        {
            var block = string.Join("\n", buffer).Trim();
            buffer.Clear();
            var isQa = bufferIsQa;
            bufferIsQa = false;
            if (block.Length > 0) yield return new Unit(block, TokenEstimator.Estimate(block), section, isQa, group++);
        }

        foreach (var rawLine in lines)
        {
            var line = rawLine.TrimEnd();
            var trimmed = line.Trim();
            if (trimmed.StartsWith("```", StringComparison.Ordinal) || trimmed.StartsWith("~~~", StringComparison.Ordinal))
            {
                if (!inCode && !bufferIsQa) foreach (var unit in FlushBuffer()) yield return unit;
                buffer.Add(line);
                inCode = !inCode;
                if (!inCode && !bufferIsQa) foreach (var unit in FlushBuffer()) yield return unit;
                continue;
            }
            if (inCode) { buffer.Add(line); continue; }

            var heading = HeadingLine.Match(line);
            if (heading.Success && !IsQuestionStart(trimmed))
            {
                foreach (var unit in FlushBuffer()) yield return unit;
                section = heading.Groups[2].Value.Trim();
                continue;
            }
            if (IsQuestionStart(trimmed))
            {
                foreach (var unit in FlushBuffer()) yield return unit;
                bufferIsQa = true;
                buffer.Add(line);
                continue;
            }
            if (trimmed.Length == 0)
            {
                // Inside a Q&A pair, blank lines belong to the answer until the next question or heading.
                if (bufferIsQa) { buffer.Add(""); continue; }
                foreach (var unit in FlushBuffer()) yield return unit;
                continue;
            }
            buffer.Add(line);
        }
        foreach (var unit in FlushBuffer()) yield return unit;
    }

    internal static bool IsQuestionStart(string line)
    {
        var lower = line.Trim().ToLowerInvariant();
        if (lower.Length == 0) return false;
        if (QuestionPrefixes.Any(prefix => lower.StartsWith(prefix, StringComparison.Ordinal))) return true;
        if (lower.StartsWith('#') && (lower.EndsWith('?') || lower.EndsWith('？'))) return true;
        return NumberedQuestion.IsMatch(lower) && (lower.EndsWith('?') || lower.EndsWith('？'));
    }

    internal static bool IsAnswerStart(string line)
    {
        var lower = line.Trim().ToLowerInvariant();
        return AnswerPrefixes.Any(prefix => lower.StartsWith(prefix, StringComparison.Ordinal));
    }

    private static string FirstLine(string text)
    {
        var index = text.IndexOf('\n');
        return index < 0 ? text : text[..index];
    }

    /// <summary>Sentence units no longer than <paramref name="maxTokens"/>; over-long sentences are cut at a word or character boundary.</summary>
    internal static IEnumerable<string> SplitSentences(string text, int maxTokens)
    {
        var sentences = new List<string>();
        var start = 0;
        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            var isEnd = character is '。' or '！' or '？' or '；' or '\n'
                || (character is '.' or '!' or '?' or ';' && (index + 1 == text.Length || char.IsWhiteSpace(text[index + 1])));
            if (!isEnd) continue;
            var sentence = text[start..(index + 1)].Trim();
            if (sentence.Length > 0) sentences.Add(sentence);
            start = index + 1;
        }
        var tail = text[start..].Trim();
        if (tail.Length > 0) sentences.Add(tail);

        foreach (var sentence in sentences)
        {
            if (TokenEstimator.Estimate(sentence) <= maxTokens) { yield return sentence; continue; }
            foreach (var part in HardSplit(sentence, maxTokens)) yield return part;
        }
    }

    private static IEnumerable<string> HardSplit(string text, int maxTokens)
    {
        var start = 0;
        while (start < text.Length)
        {
            var end = start;
            var tokens = 0;
            while (end < text.Length && tokens < maxTokens)
            {
                tokens = TokenEstimator.Estimate(text[start..Math.Min(text.Length, end + 16)]);
                end = Math.Min(text.Length, end + 16);
            }
            if (end < text.Length)
            {
                var space = text.LastIndexOf(' ', end - 1, Math.Min(end - start, 80));
                if (space > start) end = space + 1;
            }
            var piece = text[start..end].Trim();
            if (piece.Length > 0) yield return piece;
            start = end;
        }
    }
}
