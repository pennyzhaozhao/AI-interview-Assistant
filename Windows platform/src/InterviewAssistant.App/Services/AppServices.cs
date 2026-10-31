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

    public Task InitializeAsync(CancellationToken cancellationToken = default) =>
        DataStore.LoadAsync(cancellationToken);
}
