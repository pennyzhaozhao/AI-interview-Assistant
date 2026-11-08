namespace InterviewAssistant.Rag.Tests;

/// <summary>The test knowledge, indexed once with the real model.</summary>
public sealed class IndexedKnowledgeFixture : IAsyncLifetime
{
    private readonly TempDirectory _temp = new();
    public KnowledgeIndexCoordinator Coordinator { get; private set; } = null!;

    public async ValueTask InitializeAsync()
    {
        Coordinator = new KnowledgeIndexCoordinator(_temp.Path, ModelLocator.Directory is { } dir ? [dir] : []);
        Coordinator.RequestSync(TestKnowledge.All);
        await Coordinator.WhenIdleAsync();
    }

    public Task<RetrievalResult> Ask(string question, IReadOnlyList<RagConversationTurn>? turns = null, IReadOnlySet<Guid>? kbs = null, IReadOnlySet<Guid>? enabled = null)
    {
        var titles = TestKnowledge.All.Where(d => d.Kind != RagKinds.Resume).Select(d => d.Title).ToList();
        var query = QueryContextualizer.Prepare(question, turns ?? [], "Backend Engineer", titles);
        return Coordinator.RetrieveAsync(query, kbs ?? TestKnowledge.EngineerOnly, enabled ?? TestKnowledge.EnabledIds(TestKnowledge.All));
    }

    public ValueTask DisposeAsync()
    {
        Coordinator.Dispose();
        _temp.Dispose();
        return ValueTask.CompletedTask;
    }
}

public sealed class RetrievalTests(IndexedKnowledgeFixture knowledge) : IClassFixture<IndexedKnowledgeFixture>
{
    private static Guid Top(RetrievalResult result) => Assert.IsType<RetrievedChunk>(result.Chunks.FirstOrDefault()).Chunk.EntryId;

    [Fact]
    public async Task Finds_the_project_from_its_technologies()
    {
        ModelLocator.Require();
        var result = await knowledge.Ask("Have you built anything with Prometheus and WebSockets?");
        Assert.Equal(RetrievalMode.Hybrid, result.Mode);
        Assert.Equal(TestKnowledge.DashboardId, Top(result));
    }

    [Theory]
    [InlineData("What did you do with Laravel?", "a0000000-0000-0000-0000-000000000003")]
    [InlineData("Have you used Kubernetes and Helm?", "a0000000-0000-0000-0000-000000000001")]
    [InlineData("Explain Raft leader election", "a0000000-0000-0000-0000-000000000006")]
    [InlineData("你用 pandas 做过什么分析", "a0000000-0000-0000-0000-000000000004")]
    public async Task Exact_technical_terms_are_found(string question, string expectedEntry)
    {
        ModelLocator.Require();
        var result = await knowledge.Ask(question);
        Assert.Contains(result.Chunks.Take(2), chunk => chunk.Chunk.EntryId == Guid.Parse(expectedEntry));
    }

    [Fact]
    public async Task Keyword_search_alone_finds_exact_framework_names()
    {
        // No vector at all: BM25 must still find "Laravel" and "Stripe".
        var index = knowledge.Coordinator;
        var chunks = TestKnowledge.All.SelectMany(document => KnowledgeChunker.Chunk(document))
            .Select(chunk => { var terms = LexicalAnalyzer.TermFrequencies(chunk.LexicalText); return new IndexedChunk(chunk, terms, terms.Values.Sum(), null); }).ToList();
        var result = KnowledgeRetrievalService.Retrieve(chunks, QueryContextualizer.Prepare("Stripe webhook idempotency", [], "", []), null, TestKnowledge.EngineerOnly, null);
        Assert.Equal(RetrievalMode.LexicalOnly, result.Mode);
        Assert.Equal(TestKnowledge.TravelId, Top(result));
        Assert.NotNull(index);
    }

    [Theory]
    [InlineData("你的短板是什么？", "你最大的缺点")]
    [InlineData("为什么想换工作", "为什么离开上一家公司")]
    [InlineData("Describe a disagreement with a colleague and how you resolved it", "handled a conflict")]
    public async Task Finds_prepared_answers_worded_differently(string question, string expectedText)
    {
        ModelLocator.Require();
        var result = await knowledge.Ask(question);
        Assert.Contains(result.Chunks.Take(2), chunk => chunk.Text.Contains(expectedText));
    }

    [Fact]
    public async Task Only_active_knowledge_bases_are_searched()
    {
        var engineer = await knowledge.Ask("A/B test sign-up conversion fintech onboarding");
        Assert.DoesNotContain(engineer.Chunks, chunk => chunk.Chunk.KnowledgeBaseId == TestKnowledge.ProductKb);
        var product = await knowledge.Ask("A/B test sign-up conversion fintech onboarding", kbs: new HashSet<Guid> { TestKnowledge.ProductKb });
        Assert.NotEmpty(product.Chunks);
        Assert.All(product.Chunks, chunk => Assert.Equal(TestKnowledge.ProductKb, chunk.Chunk.KnowledgeBaseId));
    }

    [Fact]
    public async Task Disabled_entries_are_excluded()
    {
        var enabled = TestKnowledge.EnabledIds(TestKnowledge.All).Where(id => id != TestKnowledge.DashboardId).ToHashSet();
        var result = await knowledge.Ask("FastAPI monitoring dashboard Prometheus", enabled: enabled);
        Assert.DoesNotContain(result.Chunks, chunk => chunk.Chunk.EntryId == TestKnowledge.DashboardId);
    }

    [Fact]
    public async Task Unrelated_questions_retrieve_little_or_nothing()
    {
        ModelLocator.Require();
        var result = await knowledge.Ask("What is your favourite food?");
        Assert.True(result.Chunks.Count <= 1, $"expected no filler passages, got {result.Chunks.Count}: {string.Join(" | ", result.Chunks.Select(c => c.Chunk.Title))}");
    }

    [Fact]
    public async Task Results_are_diverse_and_within_budget()
    {
        ModelLocator.Require();
        var result = await knowledge.Ask("Tell me about consistency, consensus, Kafka, caching and rate limiting");
        Assert.InRange(result.Chunks.Count, 1, RetrievalOptions.Default.TopK);
        Assert.True(result.Chunks.GroupBy(chunk => chunk.Chunk.EntryId).All(group => group.Count() <= RetrievalOptions.Default.MaxChunksPerEntry));
        Assert.Equal(result.Chunks.Count, result.Chunks.Select(chunk => chunk.Chunk.ChunkId).Distinct().Count());
        Assert.True(result.Chunks.Sum(chunk => TokenEstimator.Estimate(chunk.Text)) <= RetrievalOptions.Default.MaxContextTokens);
    }

    [Fact]
    public void Duplicate_passages_are_returned_once()
    {
        var chunk = KnowledgeChunker.Chunk(TestKnowledge.Travel)[1];
        var copy = chunk with { ChunkId = "copy", EntryId = Guid.NewGuid() };
        var items = new[] { chunk, copy }.Select(c => { var terms = LexicalAnalyzer.TermFrequencies(c.LexicalText); return new IndexedChunk(c, terms, terms.Values.Sum(), null); }).ToList();
        var result = KnowledgeRetrievalService.Retrieve(items, QueryContextualizer.Prepare("Stripe webhook", [], "", []), null, TestKnowledge.EngineerOnly, null);
        Assert.Single(result.Chunks);
    }

    [Fact]
    public async Task Empty_question_returns_nothing()
    {
        var result = await knowledge.Ask("   ");
        Assert.Empty(result.Chunks);
    }
}

public sealed class ConversationTests(IndexedKnowledgeFixture knowledge) : IClassFixture<IndexedKnowledgeFixture>
{
    private static readonly RagConversationTurn DashboardTurn = new("Tell me about your FastAPI monitoring dashboard.",
        "I built a real-time monitoring dashboard with FastAPI and Prometheus that cut incident detection time by 40%.");
    private static readonly RagConversationTurn ChallengeTurn = new("What was the biggest technical challenge?",
        "The biggest challenge was high-cardinality metrics that made Prometheus memory explode.");

    [Fact]
    public async Task Follow_up_resolves_to_the_discussed_project()
    {
        ModelLocator.Require();
        var query = QueryContextualizer.Prepare("How did you solve it?", [DashboardTurn, ChallengeTurn], "Backend Engineer",
            TestKnowledge.All.Where(d => d.Kind != RagKinds.Resume).Select(d => d.Title).ToList());
        Assert.True(query.IsFollowUp);
        Assert.Equal("Monitoring Dashboard", query.Topic);
        var result = await knowledge.Ask("How did you solve it?", [DashboardTurn, ChallengeTurn]);
        Assert.Contains(result.Chunks.Take(2), chunk => chunk.Text.Contains("recording rules"));
    }

    [Fact]
    public async Task Chinese_follow_up_resolves_to_the_discussed_project()
    {
        ModelLocator.Require();
        var turn = new RagConversationTurn("讲讲你的出行调查数据分析项目", "我用 pandas 以 trips 表为主表做了 Left Join……");
        var result = await knowledge.Ask("具体是怎么清洗数据的？", [turn]);
        Assert.Equal(TestKnowledge.SurveyId, result.Chunks.First().Chunk.EntryId);
    }

    [Fact]
    public async Task New_topic_does_not_carry_the_previous_project()
    {
        ModelLocator.Require();
        var query = QueryContextualizer.Prepare("What did you build at UFOS Travel with PHP and MySQL?", [DashboardTurn, ChallengeTurn], "Backend Engineer",
            TestKnowledge.All.Select(d => d.Title).ToList());
        Assert.False(query.IsFollowUp);
        var result = await knowledge.Ask("What did you build at UFOS Travel with PHP and MySQL?", [DashboardTurn, ChallengeTurn]);
        Assert.Equal(TestKnowledge.TravelId, result.Chunks.First().Chunk.EntryId);
        Assert.DoesNotContain(result.Chunks.Take(2), chunk => chunk.Chunk.EntryId == TestKnowledge.DashboardId);
    }

    [Fact]
    public void Unrelated_question_after_a_project_is_not_treated_as_follow_up()
    {
        var query = QueryContextualizer.Prepare("Why do you want to join our company and what are your salary expectations?", [DashboardTurn], "Backend Engineer", ["Monitoring Dashboard"]);
        Assert.False(query.IsFollowUp);
        Assert.DoesNotContain("dashboard", query.SemanticText, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Context_is_bounded()
    {
        var huge = new RagConversationTurn(new string('x', 20_000), new string('y', 20_000));
        var query = QueryContextualizer.Prepare("And then?", [huge, huge, huge, huge], "Engineer", []);
        Assert.True(query.SemanticText.Length < 1_000);
    }
}
