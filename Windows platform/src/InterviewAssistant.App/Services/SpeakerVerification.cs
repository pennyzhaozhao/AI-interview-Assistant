using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SherpaOnnx;

namespace InterviewAssistant.Services;

// Windows port of the macOS SpeakerVerifier.swift. Same on-device model (3D-Speaker CAM++ via
// sherpa-onnx), same enrollment / scoring maths and thresholds, so a voice behaves the same on
// both platforms. Voiceprints are encrypted with Windows DPAPI instead of the macOS Keychain.

public enum SpeakerLabel { Unknown, Candidate, Interviewer }

public sealed class SpeakerProfile
{
    public float[] Embedding { get; set; } = [];
    public float RmsBaseline { get; set; }
    public float HighThreshold { get; set; } = SpeakerVerificationConstants.DefaultHighThreshold;
    public float LowThreshold { get; set; } = SpeakerVerificationConstants.DefaultLowThreshold;
    public string ModelId { get; set; } = "";
    public string ModelVersion { get; set; } = "";
}

public sealed class StoredSpeakerVoice
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public SpeakerProfile Profile { get; set; } = new();
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
}

public static class SpeakerVerificationConstants
{
    public const float EmbeddingWeight = 0.60f;
    public const float RmsWeight = 0.25f;
    public const float AnswerOverlapWeight = 0.15f;
    public const double MinimumEmbeddingDuration = 1.2;
    public const float DefaultHighThreshold = 0.72f;
    public const float DefaultLowThreshold = 0.48f;
    public const int SampleRate = 16_000;
}

public sealed class SpeakerVerifierException(string key) : Exception(LocalizationManager.Text(key));

// ───────────────────────── model ─────────────────────────

public static class SpeakerModelManager
{
    public const string ModelId = "3dspeaker-campplus-zh-cn-16k-common";
    public const string ExpectedSha256 = "f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11";
    public const string ModelVersion = "sha256:" + ExpectedSha256;
    private const string FileName = "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx";
    private static readonly Uri DownloadUri = new("https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx");

    public static string ModelPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "InterviewAssistant", "SpeakerModels", FileName);

    public static bool IsDownloaded => File.Exists(ModelPath);

    /// <summary>Downloads and SHA-256 verifies the model. Progress is 0…1 (or -1 when the size is unknown).</summary>
    public static async Task DownloadAsync(IProgress<double>? progress, CancellationToken cancellationToken = default)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("InterviewAssistant");
        using var response = await client.GetAsync(DownloadUri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength ?? -1;
        var directory = Path.GetDirectoryName(ModelPath)!;
        Directory.CreateDirectory(directory);
        var temporary = ModelPath + ".download";

        using (var sha = SHA256.Create())
        {
            await using (var source = await response.Content.ReadAsStreamAsync(cancellationToken))
            await using (var target = File.Create(temporary))
            {
                var buffer = new byte[81920];
                long received = 0;
                int read;
                while ((read = await source.ReadAsync(buffer, cancellationToken)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                    sha.TransformBlock(buffer, 0, read, null, 0);
                    received += read;
                    progress?.Report(total > 0 ? (double)received / total : -1);
                }
            }
            sha.TransformFinalBlock([], 0, 0);
            var digest = Convert.ToHexString(sha.Hash!).ToLowerInvariant();
            if (digest != ExpectedSha256)
            {
                File.Delete(temporary);
                throw new SpeakerVerifierException("The downloaded speaker model failed verification");
            }
        }
        File.Move(temporary, ModelPath, overwrite: true);
    }
}

// ───────────────────────── embeddings + scoring ─────────────────────────

public sealed class SpeakerEmbeddingEngine : IDisposable
{
    private readonly SpeakerEmbeddingExtractor _extractor;
    private readonly object _gate = new();

    public SpeakerEmbeddingEngine()
    {
        if (!SpeakerModelManager.IsDownloaded) throw new SpeakerVerifierException("Download the speaker model first");
        var config = new SpeakerEmbeddingExtractorConfig { Model = SpeakerModelManager.ModelPath, NumThreads = 1, Debug = 0, Provider = "cpu" };
        _extractor = new SpeakerEmbeddingExtractor(config);
    }

    public float[] Embedding(float[] samples16kMono)
    {
        if (samples16kMono.Length < 8_000) throw new SpeakerVerifierException("The voice sample was too short or unclear");
        lock (_gate)
        {
            using var stream = _extractor.CreateStream();
            stream.AcceptWaveform(SpeakerVerificationConstants.SampleRate, samples16kMono);
            stream.InputFinished();
            var result = _extractor.Compute(stream);
            if (result.Length == 0) throw new SpeakerVerifierException("The voice sample was too short or unclear");
            return SpeakerMath.Normalized(result);
        }
    }

    public void Dispose() => _extractor.Dispose();
}

public static class SpeakerMath
{
    public static SpeakerProfile Enroll(SpeakerEmbeddingEngine engine, IReadOnlyList<float[]> segments, float meanRms)
    {
        if (segments.Count < 3) throw new SpeakerVerifierException("Record at least three voice samples");
        var vectors = segments.Select(engine.Embedding).ToList();
        var dimension = vectors[0].Length;
        if (dimension == 0 || vectors.Any(vector => vector.Length != dimension)) throw new SpeakerVerifierException("The voice sample was too short or unclear");
        var centroid = new float[dimension];
        foreach (var vector in vectors)
            for (var index = 0; index < dimension; index++) centroid[index] += vector[index];
        for (var index = 0; index < dimension; index++) centroid[index] /= vectors.Count;
        return new SpeakerProfile
        {
            Embedding = Normalized(centroid),
            RmsBaseline = meanRms,
            HighThreshold = SpeakerVerificationConstants.DefaultHighThreshold,
            LowThreshold = SpeakerVerificationConstants.DefaultLowThreshold,
            ModelId = SpeakerModelManager.ModelId,
            ModelVersion = SpeakerModelManager.ModelVersion
        };
    }

    public static (SpeakerLabel Label, float Score) Classify(SpeakerEmbeddingEngine engine, SpeakerProfile profile, float[] samples, float meanRms, double sensitivity, float answerOverlap = 0)
    {
        var duration = samples.Length / (double)SpeakerVerificationConstants.SampleRate;
        var rmsCloseness = RmsCloseness(meanRms, profile.RmsBaseline);
        if (duration < SpeakerVerificationConstants.MinimumEmbeddingDuration)
            return (SpeakerLabel.Unknown, 0.625f * rmsCloseness + 0.375f * Math.Clamp(answerOverlap, 0, 1));

        var similarity = CosineSimilarity(engine.Embedding(samples), profile.Embedding);
        var fused = SpeakerVerificationConstants.EmbeddingWeight * Math.Clamp(similarity, -1, 1)
                    + SpeakerVerificationConstants.RmsWeight * Math.Clamp(rmsCloseness, 0, 1)
                    + SpeakerVerificationConstants.AnswerOverlapWeight * Math.Clamp(answerOverlap, 0, 1);
        var adjustment = (float)((0.5 - Math.Clamp(sensitivity, 0, 1)) * 0.20);
        var high = profile.HighThreshold + adjustment;
        var low = profile.LowThreshold + adjustment;
        var label = fused >= high ? SpeakerLabel.Candidate : fused <= low ? SpeakerLabel.Interviewer : SpeakerLabel.Unknown;
        return (label, fused);
    }

    public static float Rms(float[] samples) =>
        samples.Length == 0 ? 0 : (float)Math.Sqrt(samples.Sum(sample => (double)sample * sample) / samples.Length) * short.MaxValue;

    public static float RmsCloseness(float value, float baseline)
    {
        if (value <= 0 || baseline <= 0) return 0;
        var ratio = Math.Max(value, baseline) / Math.Min(value, baseline);
        return (float)Math.Max(0, 1 - Math.Log(ratio) / Math.Log(4));
    }

    public static float CosineSimilarity(float[] left, float[] right)
    {
        if (left.Length == 0 || left.Length != right.Length) throw new SpeakerVerifierException("The voice sample was too short or unclear");
        double dot = 0, leftNorm = 0, rightNorm = 0;
        for (var index = 0; index < left.Length; index++)
        {
            dot += left[index] * right[index];
            leftNorm += left[index] * left[index];
            rightNorm += right[index] * right[index];
        }
        if (leftNorm <= 0 || rightNorm <= 0) throw new SpeakerVerifierException("The voice sample was too short or unclear");
        return (float)(dot / (Math.Sqrt(leftNorm) * Math.Sqrt(rightNorm)));
    }

    public static float[] Normalized(float[] vector)
    {
        var norm = Math.Sqrt(vector.Sum(value => (double)value * value));
        return norm <= 0 ? vector : vector.Select(value => (float)(value / norm)).ToArray();
    }

    /// <summary>Drops leading / trailing near-silence so scores reflect actual speech.</summary>
    public static float[] TrimSilence(float[] samples, float threshold = 0.012f)
    {
        const int frame = 320; // 20 ms
        int start = 0, end = samples.Length;
        while (start + frame <= end && FrameRms(samples, start, frame) < threshold) start += frame;
        while (end - frame >= start && FrameRms(samples, end - frame, frame) < threshold) end -= frame;
        return end - start >= 8_000 ? samples[start..end] : samples;
    }

    private static double FrameRms(float[] samples, int offset, int length)
    {
        double sum = 0;
        for (var index = offset; index < offset + length; index++) sum += samples[index] * samples[index];
        return Math.Sqrt(sum / length);
    }
}

// ───────────────────────── encrypted profile store ─────────────────────────

public static class SpeakerProfileStore
{
    private sealed class Collection
    {
        public List<StoredSpeakerVoice> Voices { get; set; } = [];
        public Guid? SelectedId { get; set; }
    }

    private static readonly object Gate = new();
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("InterviewAssistant.SpeakerProfiles.v1");
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = false };

    public static event Action? Changed;

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "InterviewAssistant", "voiceprints.dat");

    public static IReadOnlyList<StoredSpeakerVoice> Voices() => Load().Voices.OrderBy(voice => voice.CreatedAt).ToList();

    public static StoredSpeakerVoice? SelectedVoice()
    {
        var collection = Load();
        return collection.SelectedId is Guid id ? collection.Voices.FirstOrDefault(voice => voice.Id == id) : null;
    }

    public static StoredSpeakerVoice Add(SpeakerProfile profile, string name)
    {
        lock (Gate)
        {
            var collection = Load();
            var voice = new StoredSpeakerVoice { Name = NormalizedName(name, collection.Voices.Count + 1), Profile = profile };
            collection.Voices.Add(voice);
            collection.SelectedId = voice.Id;
            Persist(collection);
            return voice;
        }
    }

    public static void Select(Guid? id) => Mutate(collection =>
    {
        if (id is not null && collection.Voices.All(voice => voice.Id != id)) return;
        collection.SelectedId = id;
    });

    public static void Rename(Guid id, string name) => Mutate(collection =>
    {
        var index = collection.Voices.FindIndex(voice => voice.Id == id);
        if (index >= 0) collection.Voices[index].Name = NormalizedName(name, index + 1);
    });

    public static void Delete(Guid id) => Mutate(collection =>
    {
        collection.Voices.RemoveAll(voice => voice.Id == id);
        if (collection.SelectedId == id) collection.SelectedId = null;
    });

    private static void Mutate(Action<Collection> change)
    {
        lock (Gate)
        {
            var collection = Load();
            change(collection);
            Persist(collection);
        }
    }

    private static Collection Load()
    {
        lock (Gate)
        {
            try
            {
                if (!File.Exists(FilePath)) return new Collection();
                var json = ProtectedData.Unprotect(File.ReadAllBytes(FilePath), Entropy, DataProtectionScope.CurrentUser);
                return JsonSerializer.Deserialize<Collection>(json, JsonOptions) ?? new Collection();
            }
            catch
            {
                return new Collection();
            }
        }
    }

    private static void Persist(Collection collection)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var encrypted = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(collection, JsonOptions), Entropy, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(FilePath, encrypted);
        SpeakerVerificationService.Reset();
        Changed?.Invoke();
    }

    private static string NormalizedName(string name, int fallbackIndex)
    {
        var trimmed = name.Trim();
        return trimmed.Length == 0 ? $"{LocalizationManager.Text("Voice")} {fallbackIndex}" : trimmed;
    }
}

// ───────────────────────── live interview service ─────────────────────────

public static class SpeakerVerificationService
{
    private static readonly object Gate = new();
    private static SpeakerEmbeddingEngine? _engine;

    /// <summary>True when a voice is selected and the model is present, i.e. recognition is on.</summary>
    public static bool IsActive
    {
        get
        {
            var voice = SpeakerProfileStore.SelectedVoice();
            return voice is not null
                && SpeakerModelManager.IsDownloaded
                && voice.Profile.ModelId == SpeakerModelManager.ModelId
                && voice.Profile.ModelVersion == SpeakerModelManager.ModelVersion;
        }
    }

    /// <summary>Classifies one utterance (16 kHz mono). Returns null when recognition is off or fails.</summary>
    public static (SpeakerLabel Label, float Score)? Classify(float[] samples16kMono)
    {
        try
        {
            var voice = SpeakerProfileStore.SelectedVoice();
            if (voice is null || !IsActive || samples16kMono.Length == 0) return null;
            var speech = SpeakerMath.TrimSilence(samples16kMono);
            var sensitivity = AppServices.Current.DataStore.Data.Preferences.SpeakerRecognitionSensitivity;
            lock (Gate)
            {
                _engine ??= new SpeakerEmbeddingEngine();
                return SpeakerMath.Classify(_engine, voice.Profile, speech, SpeakerMath.Rms(speech), sensitivity);
            }
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"[SpeakerVerifier] classification failed: {exception.Message}");
            return null;
        }
    }

    public static void Reset()
    {
        lock (Gate)
        {
            _engine?.Dispose();
            _engine = null;
        }
    }
}
