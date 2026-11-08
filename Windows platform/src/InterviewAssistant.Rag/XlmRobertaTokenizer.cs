using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace InterviewAssistant.Rag;

/// <summary>
/// SentencePiece Unigram tokenizer for XLM-RoBERTa vocabularies (multilingual-e5-small), read from the
/// Hugging Face tokenizer.json. Implemented natively so no Python or tokenizer library is needed.
///
/// Normalization approximates the model's "nmt_nfkc" precompiled charsmap with Unicode NFKC, whitespace → space,
/// removal of control/format characters and collapsing of repeated spaces. Verified identical to the reference
/// Hugging Face tokenizer on 1,054 of 1,055 mixed Chinese/English test lines (the one difference is a zero-width
/// space). The macOS port (XLMRobertaTokenizer.swift) implements exactly the same steps so both platforms
/// produce the same token IDs and therefore compatible vectors.
/// </summary>
public sealed class XlmRobertaTokenizer
{
    public const int BosId = 0;
    public const int PadId = 1;
    public const int EosId = 2;
    private const double UnknownPenalty = 10.0;
    private const string Metaspace = "▁";

    private readonly Dictionary<string, int> _pieces;
    private readonly Dictionary<string, int>.AlternateLookup<ReadOnlySpan<char>> _lookup;
    private readonly float[] _scores;
    private readonly int _unknownId;
    private readonly double _unknownScore;
    private readonly int _maxPieceRunes;
    private static readonly Regex RepeatedSpaces = new(" {2,}", RegexOptions.Compiled);

    private XlmRobertaTokenizer(Dictionary<string, int> pieces, float[] scores, int unknownId, int maxPieceRunes)
    {
        _pieces = pieces;
        _lookup = pieces.GetAlternateLookup<ReadOnlySpan<char>>();
        _scores = scores;
        _unknownId = unknownId;
        _maxPieceRunes = maxPieceRunes;
        _unknownScore = scores.Min() - UnknownPenalty;
    }

    public int VocabularySize => _scores.Length;

    public static XlmRobertaTokenizer Load(string tokenizerJsonPath)
    {
        using var stream = File.OpenRead(tokenizerJsonPath);
        using var document = JsonDocument.Parse(stream);
        var model = document.RootElement.GetProperty("model");
        if (model.GetProperty("type").GetString() != "Unigram") throw new InvalidDataException("tokenizer.json is not a Unigram model.");
        var unknownId = model.TryGetProperty("unk_id", out var unk) && unk.ValueKind == JsonValueKind.Number ? unk.GetInt32() : 3;
        var vocab = model.GetProperty("vocab");
        var count = vocab.GetArrayLength();
        var pieces = new Dictionary<string, int>(count, StringComparer.Ordinal);
        var scores = new float[count];
        var maxRunes = 1;
        var index = 0;
        foreach (var item in vocab.EnumerateArray())
        {
            var piece = item[0].GetString() ?? "";
            scores[index] = (float)item[1].GetDouble();
            pieces.TryAdd(piece, index);   // first occurrence wins, as in the reference tokenizer
            var runes = CountRunes(piece);
            if (runes > maxRunes) maxRunes = runes;
            index++;
        }
        return new XlmRobertaTokenizer(pieces, scores, unknownId, maxRunes);
    }

    /// <summary>Token IDs with &lt;s&gt; … &lt;/s&gt;, truncated to <paramref name="maxLength"/> (including the specials).</summary>
    public int[] Encode(string text, int maxLength = 512)
    {
        var ids = new List<int>(64) { BosId };
        var normalized = Normalize(text);
        if (normalized.Length > 0)
        {
            foreach (var word in PreTokenize(normalized))
            {
                EncodeWord(word, ids);
                if (ids.Count >= maxLength - 1) break;
            }
        }
        if (ids.Count > maxLength - 1) ids.RemoveRange(maxLength - 1, ids.Count - (maxLength - 1));
        ids.Add(EosId);
        return ids.ToArray();
    }

    internal static string Normalize(string text)
    {
        var nfkc = text.Normalize(NormalizationForm.FormKC);
        var builder = new StringBuilder(nfkc.Length);
        foreach (var rune in nfkc.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune)) { builder.Append(' '); continue; }
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.Control or UnicodeCategory.Format) continue;
            builder.Append(rune.ToString());
        }
        return RepeatedSpaces.Replace(builder.ToString(), " ");
    }

    /// <summary>Metaspace pre-tokenizer: spaces become "▁", a leading "▁" is added, and words start at each "▁".</summary>
    internal static IEnumerable<string> PreTokenize(string normalized)
    {
        var text = normalized.Replace(" ", Metaspace);
        if (!text.StartsWith(Metaspace, StringComparison.Ordinal)) text = Metaspace + text;
        var start = 0;
        for (var index = 1; index < text.Length; index++)
        {
            if (text[index] != '▁') continue;
            yield return text[start..index];
            start = index;
        }
        yield return text[start..];
    }

    /// <summary>Viterbi search for the most likely segmentation; unknown characters become &lt;unk&gt; (consecutive ones fused).</summary>
    private void EncodeWord(string word, List<int> output)
    {
        // Positions are Unicode scalar boundaries (not UTF-16 units) so emoji are never split.
        var boundaries = new List<int>(word.Length + 1);
        for (var index = 0; index < word.Length;)
        {
            boundaries.Add(index);
            index += char.IsHighSurrogate(word[index]) && index + 1 < word.Length && char.IsLowSurrogate(word[index + 1]) ? 2 : 1;
        }
        boundaries.Add(word.Length);
        var count = boundaries.Count - 1;
        var bestScore = new double[count + 1];
        var bestStart = new int[count + 1];
        var bestId = new int[count + 1];
        Array.Fill(bestScore, double.NegativeInfinity);
        bestScore[0] = 0;
        var span = word.AsSpan();
        for (var start = 0; start < count; start++)
        {
            if (double.IsNegativeInfinity(bestScore[start])) continue;
            var hasSingle = false;
            var limit = Math.Min(count, start + _maxPieceRunes);
            for (var end = start + 1; end <= limit; end++)
            {
                var piece = span[boundaries[start]..boundaries[end]];
                if (!_lookup.TryGetValue(piece, out var id)) continue;
                if (end == start + 1) hasSingle = true;
                var score = bestScore[start] + _scores[id];
                if (score > bestScore[end]) { bestScore[end] = score; bestStart[end] = start; bestId[end] = id; }
            }
            if (!hasSingle)
            {
                var score = bestScore[start] + _unknownScore;
                if (score > bestScore[start + 1]) { bestScore[start + 1] = score; bestStart[start + 1] = start; bestId[start + 1] = _unknownId; }
            }
        }
        var path = new List<int>();
        for (var end = count; end > 0; end = bestStart[end]) path.Add(bestId[end]);
        path.Reverse();
        foreach (var id in path)
        {
            if (id == _unknownId && output.Count > 0 && output[^1] == _unknownId) continue;
            output.Add(id);
        }
    }

    private static int CountRunes(string text)
    {
        var count = 0;
        foreach (var _ in text.EnumerateRunes()) count++;
        return count;
    }
}
