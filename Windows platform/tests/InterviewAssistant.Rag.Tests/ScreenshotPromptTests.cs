using InterviewAssistant.Services;

namespace InterviewAssistant.Rag.Tests;

/// <summary>Screenshot question prompts: multiple-choice detection, label rules and hidden reasoning.</summary>
public sealed class ScreenshotPromptTests
{
    [Theory]
    [InlineData("A. Linux\nB. Windows\nC. macOS", true)]
    [InlineData("(A) 1 (B) 2 (C) 3", true)]
    [InlineData("A Linux\nB Windows", true)]
    [InlineData("以下关于进程的说法正确的是\n进程是资源分配的基本单位\n线程是资源分配的基本单位", true)]
    [InlineData("Implement a function that returns a sorted array of the input", false)]
    [InlineData("Redis 为什么快？", false)]
    [InlineData("给定一个数组，返回其中位数，要求时间复杂度 O(log n)", false)]
    public void Detects_multiple_choice_questions(string text, bool expected) =>
        Assert.Equal(expected, InterviewPromptBuilder.IsMultipleChoiceQuestion(text));

    [Fact]
    public void Multiple_choice_wins_over_algorithm_keywords()
    {
        var prompt = InterviewPromptBuilder.BuildQuestionPrompt("下列排序算法中，平均时间复杂度为 O(nlogn) 的是\nA. 冒泡排序\nB. 快速排序", "zh-CN", "python");
        Assert.Contains("multiple-choice question", prompt);
        Assert.DoesNotContain("思路、步骤、代码、复杂度", prompt);
    }

    [Fact]
    public void Rules_forbid_invented_labels_and_cover_picture_options()
    {
        var prompt = InterviewPromptBuilder.BuildQuestionPrompt("A. Linux\nB. Windows", "zh-CN", "python");
        Assert.Contains("never invent letters", prompt);
        Assert.Contains("第 3 个图形", prompt);
        Assert.Contains("答案：", prompt);
        Assert.Contains("解析：", prompt);
        Assert.DoesNotContain("答案：A. Linux", prompt);
    }

    [Theory]
    [InlineData("<analysis>check B</analysis>\n答案：B. Linux\n解析：…", "\n答案：B. Linux\n解析：…")]
    [InlineData("<analysis>still thinking", "")]
    [InlineData("<think>x</think>答案：进程", "答案：进程")]
    [InlineData("答案：没有分析", "答案：没有分析")]
    public void Strips_hidden_reasoning(string raw, string expected) =>
        Assert.Equal(expected, InterviewPromptBuilder.StripHiddenReasoning(raw));
}
