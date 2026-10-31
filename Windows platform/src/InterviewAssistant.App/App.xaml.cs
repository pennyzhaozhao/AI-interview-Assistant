using System.IO;
using System.Windows;
using System.Windows.Threading;
using InterviewAssistant.Services;

namespace InterviewAssistant;

public partial class App : Application
{
    private int _fatalErrorReported;

    private static readonly string LogDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "InterviewAssistant",
        "Logs");

    private static readonly string LogPath = Path.Combine(LogDirectory, "startup.log");

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        DispatcherUnhandledException += OnDispatcherUnhandledException;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        try
        {
            WriteLog($"Application starting. Runtime: {Environment.Version}; OS: {Environment.OSVersion}");
            await AppServices.Current.InitializeAsync();
            WriteLog($"Local data loaded from {AppServices.Current.DataStore.DataPath}.");
            LocalizationManager.Apply(AppServices.Current.DataStore.Data.Preferences.Language);
            ThemeManager.Apply(AppServices.Current.DataStore.Data.Preferences.Theme);

            var window = new MainWindow
            {
                Topmost = true
            };

            MainWindow = window;
            ShutdownMode = ShutdownMode.OnMainWindowClose;
            window.ContentRendered += async (_, _) =>
            {
                window.Activate();
                window.Focus();
                window.Topmost = false;
                WriteLog($"Main window rendered at {window.Left:0},{window.Top:0} ({window.ActualWidth:0}x{window.ActualHeight:0}).");
                await CheckForUpdatesAtLaunchAsync(window);
            };

            window.Show();
            WriteLog("Main window Show() completed.");
        }
        catch (Exception exception)
        {
            ReportFatalError("Interview AI could not open its main window.", exception);
            Shutdown(-1);
        }
    }

    private static async Task CheckForUpdatesAtLaunchAsync(Window owner)
    {
        var result = await UpdateChecker.CheckAsync();
        if (!result.Succeeded || !result.UpdateAvailable) return;
        var answer = MessageBox.Show(
            owner,
            $"{result.Status}\n\n{LocalizationManager.Text("Would you like to open the download now?")}",
            LocalizationManager.Text("Update Available"),
            MessageBoxButton.YesNo,
            MessageBoxImage.Information);
        if (answer == MessageBoxResult.Yes) UpdateChecker.OpenDownload(result);
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        e.Handled = true;

        if (Interlocked.Exchange(ref _fatalErrorReported, 1) != 0)
        {
            WriteLog($"Additional UI error during shutdown:{Environment.NewLine}{e.Exception}");
            return;
        }

        ReportFatalError("Interview AI encountered an unexpected UI error.", e.Exception);
        Shutdown(-1);
    }

    private static void ReportFatalError(string message, Exception exception)
    {
        WriteLog($"FATAL: {message}{Environment.NewLine}{exception}");
        MessageBox.Show(
            $"{message}\n\n{exception.Message}\n\nLog: {LogPath}",
            "Interview AI",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
    }

    private static void WriteLog(string message)
    {
        try
        {
            Directory.CreateDirectory(LogDirectory);
            File.AppendAllText(
                LogPath,
                $"[{DateTimeOffset.Now:O}] {message}{Environment.NewLine}");
        }
        catch
        {
            // Logging must never prevent the application from starting.
        }
    }
}
