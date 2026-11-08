using System.Diagnostics;
using System.Diagnostics.Tracing;

namespace InterviewAssistant.Rag.Tests;

/// <summary>Counts outgoing HTTP requests and socket connections made by this process while active.</summary>
internal sealed class NetworkWatcher : EventListener, IObserver<DiagnosticListener>, IObserver<KeyValuePair<string, object?>>
{
    private readonly List<IDisposable> _subscriptions = [];
    public int HttpRequests;
    public int SocketConnects;

    public NetworkWatcher() => _subscriptions.Add(DiagnosticListener.AllListeners.Subscribe(this));

    protected override void OnEventSourceCreated(EventSource source)
    {
        if (source.Name is "System.Net.Sockets" or "System.Net.Http") EnableEvents(source, EventLevel.Informational);
    }

    protected override void OnEventWritten(EventWrittenEventArgs data)
    {
        if (data.EventSource.Name == "System.Net.Sockets" && data.EventName == "ConnectStart") Interlocked.Increment(ref SocketConnects);
        if (data.EventSource.Name == "System.Net.Http" && data.EventName == "RequestStart") Interlocked.Increment(ref HttpRequests);
    }

    public void OnNext(DiagnosticListener listener)
    {
        if (listener.Name == "HttpHandlerDiagnosticListener") _subscriptions.Add(listener.Subscribe(this));
    }

    public void OnNext(KeyValuePair<string, object?> value)
    {
        if (value.Key == "System.Net.Http.HttpRequestOut.Start") Interlocked.Increment(ref HttpRequests);
    }

    public void OnCompleted() { }
    public void OnError(Exception error) { }

    public override void Dispose()
    {
        foreach (var subscription in _subscriptions) subscription.Dispose();
        base.Dispose();
    }
}

/// <summary>Runs alone: the network watcher is process-wide, so parallel tests (e.g. the fake LLM request) would be counted.</summary>
[CollectionDefinition("privacy", DisableParallelization = true)]
public sealed class PrivacyCollection;

[Collection("privacy")]
public sealed class PrivacyTests
{
    [Fact]
    public async Task Watcher_detects_network_access()
    {
        using var watcher = new NetworkWatcher();
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        try { await client.GetAsync("http://127.0.0.1:9/"); } catch (Exception) { }
        Assert.True(watcher.HttpRequests + watcher.SocketConnects > 0, "positive control: the watcher must see a request");
    }

    [Fact]
    public async Task Indexing_embedding_and_retrieval_make_no_network_calls()
    {
        ModelLocator.Require();
        using var watcher = new NetworkWatcher();
        using var temp = new TempDirectory();
        using (var coordinator = new KnowledgeIndexCoordinator(temp.Path, [ModelLocator.Directory!]))
        {
            coordinator.RequestSync(TestKnowledge.All);
            await coordinator.WhenIdleAsync();
            var result = await coordinator.RetrieveAsync(QueryContextualizer.Prepare("FastAPI dashboard challenge", [], "", []), TestKnowledge.EngineerOnly, null);
            Assert.Equal(RetrievalMode.Hybrid, result.Mode);
            Assert.NotEmpty(result.Chunks);
        }
        Assert.Equal(0, watcher.HttpRequests);
        Assert.Equal(0, watcher.SocketConnects);
    }
}
