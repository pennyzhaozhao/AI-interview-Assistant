using System.Diagnostics;
using InterviewAssistant.Models;
using InterviewAssistant.Services;

namespace InterviewAssistant.Rag.Tests;

[Collection("model")]
public sealed class StressAndBenchmarkTests(ITestOutputHelper output)
{
    /// <summary>~1.6 MB of notes (hundreds of times the model's context budget) with one specific fact hidden inside.</summary>
    private static List<RagDocument> LargeKnowledgeBase(int documents)
    {
        var random = new Random(7);
        string[] subjects = ["caching", "queues", "databases", "frontend", "security", "testing", "networking", "compilers", "statistics", "leadership"];
        var list = new List<RagDocument>();
        for (var index = 0; index < documents; index++)
        {
            var subject = subjects[index % subjects.Length];
            var builder = new System.Text.StringBuilder($"# Study notes {index} on {subject}\n\n");
            for (var paragraph = 0; paragraph < 12; paragraph++)
            {
                builder.Append($"Paragraph {paragraph} about {subject}: ");
                for (var sentence = 0; sentence < 5; sentence++)
                    builder.Append($"Item {random.Next(100000)} discusses {subject} trade-offs, latency budgets and failure modes in system {random.Next(1000)}. ");
                builder.Append("\n\n");
            }
            if (index == documents / 2)
                builder.Append("## Incident retrospective\n\nThe Zephyr payment outage was caused by an expired TLS certificate on the internal gRPC gateway; I added automated certificate rotation with cert-manager.\n");
            list.Add(new RagDocument(TestKnowledge.EngineerKb, "Software Engineer", Guid.NewGuid(), $"Notes {index}", RagKinds.Material, "manual", "", "", builder.ToString(), true));
        }
        return list;
    }

    [Fact]
    public async Task Large_knowledge_base_stays_bounded_and_finds_the_needle()
    {
        ModelLocator.Require();
        var documents = TestKnowledge.All.Concat(LargeKnowledgeBase(400)).ToList();
        var totalCharacters = documents.Sum(document => document.Content.Length);
        using var temp = new TempDirectory();
        using var coordinator = new KnowledgeIndexCoordinator(temp.Path, [ModelLocator.Directory!]);
        var indexTimer = Stopwatch.StartNew();
        coordinator.RequestSync(documents);
        await coordinator.WhenIdleAsync();
        indexTimer.Stop();
        output.WriteLine($"Indexed {documents.Count} documents, {totalCharacters:N0} characters, {coordinator.Status.TotalChunks} passages in {indexTimer.Elapsed.TotalSeconds:F1} s");

        var bases = AppModels.From(documents);
        var context = await RagPromptContext.BuildAsync(coordinator, "What caused the Zephyr payment outage and how did you fix it?", bases, [TestKnowledge.EngineerKb], [], "Backend Engineer");
        var system = InterviewPromptBuilder.BuildSystemPrompt("Target role: Backend Engineer", context, []);
        Assert.Contains("expired TLS certificate", system);
        Assert.True(PromptTokenBudget.Estimate(system) <= PromptBudget.Default.Total);
        Assert.True(system.Length < totalCharacters / 100, $"prompt {system.Length:N0} chars vs knowledge {totalCharacters:N0}");

        // A second sync with unchanged data does no work.
        var resync = Stopwatch.StartNew();
        coordinator.RequestSync(documents);
        await coordinator.WhenIdleAsync();
        output.WriteLine($"Unchanged re-sync: {resync.Elapsed.TotalMilliseconds:F0} ms, pending embeddings {coordinator.Status.PendingEmbeddings}");
        Assert.Equal(0, coordinator.Status.PendingEmbeddings);
    }

    [Fact]
    public async Task Benchmark_local_retrieval_latency()
    {
        ModelLocator.Require();
        var documents = TestKnowledge.All.Concat(LargeKnowledgeBase(400)).ToList();
        using var temp = new TempDirectory();
        using var coordinator = new KnowledgeIndexCoordinator(temp.Path, [ModelLocator.Directory!]);
        coordinator.RequestSync(documents);
        await coordinator.WhenIdleAsync();
        var bases = AppModels.From(documents);
        string[] questions =
        [
            "Tell me about your FastAPI monitoring dashboard.", "你最大的缺点是什么？", "How did you handle Kubernetes migrations?",
            "讲讲你做过的数据分析项目", "What was the Zephyr outage?", "Explain Raft leader election", "Have you used Redis caching?",
            "为什么离开上一家公司", "Describe a conflict with a teammate", "What do you know about rate limiting?"
        ];
        // Warm-up, then measure each phase separately (cloud LLM latency is not part of this).
        await coordinator.RetrieveAsync(QueryContextualizer.Prepare("warm up", [], "", []), TestKnowledge.EngineerOnly, null);
        var embedding = new List<double>(); var vector = new List<double>(); var keyword = new List<double>(); var fusion = new List<double>(); var total = new List<double>(); var assembly = new List<double>();
        foreach (var question in questions)
        {
            var result = await coordinator.RetrieveAsync(QueryContextualizer.Prepare(question + " (variant)", [], "", []), TestKnowledge.EngineerOnly, null);
            embedding.Add(result.Timings.QueryEmbeddingMs); vector.Add(result.Timings.VectorSearchMs); keyword.Add(result.Timings.KeywordSearchMs);
            fusion.Add(result.Timings.FusionMs); total.Add(result.Timings.TotalMs);
            var timer = Stopwatch.StartNew();
            var context = await RagPromptContext.BuildAsync(coordinator, question, bases, [TestKnowledge.EngineerKb], [], "Backend Engineer");
            InterviewPromptBuilder.BuildSystemPrompt("Target role: Backend Engineer", context, []);
            assembly.Add(timer.Elapsed.TotalMilliseconds);
        }
        static string P(List<double> values) { values.Sort(); return $"median {values[values.Count / 2]:F1} ms, max {values[^1]:F1} ms"; }
        output.WriteLine($"Passages searched: {coordinator.Status.TotalChunks}");
        output.WriteLine($"Query embedding: {P(embedding)}");
        output.WriteLine($"Vector search:   {P(vector)}");
        output.WriteLine($"Keyword search:  {P(keyword)}");
        output.WriteLine($"Fusion+select:   {P(fusion)}");
        output.WriteLine($"Total retrieval: {P(total)}");
        output.WriteLine($"Retrieval + prompt assembly (end to end, before the LLM call): {P(assembly)}");
        Assert.True(total.Max() < 2_000, "local retrieval should stay interactive");
    }
}
