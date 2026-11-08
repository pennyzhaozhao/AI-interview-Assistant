using System.IO;
using System.Windows.Threading;
using InterviewAssistant.Models;
using InterviewAssistant.Rag;

namespace InterviewAssistant.Services;

/// <summary>
/// Connects the local RAG index to the app's data: creates it in the data folder, re-syncs it (debounced) after
/// knowledge-base changes, and recreates it when the storage folder changes. The knowledge-base JSON stays the
/// single source of truth; the index only reads snapshots of it.
/// </summary>
public sealed class KnowledgeIndexHost
{
    private AppDataStore? _store;
    private DispatcherTimer? _debounce;
    private string _lastFingerprint = "";

    public KnowledgeIndexCoordinator? Coordinator { get; private set; }
    public event Action<RagIndexStatus>? StatusChanged;

    /// <summary>Folders searched for model_quantized.onnx + tokenizer.json (bundled with the app first).</summary>
    public static IReadOnlyList<string> ModelDirectories(string dataDirectory) =>
    [
        Environment.GetEnvironmentVariable("INTERVIEW_ASSISTANT_RAG_MODEL_DIR") ?? "",
        Path.Combine(AppContext.BaseDirectory, "LocalRAG", "model"),
        Path.Combine(dataDirectory, "LocalRAG", "model")
    ];

    public void Attach(AppDataStore store)
    {
        _store = store;
        _debounce = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(1200) };
        _debounce.Tick += (_, _) => { _debounce.Stop(); SyncNow(); };
        store.Changed += () => { _debounce.Stop(); _debounce.Start(); };
        store.DataReset += Recreate;
        Recreate();
    }

    private void Recreate()
    {
        if (_store is null) return;
        var previous = Coordinator;
        if (previous is not null) previous.StatusChanged -= OnStatusChanged;
        var coordinator = new KnowledgeIndexCoordinator(Path.Combine(_store.DataDirectory, "LocalRAG"), ModelDirectories(_store.DataDirectory));
        coordinator.StatusChanged += OnStatusChanged;
        Coordinator = coordinator;
        _lastFingerprint = "";
        if (previous is not null) Task.Run(previous.Dispose);
        _ = coordinator.StartAsync();
        SyncNow();
    }

    private void OnStatusChanged(RagIndexStatus status) => StatusChanged?.Invoke(status);

    /// <summary>Snapshots the knowledge bases (on the UI thread) and queues an incremental sync when anything relevant changed.</summary>
    public void SyncNow(bool rebuild = false)
    {
        if (_store is null || Coordinator is null) return;
        var bases = _store.Data.KnowledgeBases;
        var fingerprint = Fingerprint(bases);
        if (!rebuild && fingerprint == _lastFingerprint) return;
        _lastFingerprint = fingerprint;
        var snapshot = KnowledgeContextFormatter.ToRagDocuments(bases);
        if (rebuild) Coordinator.RequestRebuild(snapshot); else Coordinator.RequestSync(snapshot);
    }

    /// <summary>Cheap change detector: the index itself compares full content hashes.</summary>
    private static string Fingerprint(IEnumerable<KnowledgeBaseModel> bases)
    {
        var hash = new HashCode();
        foreach (var kb in bases)
        {
            hash.Add(kb.Id);
            hash.Add(kb.Name);
            foreach (var entry in kb.Entries)
            {
                hash.Add(entry.Id);
                hash.Add(entry.UpdatedAt);
                hash.Add(entry.Title);
                hash.Add(entry.Content?.Length ?? 0);
                hash.Add(entry.Content?.GetHashCode() ?? 0);
                hash.Add(entry.Summary?.GetHashCode() ?? 0);
                hash.Add(entry.Kind);
            }
        }
        return hash.ToHashCode().ToString();
    }
}
