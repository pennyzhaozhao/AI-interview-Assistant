using InterviewAssistant.Rag;

namespace InterviewAssistant.Rag.Tests;

/// <summary>Finds LocalRAG/model (env INTERVIEW_ASSISTANT_RAG_MODEL_DIR, or the repository's git-ignored folder).</summary>
public static class ModelLocator
{
    public static string? Directory { get; } = Find();

    private static string? Find()
    {
        var configured = Environment.GetEnvironmentVariable("INTERVIEW_ASSISTANT_RAG_MODEL_DIR");
        if (LocalEmbeddingService.FilesExist(configured)) return configured;
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "LocalRAG", "model");
            if (LocalEmbeddingService.FilesExist(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>Skips a test that needs the model when it is not installed (run scripts/fetch-rag-model first).</summary>
    public static string Require()
    {
        if (Directory is null) Assert.Skip("Local embedding model not found. Run scripts/fetch-rag-model.sh (or .ps1) first.");
        return Directory!;
    }
}

/// <summary>One embedding model instance shared by all tests (loading takes ~1 s).</summary>
public sealed class EmbeddingFixture : IDisposable
{
    private readonly Lazy<LocalEmbeddingService?> _service = new(() => ModelLocator.Directory is { } dir ? LocalEmbeddingService.Load(dir) : null);
    public LocalEmbeddingService Service
    {
        get
        {
            ModelLocator.Require();
            return _service.Value!;
        }
    }
    public void Dispose() { if (_service.IsValueCreated) _service.Value?.Dispose(); }
}

[CollectionDefinition("model")]
public sealed class ModelCollection : ICollectionFixture<EmbeddingFixture>;

/// <summary>Temporary folder for an index, deleted afterwards.</summary>
public sealed class TempDirectory : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "rag-tests-" + Guid.NewGuid().ToString("N"));
    public TempDirectory() => System.IO.Directory.CreateDirectory(Path);
    public void Dispose()
    {
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        try { System.IO.Directory.Delete(Path, recursive: true); } catch (IOException) { }
    }
}

/// <summary>
/// Representative knowledge: a software-engineer knowledge base (resume with several projects, project READMEs,
/// prepared interview Q&amp;A, a long technical document) and a separate product-manager knowledge base.
/// </summary>
public static class TestKnowledge
{
    public static readonly Guid EngineerKb = Guid.Parse("11111111-1111-1111-1111-111111111111");
    public static readonly Guid ProductKb = Guid.Parse("22222222-2222-2222-2222-222222222222");
    public static readonly Guid ResumeId = Guid.Parse("a0000000-0000-0000-0000-000000000001");
    public static readonly Guid DashboardId = Guid.Parse("a0000000-0000-0000-0000-000000000002");
    public static readonly Guid TravelId = Guid.Parse("a0000000-0000-0000-0000-000000000003");
    public static readonly Guid SurveyId = Guid.Parse("a0000000-0000-0000-0000-000000000004");
    public static readonly Guid QaId = Guid.Parse("a0000000-0000-0000-0000-000000000005");
    public static readonly Guid DistributedId = Guid.Parse("a0000000-0000-0000-0000-000000000006");
    public static readonly Guid ProductResumeId = Guid.Parse("b0000000-0000-0000-0000-000000000001");

    public const string ResumeSummary = "Backend engineer with 4 years of Python and Go experience; built a FastAPI monitoring dashboard that cut incident detection time by 40%; M.S. Computer Science, University of Washington.";

    public static RagDocument Resume => new(EngineerKb, "Software Engineer", ResumeId, "Resume", RagKinds.Resume, "manual", ResumeSummary, "", """
        # Alex Chen
        ## 工作经历
        **Backend Engineer, Nimbus Cloud (2021.07 – 2025.06)**
        - Built a real-time service monitoring dashboard with FastAPI, WebSocket and Prometheus; incident detection time dropped by 40%.
        - Migrated 30 services to Kubernetes with Helm; deployment time fell from 45 minutes to 8 minutes.
        - Mentored 3 junior engineers and ran the on-call rotation.

        **Software Engineer Intern, UFOS Travel (2020.06 – 2020.09)**
        - Co-developed a travel booking platform with PHP and MySQL; added Redis caching that halved page load time.

        ## 教育背景
        University of Washington, M.S. Computer Science, GPA 3.9 (2019 – 2021)
        Zhejiang University, B.Eng. Software Engineering (2015 – 2019)

        ## 证书
        AWS Certified Solutions Architect – Associate (2022)
        """, true);

    public static RagDocument Dashboard => new(EngineerKb, "Software Engineer", DashboardId, "Monitoring Dashboard", RagKinds.Project, "https://github.com/alex/monitoring-dashboard",
        "Real-time monitoring dashboard built with FastAPI, WebSocket and Prometheus; cut incident detection time by 40%.", "Python · ★ 120", """
        # Monitoring Dashboard
        A real-time service health dashboard. The backend is FastAPI with async endpoints; metrics come from Prometheus and are pushed to the browser over WebSocket.

        ## Architecture
        Services expose metrics; Prometheus scrapes them every 15 seconds. A FastAPI aggregator queries PromQL, caches results in Redis for 5 seconds and pushes deltas to clients.

        ## Biggest technical challenge
        High-cardinality labels (per-user and per-request IDs) made Prometheus memory grow to 30 GB and queries time out. I solved it by dropping unbounded labels at scrape time, adding recording rules that pre-aggregate per service, and sampling traces instead of labelling every request. Memory fell to 6 GB and p95 query latency from 4 s to 300 ms.

        ## Testing
        84 Python test files with pytest; load tests with Locust simulate 2,000 concurrent dashboard sessions.
        """, true);

    public static RagDocument Travel => new(EngineerKb, "Software Engineer", TravelId, "UFOS Travel", RagKinds.Project, "https://ufostravel.com",
        "Co-developed a travel platform using PHP for backend development, MySQL and Redis caching.", "ufostravel.com", """
        UFOS Travel is a booking platform for group tours. I worked on the PHP backend (Laravel), designed the MySQL schema for itineraries and bookings, and added Redis caching for search results, which halved page load time.
        Payments go through Stripe; I wrote the webhook handlers and idempotency keys so duplicate callbacks never double-charge a customer.
        """, true);

    public static RagDocument Survey => new(EngineerKb, "Software Engineer", SurveyId, "Oneroi-Household-Travel-Survey", RagKinds.Project, "https://github.com/alex/oneroi",
        "该 Jupyter Notebook 项目针对出行调查分层数据，以 trips 表为主表做 Left Join，分析居民出行方式。", "Jupyter Notebook", """
        # 出行调查数据分析
        使用 pandas 读取 household、person、trips 三张表，以 trips 表为主表做 Left Join，保证每一次出行都保留。
        清洗了缺失的出行目的和时间字段，按年龄段和收入分组统计出行方式占比，发现公交出行在低收入家庭中占比 41%。
        最后用 matplotlib 画出分时段出行热力图，供城市规划部门参考。
        """, true);

    public static RagDocument InterviewQa => new(EngineerKb, "Software Engineer", QaId, "面经 Q&A", RagKinds.Material, "manual", "", "", """
        Q: 你最大的缺点是什么？
        A: 我有时候太追求细节，会在不重要的地方花太多时间。现在我会先和团队对齐优先级，用时间盒限制打磨的时间。

        Q: 为什么离开上一家公司？
        A: 上一家公司业务调整，监控团队被合并。我希望在可观测性和平台工程方向有更多成长，所以选择看新的机会。

        Q: Tell me about a time you handled a conflict with a teammate.
        A: On the dashboard project a teammate wanted to store every metric label. I proposed we prototype both designs for a day and compare memory usage; the data made the decision easy and we kept the friendship.

        Q: 你期望的薪资是多少？
        A: 我更看重岗位的成长空间，期望在市场水平范围内，具体可以根据整体薪酬结构再沟通。
        """, true);

    public static RagDocument Distributed => new(EngineerKb, "Software Engineer", DistributedId, "Distributed Systems Notes", RagKinds.Material, "file:notes.md", "", "", LongDistributedNotes(), true);

    public static RagDocument ProductResume => new(ProductKb, "Product Manager", ProductResumeId, "PM Resume", RagKinds.Resume, "manual",
        "Product manager for a fintech savings app; ran user research and A/B tests that raised sign-up conversion by 12%.", "", """
        ## Experience
        Product Manager, Pennywise (2022 – 2025): owned onboarding for a fintech savings app. Interviewed 40 users, redesigned the sign-up flow and ran A/B tests; conversion rose 12%.
        """, true);

    public static IReadOnlyList<RagDocument> All => [Resume, Dashboard, Travel, Survey, InterviewQa, Distributed, ProductResume];

    public static IReadOnlySet<Guid> EngineerOnly => new HashSet<Guid> { EngineerKb };
    public static IReadOnlySet<Guid> EnabledIds(IEnumerable<RagDocument> documents) => documents.Where(d => d.IsEnabled).Select(d => d.EntryId).ToHashSet();

    private static string LongDistributedNotes()
    {
        var topics = new (string Heading, string Body)[]
        {
            ("Consistency models", "Linearizability gives the illusion of a single copy; sequential consistency only preserves program order. Eventual consistency lets replicas diverge temporarily and converge when updates stop."),
            ("Consensus", "Raft elects a leader with randomized election timeouts; the leader appends entries and commits once a majority acknowledges. Paxos achieves the same safety with a different structure."),
            ("Message queues", "Kafka partitions a topic for parallelism; ordering holds only within a partition. Consumer groups balance partitions across consumers, and offsets make replay possible."),
            ("Caching", "Cache-aside reads from the cache first and populates it on a miss. Write-through keeps cache and store in sync at the cost of write latency. Stampedes are avoided with request coalescing and jittered TTLs."),
            ("Rate limiting", "Token bucket allows bursts up to the bucket size; leaky bucket smooths output. Distributed rate limiting often uses Redis with Lua scripts for atomic counters."),
            ("Observability", "Metrics, logs and traces answer different questions. RED metrics (rate, errors, duration) suit request-driven services; USE metrics (utilization, saturation, errors) suit resources."),
        };
        var builder = new System.Text.StringBuilder("# Distributed Systems Notes\n\n");
        foreach (var (heading, body) in topics)
        {
            builder.Append("## ").Append(heading).Append("\n\n");
            for (var repeat = 0; repeat < 4; repeat++) builder.Append(body).Append(' ').Append($"(Review note {repeat + 1} on {heading.ToLowerInvariant()}.)").Append("\n\n");
        }
        return builder.ToString();
    }
}
