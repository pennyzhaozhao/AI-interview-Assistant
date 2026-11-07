using System.Text;
using System.Text.RegularExpressions;
using InterviewAssistant.Models;

namespace InterviewAssistant.Services;

public sealed record KnowledgeChunk(string Label, string Text, IReadOnlyDictionary<string, int> TermFrequencies, int Length);

/// <summary>
/// Splits knowledge entries into passages and ranks them against a question with BM25.
/// Latin text is matched by words, Chinese / Japanese / Korean text by character bigrams,
/// so it works for mixed-language material without any model or network call.
/// Mirrors macOS <c>KnowledgeRetriever</c> in KnowledgeAssistant.swift.
/// </summary>
public static class KnowledgeRetriever
{
    public const int TargetChunkSize = 700;
    public const int MaxChunkSize = 1_400;

    private static readonly object CacheLock = new();
    private static readonly Dictionary<Guid, (string Signature, List<KnowledgeChunk> Chunks)> Cache = [];

    public static List<KnowledgeChunk> Chunks(KnowledgeEntryModel entry, string baseName)
    {
        var content = entry.Content.Trim();
        if (content.Length == 0) return [];
        var signature = $"{entry.UpdatedAt.ToUnixTimeMilliseconds()}|{content.Length}|{content.GetHashCode()}|{entry.Title}|{baseName}";
        lock (CacheLock)
        {
            if (Cache.TryGetValue(entry.Id, out var cached) && cached.Signature == signature) return cached.Chunks;
        }

        var kind = KnowledgeEntryKinds.Of(entry) switch
        {
            KnowledgeEntryKinds.Resume => "Resume",
            KnowledgeEntryKinds.Project => "Project",
            _ => "Material"
        };
        var label = $"{baseName} · {kind} · {entry.Title}";
        var result = Split(content).Select(piece =>
        {
            // The title is indexed with every passage so "tell me about <project>" finds it.
            var terms = Tokenize(entry.Title + "\n" + piece);
            var frequencies = new Dictionary<string, int>();
            foreach (var term in terms) frequencies[term] = frequencies.GetValueOrDefault(term) + 1;
            return new KnowledgeChunk(label, piece, frequencies, Math.Max(1, terms.Count));
        }).ToList();
        lock (CacheLock) Cache[entry.Id] = (signature, result);
        return result;
    }

    /// <summary>Best-matching passages, highest score first, within <paramref name="budget"/> characters.</summary>
    public static List<KnowledgeChunk> TopChunks(IReadOnlyList<KnowledgeChunk> chunks, string query, int budget)
    {
        var queryTerms = Tokenize(query).ToHashSet();
        if (queryTerms.Count == 0 || chunks.Count == 0) return [];
        double count = chunks.Count;
        var averageLength = chunks.Average(chunk => (double)chunk.Length);
        var documentFrequency = new Dictionary<string, int>();
        foreach (var chunk in chunks)
            foreach (var term in queryTerms)
                if (chunk.TermFrequencies.ContainsKey(term)) documentFrequency[term] = documentFrequency.GetValueOrDefault(term) + 1;

        const double k1 = 1.2, b = 0.75;
        var scored = new List<(double Score, int Index)>();
        for (var index = 0; index < chunks.Count; index++)
        {
            var chunk = chunks[index];
            var score = 0.0;
            foreach (var term in queryTerms)
            {
                if (!chunk.TermFrequencies.TryGetValue(term, out var tf) || !documentFrequency.TryGetValue(term, out var df)) continue;
                var idf = Math.Log(1 + (count - df + 0.5) / (df + 0.5));
                score += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * chunk.Length / averageLength));
            }
            if (score > 0) scored.Add((score, index));
        }
        if (scored.Count == 0) return [];
        // Drop weak matches (a single shared common bigram) once something clearly better exists.
        var floor = scored.Max(item => item.Score) * 0.2;
        var used = 0;
        var result = new List<KnowledgeChunk>();
        foreach (var (score, index) in scored.OrderByDescending(item => item.Score))
        {
            if (score < floor) break;
            var chunk = chunks[index];
            var cost = chunk.Text.Length + chunk.Label.Length + 4;
            if (used + cost > budget)
            {
                if (result.Count == 0) continue;
                break;
            }
            used += cost;
            result.Add(chunk);
        }
        return result;
    }

    /// <summary>
    /// Paragraph-based passages. A line that starts a new question ("Q:", "问：", "## …", "1. …?")
    /// always starts a new passage, so a prepared question stays together with its answer.
    /// </summary>
    public static List<string> Split(string text)
    {
        var normalized = text.Replace("\r\n", "\n").Replace('\r', '\n');
        var paragraphs = new List<string>();
        var current = new List<string>();
        void FlushParagraph()
        {
            var paragraph = string.Join("\n", current).Trim();
            if (paragraph.Length > 0) paragraphs.Add(paragraph);
            current.Clear();
        }
        foreach (var line in normalized.Split('\n'))
        {
            if (string.IsNullOrWhiteSpace(line)) { FlushParagraph(); continue; }
            if (IsQuestionStart(line)) FlushParagraph();
            current.Add(line);
        }
        FlushParagraph();

        var pieces = new List<string>();
        var buffer = new StringBuilder();
        void FlushBuffer()
        {
            var piece = buffer.ToString().Trim();
            if (piece.Length > 0) pieces.Add(piece);
            buffer.Clear();
        }
        foreach (var paragraph in paragraphs)
        {
            if (paragraph.Length > MaxChunkSize)
            {
                FlushBuffer();
                pieces.AddRange(HardSplit(paragraph));
                continue;
            }
            var startsQuestion = IsQuestionStart(FirstLine(paragraph));
            var bufferIsQuestion = buffer.Length > 0 && IsQuestionStart(FirstLine(buffer.ToString()));
            // Keep an answer with its question; otherwise pack paragraphs up to the target size.
            var wouldOverflow = buffer.Length + paragraph.Length + 2 > (bufferIsQuestion ? MaxChunkSize : TargetChunkSize);
            if (buffer.Length > 0 && (startsQuestion || wouldOverflow)) FlushBuffer();
            if (buffer.Length > 0) buffer.Append("\n\n");
            buffer.Append(paragraph);
        }
        FlushBuffer();
        return pieces;
    }

    private static string FirstLine(string text)
    {
        var index = text.IndexOf('\n');
        return index < 0 ? text : text[..index];
    }

    private static readonly string[] QuestionPrefixes = ["q:", "q：", "q.", "question:", "问：", "问:", "问题：", "问题:", "面试题", "#"];
    private static readonly Regex NumberedQuestion = new(@"^(q|问题|题)?\s*\d{1,3}\s*[\.、:：\)]", RegexOptions.Compiled);

    private static bool IsQuestionStart(string line)
    {
        var lower = line.Trim().ToLowerInvariant();
        if (lower.Length == 0) return false;
        if (QuestionPrefixes.Any(prefix => lower.StartsWith(prefix, StringComparison.Ordinal))) return true;
        return NumberedQuestion.IsMatch(lower) && (lower.EndsWith('?') || lower.EndsWith('？'));
    }

    private static IEnumerable<string> HardSplit(string text)
    {
        var start = 0;
        while (start < text.Length)
        {
            var end = Math.Min(text.Length, start + TargetChunkSize);
            // Prefer to cut after a sentence end within the last 200 characters.
            if (end < text.Length)
            {
                var windowStart = Math.Max(start, end - 200);
                var cut = text.LastIndexOfAny("。！？.!?\n；;".ToCharArray(), end - 1, end - windowStart);
                if (cut >= windowStart) end = cut + 1;
            }
            var piece = text[start..end].Trim();
            if (piece.Length > 0) yield return piece;
            start = end;
        }
    }

    private static readonly HashSet<string> StopWords =
    [
        "the", "and", "for", "you", "your", "are", "was", "were", "with", "that", "this", "what", "how", "why",
        "can", "could", "would", "about", "have", "has", "had", "did", "does", "from", "tell", "me", "is", "it",
        "of", "to", "in", "on", "a", "an", "or", "be", "do", "as", "at", "by", "we", "our", "my", "i"
    ];

    private static readonly HashSet<string> CjkStopBigrams =
    [
        "一下", "什么", "怎么", "如何", "你的", "我的", "一个", "这个", "那个", "可以", "是否", "为什", "么样",
        "请问", "介绍", "说说", "讲讲", "谈谈", "觉得", "我们", "你们", "他们", "的时", "时候", "有没", "没有"
    ];

    public static List<string> Tokenize(string text)
    {
        var tokens = new List<string>();
        var word = new StringBuilder();
        char? previousCjk = null;
        void FlushWord()
        {
            if (word.Length >= 2)
            {
                var value = word.ToString();
                if (!StopWords.Contains(value)) tokens.Add(Stem(value));
            }
            word.Clear();
        }
        foreach (var character in text.ToLowerInvariant())
        {
            if (IsCjk(character))
            {
                FlushWord();
                if (previousCjk is { } previous)
                {
                    var bigram = new string([previous, character]);
                    if (!CjkStopBigrams.Contains(bigram)) tokens.Add(bigram);
                }
                previousCjk = character;
            }
            else if (char.IsLetterOrDigit(character) || character == '+' || character == '#')
            {
                previousCjk = null;
                word.Append(character);
            }
            else
            {
                previousCjk = null;
                FlushWord();
            }
        }
        FlushWord();
        return tokens;
    }

    /// <summary>Very light English stemming so "conflicts" / "conflict" and "handled" / "handling" match.</summary>
    private static string Stem(string word)
    {
        if (word.Length <= 4 || !word.All(character => character is >= 'a' and <= 'z')) return word;
        if (word.EndsWith("ies", StringComparison.Ordinal)) return word[..^3] + "y";
        if (word.EndsWith("ing", StringComparison.Ordinal) && word.Length > 5) return word[..^3];
        if (word.EndsWith("ed", StringComparison.Ordinal)) return word[..^2];
        if (word.EndsWith("es", StringComparison.Ordinal) && !word.EndsWith("ses", StringComparison.Ordinal)) return word[..^2];
        if (word.EndsWith('s') && !word.EndsWith("ss", StringComparison.Ordinal)) return word[..^1];
        return word;
    }

    private static bool IsCjk(char character) => character switch
    {
        >= '一' and <= '鿿' => true,
        >= '㐀' and <= '䶿' => true,
        >= '぀' and <= 'ヿ' => true,
        >= '가' and <= '힯' => true,
        _ => false
    };
}
