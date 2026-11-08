using System.Security.Cryptography;
using System.Text;

namespace InterviewAssistant.Rag;

internal static class TextUtilities
{
    public static bool IsCjk(char character) => character switch
    {
        >= '぀' and <= 'ヿ' => true,   // Japanese kana
        >= '㐀' and <= '䶿' => true,   // CJK extension A
        >= '一' and <= '鿿' => true,   // CJK unified ideographs
        >= '가' and <= '힯' => true,   // Hangul syllables
        >= '豈' and <= '﫿' => true,   // CJK compatibility ideographs
        _ => false
    };

    public static string Sha256Hex(string text)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    public static string NormalizeNewlines(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n');
}
