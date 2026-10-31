using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using InterviewAssistant.Infrastructure;
using InterviewAssistant.Services;
using QRCoder;
using System.IO;
using System.Windows.Media.Imaging;

namespace InterviewAssistant.ViewModels;

public sealed class DirectorViewModel : PageViewModel
{
    private readonly DirectorConnectionService _connection = new();
    private readonly DirectorHostService _host = new();
    private string _hostIp = "";
    private string _status = LocalizationManager.Text("Waiting for host connection");
    private string _draft = "";
    private RemoteQuestionViewModel? _selectedQuestion;
    private bool _hostBoardOpen;
    private string _remoteMode = "director";

    public DirectorViewModel() : base("Director Mode", "Host a prompt board or connect as a controller")
    {
        LocalIp = DirectorConnectionService.GetLocalIPv4Address();
        ControllerQrCode = CreateQrCode($"http://{LocalIp}:9999");
        ConnectCommand = new AsyncRelayCommand(ConnectAsync);
        SendCommand = new AsyncRelayCommand(SendAsync);
        ClearCommand = new RelayCommand(() => Draft = "");
        PreviousQuestionCommand = new RelayCommand(PreviousQuestion, () => SelectedQuestionIndex > 0);
        NextQuestionCommand = new RelayCommand(NextQuestion, () => SelectedQuestionIndex >= 0 && SelectedQuestionIndex < Questions.Count - 1);
        OpenHostBoardCommand = new AsyncRelayCommand(StartHostBoardAsync);
        _connection.StatusChanged += status => Application.Current.Dispatcher.Invoke(() => Status = LocalizeStatus(status));
        _connection.PacketReceived += packet => Application.Current.Dispatcher.Invoke(() => Receive(packet));
        _host.StatusChanged += status => Application.Current.Dispatcher.Invoke(() => Status = LocalizeStatus(status));
        _host.PacketReceived += packet => Application.Current.Dispatcher.Invoke(() => Receive(packet));
        LocalizationManager.Instance.LanguageChanged += () => OnPropertyChanged(nameof(ModeStatusText));
    }

    public string LocalIp { get; }
    public BitmapImage ControllerQrCode { get; }
    public ObservableCollection<RemoteQuestionViewModel> Questions { get; } = [];
    public ICommand ConnectCommand { get; }
    public ICommand SendCommand { get; }
    public ICommand ClearCommand { get; }
    public ICommand PreviousQuestionCommand { get; }
    public ICommand NextQuestionCommand { get; }
    public ICommand OpenHostBoardCommand { get; }
    public event Action? HostBoardRequested;
    public event Action<DirectorPacket>? HostPacketReceived;

    public string HostIp
    {
        get => _hostIp;
        set => SetProperty(ref _hostIp, value);
    }

    public string Status
    {
        get => _status;
        private set => SetProperty(ref _status, value);
    }

    public string Draft
    {
        get => _draft;
        set => SetProperty(ref _draft, value);
    }

    public RemoteQuestionViewModel? SelectedQuestion
    {
        get => _selectedQuestion;
        set
        {
            if (!SetProperty(ref _selectedQuestion, value)) return;
            OnPropertyChanged(nameof(SelectedQuestionIndex));
            (PreviousQuestionCommand as RelayCommand)?.NotifyCanExecuteChanged();
            (NextQuestionCommand as RelayCommand)?.NotifyCanExecuteChanged();
        }
    }
    public int SelectedQuestionIndex => SelectedQuestion is null ? -1 : Questions.IndexOf(SelectedQuestion);

    public bool HostBoardOpen
    {
        get => _hostBoardOpen;
        private set => SetProperty(ref _hostBoardOpen, value);
    }

    public string RemoteMode
    {
        get => _remoteMode;
        private set
        {
            if (SetProperty(ref _remoteMode, value)) OnPropertyChanged(nameof(ModeStatusText));
        }
    }
    public string ModeStatusText => LocalizationManager.Instance.IsChinese
        ? $"用户模式：{(RemoteMode.Equals("director", StringComparison.OrdinalIgnoreCase) ? "导演" : "AI")}" : $"User mode: {RemoteMode}";

    private async Task ConnectAsync()
    {
        try
        {
            await _connection.ConnectAsync(HostIp);
        }
        catch (Exception exception)
        {
            Status = exception.Message;
        }
    }

    private async Task StartHostBoardAsync()
    {
        try
        {
            await _host.StartAsync();
            _host.Publish(new DirectorPacket { Kind = "state", HostBoardOpen = true, Mode = "director" });
            HostBoardOpen = true;
            RemoteMode = "director";
            HostBoardRequested?.Invoke();
            Status = LocalizationManager.Instance.IsChinese ? "Host 已启动，网页控制端可以连接。" : "Host is running. The web controller can connect.";
        }
        catch (Exception exception)
        {
            Status = exception.Message;
        }
    }

    public void PublishHostQuestion(string text)
    {
        var packet = new DirectorPacket { Kind = "question", QuestionID = Guid.NewGuid().ToString("N"), Text = text };
        _host.Publish(packet);
        Receive(packet);
    }

    public void PublishHostState(bool open, string mode)
    {
        HostBoardOpen = open;
        RemoteMode = mode;
        _host.Publish(new DirectorPacket { Kind = "state", HostBoardOpen = open, Mode = mode });
    }

    private async Task SendAsync()
    {
        var text = Draft.Trim();
        if (text.Length == 0) return;
        if (!_connection.IsConnected)
        {
            Status = LocalizationManager.Instance.IsChinese ? "请先连接 Host。" : "Connect to a Host before sending.";
            return;
        }
        if (!HostBoardOpen)
        {
            Status = LocalizationManager.Instance.IsChinese ? "Host 提示板已关闭。" : "The Host prompt board is closed.";
            return;
        }
        if (string.Equals(RemoteMode, "ai", StringComparison.OrdinalIgnoreCase))
        {
            Status = LocalizationManager.Instance.IsChinese ? "Host 当前处于 AI 模式。" : "The Host is currently in AI mode.";
            return;
        }

        try
        {
            await _connection.SendAsync(new DirectorPacket
            {
                Kind = "answer",
                QuestionID = SelectedQuestion?.Id,
                Text = text
            });
            SelectedQuestion?.Answers.Add(text);
            Draft = "";
            Status = LocalizationManager.Instance.IsChinese ? "回答已发送" : "Answer sent";
        }
        catch (Exception exception)
        {
            Status = exception.Message;
        }
    }

    private void Receive(DirectorPacket packet)
    {
        HostPacketReceived?.Invoke(packet);
        if (packet.HostBoardOpen is { } isOpen) HostBoardOpen = isOpen;
        if (!string.IsNullOrWhiteSpace(packet.Mode)) RemoteMode = packet.Mode;
        if (packet.Kind == "answer" && packet.Text is not null)
        {
            SelectedQuestion?.Answers.Add(packet.Text);
            Status = LocalizationManager.Instance.IsChinese ? "已收到控制端回答" : "Answer received from controller";
            return;
        }
        if ((packet.Kind != "question" && packet.Kind != "snapshot") || string.IsNullOrWhiteSpace(packet.QuestionID) || packet.Text is null) return;

        var question = Questions.FirstOrDefault(item => item.Id == packet.QuestionID);
        if (question is null)
        {
            question = new RemoteQuestionViewModel(packet.QuestionID, packet.Text);
            Questions.Add(question);
        }
        else
        {
            question.Text = packet.Text;
        }
        SelectedQuestion = question;
    }

    private void PreviousQuestion() { var index = SelectedQuestionIndex; if (index > 0) SelectedQuestion = Questions[index - 1]; }
    private void NextQuestion() { var index = SelectedQuestionIndex; if (index >= 0 && index < Questions.Count - 1) SelectedQuestion = Questions[index + 1]; }

    private static string LocalizeStatus(string status)
    {
        if (!LocalizationManager.Instance.IsChinese) return status;
        if (status.StartsWith("Connecting to ", StringComparison.OrdinalIgnoreCase)) return "正在连接 Host…";
        if (status.Equals("Connected to host", StringComparison.OrdinalIgnoreCase)) return "已连接 Host";
        if (status.Equals("Disconnected", StringComparison.OrdinalIgnoreCase)) return "连接已断开";
        if (status.StartsWith("Host listening on port ", StringComparison.OrdinalIgnoreCase)) return "Host 服务已启动，正在等待控制端连接";
        if (status.StartsWith("Host error:", StringComparison.OrdinalIgnoreCase)) return "Host 服务异常：" + status[11..].Trim();
        return status;
    }

    private static BitmapImage CreateQrCode(string value)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(value, QRCodeGenerator.ECCLevel.M);
        var bytes = new PngByteQRCode(data).GetGraphic(8);
        using var stream = new MemoryStream(bytes);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        return image;
    }
}

public sealed class RemoteQuestionViewModel(string id, string text) : ObservableObject
{
    private string _text = text;
    public string Id { get; } = id;
    public ObservableCollection<string> Answers { get; } = [];
    public string Text
    {
        get => _text;
        set => SetProperty(ref _text, value);
    }
}
