using System.Text;

namespace InterviewAssistant.Rag;

/// <summary>
/// Keyword terms for BM25: lowercase Latin words/numbers (keeps "c++", "c#", "gpt-4o" pieces), light English
/// stemming, and character bigrams for Chinese/Japanese/Korean (no word segmenter needed). Exact technical names
/// such as FastAPI, PyTorch, Kubernetes or SQL therefore match even when semantic similarity is weak.
/// </summary>
public static class LexicalAnalyzer
{
    private static readonly HashSet<string> StopWords =
    [
        "the", "and", "for", "you", "your", "are", "was", "were", "with", "that", "this", "what", "how", "why",
        "can", "could", "would", "about", "have", "has", "had", "did", "does", "from", "tell", "me", "is", "it",
        "of", "to", "in", "on", "a", "an", "or", "be", "do", "as", "at", "by", "we", "our", "my", "i", "any",
        "some", "there", "their", "they", "them", "then", "than", "so", "if", "when", "which", "who", "will", "into",
        "more", "most", "very", "also", "just", "give", "example", "describe", "explain", "walk", "through", "please",
        "query", "passage"
    ];

    private static readonly HashSet<string> CjkStopBigrams =
    [
        "一下", "什么", "怎么", "如何", "你的", "我的", "一个", "这个", "那个", "可以", "是否", "为什", "么样",
        "请问", "介绍", "说说", "讲讲", "谈谈", "觉得", "我们", "你们", "他们", "的时", "时候", "有没", "没有",
        "是什", "做过", "过什", "么项", "一些", "哪些", "这些", "那些", "以及", "还有", "然后"
    ];

    /// <summary>Terms of <paramref name="text"/>, in order, with repeats (term frequency matters for BM25).</summary>
    public static List<string> Terms(string text)
    {
        var tokens = new List<string>();
        var word = new StringBuilder();
        char? previousCjk = null;
        void FlushWord()
        {
            if (word.Length > 0)
            {
                var value = word.ToString().Trim('+', '#', '.', '-');
                // Keep 1-letter terms only for "c", "r" style language names written with a symbol (c++, c#).
                var raw = word.ToString();
                if (raw is "c++" or "c#" or "f#") tokens.Add(raw);
                else if (value.Length >= 2 && !StopWords.Contains(value)) tokens.Add(Stem(value));
                else if (value.Length == 1 && char.IsDigit(value[0])) tokens.Add(value);
            }
            word.Clear();
        }
        foreach (var character in text.ToLowerInvariant())
        {
            if (TextUtilities.IsCjk(character))
            {
                FlushWord();
                if (previousCjk is { } previous)
                {
                    var bigram = new string([previous, character]);
                    if (!CjkStopBigrams.Contains(bigram)) tokens.Add(bigram);
                }
                previousCjk = character;
            }
            else if (char.IsLetterOrDigit(character) || character is '+' or '#')
            {
                previousCjk = null;
                word.Append(character);
            }
            else if (character is '.' or '-' && word.Length > 0)
            {
                // "node.js" → "node", "js"; "gpt-4o" → "gpt", "4o"; but "3.5" stays one number.
                if (character == '.' && char.IsDigit(word[^1])) { word.Append(character); continue; }
                FlushWord();
                previousCjk = null;
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

    public static Dictionary<string, int> TermFrequencies(string text)
    {
        var frequencies = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var term in Terms(text)) frequencies[term] = frequencies.GetValueOrDefault(term) + 1;
        return frequencies;
    }

    /// <summary>Very light English stemming so "conflicts" / "conflict" and "handled" / "handling" match.</summary>
    internal static string Stem(string word)
    {
        if (word.Length <= 4) return word;
        foreach (var character in word) if (character is < 'a' or > 'z') return word;
        if (word.EndsWith("ies", StringComparison.Ordinal)) return word[..^3] + "y";
        if (word.EndsWith("ing", StringComparison.Ordinal) && word.Length > 5) return word[..^3];
        if (word.EndsWith("ed", StringComparison.Ordinal)) return word[..^2];
        if (word.EndsWith("es", StringComparison.Ordinal) && !word.EndsWith("ses", StringComparison.Ordinal)) return word[..^2];
        if (word.EndsWith('s') && !word.EndsWith("ss", StringComparison.Ordinal)) return word[..^1];
        return word;
    }
}
