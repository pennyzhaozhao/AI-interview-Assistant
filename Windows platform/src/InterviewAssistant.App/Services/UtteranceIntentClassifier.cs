namespace InterviewAssistant.Services;

/// <summary>
/// How aggressively microphone transcripts that read like the candidate's own answer are
/// discarded. Complements voiceprint recognition, which can miss the candidate on some
/// microphones or rooms. Mirrors the macOS <c>SpeechContentFilterLevel</c>.
/// </summary>
public static class SpeechContentFilterLevels
{
    public const string Off = "off";
    public const string Relaxed = "relaxed";
    public const string Standard = "standard";
    public const string Strict = "strict";

    public static readonly string[] All = [Off, Relaxed, Standard, Strict];

    public static string Current =>
        Normalize(AppServices.Current.DataStore.Data.Preferences.SpeechContentFilterLevel);

    public static string Normalize(string? value) =>
        All.Contains(value ?? "", StringComparer.OrdinalIgnoreCase) ? value!.ToLowerInvariant() : Standard;

    /// <summary>Minimum <c>answerScore - questionScore</c> required to drop an utterance.</summary>
    public static double? DropMargin(string level) => Normalize(level) switch
    {
        Off => null,
        Relaxed => 3.0,
        Strict => 1.0,
        _ => 2.0
    };
}

/// <summary>
/// Scores whether a transcript reads like an interviewer question or like the candidate
/// answering. Purely local and lexical, so it adds no latency. Port of the macOS
/// <c>UtteranceIntentClassifier</c>; keep the two in sync.
///
/// The filter is deliberately one-sided: it only drops text with clear answer-style evidence
/// (first-person narration, storytelling connectors, repeating the on-screen suggestion).
/// Neutral fragments such as “你上一个项目” pass through so split questions can still merge.
/// </summary>
public static class UtteranceIntentClassifier
{
    public readonly record struct Assessment(double QuestionScore, double AnswerScore)
    {
        public double Margin => AnswerScore - QuestionScore;
    }

    /// <summary>Extra margin required when the voiceprint labelled the speaker as the interviewer.</summary>
    public const double InterviewerLabelBonus = 1.5;

    public static bool ShouldDrop(string text, string currentAnswer, SpeakerLabel speaker, string level)
    {
        if (speaker == SpeakerLabel.Candidate || SpeechContentFilterLevels.DropMargin(level) is not { } margin) return false;
        if (speaker == SpeakerLabel.Interviewer) margin += InterviewerLabelBonus;
        return Assess(text, currentAnswer).Margin >= margin;
    }

    public static Assessment Assess(string text, string currentAnswer = "")
    {
        var clean = text.Trim();
        if (clean.Length == 0) return new Assessment(0, 0);
        var lower = clean.ToLowerInvariant();
        var words = SplitWords(lower);
        var wordSet = words.ToHashSet();
        var core = new string(lower.Where(c => !char.IsWhiteSpace(c) && !char.IsPunctuation(c)).ToArray());
        var opening = StripFillers(core);
        var englishOpening = words.SkipWhile(EnglishFillers.Contains).ToList();

        // Question evidence.
        double question = 0;
        if (clean.EndsWith('?') || clean.EndsWith('？')) question += 3;
        if (core.Length > 0 && "吗呢么".Contains(core[^1])) question += 2;
        question += Math.Min(Count(ChineseInterrogatives, lower) * 1.5, 3);
        question += Math.Min(Count(ChinesePrompts, lower) * 1.5, 3);
        if (lower.Contains('你') || lower.Contains('您')) question += 1;
        if (englishOpening.Count > 0 && EnglishQuestionOpeners.Contains(englishOpening[0])) question += 2;
        question += Math.Min(Count(EnglishPromptPhrases, lower) * 1.5, 3);
        if (wordSet.Contains("you") || wordSet.Contains("your") || wordSet.Contains("yourself")) question += 1;

        // Answer evidence.
        double answer = 0;
        if (opening.StartsWith('我')) answer += 2;
        if (englishOpening.Count > 0 && EnglishFirstPerson.Contains(englishOpening[0])) answer += 2;
        var firstPersonCount = lower.Count(c => c == '我') + words.Count(EnglishFirstPerson.Contains);
        if (firstPersonCount >= 2) answer += 1;
        answer += Math.Min(Count(ChineseNarrative, lower) * 0.75, 3);
        answer += Math.Min(Count(EnglishNarrative, " " + string.Join(' ', words) + " ") * 0.75, 3);
        if (AnswerOpeners.Any(o => core.StartsWith(o, StringComparison.Ordinal) || opening.StartsWith(o, StringComparison.Ordinal))) answer += 2;

        var overlap = AnswerOverlap(clean, currentAnswer);
        if (overlap >= 0.2) answer += overlap * 4;

        var isLong = core.Length > 40 || words.Count > 25;
        if (isLong && question < 1.5) answer += 1;

        return new Assessment(question, answer);
    }

    /// <summary>Share of the transcript's tokens (Chinese bigrams or English words) found in the answer.</summary>
    public static double AnswerOverlap(string transcript, string answer)
    {
        var left = Tokens(transcript);
        var right = Tokens(answer);
        if (left.Count == 0 || right.Count == 0) return 0;
        var intersection = left.Intersect(right).Count();
        return intersection / (double)Math.Min(left.Count, right.Count);
    }

    // Lexicons ---------------------------------------------------------------

    private static readonly string[] ChineseInterrogatives =
    [
        "什么", "为什么", "为啥", "怎么", "怎样", "如何", "哪个", "哪些", "哪里", "哪儿",
        "多少", "多久", "几个", "是否", "是不是", "有没有", "能不能", "会不会", "可不可以",
        "要不要", "请问"
    ];
    private static readonly string[] ChinesePrompts =
    [
        "介绍一下", "介绍下", "说说", "说一下", "讲讲", "讲一下", "谈谈", "聊聊", "描述一下",
        "举个例子", "举例", "解释一下", "分享一下", "展开讲", "具体说", "问一下", "问你"
    ];
    private static readonly string[] ChineseNarrative =
    [
        "然后", "当时", "所以", "因为", "首先", "其次", "最后", "主要是", "负责", "实现了",
        "完成了", "带领", "团队", "上线", "优化了", "提升了", "降低了", "项目中", "那时候",
        "基本上", "其实", "用了", "做了", "采用", "我觉得", "我认为", "我的经验"
    ];
    private static readonly string[] AnswerOpeners =
    [
        "这个问题", "这是一个好问题", "好问题", "我来回答", "我先说", "我先简单", "我简单介绍",
        "goodquestion", "thatsagoodquestion", "thatsagreatquestion"
    ];
    /// <summary>Fillers and connectors skipped before checking how a sentence opens.</summary>
    private static readonly string[] ChineseFillers =
    [
        "嗯", "呃", "额", "啊", "那个", "就是", "对", "好的", "好", "是的", "ok",
        "然后", "所以", "其实", "当时", "那"
    ];
    private static readonly HashSet<string> EnglishQuestionOpeners =
    [
        "what", "what's", "why", "how", "when", "where", "which", "who", "whose",
        "can", "could", "would", "will", "do", "does", "did", "are", "is", "have", "has", "should"
    ];
    private static readonly string[] EnglishPromptPhrases =
    [
        "tell me", "walk me through", "describe", "explain", "give me an example",
        "talk about", "share an example", "how would you", "what would you", "can you", "could you"
    ];
    private static readonly HashSet<string> EnglishFirstPerson = ["i", "i'm", "i've", "i'd", "my", "we", "we're", "we've", "our"];
    private static readonly string[] EnglishNarrative =
    [
        " so ", " then ", " because ", " basically ", " actually ", " i was responsible ",
        " we built ", " i built ", " i led ", " i implemented ", " we implemented ", " in my previous ",
        " at my last ", " my role ", " the result ", " we reduced ", " we improved ", " i think "
    ];
    private static readonly HashSet<string> EnglishFillers = ["um", "uh", "er", "well", "yeah", "yes", "ok", "okay", "sure", "right", "so"];

    // Helpers ----------------------------------------------------------------

    private static double Count(IEnumerable<string> needles, string haystack) =>
        needles.Count(needle => haystack.Contains(needle, StringComparison.Ordinal));

    private static List<string> SplitWords(string text)
    {
        var words = new List<string>();
        var current = new System.Text.StringBuilder();
        foreach (var c in text)
        {
            if (char.IsLetterOrDigit(c) || c == '\'') current.Append(c);
            else if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); }
        }
        if (current.Length > 0) words.Add(current.ToString());
        return words;
    }

    private static string StripFillers(string text)
    {
        var changed = true;
        while (changed)
        {
            changed = false;
            foreach (var filler in ChineseFillers)
            {
                if (!text.StartsWith(filler, StringComparison.Ordinal)) continue;
                text = text[filler.Length..];
                changed = true;
            }
        }
        return text;
    }

    private static HashSet<string> Tokens(string text)
    {
        var normalized = text.Trim().ToLowerInvariant();
        if (normalized.Length == 0) return [];
        var containsCjk = normalized.Any(c => c is >= '㐀' and <= '䶿' or >= '一' and <= '鿿');
        if (containsCjk)
        {
            var characters = normalized.Where(c => !char.IsWhiteSpace(c) && !char.IsPunctuation(c)).ToArray();
            if (characters.Length < 2) return characters.Length == 0 ? [] : [new string(characters)];
            return Enumerable.Range(0, characters.Length - 1).Select(i => new string(characters, i, 2)).ToHashSet();
        }
        return SplitWords(normalized).Where(w => w != "'").ToHashSet();
    }
}
