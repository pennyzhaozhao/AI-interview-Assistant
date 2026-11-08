namespace InterviewAssistant.Rag.Tests;

public sealed class ChunkerTests
{
    [Fact]
    public void Short_content_is_one_chunk()
    {
        var document = TestKnowledge.Travel with { Kind = RagKinds.Material, Summary = "" };
        var chunks = KnowledgeChunker.Chunk(document);
        Assert.Single(chunks);
        Assert.Contains("idempotency keys", chunks[0].Text);
    }

    [Fact]
    public void Long_document_is_split_within_limits_with_sections_and_overlap()
    {
        var chunks = KnowledgeChunker.Chunk(TestKnowledge.Distributed);
        Assert.True(chunks.Count >= 4, $"expected several chunks, got {chunks.Count}");
        Assert.All(chunks, chunk => Assert.InRange(TokenEstimator.Estimate(chunk.Text), 1, ChunkerOptions.Default.MaxTokens + ChunkerOptions.Default.OverlapTokens));
        Assert.Contains(chunks, chunk => chunk.Section == "Consensus" && chunk.Text.Contains("Raft"));
    }

    [Fact]
    public void Long_section_passages_overlap()
    {
        var paragraphs = Enumerable.Range(1, 30).Select(i => $"Paragraph {i}: the cache layer handles invalidation step {i} carefully. It also records metric {i} for later review.");
        var document = TestKnowledge.Distributed with { Content = "## Caching deep dive\n\n" + string.Join("\n\n", paragraphs) };
        var chunks = KnowledgeChunker.Chunk(document);
        Assert.True(chunks.Count >= 2);
        Assert.All(chunks, chunk => Assert.Equal("Caching deep dive", chunk.Section));
        // Each passage after the first starts with the last sentences of the previous one.
        foreach (var (first, second) in chunks.Zip(chunks.Skip(1)))
        {
            var opening = second.Text[..Math.Min(40, second.Text.Length)];
            Assert.Contains(opening, first.Text);
        }
    }

    [Fact]
    public void Question_and_answer_pairs_stay_together()
    {
        var long_ = TestKnowledge.InterviewQa with { Content = TestKnowledge.InterviewQa.Content + "\n\n" + string.Join("\n\n", Enumerable.Range(1, 30).Select(i => $"Q: Filler question {i} about caching?\nA: Filler answer {i} about cache-aside and TTLs.")) };
        var chunks = KnowledgeChunker.Chunk(long_);
        var weakness = Assert.Single(chunks, chunk => chunk.Text.Contains("你最大的缺点"));
        Assert.Contains("时间盒", weakness.Text);
        Assert.True(weakness.IsQuestionAnswer);
        Assert.DoesNotContain("为什么离开", weakness.Text);
    }

    [Fact]
    public void Long_answer_keeps_its_question_in_every_part()
    {
        var answer = string.Join(" ", Enumerable.Range(1, 120).Select(i => $"Sentence {i} explains the cache invalidation strategy in detail."));
        var document = TestKnowledge.InterviewQa with { Content = "Q: How do you invalidate caches?\nA: " + answer + "\n\nQ: Next question?\nA: Short." };
        var parts = KnowledgeChunker.Chunk(document).Where(chunk => chunk.Text.Contains("invalidate caches")).ToList();
        Assert.True(parts.Count >= 2);
        Assert.All(parts, part => Assert.StartsWith("Q: How do you invalidate caches?", part.Text));
    }

    [Fact]
    public void Code_blocks_are_not_split_inside()
    {
        var code = "```python\n" + string.Join("\n", Enumerable.Range(1, 20).Select(i => $"result_{i} = compute(value_{i})  # step {i}")) + "\n```";
        var document = TestKnowledge.Distributed with { Content = TestKnowledge.Distributed.Content + "\n\n## Code\n\n" + code };
        var chunk = Assert.Single(KnowledgeChunker.Chunk(document), item => item.Text.Contains("result_1 ="));
        Assert.Contains("result_20 =", chunk.Text);
    }

    [Fact]
    public void Project_and_resume_summaries_are_their_own_passages()
    {
        var project = KnowledgeChunker.Chunk(TestKnowledge.Dashboard);
        Assert.StartsWith("Project: Monitoring Dashboard (Python · ★ 120)", project[0].Text);
        Assert.Equal(TestKnowledge.ResumeSummary, KnowledgeChunker.Chunk(TestKnowledge.Resume)[0].Text);
    }

    [Fact]
    public void Chunk_ids_are_deterministic_and_change_with_content()
    {
        var first = KnowledgeChunker.Chunk(TestKnowledge.Dashboard).Select(chunk => chunk.ChunkId).ToList();
        var again = KnowledgeChunker.Chunk(TestKnowledge.Dashboard).Select(chunk => chunk.ChunkId).ToList();
        Assert.Equal(first, again);
        Assert.Equal(first.Count, first.Distinct().Count());
        var edited = KnowledgeChunker.Chunk(TestKnowledge.Dashboard with { Content = TestKnowledge.Dashboard.Content + "\nNew line." });
        Assert.Empty(first.Intersect(edited.Select(chunk => chunk.ChunkId)));
        // Same text in another entry never collides.
        var other = KnowledgeChunker.Chunk(TestKnowledge.Dashboard with { EntryId = Guid.NewGuid() });
        Assert.Empty(first.Intersect(other.Select(chunk => chunk.ChunkId)));
    }

    [Fact]
    public void Empty_content_produces_no_chunks_for_materials()
    {
        Assert.Empty(KnowledgeChunker.Chunk(TestKnowledge.InterviewQa with { Content = "   \n  " }));
    }
}
