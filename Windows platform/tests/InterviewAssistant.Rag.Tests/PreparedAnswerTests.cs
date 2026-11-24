using InterviewAssistant.Models;
using InterviewAssistant.Services;

namespace InterviewAssistant.Rag.Tests;

/// <summary>Prepared-answer matching; mirrors the macOS tests in SpeechProtectionTests.swift.</summary>
public sealed class PreparedAnswerTests
{
    [Fact]
    public void SimilarityIgnoresPoliteFillers()
    {
        Assert.True(PreparedAnswerLibrary.Similarity("请做一下自我介绍", "自我介绍一下") > 0.8);
        Assert.Equal(1, PreparedAnswerLibrary.Similarity("Tell me about yourself", "Tell me about yourself."), 4);
        Assert.True(PreparedAnswerLibrary.Similarity("Redis 和 MySQL 的区别", "你的期望薪资是多少") < 0.1);
    }

    [Fact]
    public void ParsesQuestionAnswerPairsFromMaterial()
    {
        const string material = """
            # 常见问题
            Q: 为什么从上家公司离职？
            A: 我希望做更贴近用户的产品。
            补充一句。
            问：你的缺点是什么？
            答：我有时过于追求细节。
            """;
        var items = PreparedAnswerLibrary.ParseMaterial(material, "Notes");
        Assert.Equal(["为什么从上家公司离职？", "你的缺点是什么？"], items.Select(item => item.Question));
        Assert.Equal("我希望做更贴近用户的产品。\n补充一句。", items[0].Answer);
        Assert.Equal("我有时过于追求细节。", items[1].Answer);
    }

    [Fact]
    public void FollowUpsOnlyApplyAfterTheirPrimaryQuestion()
    {
        PreparedQA[] items =
        [
            new("请做一下自我介绍", "我是……", "Bank"),
            new("具体说说难点", "难点是……", "Bank", "介绍一下你最有挑战的项目")
        ];
        Assert.Equal(["请做一下自我介绍"], PreparedAnswerLibrary.Candidates("自我介绍一下", null, items, []).Select(item => item.Question));
        Assert.NotEmpty(PreparedAnswerLibrary.Candidates("具体说说难点", "你的期望薪资是多少", items, []));
        Assert.Empty(PreparedAnswerLibrary.Candidates("能展开讲讲吗", "你的期望薪资是多少", items, []));
        Assert.Equal("具体说说难点", PreparedAnswerLibrary.Candidates("能展开讲讲吗", "介绍一下你最有挑战的项目", items, []).Single().Question);
    }

    [Fact]
    public void QuestionBankIsChunkedAsQuestionAnswerPairs()
    {
        // Long enough to be split (short content intentionally stays one passage).
        var content = QuestionBankService.Encode(new QuestionBankDocument
        {
            Questions = Enumerable.Range(1, 8).Select(index => new QuestionBankPrimary
            {
                Question = $"第{index}题：请讲讲你在项目{index}中遇到的问题？",
                Answer = string.Concat(Enumerable.Repeat($"在项目{index}里我负责后端架构设计，并推动团队完成了性能优化和稳定性治理。", 6))
            }).ToList()
        });
        var document = new RagDocument(Guid.NewGuid(), "KB", Guid.NewGuid(), "Bank", KnowledgeEntryKinds.QuestionBank, "manual", "", "",
            QuestionBankService.SearchableText(content), true);
        var chunks = KnowledgeChunker.Chunk(document);
        Assert.True(chunks.Count >= 8);
        Assert.All(chunks, chunk =>
        {
            Assert.True(chunk.IsQuestionAnswer);
            Assert.Equal(1, chunk.Text.Split('\n').Count(line => line.StartsWith("Q: ", StringComparison.Ordinal)));
        });
    }

    [Fact]
    public void PromptBlockCarriesFullAnswerAndReuseRules()
    {
        var block = PreparedAnswerLibrary.PromptBlock([new PreparedQA("请做一下自我介绍", "我是一名后端工程师。", "Bank")]);
        Assert.Contains("我是一名后端工程师。", block);
        Assert.Contains("Same question: answer with that prepared answer", block);
        Assert.Equal("", PreparedAnswerLibrary.PromptBlock([]));
        Assert.Equal(900, PreparedAnswerLibrary.RecommendedMaxTokens([], 900));
    }
}
