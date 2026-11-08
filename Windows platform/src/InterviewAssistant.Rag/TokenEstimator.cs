namespace InterviewAssistant.Rag;

/// <summary>
/// Conservative, model-independent token estimate. Calibrated against the XLM-R tokenizer used by the
/// embedding model (median real/estimate 0.87 on mixed Chinese/English Markdown) and kept on the high side for
/// cloud LLM tokenizers (GPT, Claude, DeepSeek, Gemini), whose exact tokenizers are not available offline.
/// Chinese/Japanese/Korean: ~1 token per character; ASCII words: ~1 token per 3 characters; punctuation: 1 each.
/// Identical on macOS (TokenEstimator.swift) so chunk boundaries — and chunk IDs — match across platforms.
/// </summary>
public static class TokenEstimator
{
    public static int Estimate(string text)
    {
        if (string.IsNullOrEmpty(text)) return 0;
        double total = 0;
        foreach (var character in text)
        {
            if (TextUtilities.IsCjk(character)) total += 1.0;
            else if (char.IsWhiteSpace(character)) continue;
            else if (character < 128) total += char.IsLetterOrDigit(character) ? 0.34 : 1.0;
            else if (char.IsLowSurrogate(character)) continue;
            else total += 1.0;
        }
        return (int)Math.Ceiling(total);
    }
}
