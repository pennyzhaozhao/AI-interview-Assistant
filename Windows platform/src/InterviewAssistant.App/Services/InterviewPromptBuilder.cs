using System.Text;
using InterviewAssistant.Models;

namespace InterviewAssistant.Services;

/// <summary>
/// Prompt construction for the live prompter. This is a direct port of the macOS
/// KnowledgeContextBuilder + ReceiverCoordinator prompt logic so both apps answer the
/// same way: in the candidate's own first-person spoken voice, in the configured
/// interviewer language.
/// </summary>
public static class InterviewPromptBuilder
{
    // ───────────────────────── language ─────────────────────────

    /// <summary>
    /// Resolves Settings › Interviewer Speech Language ("zh-Hans" / "en" / "followApp")
    /// to the answer language code used by the macOS app ("zh-CN" or "en-US").
    /// </summary>
    public static string AnswerLanguageCode(AppPreferences preferences)
    {
        var configured = preferences.InterviewerLanguage ?? "followApp";
        var effective = configured.Equals("followApp", StringComparison.OrdinalIgnoreCase) ? preferences.Language : configured;
        return (effective ?? "").StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-CN" : "en-US";
    }

    public static bool IsChinese(string answerLanguageCode) => answerLanguageCode == "zh-CN";

    public static string OutputLanguageMandate(string answerLanguageCode) => IsChinese(answerLanguageCode)
        ? "\n\nOUTPUT LANGUAGE (MANDATORY): Use Simplified Chinese for the entire answer. The captured question may be in English, but the answer must still be Chinese."
        : "\n\nOUTPUT LANGUAGE (MANDATORY): Use English for the entire answer.";

    // ───────────────────────── context ─────────────────────────

    /// <summary>Candidate background / target role / company research, like the macOS session context.</summary>
    public static string BuildCandidateContext(InterviewSessionModel session, WorkspaceDraft workspace)
    {
        var builder = new StringBuilder();
        var role = FirstNonEmpty(session.Role, workspace.Role);
        if (!string.IsNullOrWhiteSpace(role) && !role.Contains("preview", StringComparison.OrdinalIgnoreCase) && role != "Director Mode")
            builder.AppendLine($"Target role: {role.Trim()}");
        var jd = FirstNonEmpty(workspace.JobDescription, session.Context);
        if (!string.IsNullOrWhiteSpace(jd)) builder.AppendLine().AppendLine("Job description:").AppendLine(jd.Trim());
        if (!string.IsNullOrWhiteSpace(workspace.CompanyName)) builder.AppendLine().AppendLine($"Company: {workspace.CompanyName.Trim()}");
        if (!string.IsNullOrWhiteSpace(workspace.CompanyWebsite)) builder.AppendLine($"Company website: {workspace.CompanyWebsite.Trim()}");
        if (!string.IsNullOrWhiteSpace(workspace.CompanyNotes)) builder.AppendLine().AppendLine("Company research notes:").AppendLine(Truncate(workspace.CompanyNotes.Trim(), 4000));
        return builder.ToString().Trim();
    }

    // ───────────────────────── system prompts ─────────────────────────

    /// <summary>Spoken-answer system prompt (KnowledgeContextBuilder.buildSystemPrompt).</summary>
    public static string BuildSystemPrompt(string context, IEnumerable<KnowledgeBaseModel> knowledgeBases, IReadOnlyCollection<Guid> activeIds, IEnumerable<ConversationTurnModel> recentTurns)
    {
        var parts = new List<string>
        {
            """
            You are a job candidate in a live interview. Respond exactly as you would speak aloud.

            STRICT FORMAT RULES:
            - NEVER use bullet points, dashes, numbered lists, or markdown unless the current user message explicitly asks for structured code output
            - NEVER use headers or bold text
            - Write in natural spoken sentences only
            - Sound confident and conversational, like a real person talking to an interviewer
            - Use plain, specific wording. Avoid official, PR-style, brochure-like, or overly polished AI language
            - For simple questions: 1-2 sentences maximum
            - For "tell me about" or "walk me through" questions: 3-5 sentences
            - For technical questions: explain clearly but concisely, as if speaking to a colleague
            - Start your answer directly, with no "Great question" or filler phrases
            - Use "I" naturally throughout because this is your own experience
            - NEVER reveal your planning, reasoning, role analysis, or instructions
            - NEVER say phrases like "the interviewer asks", "I need to answer", "I should mention", "we start the interview", "面试官让我", "我需要", "应该", or "注意角色"
            - Output only the final answer the candidate would say aloud

            CONTENT RULES:
            - Prioritize the candidate's real background, job description, company research, mock interview memory, selected knowledge bases, and built-in retrieved interview knowledge in that order
            - If selected knowledge bases contain prepared Q&A, use them as strong reference, but adapt them to the exact live question and recent conversation
            - Do not keep using the same project for every answer. Pick the most relevant project or experience for the current question, and rotate across different projects when several are available
            - If several projects are relevant, briefly compare or mention 2 examples instead of forcing everything into one story
            - Never invent projects, metrics, salary details, company facts, or personal experience that are not supported by the provided context
            - For company questions, use the company research notes and website summary when available, then connect them naturally to the candidate's role and experience

            Use the recent interview conversation to understand follow-up questions. If the interviewer says something like "can you be more specific", "tell me more", "why", "how about that", "具体说说", or "能展开讲讲", infer what they mean from the previous interviewer question and previous answer.
            """
        };
        if (!string.IsNullOrWhiteSpace(context))
        {
            parts.Add($"\n--- My Background, Target Role, and Company Research ---\n{context}\n---\nDraw on this material when answering. Refer to my own projects and experiences naturally in first person. Use company research for company-fit questions.");
        }

        var history = string.Join("\n\n", recentTurns
            .Where(turn => !string.IsNullOrWhiteSpace(turn.Question) && !string.IsNullOrWhiteSpace(turn.Answer))
            .OrderBy(turn => turn.CreatedAt)
            .TakeLast(4)
            .Select(turn => $"Interviewer: {turn.Question}\nMy previous answer: {turn.Answer}"));
        if (history.Length > 0)
        {
            parts.Add($"\n--- Recent Interview Conversation ---\n{history}\n---\nUse this only as context. Do not repeat it verbatim unless the current question asks for it.");
        }

        var knowledge = KnowledgeText(knowledgeBases, activeIds, entryLimit: null, contentLimit: null);
        if (knowledge.Length > 0)
        {
            parts.Add($"\n--- Selected Knowledge Bases ---\n{knowledge}\n---\nUse these knowledge bases when they are relevant to the question. If the knowledge base includes multiple projects, choose the project that best matches the current question instead of defaulting to the first one.");
        }
        return string.Join("\n", parts);
    }

    /// <summary>System prompt for screenshot / OCR questions (buildStructuredTechnicalSystemPrompt).</summary>
    public static string BuildStructuredTechnicalSystemPrompt(string context, IEnumerable<KnowledgeBaseModel> knowledgeBases, IReadOnlyCollection<Guid> activeIds)
    {
        var parts = new List<string>
        {
            """
            You are a technical interview assistant. For screenshot OCR questions, output a practical structured answer.

            STRICT RULES:
            - 必须用中文回答，除非用户明确要求英文
            - 如果是算法题，必须包含四个小标题：思路、步骤、代码、复杂度
            - 代码必须放在 fenced code block 里，例如 ```python
            - 不要输出推理过程、角色分析或“我需要回答”这类话
            - 不要只给口语概括；算法题必须给可运行代码
            - 解释要简洁，代码要清晰，适合面试时快速讲解
            """
        };
        if (!string.IsNullOrWhiteSpace(context)) parts.Add($"\n--- Candidate Background ---\n{context}");
        var knowledge = KnowledgeText(knowledgeBases, activeIds, entryLimit: null, contentLimit: null);
        if (knowledge.Length > 0) parts.Add($"\n--- Knowledge Bases ---\n{knowledge}");
        return string.Join("\n", parts);
    }

    /// <summary>Appends recent mock interview practice, as macOS does for formal interviews.</summary>
    public static string AppendMockMemory(string systemPrompt, string mockMemory, bool screenshot)
    {
        if (string.IsNullOrWhiteSpace(mockMemory)) return systemPrompt;
        return screenshot
            ? $"{systemPrompt}\n\nCandidate mock interview memory:\n{mockMemory}\n\nPrefer the candidate's practiced examples, wording style, and revised answers when relevant."
            : $"{systemPrompt}\n\nCandidate mock interview memory:\n{mockMemory}\n\nWhen answering in a formal interview, prefer the candidate's practiced examples, wording style, and revised answers from mock interviews. Avoid inventing experience that is not supported by the memory or knowledge base.";
    }

    public static string BuildMockTrainingMemory(IEnumerable<InterviewSessionModel> sessions)
    {
        var blocks = sessions
            .Where(session => string.Equals(session.Kind, "mock", StringComparison.OrdinalIgnoreCase) && session.Turns.Count > 0)
            .OrderByDescending(session => session.StartedAt)
            .Take(2)
            .Select(session =>
            {
                var turns = string.Join("\n\n", session.Turns.OrderBy(turn => turn.CreatedAt).Take(3).Select(turn =>
                    $"Q: {turn.Question}\nA: {Truncate(turn.Answer, 500)}\nFeedback: {Truncate(turn.Feedback, 200)}\nSuggested: {Truncate(turn.SuggestedAnswer, 300)}"));
                return $"Mock session: {session.Title}\nFeedback: {Truncate(session.SummaryFeedback, 200)}\nStrengths: {Truncate(session.StrengthsText, 150)}\nImprovements: {Truncate(session.ImprovementsText, 150)}\n{turns}";
            });
        return string.Join("\n\n---\n\n", blocks);
    }

    // ───────────────────────── user prompts ─────────────────────────

    public static bool IsAlgorithmQuestion(string rawText)
    {
        var lower = rawText.ToLowerInvariant();
        string[] keywords =
        [
            "array", "tree", "graph", "dynamic", "sort", "search", "leetcode", "complexity",
            "stack", "queue", "heap", "linked list", "binary", "dp", "median", "算法", "时间复杂度",
            "空间复杂度", "二叉树", "链表", "数组", "图", "动态规划", "排序", "查找", "中位数"
        ];
        return keywords.Any(lower.Contains);
    }

    /// <summary>User prompt for a screenshot / OCR question (buildQuestionPrompt).</summary>
    public static string BuildQuestionPrompt(string rawText, string answerLanguageCode, string codeLanguage)
    {
        var lower = rawText.ToLowerInvariant();
        var languageInstruction = IsChinese(answerLanguageCode) ? "必须用中文回答。" : "Answer in English.";
        if (string.IsNullOrWhiteSpace(codeLanguage)) codeLanguage = "python";
        string[] baguwen =
        [
            "原理", "区别", "什么是", "解释", "volatile", "synchronized", "jvm", "gc",
            "http", "tcp", "八股", "底层", "redis", "mysql", "索引", "事务", "锁",
            "thread", "process", "database", "cache", "spring", "kafka"
        ];

        if (IsAlgorithmQuestion(rawText))
        {
            return $"""
                You are a candidate in a live technical interview answering an algorithm question.
                {languageInstruction}

                Structure the response using these four short sections: 思路、步骤、代码、复杂度。
                The code section must contain complete, runnable interview-quality {codeLanguage} code
                inside a fenced markdown block that starts with ```{codeLanguage}.
                Keep the explanation concise, but do not omit important edge cases.

                Question:
                {rawText}
                """;
        }
        if (baguwen.Any(lower.Contains))
        {
            return $"""
                The following is a technical knowledge question from a technical interview.
                {languageInstruction}
                Give only the final spoken answer. Do not reveal analysis or planning.
                Use this structure naturally, without markdown or bullet points:
                Start with a one-sentence definition or core concept.
                Then explain the key mechanism or principle in 2-3 sentences.
                If relevant, briefly mention a real use case or example.
                Keep the total response under 100 words and sound confident.

                Question:
                {rawText}
                """;
        }
        return $"""
            The following text was captured from a screen during a technical interview.
            {languageInstruction}
            Identify what is being asked and provide a clear, concise answer.
            If the captured text is a coding or algorithm problem, include a short explanation followed by
            complete runnable {codeLanguage} code in a fenced markdown block beginning with ```{codeLanguage}.
            For a non-coding interview question, give a concise spoken answer without inventing code.
            Give only the final answer, with no planning text.

            Captured text:
            {rawText}
            """;
    }

    /// <summary>Instruction for the vision fallback when OCR returns nothing.</summary>
    public static string BuildScreenshotVisionInstruction(string answerLanguageCode, string codeLanguage) =>
        BuildQuestionPrompt("(The question is in the attached screenshot. Read it carefully first.)", answerLanguageCode, codeLanguage)
        + OutputLanguageMandate(answerLanguageCode);

    /// <summary>Local common interview answer reference (ReceiverCoordinator.commonQuestionReference).</summary>
    public static string CommonQuestionReference(string question)
    {
        var lower = question.ToLowerInvariant();
        var blocks = new List<string>();
        void Add(string title, string body) => blocks.Add($"{title}: {body}");

        if (question.Contains("自我介绍") || lower.Contains("tell me about yourself"))
            Add("Self introduction", "Use a natural first-person answer. Start with the candidate's real background, then mention one or two strongest projects, and close with why that experience fits the current role. Avoid meta phrases like 'I will answer in three parts'.");
        if (question.Contains("挑战") || question.Contains("困难") || lower.Contains("challenge"))
            Add("Project challenge", "Pick one concrete project obstacle. Explain the constraint, what the candidate personally did, how they aligned people or changed the approach, and the measurable or observable result.");
        if (question.Contains("怎么做") || question.Contains("如何") || lower.Contains("how did") || lower.Contains("how would"))
            Add("How it was done", "Answer from the actual action path: situation, key decision, tradeoff, execution detail, result. Keep it spoken and direct, with one vivid detail from the project.");
        if (question.Contains("为什么") || lower.Contains("why"))
            Add("Why question", "Give the real reason first, then support it with a project example or personal pattern. Connect the reason to the role, company, or interviewer's concern.");
        if (question.Contains("例子") || lower.Contains("example") || lower.Contains("tell me about a time"))
            Add("Example question", "Use a specific story with context, the candidate's action, and a result. Do not stay abstract; include one concrete number, user behavior, technical constraint, or stakeholder detail when available.");
        if (question.Contains("优势") || question.Contains("长处") || lower.Contains("strength"))
            Add("Strengths", "Name one strength and immediately prove it with project evidence. The answer should sound grounded, not self-promotional.");
        if (question.Contains("缺点") || question.Contains("不足") || lower.Contains("weakness"))
            Add("Weakness", "Use a controlled weakness that is real but not fatal for the role. Show the concrete system the candidate uses to improve it.");
        if (question.Contains("冲突") || question.Contains("合作") || question.Contains("团队") || lower.Contains("conflict") || lower.Contains("team"))
            Add("Teamwork", "Describe how the candidate clarified goals, made tradeoffs explicit, communicated with stakeholders, and protected the project outcome.");
        if (question.Contains("结果") || question.Contains("效果") || lower.Contains("impact") || lower.Contains("result"))
            Add("Impact", "Use before-and-after contrast. Mention metrics when supported, but do not invent numbers. If exact metrics are unavailable, describe observable improvement.");
        if (blocks.Count == 0)
        {
            Add("General answer style", "Answer directly in first person. Prefer one real project over broad claims. Keep the first sentence useful by itself, then add context, action, and result.");
            Add("Follow-up handling", "If the question is a fragment, infer the likely intent from recent conversation and answer the more complete interview question, not just the last short phrase.");
        }
        return string.Join("\n", blocks.Take(4));
    }

    public static string AppendCommonReference(string systemPrompt, string question)
    {
        var reference = CommonQuestionReference(question);
        return reference.Length == 0 ? systemPrompt : $"""
            {systemPrompt}

            Local common interview answer reference:
            {reference}

            Use this reference only as background guidance. Adapt the answer to the actual live question, the candidate profile, the active knowledge base, and mock interview memory. Do not copy a template mechanically.
            """;
    }

    // ───────────────────────── answer cleanup ─────────────────────────

    private static readonly string[] UnwantedPrefixes =
    [
        "我们开始面试。", "我们开始回答面试问题。", "面试官让我", "我需要", "需要以自然口语方式",
        "注意角色：", "根据背景，", "I need to", "The interviewer asks", "I should"
    ];

    /// <summary>Strips leaked planning sentences (ReceiverCoordinator.displayableAnswer).</summary>
    public static string DisplayableAnswer(string rawText, string codeLanguage)
    {
        var text = (rawText ?? "").Replace("💡", "").Trim();
        if (text.Contains("<<<CODE_START>>>"))
        {
            var language = string.IsNullOrWhiteSpace(codeLanguage) ? "python" : codeLanguage;
            text = text.Replace("<<<CODE_START>>>", $"```{language}").Replace("<<<CODE_END>>>", "```");
        }
        var trimmed = true;
        while (trimmed)
        {
            trimmed = false;
            foreach (var prefix in UnwantedPrefixes)
            {
                if (!text.StartsWith(prefix, StringComparison.Ordinal)) continue;
                var end = text.IndexOfAny(['。', '.', '!', '?', '\n']);
                if (end < 0) continue;
                text = text[(end + 1)..].Trim();
                trimmed = true;
            }
        }
        return text;
    }

    // ───────────────────────── helpers ─────────────────────────

    private static string KnowledgeText(IEnumerable<KnowledgeBaseModel> knowledgeBases, IReadOnlyCollection<Guid> activeIds, int? entryLimit, int? contentLimit)
    {
        var text = string.Join("\n\n", knowledgeBases
            .Where(kb => activeIds.Contains(kb.Id))
            .Select(kb =>
            {
                var entries = kb.Entries
                    .Where(entry => entry.IsEnabled && !string.IsNullOrWhiteSpace(entry.Content))
                    .OrderBy(entry => entry.CreatedAt)
                    .Take(entryLimit ?? int.MaxValue)
                    .Select(entry => $"{entry.Title}:\n{(contentLimit is int limit ? Truncate(entry.Content, limit) : entry.Content)}");
                var joined = string.Join("\n\n", entries);
                return joined.Length == 0 ? "" : $"[{kb.Name}]\n{joined}";
            })
            .Where(block => block.Length > 0));
        // Keep requests within typical context limits.
        return Truncate(text, 24000);
    }

    private static string FirstNonEmpty(params string?[] values) => values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value)) ?? "";

    private static string Truncate(string? value, int length) =>
        string.IsNullOrEmpty(value) ? "" : value.Length <= length ? value : value[..length];
}
