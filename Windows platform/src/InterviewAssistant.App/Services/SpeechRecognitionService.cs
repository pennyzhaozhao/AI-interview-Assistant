using System.Globalization;
using System.IO;
using System.Speech.Recognition;
using NAudio.Wave;

namespace InterviewAssistant.Services;

public sealed class SpeechRecognitionService : IDisposable
{
    private SpeechRecognitionEngine? _engine;
    private DoubaoSpeechRecognitionService? _doubao;
    private bool _isListening;
    private readonly object _lifecycleGate = new();
    private int _startGeneration;

    public bool IsListening => _isListening;
    public event Action<string>? Recognized;
    public event Action<string>? PartialRecognized;
    public event Action<string>? StatusChanged;
    /// <summary>Raised instead of <see cref="Recognized"/> when speaker verification says the candidate is talking.</summary>
    public event Action<string>? CandidateSpeechDetected;

    /// <summary>
    /// When on (live prompter only), final results are checked against the selected voice in
    /// Settings › Voices, and the candidate's own speech is not treated as an interviewer question.
    /// </summary>
    public bool FilterCandidateVoice { get; set; }

    public async Task<bool> StartAsync(string languageCode, bool systemAudio = false)
    {
        int generation;
        lock (_lifecycleGate)
        {
            generation = ++_startGeneration;
            StopCurrent();
        }
        if (AppServices.Current.DataStore.Data.Preferences.SpeechRecognitionEngine == "volcano")
        {
            var doubao = new DoubaoSpeechRecognitionService();
            lock (_lifecycleGate)
            {
                if (generation != _startGeneration) return false;
                _doubao = doubao;
            }
            string? doubaoStatus = null;
            doubao.Recognized += text => Deliver(text, () => doubao.TakeUtteranceAudio());
            doubao.PartialRecognized += text => PartialRecognized?.Invoke(text);
            // Hold connection errors until we know whether the transparent local fallback is needed.
            // Otherwise a transient Doubao timeout covers the prompter even though Windows speech
            // recognition starts successfully a moment later.
            doubao.StatusChanged += text => doubaoStatus = text;
            var started = await doubao.StartAsync(languageCode, systemAudio);
            bool stale;
            lock (_lifecycleGate)
            {
                stale = generation != _startGeneration || !ReferenceEquals(_doubao, doubao);
                if (!stale) _isListening = started;
            }
            if (stale)
            {
                doubao.Dispose();
                return false;
            }
            if (_isListening)
            {
                if (!string.IsNullOrWhiteSpace(doubaoStatus)) StatusChanged?.Invoke(doubaoStatus);
                return true;
            }
            doubao.Dispose();
            lock (_lifecycleGate)
            {
                if (ReferenceEquals(_doubao, doubao)) _doubao = null;
            }
            if (systemAudio)
            {
                if (!string.IsNullOrWhiteSpace(doubaoStatus)) StatusChanged?.Invoke(doubaoStatus);
                return false;
            }
            StatusChanged?.Invoke("Doubao Voice is unavailable; using Windows speech recognition instead.");
        }
        if (systemAudio)
        {
            StatusChanged?.Invoke("System audio recognition requires Doubao Voice. Select it in API settings.");
            return false;
        }
        try
        {
            lock (_lifecycleGate)
            {
                if (generation != _startGeneration) return false;
                var culture = ResolveCulture(languageCode);
                var recognizer = SpeechRecognitionEngine.InstalledRecognizers()
                    .FirstOrDefault(item => string.Equals(item.Culture.Name, culture.Name, StringComparison.OrdinalIgnoreCase))
                    ?? SpeechRecognitionEngine.InstalledRecognizers()
                        .FirstOrDefault(item => string.Equals(item.Culture.TwoLetterISOLanguageName, culture.TwoLetterISOLanguageName, StringComparison.OrdinalIgnoreCase))
                    ?? SpeechRecognitionEngine.InstalledRecognizers().FirstOrDefault();
                if (recognizer is null)
                {
                    StatusChanged?.Invoke("No Windows speech recognition language is installed.");
                    return false;
                }

                _engine = new SpeechRecognitionEngine(recognizer);
                _engine.LoadGrammar(new DictationGrammar());
                _engine.SetInputToDefaultAudioDevice();
                _engine.SpeechRecognized += OnSpeechRecognized;
                _engine.SpeechHypothesized += OnSpeechHypothesized;
                _engine.RecognizeCompleted += OnRecognizeCompleted;
                _engine.RecognizeAsync(RecognizeMode.Multiple);
                _isListening = true;
                StatusChanged?.Invoke($"Listening · {recognizer.Culture.DisplayName}");
                return true;
            }
        }
        catch (Exception exception)
        {
            Stop();
            StatusChanged?.Invoke($"Speech recognition could not start: {exception.Message}");
            return false;
        }
    }

    public void Stop()
    {
        lock (_lifecycleGate)
        {
            _startGeneration++;
            StopCurrent();
        }
    }

    private void StopCurrent()
    {
        var engine = _engine;
        _doubao?.Dispose();
        _doubao = null;
        _engine = null;
        _isListening = false;
        if (engine is null) return;
        try { engine.RecognizeAsyncCancel(); } catch { }
        engine.SpeechRecognized -= OnSpeechRecognized;
        engine.SpeechHypothesized -= OnSpeechHypothesized;
        engine.RecognizeCompleted -= OnRecognizeCompleted;
        engine.Dispose();
        StatusChanged?.Invoke("Microphone stopped");
    }

    private void OnSpeechRecognized(object? sender, SpeechRecognizedEventArgs e)
    {
        var text = e.Result.Text.Trim();
        if (text.Length == 0 || e.Result.Confidence < 0.30) return;
        var audio = e.Result.Audio;
        Deliver(text, () => ReadRecognizedAudio(audio));
    }

    private void OnSpeechHypothesized(object? sender, SpeechHypothesizedEventArgs e)
    {
        var text = e.Result.Text.Trim();
        if (text.Length > 0) PartialRecognized?.Invoke(text);
    }

    private void OnRecognizeCompleted(object? sender, RecognizeCompletedEventArgs e)
    {
        if (e.Error is not null) StatusChanged?.Invoke($"Speech recognition stopped: {e.Error.Message}");
        _isListening = false;
    }

    private void Deliver(string text, Func<float[]> takeAudio)
    {
        if (!FilterCandidateVoice || !SpeakerVerificationService.IsActive)
        {
            if (FilterCandidateVoice) takeAudio();
            Recognized?.Invoke(text);
            return;
        }
        var audio = takeAudio();
        _ = Task.Run(() =>
        {
            var result = SpeakerVerificationService.Classify(audio);
            if (result?.Label == SpeakerLabel.Candidate) CandidateSpeechDetected?.Invoke(text);
            else Recognized?.Invoke(text);
        });
    }

    private static float[] ReadRecognizedAudio(RecognizedAudio? audio)
    {
        if (audio is null) return [];
        try
        {
            using var wav = new MemoryStream();
            audio.WriteToWaveStream(wav);
            wav.Position = 0;
            using var reader = new WaveFileReader(wav);
            var provider = reader.ToSampleProvider();
            if (provider.WaveFormat.Channels > 1) provider = provider.ToMono();
            var rate = provider.WaveFormat.SampleRate;
            var source = new List<float>();
            var buffer = new float[4096];
            int read;
            while ((read = provider.Read(buffer, 0, buffer.Length)) > 0) source.AddRange(buffer.AsSpan(0, read).ToArray());
            if (rate == 16_000) return source.ToArray();
            // Linear resample to 16 kHz.
            var ratio = rate / 16_000d;
            var output = new float[(int)(source.Count / ratio)];
            for (var index = 0; index < output.Length; index++)
            {
                var position = index * ratio;
                var left = (int)position;
                var right = Math.Min(source.Count - 1, left + 1);
                var fraction = (float)(position - left);
                output[index] = source[left] * (1 - fraction) + source[right] * fraction;
            }
            return output;
        }
        catch
        {
            return [];
        }
    }

    private static CultureInfo ResolveCulture(string value)
    {
        if (value.Equals("zh-Hans", StringComparison.OrdinalIgnoreCase) || value.StartsWith("zh", StringComparison.OrdinalIgnoreCase)) return CultureInfo.GetCultureInfo("zh-CN");
        if (value.Equals("en", StringComparison.OrdinalIgnoreCase) || value.StartsWith("en", StringComparison.OrdinalIgnoreCase)) return CultureInfo.GetCultureInfo("en-US");
        return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? CultureInfo.GetCultureInfo("zh-CN") : CultureInfo.GetCultureInfo("en-US");
    }

    public void Dispose() => Stop();
}
