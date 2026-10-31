using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Runtime.InteropServices;
using InterviewAssistant.Windows;

namespace InterviewAssistant;

public partial class MainWindow : Window
{
    private const int ScreenshotHotkeyId = 0x4941;
    private PrompterWindow? _prompterWindow;
    private nint _windowHandle;

    public MainWindow()
    {
        InitializeComponent();
        if (DataContext is ViewModels.MainViewModel viewModel)
        {
            viewModel.InterviewStarted += OpenInterviewPrompter;
            viewModel.MockInterviewRequested += OpenMockInterview;
            viewModel.MockInterviewOptionsRequested += OpenMockInterviewOptions;
        }
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
                var window = new Windows.MockInterviewWindow(config) { Owner = this };
                window.Closed += (_, _) =>
                {
                    if (DataContext is ViewModels.MainViewModel viewModel) viewModel.RefreshHistory();
                };
                window.Show();
                window.Activate();
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

    private void OpenInterviewPrompter(Models.InterviewSessionModel session)
    {
        Dispatcher.BeginInvoke(
            System.Windows.Threading.DispatcherPriority.Loaded,
            new Action(() =>
            {
                _prompterWindow?.Close();
                _prompterWindow = new PrompterWindow(session);
                _prompterWindow.Closed += (_, _) => _prompterWindow = null;
                _prompterWindow.Show();
            }));
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        _windowHandle = new WindowInteropHelper(this).Handle;
        var source = HwndSource.FromHwnd(_windowHandle);
        source?.AddHook(WindowMessageHook);
        RegisterScreenshotHotkey();
        ApplyRoundedCorners();
    }

    private nint WindowMessageHook(nint windowHandle, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == NativeMethods.WmHotkey && wParam.ToInt32() == ScreenshotHotkeyId)
        {
            if (_prompterWindow is not null) _ = _prompterWindow.CaptureAndAnalyzeScreenshotAsync();
            handled = true;
            return nint.Zero;
        }
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

    private void RegisterScreenshotHotkey()
    {
        var text = Services.AppServices.Current.DataStore.Data.Preferences.ScreenshotHotkey;
        var modifiers = 0u;
        var key = Key.S;
        foreach (var part in text.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            if (part.Equals("Ctrl", StringComparison.OrdinalIgnoreCase) || part.Equals("Control", StringComparison.OrdinalIgnoreCase)) modifiers |= NativeMethods.ModControl;
            else if (part.Equals("Shift", StringComparison.OrdinalIgnoreCase)) modifiers |= NativeMethods.ModShift;
            else if (part.Equals("Alt", StringComparison.OrdinalIgnoreCase)) modifiers |= NativeMethods.ModAlt;
            else if (part.Equals("Win", StringComparison.OrdinalIgnoreCase) || part.Equals("Windows", StringComparison.OrdinalIgnoreCase)) modifiers |= NativeMethods.ModWin;
            else if (Enum.TryParse<Key>(part, true, out var parsed)) key = parsed;
        }
        if (modifiers == 0) modifiers = NativeMethods.ModControl | NativeMethods.ModShift;
        if (!NativeMethods.RegisterHotKey(_windowHandle, ScreenshotHotkeyId, modifiers, (uint)KeyInterop.VirtualKeyFromKey(key)))
        {
            MessageBox.Show(Services.LocalizationManager.Instance.IsChinese ? "截图全局快捷键注册失败，可能已被其他程序占用。" : "The screenshot hotkey is already used by another application.", "Interview AI", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
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
        if (_windowHandle != nint.Zero) _ = NativeMethods.UnregisterHotKey(_windowHandle, ScreenshotHotkeyId);
        _prompterWindow?.Close();
        base.OnClosed(e);
    }

    private void ToggleMaximize() =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
}
