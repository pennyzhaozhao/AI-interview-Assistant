import Foundation

enum KnowledgeContextBuilder {
    static func isAlgorithmQuestion(_ rawText: String) -> Bool {
        let lower = rawText.lowercased()
        return [
            "array", "tree", "graph", "dynamic", "sort", "search", "leetcode", "complexity",
            "stack", "queue", "heap", "linked list", "binary", "dp", "median", "算法", "时间复杂度",
            "空间复杂度", "二叉树", "链表", "数组", "图", "动态规划", "排序", "查找", "中位数"
        ].contains { lower.contains($0) }
    }

    static func buildAlgorithmApproachPrompt(rawText: String, answerLanguage: String = "zh-CN") -> String {
        let languageInstruction = answerLanguage == "zh-CN"
            ? """
            必须用中文回答。回答要像专业候选人在现场面试中讲解算法，不要只给一句摘要。
            """
            : """
            Answer in English. Speak like a strong candidate explaining the algorithm in a live technical interview; do not give a one-sentence summary.
            """
        return """
        The following is an algorithm or coding question from a technical interview.
        \(languageInstruction)
        Explain only the approach first. Do not write code yet.

        Output exactly these three sections and make every section substantive:

        思路:
        First identify the algorithm pattern you would use, for example sliding window, binary search, dynamic programming, stack, graph traversal, or greedy. Explain why the original problem can be transformed into that pattern. State the key invariant in plain interview language. For sliding-window problems, explicitly say what makes a window valid.

        步骤:
        Walk through the implementation with concrete variable names such as left, right, zero_count, ans, stack, dp, visited, or whichever fits the problem. Explain how the state expands, when it shrinks or transitions, and exactly when the answer is updated. Use interview-ready wording, not a vague summary.

        复杂度:
        State time and space complexity and briefly justify why.

        Requirements:
        - Sound like you are answering an interviewer, using phrases like “这题我会用...” or “I would use...”.
        - The answer should be detailed enough to guide implementation: about 260-450 Chinese characters or 140-220 English words.
        - Do not compress the whole answer into one paragraph.
        - Do not use markdown tables.
        - Do not include code.
        - Do not reveal hidden reasoning or say “I need to”.

        Question:
        \(rawText)
        """
    }

    static func buildAlgorithmApproachSystemPrompt(context: String, knowledgeBases: [KnowledgeBase], activeIDs: [UUID]) -> String {
        var parts = [
            """
            You are a senior technical interview coach helping a candidate answer an algorithm question live.

            STRICT RULES:
            - 必须用中文回答，除非用户明确要求英文
            - 这里只输出算法思路，不要写代码
            - 不要只给一句概括；必须讲清楚题目本质、算法选择、状态维护、答案更新和复杂度
            - 语气像候选人在面试现场自然讲解，可以用“这题我会用...”开头
            - 不要输出推理过程、角色分析或“我需要回答”这类话
            - 不要使用 markdown 表格
            """
        ]
        if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("\n--- Candidate Background ---\n\(context)")
        }
        let selected = knowledgeBases.filter { activeIDs.contains($0.id) }
        let kbText = selected.compactMap { kb -> String? in
            let entries = kb.entries
                .filter { $0.isEnabled }
                .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(3)
                .map { "- \($0.title): \($0.content.prefix(800))" }
                .joined(separator: "\n")
            return entries.isEmpty ? nil : "Knowledge Base: \(kb.name)\n\(entries)"
        }.joined(separator: "\n\n")
        if !kbText.isEmpty {
            parts.append("\n--- Useful Knowledge ---\n\(kbText)")
        }
        return parts.joined(separator: "\n\n")
    }

    static func buildAlgorithmCodePrompt(rawText: String, language: String) -> String {
        let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "python" : language
        return """
        Write the solution code for this algorithm problem in \(normalizedLanguage).
        Output only a fenced code block using ```\(normalizedLanguage), with complete runnable interview-quality code.
        The code must be complete: include the full function body, all branches, return statements, and necessary imports/types.
        Do not stop halfway. Do not use ellipses or comments like "rest omitted".
        Do not add explanation outside the code block.

        Question:
        \(rawText)
        """
    }

    static func buildQuestionPrompt(
        rawText: String,
        answerLanguage: String = "zh-CN",
        codeLanguage: String = "python"
    ) -> String {
        let lower = rawText.lowercased()
        let languageInstruction = answerLanguage == "zh-CN" ? "必须用中文回答。" : "Answer in English."

        let isAlgorithm = isAlgorithmQuestion(rawText)

        let isBaguwen = [
            "原理", "区别", "什么是", "解释", "volatile", "synchronized", "jvm", "gc",
            "http", "tcp", "八股", "底层", "redis", "mysql", "索引", "事务", "锁",
            "thread", "process", "database", "cache", "spring", "kafka"
        ].contains { lower.contains($0) }

        if isAlgorithm {
            return """
            You are a candidate in a live technical interview answering an algorithm question.
            \(languageInstruction)

            Structure the response using these four short sections: 思路、步骤、代码、复杂度。
            The code section must contain complete, runnable interview-quality \(codeLanguage) code
            inside a fenced markdown block that starts with ```\(codeLanguage).
            Keep the explanation concise, but do not omit important edge cases.

            Question:
            \(rawText)
            """
        } else if isBaguwen {
            return """
            The following is a technical knowledge question from a technical interview.
            \(languageInstruction)
            Give only the final spoken answer. Do not reveal analysis or planning.
            Use this structure naturally, without markdown or bullet points:
            Start with a one-sentence definition or core concept.
            Then explain the key mechanism or principle in 2-3 sentences.
            If relevant, briefly mention a real use case or example.
            Keep the total response under 100 words and sound confident.

            Question:
            \(rawText)
            """
        } else {
            return """
            The following text was captured from a screen during a technical interview.
            \(languageInstruction)
            Identify what is being asked and provide a clear, concise answer.
            If the captured text is a coding or algorithm problem, include a short explanation followed by
            complete runnable \(codeLanguage) code in a fenced markdown block beginning with ```\(codeLanguage).
            For a non-coding interview question, give a concise spoken answer without inventing code.
            Give only the final answer, with no planning text.

            Captured text:
            \(rawText)
            """
        }
    }

    static func buildStructuredTechnicalSystemPrompt(context: String, knowledgeBases: [KnowledgeBase], activeIDs: [UUID]) -> String {
        var parts = [
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
        ]
        if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("\n--- Candidate Background ---\n\(context)")
        }
        let selected = knowledgeBases.filter { activeIDs.contains($0.id) }
        let kbText = selected.compactMap { kb -> String? in
            let entries = kb.entries
                .filter { $0.isEnabled }
                .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { "\($0.title):\n\($0.content)" }
                .joined(separator: "\n\n")
            return entries.isEmpty ? nil : "[\(kb.name)]\n\(entries)"
        }.joined(separator: "\n\n")
        if !kbText.isEmpty {
            parts.append("\n--- Knowledge Bases ---\n\(kbText)")
        }
        return parts.joined(separator: "\n")
    }

    static func buildSystemPrompt(context: String, knowledgeBases: [KnowledgeBase], activeIDs: [UUID], recentTurns: [ConversationTurn] = []) -> String {
        var parts = [
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
        ]
        if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("\n--- My Background, Target Role, and Company Research ---\n\(context)\n---\nDraw on this material when answering. Refer to my own projects and experiences naturally in first person. Use company research for company-fit questions.")
        }
        let historyText = recentTurns
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(4)
            .map { turn in
                """
                Interviewer: \(turn.question)
                My previous answer: \(turn.answer)
                """
            }
            .joined(separator: "\n\n")
        if !historyText.isEmpty {
            parts.append("\n--- Recent Interview Conversation ---\n\(historyText)\n---\nUse this only as context. Do not repeat it verbatim unless the current question asks for it.")
        }
        let selected = knowledgeBases.filter { activeIDs.contains($0.id) }
        let kbText = selected.compactMap { kb -> String? in
            let entries = kb.entries
                .filter { $0.isEnabled }
                .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.createdAt < $1.createdAt }
                .map { "\($0.title):\n\($0.content)" }
                .joined(separator: "\n\n")
            return entries.isEmpty ? nil : "[\(kb.name)]\n\(entries)"
        }.joined(separator: "\n\n")
        if !kbText.isEmpty {
            parts.append("\n--- Selected Knowledge Bases ---\n\(kbText)\n---\nUse these knowledge bases when they are relevant to the question. If the knowledge base includes multiple projects, choose the project that best matches the current question instead of defaulting to the first one.")
        }
        return parts.joined(separator: "\n")
    }
}
