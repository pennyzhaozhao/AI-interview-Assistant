using System.Globalization;
using System.Speech.Recognition;

namespace InterviewAssistant.Services;

public sealed class SpeechRecognitionService : IDisposable
{
    private SpeechRecognitionEngine? _engine;
    private DoubaoSpeechRecognitionService? _doubao;
    private bool _isListening;

    public bool IsListening => _isListening;
    public event Action<string>? Recognized;
    public event Action<string>? PartialRecognized;
    public event Action<string>? StatusChanged;

    public async Task<bool> StartAsync(string languageCode, bool systemAudio = false)
    {
        Stop();
        if (AppServices.Current.DataStore.Data.Preferences.SpeechRecognitionEngine == "volcano")
        {
            _doubao = new DoubaoSpeechRecognitionService();
            _doubao.Recognized += text => Recognized?.Invoke(text);
            _doubao.PartialRecognized += text => PartialRecognized?.Invoke(text);
            _doubao.StatusChanged += text => StatusChanged?.Invoke(text);
            _isListening = await _doubao.StartAsync(languageCode, systemAudio);
            return _isListening;
        }
        if (systemAudio)
        {
            StatusChanged?.Invoke("System audio recognition requires Doubao Voice. Select it in API settings.");
            return false;
        }
        try
        {
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
        catch (Exception exception)
        {
            Stop();
            StatusChanged?.Invoke($"Speech recognition could not start: {exception.Message}");
            return false;
        }
    }

    public void Stop()
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
        if (text.Length > 0 && e.Result.Confidence >= 0.30) Recognized?.Invoke(text);
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

    private static CultureInfo ResolveCulture(string value)
    {
        if (value.Equals("zh-Hans", StringComparison.OrdinalIgnoreCase) || value.StartsWith("zh", StringComparison.OrdinalIgnoreCase)) return CultureInfo.GetCultureInfo("zh-CN");
        if (value.Equals("en", StringComparison.OrdinalIgnoreCase) || value.StartsWith("en", StringComparison.OrdinalIgnoreCase)) return CultureInfo.GetCultureInfo("en-US");
        return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? CultureInfo.GetCultureInfo("zh-CN") : CultureInfo.GetCultureInfo("en-US");
    }

    public void Dispose() => Stop();
}
