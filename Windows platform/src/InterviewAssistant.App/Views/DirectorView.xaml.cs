using System.Windows.Controls;
using InterviewAssistant.Services;
namespace InterviewAssistant.Views;
public partial class DirectorView : UserControl
{
    private ViewModels.DirectorViewModel? _subscribedViewModel;
    private Windows.PrompterWindow? _prompterWindow;

    public DirectorView() => InitializeComponent();

    private void DirectorView_Loaded(object sender, System.Windows.RoutedEventArgs e)
    {
        if (DataContext is not ViewModels.DirectorViewModel viewModel || ReferenceEquals(_subscribedViewModel, viewModel)) return;
        if (_subscribedViewModel is not null) _subscribedViewModel.HostBoardRequested -= OpenHostBoard;
        if (_subscribedViewModel is not null) _subscribedViewModel.HostPacketReceived -= ApplyHostPacket;
        _subscribedViewModel = viewModel;
        viewModel.HostBoardRequested += OpenHostBoard;
        viewModel.HostPacketReceived += ApplyHostPacket;
    }

    private void OpenHostBoard()
    {
        _prompterWindow?.Close();
        _prompterWindow = new Windows.PrompterWindow(directorMode: true);
        _prompterWindow.DirectorQuestionCaptured += OnDirectorQuestionCaptured;
        _prompterWindow.DirectorModeChanged += OnDirectorModeChanged;
        _prompterWindow.Closed += (_, _) =>
        {
            if (_subscribedViewModel is not null) _subscribedViewModel.PublishHostState(false, "director");
            _prompterWindow = null;
        };
        _prompterWindow.Show();
        _subscribedViewModel?.PublishHostState(true, "director");
    }

    private void OnDirectorQuestionCaptured(string text) => _subscribedViewModel?.PublishHostQuestion(text);
    private void OnDirectorModeChanged(bool isDirector) => _subscribedViewModel?.PublishHostState(true, isDirector ? "director" : "ai");
    private void ApplyHostPacket(DirectorPacket packet) => _prompterWindow?.ApplyDirectorPacket(packet);
}
