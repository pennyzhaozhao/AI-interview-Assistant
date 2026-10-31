using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using InterviewAssistant.Infrastructure;
using InterviewAssistant.Services;
using NAudio.Wave;

namespace InterviewAssistant.Windows;

/// <summary>
/// "Add a Voice" sheet, ported from the macOS VoiceEnrollmentSheet: name the voice, download the
/// on-device speaker model once, read a passage for 15 seconds, then a voiceprint is enrolled.
/// </summary>
public sealed class VoiceEnrollmentWindow : Window
{
    private const double RecordSeconds = 15;

    private readonly TextBlock _title = new() { FontSize = 26, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.NoWrap };
    private readonly TextBlock _subtitle = new() { FontSize = 15, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 500, Margin = new Thickness(0, 10, 0, 0) };
    private readonly Grid _mark = new() { Width = 180, Height = 180, Margin = new Thickness(0, 18, 0, 10) };
    private readonly TextBlock _markIcon = new() { FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 40, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _setup = new() { HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBox _name = new() { Width = 360 };
    private readonly ProgressBar _progress = new() { Width = 420, Height = 8, Minimum = 0, Maximum = 1, Margin = new Thickness(0, 18, 0, 0) };
    private readonly TextBlock _error = new() { FontSize = 12.5, Foreground = new SolidColorBrush(Color.FromRgb(0xDC, 0x3B, 0x3B)), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 480, Margin = new Thickness(0, 10, 0, 0) };
    private readonly Button _action = new() { Margin = new Thickness(0, 18, 0, 0), HorizontalAlignment = HorizontalAlignment.Center, MinWidth = 220 };
    private readonly TextBlock _actionText = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly ActivitySpinner _actionSpinner = new() { Width = 16, Height = 16, SpokeThickness = 1.8, SpokeBrush = Brushes.White, Margin = new Thickness(0, 0, 9, 0), Visibility = Visibility.Collapsed };
    private readonly TextBlock _status = new() { FontSize = 12.5, FontWeight = FontWeights.Medium, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 520, Margin = new Thickness(0, 14, 0, 0) };
    private readonly DispatcherTimer _progressTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private readonly List<float> _samples = [];
    private WaveInEvent? _recorder;
    private DateTime _recordStarted;
    private bool _busy;
    private bool _complete;

    public VoiceEnrollmentWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        Width = 640;
        Height = 760;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = new FontFamily("Segoe UI Variable Text, SimSun, Segoe UI");
        SetResourceReference(ForegroundProperty, "TextPrimaryBrush");
        _subtitle.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        _status.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        _name.SetResourceReference(StyleProperty, "InputStyle");
        _action.SetResourceReference(StyleProperty, "PrimaryButtonStyle");
        _action.Content = new StackPanel { Orientation = Orientation.Horizontal, Children = { _actionSpinner, _actionText } };
        _action.Click += Action_Click;
        _progress.Template = ProgressTemplate();
        _progressTimer.Tick += ProgressTimer_Tick;

        var close = new Button { Width = 36, Height = 36, Cursor = Cursors.Hand, HorizontalAlignment = HorizontalAlignment.Left, ToolTip = LocalizationManager.Text("Close") };
        close.Template = CircleButtonTemplate();
        close.Content = new TextBlock { Text = "", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 13, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        close.Click += (_, _) => Close();

        BuildVoiceMark();
        BuildSetup();

        var body = new StackPanel { Margin = new Thickness(34, 0, 34, 30) };
        body.Children.Add(_title);
        body.Children.Add(_subtitle);
        body.Children.Add(new Border { Child = _mark, HorizontalAlignment = HorizontalAlignment.Center });
        body.Children.Add(_setup);
        body.Children.Add(_status);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Border { Padding = new Thickness(18), Child = close, Background = Brushes.Transparent };
        header.MouseLeftButtonDown += (_, e) => { if (e.ChangedButton == MouseButton.Left) DragMove(); };
        root.Children.Add(header);
        var scroller = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroller, 1);
        root.Children.Add(scroller);

        var card = new Border { CornerRadius = new CornerRadius(24), BorderThickness = new Thickness(1), Child = root, ClipToBounds = true };
        card.SetResourceReference(Border.BackgroundProperty, "BackgroundBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "BorderBrush");
        Content = card;

        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        Closed += (_, _) => StopRecorder();
        Refresh();
    }

    /// <summary>The voice that was added, when enrollment completed.</summary>
    public StoredSpeakerVoice? AddedVoice { get; private set; }

    private static bool Chinese => LocalizationManager.Instance.IsChinese;

    private void BuildVoiceMark()
    {
        for (var index = 3; index >= 0; index--)
        {
            var ring = new Ellipse { Width = 84 + index * 25, Height = 84 + index * 25, StrokeThickness = 3, Tag = index };
            _mark.Children.Add(ring);
        }
        _mark.Children.Add(_markIcon);
    }

    private void BuildSetup()
    {
        var nameLabel = new TextBlock { Text = LocalizationManager.Text("Voice Name"), FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(4, 0, 0, 7) };
        nameLabel.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        _setup.Children.Add(new StackPanel { Width = 360, Children = { nameLabel, _name } });

        var passageTitle = new TextBlock { Text = LocalizationManager.Text("Read this passage for about 15 seconds using the same microphone and room you will use for interviews."), FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        var passage = new TextBlock
        {
            Text = Chinese
                ? "我正在为面试助手注册自己的声音。清晰的表达来自充分准备，也来自对经历的真实总结。我会保持自然语速，使用平时面试时的音量，完整读完这段文字。"
                : "I am registering my voice with InterviewAssistant. Clear answers come from careful preparation and an honest account of my experience. I will use my normal interview pace and volume while reading this passage to the end.",
            FontSize = 14,
            LineHeight = 22,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 10, 0, 0)
        };
        passage.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        var passageCard = new Border { CornerRadius = new CornerRadius(16), Padding = new Thickness(16), BorderThickness = new Thickness(1), MaxWidth = 520, Margin = new Thickness(0, 18, 0, 0), Child = new StackPanel { Children = { passageTitle, passage } } };
        passageCard.SetResourceReference(Border.BackgroundProperty, "SurfaceBrush");
        passageCard.SetResourceReference(Border.BorderBrushProperty, "BorderBrush");
        _setup.Children.Add(passageCard);
        _setup.Children.Add(_progress);
        _setup.Children.Add(_error);
        _setup.Children.Add(_action);
    }

    private void Refresh()
    {
        _title.Text = LocalizationManager.Text(_complete ? "Voice Added" : "Add a Voice");
        _subtitle.Text = LocalizationManager.Text(_complete
            ? "This voice is now selected for speaker recognition."
            : "Speak naturally using the microphone and room you normally use for interviews.");
        var accent = (Brush)FindResource(_complete ? "SuccessBrush" : "PrimaryBrush");
        var color = accent is SolidColorBrush solid ? solid.Color : Colors.DodgerBlue;
        foreach (var ring in _mark.Children.OfType<Ellipse>())
        {
            var index = (int)ring.Tag;
            var opacity = _complete ? 0.8 - index * 0.13 : 0.7 - index * 0.12;
            ring.Stroke = new SolidColorBrush(Color.FromArgb((byte)(Math.Clamp(opacity, 0, 1) * 255), color.R, color.G, color.B));
        }
        _markIcon.Text = _complete ? "" : "";
        _markIcon.Foreground = accent;
        _error.Visibility = string.IsNullOrEmpty(_error.Text) ? Visibility.Collapsed : Visibility.Visible;

        if (_complete)
        {
            _setup.Children.Clear();
            _action.IsEnabled = true;
            _actionSpinner.Visibility = Visibility.Collapsed;
            _actionText.Text = LocalizationManager.Text("Done");
            _setup.Children.Add(_action);
            return;
        }
        _actionSpinner.Visibility = _busy ? Visibility.Visible : Visibility.Collapsed;
        _action.IsEnabled = !_busy;
        if (!SpeakerModelManager.IsDownloaded)
            _actionText.Text = LocalizationManager.Text(_busy ? "Downloading..." : "Download Speaker Model (28.3 MB)");
        else if (_recorder is not null)
            _actionText.Text = LocalizationManager.Text("Recording...");
        else
            _actionText.Text = LocalizationManager.Text(_busy ? "Processing…" : "Start Voice Setup");
    }

    private async void Action_Click(object sender, RoutedEventArgs e)
    {
        if (_complete) { Close(); return; }
        if (_busy || _recorder is not null) return;
        _error.Text = "";
        if (!SpeakerModelManager.IsDownloaded) await DownloadModelAsync();
        else StartRecording();
    }

    private async Task DownloadModelAsync()
    {
        _busy = true;
        _status.Text = LocalizationManager.Text("Downloading the on-device speaker model...");
        Refresh();
        try
        {
            var progress = new Progress<double>(value =>
            {
                if (value < 0) return;
                _progress.Value = value;
                _actionText.Text = $"{LocalizationManager.Text("Downloading...")} {value:P0}";
            });
            await SpeakerModelManager.DownloadAsync(progress);
            _status.Text = LocalizationManager.Text("Speaker model downloaded and verified");
        }
        catch (Exception exception)
        {
            _error.Text = exception.Message;
            _status.Text = "";
        }
        _progress.Value = 0;
        _busy = false;
        Refresh();
    }

    private void StartRecording()
    {
        try
        {
            if (WaveInEvent.DeviceCount == 0) throw new InvalidOperationException(Chinese ? "没有可用的麦克风输入设备。" : "No microphone input device is available.");
            _samples.Clear();
            _recorder = new WaveInEvent { WaveFormat = new WaveFormat(SpeakerVerificationConstants.SampleRate, 16, 1), BufferMilliseconds = 100 };
            _recorder.DataAvailable += (_, args) =>
            {
                lock (_samples)
                    for (var offset = 0; offset + 1 < args.BytesRecorded; offset += 2)
                        _samples.Add(BitConverter.ToInt16(args.Buffer, offset) / 32768f);
            };
            _recorder.StartRecording();
            _recordStarted = DateTime.UtcNow;
            _progressTimer.Start();
            _status.Text = LocalizationManager.Text("Keep speaking naturally until recording finishes.");
            PulseIcon(true);
        }
        catch (Exception exception)
        {
            StopRecorder();
            _error.Text = exception.Message;
        }
        Refresh();
    }

    private async void ProgressTimer_Tick(object? sender, EventArgs e)
    {
        var elapsed = (DateTime.UtcNow - _recordStarted).TotalSeconds;
        _progress.Value = Math.Min(1, elapsed / RecordSeconds);
        if (elapsed < RecordSeconds) return;
        StopRecorder();
        float[] samples;
        lock (_samples) samples = _samples.ToArray();
        await ProcessEnrollmentAsync(samples);
    }

    private async Task ProcessEnrollmentAsync(float[] samples)
    {
        _busy = true;
        Refresh();
        var name = _name.Text;
        try
        {
            var profile = await Task.Run(() =>
            {
                var segmentLength = samples.Length / 4;
                if (segmentLength < 16_000) throw new SpeakerVerifierException("The voice sample was too short or unclear");
                var segments = Enumerable.Range(0, 4)
                    .Select(index => index == 3 ? samples[(index * segmentLength)..] : samples[(index * segmentLength)..((index + 1) * segmentLength)])
                    .ToList();
                using var engine = new SpeakerEmbeddingEngine();
                return SpeakerMath.Enroll(engine, segments, SpeakerMath.Rms(samples));
            });
            AddedVoice = SpeakerProfileStore.Add(profile, name);
            _status.Text = LocalizationManager.Text("Voice setup is complete.");
            _complete = true;
        }
        catch (Exception exception)
        {
            _error.Text = exception.Message;
            _status.Text = "";
        }
        _progress.Value = 0;
        _busy = false;
        Refresh();
    }

    private void StopRecorder()
    {
        _progressTimer.Stop();
        PulseIcon(false);
        var recorder = _recorder;
        _recorder = null;
        if (recorder is null) return;
        try { recorder.StopRecording(); } catch { }
        recorder.Dispose();
    }

    private void PulseIcon(bool on)
    {
        if (!on) { _markIcon.BeginAnimation(OpacityProperty, null); _markIcon.Opacity = 1; return; }
        _markIcon.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.35, TimeSpan.FromMilliseconds(650)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
    }

    private static ControlTemplate ProgressTemplate()
    {
        var root = new FrameworkElementFactory(typeof(Grid));
        var track = new FrameworkElementFactory(typeof(Border), "PART_Track");
        track.SetValue(Border.CornerRadiusProperty, new CornerRadius(4));
        track.SetResourceReference(Border.BackgroundProperty, "ButtonBrush");
        var indicator = new FrameworkElementFactory(typeof(Border), "PART_Indicator");
        indicator.SetValue(Border.CornerRadiusProperty, new CornerRadius(4));
        indicator.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Left);
        indicator.SetResourceReference(Border.BackgroundProperty, "PrimaryBrush");
        root.AppendChild(track);
        root.AppendChild(indicator);
        return new ControlTemplate(typeof(ProgressBar)) { VisualTree = root };
    }

    private static ControlTemplate CircleButtonTemplate()
    {
        var border = new FrameworkElementFactory(typeof(Border), "Root");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(18));
        border.SetResourceReference(Border.BackgroundProperty, "SurfaceHoverBrush");
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);
        return new ControlTemplate(typeof(Button)) { VisualTree = border };
    }
}
