using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Runtime.InteropServices;
using InterviewAssistant.Windows;

namespace InterviewAssistant;

public partial class MainWindow : Window
{
    private PrompterWindow? _prompterWindow;
    private nint _windowHandle;
    private int _activeInterviewWindows;
    private WindowState _stateBeforeInterview = WindowState.Normal;
    private Windows.MockInterviewWindow? _mockInterviewView;

    public MainWindow()
    {
        InitializeComponent();
        if (DataContext is ViewModels.MainViewModel viewModel)
        {
            viewModel.InterviewStarted += OpenInterviewPrompter;
            viewModel.MockInterviewRequested += OpenMockInterview;
            viewModel.MockInterviewOptionsRequested += OpenMockInterviewOptions;
        }
        Services.AppServices.Current.DataStore.Changed += DataStore_Changed;
        ScreenshotHotkey.Pressed += ScreenshotHotkey_Pressed;
    }

    private void OpenMockInterviewOptions()
    {
        var dialog = new Windows.MockInterviewOptionsWindow { Owner = this };
        if (dialog.ShowDialog() == true && DataContext is ViewModels.MainViewModel viewModel)
        {
            viewModel.StartMockInterview(dialog.QuestionCount);
        }
    }

    private void OpenMockInterview(Models.MockInterviewLaunchConfig config)
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            try
            {
                CloseEmbeddedMockInterview();
                _mockInterviewView = new Windows.MockInterviewWindow(config);
                _mockInterviewView.CloseRequested += CloseEmbeddedMockInterview;
                MockInterviewContent.Content = _mockInterviewView;
                MockInterviewHost.Visibility = Visibility.Visible;
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    $"Mock interview could not open.\n\n{exception.Message}",
                    "Interview AI",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }), System.Windows.Threading.DispatcherPriority.Normal);
    }

    private void CloseEmbeddedMockInterview()
    {
        if (_mockInterviewView is not null)
        {
            _mockInterviewView.CloseRequested -= CloseEmbeddedMockInterview;
            _mockInterviewView.CloseSession();
        }
        MockInterviewContent.Content = null;
        MockInterviewHost.Visibility = Visibility.Collapsed;
        _mockInterviewView = null;
        if (DataContext is ViewModels.MainViewModel viewModel) viewModel.RefreshHistory();
    }

    private void OpenInterviewPrompter(Models.InterviewSessionModel session)
    {
        Dispatcher.BeginInvoke(
            System.Windows.Threading.DispatcherPriority.Loaded,
            new Action(() =>
            {
                // Count the new board before closing the old one, so the main window does not flash back.
                var previous = _prompterWindow;
                var prompter = new PrompterWindow(session);
                _prompterWindow = prompter;
                BeginInterviewWindow();
                prompter.Closed += (_, _) =>
                {
                    if (ReferenceEquals(_prompterWindow, prompter)) _prompterWindow = null;
                    EndInterviewWindow();
                };
                previous?.Close();
                prompter.Show();
            }));
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        _windowHandle = new WindowInteropHelper(this).Handle;
        var source = HwndSource.FromHwnd(_windowHandle);
        source?.AddHook(WindowMessageHook);
        // A re-created handle loses its extended styles: keep it out of the taskbar while an interview runs.
        if (_activeInterviewWindows > 0) ApplyInterviewTaskbarStyle();
        ApplyRoundedCorners();
    }

    private nint WindowMessageHook(nint windowHandle, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message != NativeMethods.WmGetMinMaxInfo || lParam == nint.Zero) return nint.Zero;
        var monitor = NativeMethods.MonitorFromWindow(windowHandle, NativeMethods.MonitorDefaultToNearest);
        var info = new NativeMethods.MonitorInfo { Size = Marshal.SizeOf<NativeMethods.MonitorInfo>() };
        if (monitor == nint.Zero || !NativeMethods.GetMonitorInfo(monitor, ref info)) return nint.Zero;
        var minMax = Marshal.PtrToStructure<NativeMethods.MinMaxInfo>(lParam);
        minMax.MaxPosition.X = Math.Abs(info.WorkArea.Left - info.Monitor.Left);
        minMax.MaxPosition.Y = Math.Abs(info.WorkArea.Top - info.Monitor.Top);
        minMax.MaxSize.X = info.WorkArea.Right - info.WorkArea.Left;
        minMax.MaxSize.Y = info.WorkArea.Bottom - info.WorkArea.Top;
        Marshal.StructureToPtr(minMax, lParam, true);
        handled = true;
        return nint.Zero;
    }

    /// <summary>The visible prompt board the hotkey acts on: the interview board or the Director Mode host board.</summary>
    private static PrompterWindow? ActivePrompter =>
        Application.Current.Windows.OfType<PrompterWindow>().LastOrDefault(window => window.IsVisible);

    private void ScreenshotHotkey_Pressed()
    {
        if (ActivePrompter is { } prompter) _ = prompter.CaptureAndAnalyzeScreenshotAsync();
    }

    /// <summary>Held only while a prompt board is open; reports a conflict on the board instead of a blocking dialog.</summary>
    private void UpdateScreenshotHotkey()
    {
        if (_activeInterviewWindows == 0)
        {
            ScreenshotHotkey.Unregister();
            return;
        }
        var text = Services.AppServices.Current.DataStore.Data.Preferences.ScreenshotHotkey;
        if (ScreenshotHotkey.Register(text)) return;
        var notice = Services.LocalizationManager.Instance.IsChinese
            ? $"截图快捷键 {text} 已被其他程序占用，请在设置中更换，或点击截图按钮。"
            : $"The screenshot shortcut {text} is used by another app. Change it in Settings or use the screenshot button.";
        // Let the board finish appearing so the notice is visible.
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, new Action(() => ActivePrompter?.ShowNotice(notice)));
    }

    private void DataStore_Changed()
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            UpdateScreenshotHotkey();
            if (_activeInterviewWindows > 0) MoveToBackground();
        }));
    }

    /// <summary>
    /// A prompt board opened (interview or Director Mode host): the main window steps aside.
    /// With "Hide from the taskbar" it is hidden completely (no taskbar button, no Alt+Tab);
    /// otherwise it is minimized to the taskbar.
    /// </summary>
    public void BeginInterviewWindow()
    {
        if (_activeInterviewWindows++ == 0)
        {
            _stateBeforeInterview = WindowState == WindowState.Minimized ? WindowState.Normal : WindowState;
        }
        MoveToBackground();
        UpdateScreenshotHotkey();
    }

    /// <summary>The last prompt board closed: bring the main window back.</summary>
    public void EndInterviewWindow()
    {
        _activeInterviewWindows = Math.Max(0, _activeInterviewWindows - 1);
        if (_activeInterviewWindows > 0) return;
        UpdateScreenshotHotkey();
        ClearInterviewTaskbarStyle();
        ShowInTaskbar = true;
        if (!IsVisible) Show();
        WindowState = _stateBeforeInterview;
        Activate();
    }

    /// <summary>Opened from the prompt board's menu (Knowledge Base / History) while it stays open.</summary>
    public void RevealDuringInterview()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = _stateBeforeInterview;
        Activate();
    }

    private void MoveToBackground()
    {
        if (Services.AppServices.Current.DataStore.Data.Preferences.HideTaskbarIconDuringInterview)
        {
            if (IsVisible) Hide();
            ShowInTaskbar = false;
            // ShowInTaskbar alone is not enough: once the window is brought back mid-interview
            // (Knowledge Base / History) its button can reappear. A tool window never gets one.
            ApplyInterviewTaskbarStyle();
        }
        else
        {
            ClearInterviewTaskbarStyle();
            ShowInTaskbar = true;
            if (!IsVisible) Show();
            WindowState = WindowState.Minimized;
        }
    }

    private void ApplyInterviewTaskbarStyle()
    {
        if (_windowHandle == nint.Zero || !Services.AppServices.Current.DataStore.Data.Preferences.HideTaskbarIconDuringInterview) return;
        var style = NativeMethods.GetWindowLong(_windowHandle, NativeMethods.GwlExStyle);
        _ = NativeMethods.SetWindowLong(_windowHandle, NativeMethods.GwlExStyle, (style | NativeMethods.WsExToolWindow) & ~NativeMethods.WsExAppWindow);
    }

    private void ClearInterviewTaskbarStyle()
    {
        if (_windowHandle == nint.Zero) return;
        var style = NativeMethods.GetWindowLong(_windowHandle, NativeMethods.GwlExStyle);
        if ((style & NativeMethods.WsExToolWindow) == 0) return;
        // The taskbar only re-reads the style when the window is shown, so hide while changing it.
        var wasVisible = IsVisible;
        if (wasVisible) Hide();
        _ = NativeMethods.SetWindowLong(_windowHandle, NativeMethods.GwlExStyle, style & ~NativeMethods.WsExToolWindow);
        if (wasVisible) Show();
    }

    private void ApplyRoundedCorners()
    {
        try
        {
            var handle = new WindowInteropHelper(this).Handle;
            var preference = NativeMethods.DwmwcpRound;
            _ = NativeMethods.DwmSetWindowAttribute(handle, NativeMethods.DwmwaWindowCornerPreference, ref preference, Marshal.SizeOf<int>());
        }
        catch
        {
            // Older Windows versions do not expose the corner preference attribute.
        }
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            ToggleMaximize();
            return;
        }

        DragMove();
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void MaximizeButton_Click(object sender, RoutedEventArgs e) => ToggleMaximize();
    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    protected override void OnClosed(EventArgs e)
    {
        Services.AppServices.Current.DataStore.Changed -= DataStore_Changed;
        ScreenshotHotkey.Pressed -= ScreenshotHotkey_Pressed;
        ScreenshotHotkey.Unregister();
        _prompterWindow?.Close();
        CloseEmbeddedMockInterview();
        base.OnClosed(e);
    }

    private void ToggleMaximize() =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
}
