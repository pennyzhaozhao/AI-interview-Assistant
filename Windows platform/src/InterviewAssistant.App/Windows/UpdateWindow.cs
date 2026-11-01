using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using InterviewAssistant.Infrastructure;
using InterviewAssistant.Services;

namespace InterviewAssistant.Windows;

/// <summary>
/// Update dialog in the app's card style: release notes → download progress → installing →
/// "Update complete, restarting" (or an error with a fallback to the download page).
/// </summary>
public sealed class UpdateWindow : Window
{
    private readonly UpdateCheckResult _result;
    private readonly bool _canInstall;
    private readonly Border _iconBox = new() { Width = 46, Height = 46, CornerRadius = new CornerRadius(14), HorizontalAlignment = HorizontalAlignment.Left };
    private readonly TextBlock _iconGlyph = new() { FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 21, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly ActivitySpinner _spinner = new() { Width = 26, Height = 26, Visibility = Visibility.Collapsed };
    private readonly TextBlock _title = new() { FontSize = 19, FontWeight = FontWeights.Bold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 16, 0, 0) };
    private readonly TextBlock _subtitle = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) };
    private readonly StackPanel _notes = new();
    private readonly ScrollViewer _notesScroller;
    private readonly Grid _progressTrack = new() { Height = 8, Margin = new Thickness(0, 18, 0, 0), Visibility = Visibility.Collapsed };
    private readonly Border _progressFill = new() { CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ScaleTransform _progressScale = new(0, 1);
    private readonly TextBlock _progressText = new() { FontSize = 12.5, Margin = new Thickness(0, 8, 0, 0), Visibility = Visibility.Collapsed };
    private readonly Button _secondary = new() { Margin = new Thickness(0, 0, 10, 0) };
    private readonly Button _primary = new();
    private CancellationTokenSource? _download;
    private DispatcherTimer? _restartTimer;
    private State _state = State.Available;
    private bool _restarting;

    private enum State { Available, Downloading, Installing, Done, Failed }

    private UpdateWindow(UpdateCheckResult result)
    {
        _result = result;
        _canInstall = UpdateInstaller.CanInstall(result);

        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        SizeToContent = SizeToContent.Height;
        Width = 480;
        FontFamily = new FontFamily("Segoe UI Variable Text, SimSun, Segoe UI");
        SetResourceReference(ForegroundProperty, "TextPrimaryBrush");
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _iconBox.SetResourceReference(Border.BackgroundProperty, "InputBrush");
        _iconBox.Child = new Grid { Children = { _iconGlyph, _spinner } };
        _spinner.SetResourceReference(ActivitySpinner.SpokeBrushProperty, "PrimaryBrush");
        _subtitle.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        _progressText.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");

        _notesScroller = new ScrollViewer
        {
            Content = _notes,
            MaxHeight = 280,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Margin = new Thickness(0, 14, 0, 0),
            Padding = new Thickness(0, 0, 6, 0)
        };
        var notesText = result.ReleaseNotes?.Trim() ?? "";
        if (notesText.Length == 0) notesText = LocalizationManager.Text("A newer version is ready to download.");
        MarkdownAnswerRenderer.Render(_notes, notesText.Length > 4000 ? notesText[..4000] : notesText,
            (Brush)FindResource("TextSecondaryBrush"), 13.5);

        var track = new Border { CornerRadius = new CornerRadius(4) };
        track.SetResourceReference(Border.BackgroundProperty, "InputBrush");
        _progressFill.SetResourceReference(Border.BackgroundProperty, "PrimaryBrush");
        _progressFill.RenderTransformOrigin = new Point(0, 0.5);
        _progressFill.RenderTransform = _progressScale;
        _progressTrack.Children.Add(track);
        _progressTrack.Children.Add(_progressFill);

        _secondary.SetResourceReference(StyleProperty, "SecondaryButtonStyle");
        _primary.SetResourceReference(StyleProperty, "PrimaryButtonStyle");
        _secondary.Click += (_, _) => OnSecondary();
        _primary.Click += (_, _) => OnPrimary();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 22, 0, 0) };
        buttons.Children.Add(_secondary);
        buttons.Children.Add(_primary);

        var stack = new StackPanel();
        stack.Children.Add(_iconBox);
        stack.Children.Add(_title);
        stack.Children.Add(_subtitle);
        stack.Children.Add(_notesScroller);
        stack.Children.Add(_progressTrack);
        stack.Children.Add(_progressText);
        stack.Children.Add(buttons);

        var card = new Border
        {
            CornerRadius = new CornerRadius(22),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(26, 24, 26, 22),
            Margin = new Thickness(18),
            Child = stack,
            Effect = new DropShadowEffect { BlurRadius = 30, ShadowDepth = 8, Direction = 270, Opacity = 0.22, Color = Color.FromRgb(0x1E, 0x29, 0x3B) }
        };
        card.SetResourceReference(Border.BackgroundProperty, "SurfaceBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "BorderBrush");
        card.MouseLeftButtonDown += (_, e) => { if (e.ChangedButton == MouseButton.Left) DragMove(); };
        Content = card;

        KeyDown += (_, e) => { if (e.Key == Key.Escape) OnSecondary(); };
        Closing += (_, e) =>
        {
            // Installing swaps files: do not interrupt it.
            if (_state == State.Installing && !_restarting) e.Cancel = true;
            else _download?.Cancel();
        };
        Loaded += (_, _) =>
        {
            card.RenderTransformOrigin = new Point(0.5, 0.5);
            var scale = new ScaleTransform(0.96, 0.96);
            card.RenderTransform = scale;
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.96, 1, TimeSpan.FromMilliseconds(160)) { EasingFunction = ease });
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.96, 1, TimeSpan.FromMilliseconds(160)) { EasingFunction = ease });
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140)));
        };

        ShowAvailable();
    }

    /// <summary>Shows the update dialog for an available release.</summary>
    public static void ShowFor(Window? owner, UpdateCheckResult result)
    {
        var dialog = new UpdateWindow(result);
        var resolved = owner ?? Application.Current?.MainWindow;
        if (resolved is not null && resolved.IsLoaded) dialog.Owner = resolved;
        else dialog.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dialog.ShowDialog();
    }

    private void ShowAvailable()
    {
        _state = State.Available;
        SetIcon("", "PrimaryBrush");
        _title.Text = _result.Title;
        _subtitle.Text = string.Format(LocalizationManager.Text("Current version {0} → new version {1}"), _result.CurrentVersion, _result.LatestVersion);
        _secondary.Content = LocalizationManager.Text("Later");
        _secondary.Visibility = Visibility.Visible;
        _primary.Content = _canInstall ? LocalizationManager.Text("Update Now") : LocalizationManager.Text("Download Update");
        _primary.IsEnabled = true;
    }

    private async void OnPrimary()
    {
        switch (_state)
        {
            case State.Available when _canInstall:
                await InstallAsync();
                break;
            case State.Available:
            case State.Failed:
                UpdateChecker.OpenDownload(_result);
                Close();
                break;
            case State.Done:
                await RestartNowAsync();
                break;
        }
    }

    private void OnSecondary()
    {
        switch (_state)
        {
            case State.Downloading:
                _download?.Cancel();
                break;
            case State.Installing:
            case State.Done:
                break;
            default:
                Close();
                break;
        }
    }

    private async Task InstallAsync()
    {
        if (_result.Asset is not { } asset) return;
        _state = State.Downloading;
        _download = new CancellationTokenSource();
        SetBusy(true);
        _title.Text = string.Format(LocalizationManager.Text("Downloading version {0}…"), _result.LatestVersion);
        _subtitle.Text = LocalizationManager.Text("You can keep using the app. Do not close this window.");
        _notesScroller.Visibility = Visibility.Collapsed;
        _progressTrack.Visibility = Visibility.Visible;
        _progressText.Visibility = Visibility.Visible;
        _progressText.Text = LocalizationManager.Text("Connecting…");
        _secondary.Content = LocalizationManager.Text("Cancel");
        _primary.Visibility = Visibility.Collapsed;

        var progress = new Progress<(long Received, long Total)>(value =>
        {
            if (_state != State.Downloading) return;
            var fraction = value.Total > 0 ? Math.Clamp((double)value.Received / value.Total, 0, 1) : 0;
            _progressScale.BeginAnimation(ScaleTransform.ScaleXProperty,
                new DoubleAnimation(fraction, TimeSpan.FromMilliseconds(120)));
            _progressText.Text = value.Total > 0
                ? $"{FormatMegabytes(value.Received)} / {FormatMegabytes(value.Total)} · {fraction:P0}"
                : FormatMegabytes(value.Received);
            if (fraction >= 1 && _state == State.Downloading) ShowInstalling();
        });

        try
        {
            await UpdateInstaller.InstallAsync(asset, progress, _download.Token);
            ShowDone();
        }
        catch (OperationCanceledException)
        {
            SetBusy(false);
            _progressTrack.Visibility = Visibility.Collapsed;
            _progressText.Visibility = Visibility.Collapsed;
            _progressScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            _progressScale.ScaleX = 0;
            _notesScroller.Visibility = Visibility.Visible;
            _primary.Visibility = Visibility.Visible;
            ShowAvailable();
        }
        catch (Exception exception)
        {
            ShowFailed(exception.Message);
        }
    }

    private void ShowInstalling()
    {
        _state = State.Installing;
        _title.Text = LocalizationManager.Text("Installing update…");
        _subtitle.Text = LocalizationManager.Text("Replacing the app with the new version.");
        _secondary.Visibility = Visibility.Collapsed;
    }

    private void ShowDone()
    {
        _state = State.Done;
        SetBusy(false);
        SetIcon("", "SuccessBrush");
        _progressScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(120)));
        _progressFill.SetResourceReference(Border.BackgroundProperty, "SuccessBrush");
        var installer = _result.Asset?.IsInstaller == true;
        _title.Text = installer ? LocalizationManager.Text("Download complete") : LocalizationManager.Text("Update successful");
        _secondary.Visibility = Visibility.Collapsed;
        _primary.Visibility = Visibility.Visible;
        _primary.Content = LocalizationManager.Text("Restart Now");

        var remaining = 3;
        void Tick()
        {
            _subtitle.Text = installer
                ? string.Format(LocalizationManager.Text("The app will close in {0} s to install the update, then reopen automatically."), remaining)
                : string.Format(LocalizationManager.Text("The app will reopen automatically in {0} s."), remaining);
            _progressText.Text = string.Format(LocalizationManager.Text("Updated to version {0}."), _result.LatestVersion);
        }
        Tick();
        _restartTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _restartTimer.Tick += async (_, _) =>
        {
            remaining--;
            if (remaining <= 0) await RestartNowAsync();
            else Tick();
        };
        _restartTimer.Start();
    }

    private async Task RestartNowAsync()
    {
        _restartTimer?.Stop();
        _primary.IsEnabled = false;
        _state = State.Installing; // keep the window open until the app exits
        _restarting = true;
        await UpdateInstaller.RestartAsync(_result.CurrentVersion);
    }

    private void ShowFailed(string reason)
    {
        _state = State.Failed;
        SetBusy(false);
        SetIcon("", "WarningBrush");
        _title.Text = LocalizationManager.Text("Update failed");
        _subtitle.Text = $"{reason}\n{LocalizationManager.Text("Your current version was not changed. You can download the new version from the release page instead.")}";
        _progressTrack.Visibility = Visibility.Collapsed;
        _progressText.Visibility = Visibility.Collapsed;
        _secondary.Visibility = Visibility.Visible;
        _secondary.Content = LocalizationManager.Text("Close");
        _primary.Visibility = Visibility.Visible;
        _primary.IsEnabled = true;
        _primary.Content = LocalizationManager.Text("Open Download Page");
    }

    private void SetIcon(string glyph, string brushKey)
    {
        _iconGlyph.Text = glyph;
        _iconGlyph.SetResourceReference(TextBlock.ForegroundProperty, brushKey);
    }

    private void SetBusy(bool busy)
    {
        _spinner.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        _iconGlyph.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
    }

    private static string FormatMegabytes(long bytes) => $"{bytes / 1024d / 1024d:0.0} MB";
}
