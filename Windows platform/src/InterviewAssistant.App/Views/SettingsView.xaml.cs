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
        var next = viewModel.Theme == "Dark" ? "Light" : "Dark";
        // Slide the toggle first while nothing else is changing, then swap the theme in one
        // cross-faded step (see ThemeManager). Doing both at once caused dropped frames.
        UpdateThemeToggle(next, animate: true);
        await Task.Delay(220);
        viewModel.Theme = next;
        await Task.Delay(280);
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
    }

    // ───────────────────────── Voices ─────────────────────────

    private bool _loadingSensitivity;

    private void ShowVoices_Click(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        SettingsRootPanel.Visibility = Visibility.Collapsed;
        ApiConfigPanel.Visibility = Visibility.Collapsed;
        VoicesPanel.Visibility = Visibility.Visible;
        VoiceStatusText.Text = "";
        _loadingSensitivity = true;
        SensitivitySlider.Value = AppServices.Current.DataStore.Data.Preferences.SpeakerRecognitionSensitivity;
        _loadingSensitivity = false;
        BuildVoiceRows();
    }

    private void BackFromVoices_Click(object sender, RoutedEventArgs e)
    {
        VoicesPanel.Visibility = Visibility.Collapsed;
        SettingsRootPanel.Visibility = Visibility.Visible;
    }

    private void SensitivitySlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loadingSensitivity || !IsLoaded) return;
        var store = AppServices.Current.DataStore;
        store.Data.Preferences.SpeakerRecognitionSensitivity = Math.Round(e.NewValue, 2);
        store.ScheduleSave();
    }

    private void BuildVoiceRows()
    {
        VoiceList.Children.Clear();
        var selected = SpeakerProfileStore.SelectedVoice()?.Id;
        VoiceList.Children.Add(VoiceRow(LocalizationManager.Text("None"), LocalizationManager.Text("Turn off voice recognition"), "\uE74F", selected is null, () => SelectVoice(null), null));
        foreach (var voice in SpeakerProfileStore.Voices())
        {
            VoiceList.Children.Add(Separator());
            var isSelected = voice.Id == selected;
            VoiceList.Children.Add(VoiceRow(voice.Name, LocalizationManager.Text(isSelected ? "Active" : "Available"), "\uE9D9", isSelected, () => SelectVoice(voice.Id), voice));
        }
        VoiceList.Children.Add(Separator());
        VoiceList.Children.Add(AddVoiceRow());
    }

    private Border Separator()
    {
        var line = new Border { Height = 1 };
        line.SetResourceReference(Border.BackgroundProperty, "BorderBrush");
        return line;
    }

    private UIElement VoiceRow(string title, string subtitle, string glyph, bool isSelected, Action select, StoredSpeakerVoice? voice)
    {
        var tile = new Border { Width = 52, Height = 52, CornerRadius = new CornerRadius(14), VerticalAlignment = VerticalAlignment.Center };
        tile.SetResourceReference(Border.BackgroundProperty, isSelected ? "PrimarySoftBrush" : "ButtonBrush");
        var icon = new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 22, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        icon.SetResourceReference(TextBlock.ForegroundProperty, isSelected ? "PrimaryBrush" : "TextSecondaryBrush");
        tile.Child = icon;

        var titleText = new TextBlock { Text = title, FontSize = 17, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
        titleText.SetResourceReference(TextBlock.ForegroundProperty, "TextPrimaryBrush");
        var subtitleText = new TextBlock { Text = subtitle, FontSize = 13, Margin = new Thickness(0, 3, 0, 0) };
        subtitleText.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 12, 0), Children = { titleText, subtitleText } };

        var grid = new Grid { MinHeight = 82, Background = Brushes.Transparent, Cursor = System.Windows.Input.Cursors.Hand };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(texts, 1);
        grid.Children.Add(tile);
        grid.Children.Add(texts);

        if (isSelected)
        {
            var check = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(14), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) };
            check.SetResourceReference(Border.BackgroundProperty, "PrimaryBrush");
            check.Child = new TextBlock { Text = "\uE73E", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 13, FontWeight = FontWeights.Bold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(check, 2);
            grid.Children.Add(check);
        }
        if (voice is not null)
        {
            var more = new Button { Width = 48, Height = 40, Cursor = System.Windows.Input.Cursors.Hand, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0), ToolTip = LocalizationManager.Text("More") };
            more.Template = PlainButtonTemplate();
            var moreContent = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
            foreach (var (glyph2, size) in new[] { ("\uE712", 18.0), ("\uE70D", 10.0) })
            {
                var part = new TextBlock { Text = glyph2, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = size, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 2, 0) };
                part.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
                moreContent.Children.Add(part);
            }
            more.Content = moreContent;
            more.Click += (_, args) =>
            {
                args.Handled = true;
                var menu = new ContextMenu { PlacementTarget = more, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
                var rename = new MenuItem { Header = LocalizationManager.Text("Rename Voice") };
                rename.Click += (_, _) => RenameVoice(voice);
                var delete = new MenuItem { Header = LocalizationManager.Text("Delete Voice") };
                delete.SetResourceReference(MenuItem.ForegroundProperty, "DangerBrush");
                delete.Click += (_, _) => DeleteVoice(voice);
                menu.Items.Add(rename);
                menu.Items.Add(delete);
                menu.IsOpen = true;
            };
            Grid.SetColumn(more, 3);
            grid.Children.Add(more);
        }

        var row = new Border { Padding = new Thickness(20, 0, 16, 0), Background = Brushes.Transparent, Child = grid };
        row.MouseEnter += (_, _) => row.SetResourceReference(Border.BackgroundProperty, "SurfaceHoverBrush");
        row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
        row.MouseLeftButtonUp += (_, args) => { if (args.OriginalSource is not DependencyObject source || !IsInside<Button>(source)) select(); };
        return row;
    }

    private UIElement AddVoiceRow()
    {
        var plus = new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(13), VerticalAlignment = VerticalAlignment.Center };
        plus.SetResourceReference(Border.BackgroundProperty, "PrimaryBrush");
        plus.Child = new TextBlock { Text = "\uE710", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 12, FontWeight = FontWeights.Bold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var label = new TextBlock { Text = LocalizationManager.Text("Add Voice…"), FontSize = 16, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(14, 0, 0, 0) };
        label.SetResourceReference(TextBlock.ForegroundProperty, "PrimaryBrush");
        var row = new Border { Padding = new Thickness(26, 0, 16, 0), MinHeight = 64, Background = Brushes.Transparent, Cursor = System.Windows.Input.Cursors.Hand, Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { plus, label } } };
        row.MouseEnter += (_, _) => row.SetResourceReference(Border.BackgroundProperty, "SurfaceHoverBrush");
        row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
        row.MouseLeftButtonUp += (_, _) => AddVoice();
        return row;
    }

    private static bool IsInside<T>(DependencyObject source) where T : DependencyObject
    {
        for (var current = source; current is not null; current = current is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(current) : LogicalTreeHelper.GetParent(current))
            if (current is T) return true;
        return false;
    }

    private static ControlTemplate PlainButtonTemplate()
    {
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);
        return new ControlTemplate(typeof(Button)) { VisualTree = border };
    }

    private void SelectVoice(Guid? id)
    {
        try
        {
            SpeakerProfileStore.Select(id);
            VoiceStatusText.Text = LocalizationManager.Text(id is null ? "Voice recognition is off." : "Active voice updated.");
        }
        catch (Exception exception) { VoiceStatusText.Text = exception.Message; }
        BuildVoiceRows();
    }

    private void RenameVoice(StoredSpeakerVoice voice)
    {
        var name = Windows.AppDialog.Prompt(Window.GetWindow(this), LocalizationManager.Text("Rename Voice"),
            LocalizationManager.Text("Enter a name that will help you recognize this voice."), voice.Name);
        if (name is null) return;
        try { SpeakerProfileStore.Rename(voice.Id, name); }
        catch (Exception exception) { VoiceStatusText.Text = exception.Message; }
        BuildVoiceRows();
    }

    private void DeleteVoice(StoredSpeakerVoice voice)
    {
        var confirmed = Windows.AppDialog.Show(Window.GetWindow(this), LocalizationManager.Text("Delete Voice"),
            LocalizationManager.Text("This removes the voiceprint from this device."), Windows.DialogTone.Danger,
            LocalizationManager.Text("Delete"), LocalizationManager.Text("Cancel"), destructive: true);
        if (!confirmed) return;
        try { SpeakerProfileStore.Delete(voice.Id); }
        catch (Exception exception) { VoiceStatusText.Text = exception.Message; }
        BuildVoiceRows();
    }

    private void AddVoice()
    {
        var window = new Windows.VoiceEnrollmentWindow { Owner = Window.GetWindow(this) };
        window.ShowDialog();
        if (window.AddedVoice is not null) VoiceStatusText.Text = LocalizationManager.Text("Voice setup is complete.");
        BuildVoiceRows();
    }

    public sealed record PolicySection(string Heading, string Body);

    private void ShowPolicy_Click(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        var privacy = (sender as FrameworkElement)?.Tag as string == "privacy";
        PolicyTitleText.Text = LocalizationManager.Text(privacy ? "Privacy Policy" : "Terms of Service");
        PolicySections.ItemsSource = PolicyContent(privacy, LocalizationManager.Instance.IsChinese);
        AboutPanel.Visibility = Visibility.Collapsed;
        PolicyPanel.Visibility = Visibility.Visible;
    }

    private void BackFromPolicy_Click(object sender, RoutedEventArgs e)
    {
        PolicyPanel.Visibility = Visibility.Collapsed;
        AboutPanel.Visibility = Visibility.Visible;
    }

    /// <summary>Same sections as the macOS SimplePolicyView, adapted to Windows storage and speech.</summary>
    private static IReadOnlyList<PolicySection> PolicyContent(bool privacy, bool chinese)
    {
        if (privacy)
        {
            return chinese
                ?
                [
                    new("本地存储", "Interview AI 会将面试历史、知识库、API 配置和偏好设置保存在你的设备本地。"),
                    new("凭证", "API Key 和语音服务凭证保存在 Windows 凭据管理器中，只用于直接连接你配置的服务商。声纹使用 Windows 数据保护（DPAPI）加密保存在本机，绝不会上传。"),
                    new("第三方服务", "当你使用外部 AI 或语音服务时，该请求所需的问题、相关上下文、截图或音频可能会被直接发送给对应服务商，并受其隐私条款约束。"),
                    new("你的选择", "你可以使用 Ollama 和 Windows 本地语音识别获得更本地化的使用方式，也可以在应用中删除本地保存的面试和知识库内容。")
                ]
                :
                [
                    new("Local storage", "Interview AI stores interview history, knowledge bases, API configuration, and preferences locally on your device."),
                    new("Credentials", "API keys and speech-service credentials are stored in Windows Credential Manager. They are used only to connect directly to the provider you configure. Voiceprints are encrypted on this device with Windows Data Protection (DPAPI) and never uploaded."),
                    new("Third-party services", "When you use an external AI or speech provider, the question, relevant context, screenshot, or audio required for that request may be sent directly to that provider under its own privacy terms."),
                    new("Your choices", "You can use Ollama and Windows on-device speech recognition for a more local workflow. You can delete locally stored interview and knowledge content from the app.")
                ];
        }
        return chinese
            ?
            [
                new("使用应用", "Interview AI 是一款面试准备与辅助工具。你需要自行遵守面试规则、工作单位或学校的规定以及当地法律。"),
                new("AI 输出", "生成的回答可能不完整或不准确，请在采用之前自行核对。"),
                new("你的内容", "除非已获得许可，请不要将机密或受限内容发送给外部模型或语音服务商。"),
                new("可用性", "外部模型和语音功能取决于你配置的服务商。完全本地化的可用性取决于你安装的本地模型和 Windows 语音资源。")
            ]
            :
            [
                new("Using the app", "Interview AI is a preparation and assistance tool. You are responsible for complying with interview rules, workplace or school policies, and local laws."),
                new("AI output", "Generated responses can be incomplete or inaccurate. Review suggestions before relying on them."),
                new("Your content", "Do not send confidential or restricted content to an external model or speech provider unless you have permission."),
                new("Availability", "External model and speech features depend on the providers you configure. Fully local availability depends on your installed local models and Windows speech resources.")
            ];
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
        UpdateCheckResult result;
        try
        {
            result = await UpdateChecker.CheckAsync();
        }
        finally
        {
            UpdateSpinner.Visibility = Visibility.Collapsed;
            UpdateChevron.Visibility = Visibility.Visible;
            UpdateTitleText.Text = LocalizationManager.Text("Check for Updates...");
            CheckUpdatesButton.IsEnabled = true;
        }
        UpdateStatusText.Text = result.Status;

        // Small popup, like the macOS update alert.
        var owner = Window.GetWindow(this);
        if (result.UpdateAvailable)
        {
            var download = Windows.AppDialog.Show(owner, result.Title, result.Message, Windows.DialogTone.Update,
                LocalizationManager.Text("Download Update"), LocalizationManager.Text("Later"));
            if (download) UpdateChecker.OpenDownload(result);
        }
        else
        {
            Windows.AppDialog.Show(owner, result.Title, result.Message,
                result.Succeeded ? Windows.DialogTone.Success : Windows.DialogTone.Warning);
        }
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
