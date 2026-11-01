using System.Windows;
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
        var main = Application.Current.MainWindow as MainWindow;
        var previous = _prompterWindow;
        var prompter = new Windows.PrompterWindow(directorMode: true);
        _prompterWindow = prompter;
        prompter.DirectorQuestionCaptured += OnDirectorQuestionCaptured;
        prompter.DirectorModeChanged += OnDirectorModeChanged;
        // The main window steps aside while the host board is open (same as an interview).
        main?.BeginInterviewWindow();
        prompter.Closed += (_, _) =>
        {
            if (!ReferenceEquals(_prompterWindow, prompter)) { main?.EndInterviewWindow(); return; }
            if (_subscribedViewModel is not null) _subscribedViewModel.PublishHostState(false, "director");
            _prompterWindow = null;
            main?.EndInterviewWindow();
        };
        previous?.Close();
        prompter.Show();
        _subscribedViewModel?.PublishHostState(true, "director");
    }

    private void OnDirectorQuestionCaptured(string text) => _subscribedViewModel?.PublishHostQuestion(text);
    private void OnDirectorModeChanged(bool isDirector) => _subscribedViewModel?.PublishHostState(true, isDirector ? "director" : "ai");
    private void ApplyHostPacket(DirectorPacket packet) => _prompterWindow?.ApplyDirectorPacket(packet);
}
