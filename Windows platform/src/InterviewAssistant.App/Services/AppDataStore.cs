using System.IO;
using System.Text.Json;
using InterviewAssistant.Models;

namespace InterviewAssistant.Services;

public sealed class AppDataStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    private readonly SemaphoreSlim _saveLock = new(1, 1);
    private readonly object _scheduleLock = new();
    private CancellationTokenSource? _scheduledSave;

    public AppDataStore()
    {
        var defaultRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "InterviewAssistant");
        StoragePointerPath = Path.Combine(defaultRoot, "storage-location.txt");
        var configuredDirectory = File.Exists(StoragePointerPath) ? File.ReadAllText(StoragePointerPath).Trim() : "";
        DataDirectory = Directory.Exists(configuredDirectory) ? configuredDirectory : Path.Combine(defaultRoot, "Data");
        DataPath = Path.Combine(DataDirectory, "interview-assistant.json");
    }

    private string StoragePointerPath { get; }
    public string DataDirectory { get; private set; }
    public string DataPath { get; private set; }
    public AppData Data { get; private set; } = new();
    public event Action? Changed;
    public event Action? DataReset;

    public void NotifyDataReset()
    {
        Changed?.Invoke();
        DataReset?.Invoke();
    }

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(DataDirectory);

        if (File.Exists(DataPath))
        {
            try
            {
                await using var stream = File.OpenRead(DataPath);
                Data = await JsonSerializer.DeserializeAsync<AppData>(stream, JsonOptions, cancellationToken) ?? new AppData();
            }
            catch (JsonException)
            {
                var backup = Path.Combine(DataDirectory, $"interview-assistant.invalid-{DateTime.Now:yyyyMMdd-HHmmss}.json");
                File.Copy(DataPath, backup, overwrite: false);
                Data = new AppData();
            }
        }

        EnsureDefaults();
        await SaveAsync(cancellationToken);
    }

    public ProviderSettings GetProviderSettings(AIProvider provider)
    {
        var key = provider.ToString();
        if (!Data.ProviderSettings.TryGetValue(key, out var settings))
        {
            var definition = ProviderCatalog.Get(provider);
            settings = new ProviderSettings { ApiUrl = definition.DefaultUrl, Model = definition.DefaultModel };
            Data.ProviderSettings[key] = settings;
        }

        return settings;
    }

    public InterviewSessionModel CreateFormalSession()
    {
        var draft = Data.Workspace;
        var title = string.IsNullOrWhiteSpace(draft.Role)
            ? $"Interview {DateTime.Now:g}"
            : draft.Role.Trim();

        var session = new InterviewSessionModel
        {
            Title = title,
            Role = draft.Role,
            Context = draft.JobDescription,
            ActiveKnowledgeBaseIds = draft.ActiveKnowledgeBaseIds.ToList(),
            Kind = "formal"
        };
        Data.Sessions.Insert(0, session);
        ScheduleSave();
        return session;
    }

    public void ScheduleSave(TimeSpan? delay = null)
    {
        Changed?.Invoke();
        lock (_scheduleLock)
        {
            _scheduledSave?.Cancel();
            _scheduledSave?.Dispose();
            _scheduledSave = new CancellationTokenSource();
            var token = _scheduledSave.Token;
            _ = Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(delay ?? TimeSpan.FromMilliseconds(350), token);
                    await SaveAsync(token);
                }
                catch (OperationCanceledException)
                {
                }
            }, token);
        }
    }

    public async Task SaveAsync(CancellationToken cancellationToken = default)
    {
        await _saveLock.WaitAsync(cancellationToken);
        try
        {
            Directory.CreateDirectory(DataDirectory);
            var temporaryPath = DataPath + ".tmp";
            await using (var stream = File.Create(temporaryPath))
            {
                await JsonSerializer.SerializeAsync(stream, Data, JsonOptions, cancellationToken);
            }

            File.Move(temporaryPath, DataPath, overwrite: true);
        }
        finally
        {
            _saveLock.Release();
        }
    }

    public async Task ChangeDataDirectoryAsync(string directory, CancellationToken cancellationToken = default)
    {
        var target = Path.GetFullPath(directory);
        if (string.Equals(target.TrimEnd(Path.DirectorySeparatorChar), DataDirectory.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)) return;
        Directory.CreateDirectory(target);
        await SaveAsync(cancellationToken);
        var newDataPath = Path.Combine(target, "interview-assistant.json");
        File.Copy(DataPath, newDataPath, overwrite: true);
        Directory.CreateDirectory(Path.GetDirectoryName(StoragePointerPath)!);
        await File.WriteAllTextAsync(StoragePointerPath, target, cancellationToken);
        DataDirectory = target;
        DataPath = newDataPath;
        Changed?.Invoke();
    }

    private void EnsureDefaults()
    {
        foreach (var provider in ProviderCatalog.All)
        {
            _ = GetProviderSettings(provider.Provider);
        }

        Data.Workspace.ActiveKnowledgeBaseIds.RemoveWhere(id => Data.KnowledgeBases.All(item => item.Id != id));
    }
}
