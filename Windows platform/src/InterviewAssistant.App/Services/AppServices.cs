using InterviewAssistant.Rag;

namespace InterviewAssistant.Services;

public sealed class AppServices
{
    private AppServices()
    {
    }

    public static AppServices Current { get; } = new();

    public AppDataStore DataStore { get; } = new();
    public WindowsCredentialStore Credentials { get; } = new();
    public AIService AI { get; } = new();
    /// <summary>Local RAG index (derived data in the data folder); null until the data store is loaded.</summary>
    public KnowledgeIndexCoordinator? KnowledgeIndex => KnowledgeIndexHost.Coordinator;
    public KnowledgeIndexHost KnowledgeIndexHost { get; } = new();

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await DataStore.LoadAsync(cancellationToken);
        KnowledgeIndexHost.Attach(DataStore);
    }
}
