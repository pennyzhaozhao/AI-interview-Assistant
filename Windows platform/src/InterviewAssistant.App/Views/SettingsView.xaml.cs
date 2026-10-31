using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Animation;
using System.Windows.Media;
using Microsoft.Win32;
using InterviewAssistant.Services;
namespace InterviewAssistant.Views;
public partial class SettingsView : UserControl
{
    private bool _isLoadingPassword;
    private bool _isChangingTheme;
    private ViewModels.SettingsViewModel? _subscribedViewModel;
    private UpdateCheckResult? _lastUpdateResult;

    public SettingsView() => InitializeComponent();

    private void SettingsView_Loaded(object sender, System.Windows.RoutedEventArgs e)
    {
        if (DataContext is not ViewModels.SettingsViewModel viewModel) return;
        _isLoadingPassword = true;
        ApiKeyBox.Password = viewModel.ApiKey;
        SpeechTokenBox.Password = viewModel.SpeechAccessToken;
        UpdateThemeToggle(viewModel.Theme, animate: false);
        _isLoadingPassword = false;
        if (ReferenceEquals(_subscribedViewModel, viewModel)) return;
        _subscribedViewModel = viewModel;
        viewModel.PropertyChanged += (_, args) =>
        {
            _isLoadingPassword = true;
            if (args.PropertyName == nameof(ViewModels.SettingsViewModel.ApiKey))
            {
                ApiKeyBox.Password = viewModel.ApiKey;
            }
            else if (args.PropertyName == nameof(ViewModels.SettingsViewModel.SpeechAccessToken))
            {
                SpeechTokenBox.Password = viewModel.SpeechAccessToken;
            }
            else if (args.PropertyName == nameof(ViewModels.SettingsViewModel.Theme))
            {
                UpdateThemeToggle(viewModel.Theme, animate: true);
            }
            _isLoadingPassword = false;
        };
    }

    private void ApiKeyBox_PasswordChanged(object sender, System.Windows.RoutedEventArgs e)
    {
        if (_isLoadingPassword || DataContext is not ViewModels.SettingsViewModel viewModel) return;
        viewModel.ApiKey = ApiKeyBox.Password;
    }

    private void SpeechTokenBox_PasswordChanged(object sender, RoutedEventArgs e)
    {
        if (_isLoadingPassword || DataContext is not ViewModels.SettingsViewModel viewModel) return;
        viewModel.SpeechAccessToken = SpeechTokenBox.Password;
    }

    private void OpenApiConfig_Click(object sender, RoutedEventArgs e)
    {
        SettingsRootPanel.Visibility = Visibility.Collapsed;
        ApiConfigPanel.Visibility = Visibility.Visible;
    }

    private void BackToSettings_Click(object sender, RoutedEventArgs e)
    {
        ApiConfigPanel.Visibility = Visibility.Collapsed;
        SettingsRootPanel.Visibility = Visibility.Visible;
    }

    private void OpenDataFolder_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not ViewModels.SettingsViewModel viewModel) return;
        Process.Start(new ProcessStartInfo("explorer.exe", viewModel.DataDirectory) { UseShellExecute = true });
    }

    private async void ChooseDataFolder_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not ViewModels.SettingsViewModel viewModel) return;
        var dialog = new OpenFolderDialog
        {
            Title = "Choose where Interview AI stores local data",
            InitialDirectory = viewModel.DataDirectory,
            Multiselect = false
        };
        if (dialog.ShowDialog() == true)
        {
            await viewModel.ChangeDataDirectoryAsync(dialog.FolderName);
        }
    }

    private async void ToggleTheme_Click(object sender, RoutedEventArgs e)
    {
        if (_isChangingTheme || DataContext is not ViewModels.SettingsViewModel viewModel) return;
        _isChangingTheme = true;
        ThemeToggleHost.BeginAnimation(
            OpacityProperty,
            new DoubleAnimation(1, 0.25, TimeSpan.FromMilliseconds(90)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn } });
        await Task.Delay(85);
        viewModel.Theme = viewModel.Theme == "Dark" ? "Light" : "Dark";
        ThemeToggleHost.BeginAnimation(
            OpacityProperty,
            new DoubleAnimation(0.25, 1, TimeSpan.FromMilliseconds(140)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } });
        await Task.Delay(145);
        _isChangingTheme = false;
    }

    private void UpdateThemeToggle(string theme, bool animate)
    {
        var isLight = theme == "Light";
        ThemeToggleTrack.Background = new SolidColorBrush(isLight ? Color.FromRgb(231, 231, 231) : Color.FromRgb(15, 0, 0));
        ThemeToggleIcon.Text = isLight ? "\uE706" : "\uE708";
        ThemeToggleIcon.Foreground = new SolidColorBrush(isLight ? Color.FromRgb(17, 19, 24) : Color.FromRgb(6, 6, 37));
        var destination = isLight ? 75d : 0d;
        if (!animate)
        {
            ThemeToggleTranslate.X = destination;
            return;
        }
        ThemeToggleTranslate.BeginAnimation(
            TranslateTransform.XProperty,
            new DoubleAnimation(ThemeToggleTranslate.X, destination, TimeSpan.FromMilliseconds(210))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut }
            });
    }

    private async void ClearLocalData_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not ViewModels.SettingsViewModel viewModel) return;
        var result = MessageBox.Show(
            "This removes interview drafts, history and knowledge bases from this device. API credentials and preferences are kept.",
            "Clear local data?",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);
        if (result == MessageBoxResult.Yes)
        {
            await viewModel.ClearLocalDataAsync();
            ThemeManager.Apply(viewModel.Theme.ToLowerInvariant(), animate: true);
        }
    }

    private void ShowAbout_Click(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        SettingsRootPanel.Visibility = Visibility.Collapsed;
        ApiConfigPanel.Visibility = Visibility.Collapsed;
        AboutPanel.Visibility = Visibility.Visible;
        AboutVersionText.Text = UpdateChecker.CurrentVersion;
        AboutBuildText.Text = UpdateChecker.BuildNumber;
        UpdateStatusText.Text = string.Format(
            LocalizationManager.Text("InterviewAssistant {0} is installed."),
            UpdateChecker.CurrentVersion);
        UpdateTitleText.Text = LocalizationManager.Text("Check for Updates...");
        UpdateResultCard.Visibility = Visibility.Collapsed;
    }

    private void BackFromAbout_Click(object sender, RoutedEventArgs e)
    {
        AboutPanel.Visibility = Visibility.Collapsed;
        SettingsRootPanel.Visibility = Visibility.Visible;
    }

    private async void CheckUpdates_Click(object sender, RoutedEventArgs e)
    {
        CheckUpdatesButton.IsEnabled = false;
        UpdateTitleText.Text = LocalizationManager.Text("Checking for Updates...");
        UpdateStatusText.Text = LocalizationManager.Text("Contacting GitHub Releases...");
        UpdateChevron.Visibility = Visibility.Collapsed;
        UpdateSpinner.Visibility = Visibility.Visible;
        UpdateResultCard.Visibility = Visibility.Collapsed;
        DownloadUpdateButton.Visibility = Visibility.Collapsed;
        try
        {
            var result = await UpdateChecker.CheckAsync();
            _lastUpdateResult = result;
            UpdateTitleText.Text = LocalizationManager.Text("Check for Updates...");
            UpdateStatusText.Text = result.Status;

            UpdateResultTitle.Text = result.Title;
            UpdateResultMessage.Text = result.Message;
            UpdateResultIcon.Text = !result.Succeeded ? "\uE7BA" : result.UpdateAvailable ? "\uE896" : "\uE930";
            UpdateResultIcon.Foreground = (System.Windows.Media.Brush)FindResource(
                !result.Succeeded ? "WarningBrush" : result.UpdateAvailable ? "PrimaryBrush" : "SuccessBrush");
            DownloadUpdateButton.Visibility = result.UpdateAvailable && !string.IsNullOrWhiteSpace(result.DownloadUrl)
                ? Visibility.Visible
                : Visibility.Collapsed;
            UpdateResultCard.Visibility = Visibility.Visible;
        }
        finally
        {
            UpdateSpinner.Visibility = Visibility.Collapsed;
            UpdateChevron.Visibility = Visibility.Visible;
            CheckUpdatesButton.IsEnabled = true;
        }
    }

    private void DownloadUpdate_Click(object sender, RoutedEventArgs e)
    {
        if (_lastUpdateResult is not null) UpdateChecker.OpenDownload(_lastUpdateResult);
    }

    private void SetScreenshotRegion_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not ViewModels.SettingsViewModel viewModel) return;
        var selector = new Windows.RegionSelectionWindow { Owner = Window.GetWindow(this) };
        if (selector.ShowDialog() == true)
        {
            viewModel.SetScreenshotRegion(selector.SelectedRegion);
        }
    }

    private void ClearScreenshotRegion_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is ViewModels.SettingsViewModel viewModel) viewModel.ClearScreenshotRegion();
    }
}
