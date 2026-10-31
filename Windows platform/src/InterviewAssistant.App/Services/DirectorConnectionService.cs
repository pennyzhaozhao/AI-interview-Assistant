using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace InterviewAssistant.Services;

public sealed class DirectorPacket
{
    public long Sequence { get; set; }
    public string Kind { get; set; } = "hello";
    public string? QuestionID { get; set; }
    public string? Text { get; set; }
    public string? Mode { get; set; }
    public bool? HostBoardOpen { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class DirectorConnectionService : IAsyncDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(8) };
    private string? _baseUrl;
    private long _lastSequence;
    private CancellationTokenSource? _connectionCancellation;

    public event Action<DirectorPacket>? PacketReceived;
    public event Action<string>? StatusChanged;
    public bool IsConnected => _baseUrl is not null;

    public async Task ConnectAsync(string host, int port = 9999, CancellationToken cancellationToken = default)
    {
        await DisconnectAsync();
        var cleanHost = host.Trim().Trim(',', '，', ';', '；');
        if (cleanHost.Length == 0) throw new InvalidOperationException("Enter the Host IP address.");

        StatusChanged?.Invoke($"Connecting to {cleanHost}…");
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _connectionCancellation = cancellation;
        _baseUrl = $"http://{cleanHost}:{port}";
        using var response = await _http.GetAsync($"{_baseUrl}/api/state?after=0", cancellation.Token);
        response.EnsureSuccessStatusCode();
        StatusChanged?.Invoke("Connected to host");
        _ = PollLoopAsync(cancellation.Token);
    }

    public async Task SendAsync(DirectorPacket packet, CancellationToken cancellationToken = default)
    {
        if (_baseUrl is null) throw new InvalidOperationException("Connect to a Host first.");
        using var response = await _http.PostAsJsonAsync($"{_baseUrl}/api/send", packet, JsonOptions, cancellationToken);
        response.EnsureSuccessStatusCode();
    }

    public Task DisconnectAsync()
    {
        _connectionCancellation?.Cancel();
        _connectionCancellation?.Dispose();
        _connectionCancellation = null;
        _baseUrl = null;
        _lastSequence = 0;
        StatusChanged?.Invoke("Disconnected");
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        _ = DisconnectAsync();
        return ValueTask.CompletedTask;
    }

    public static string GetLocalIPv4Address()
    {
        foreach (var networkInterface in NetworkInterface.GetAllNetworkInterfaces()
                     .Where(item => item.OperationalStatus == OperationalStatus.Up && item.NetworkInterfaceType != NetworkInterfaceType.Loopback))
        {
            foreach (var address in networkInterface.GetIPProperties().UnicastAddresses)
            {
                if (address.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var bytes = address.Address.GetAddressBytes();
                if (bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31))
                {
                    return address.Address.ToString();
                }
            }
        }
        return "No private IPv4 address detected";
    }

    private async Task PollLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var baseUrl = _baseUrl;
                if (baseUrl is null) break;
                using var response = await _http.GetAsync($"{baseUrl}/api/state?after={_lastSequence}", cancellationToken);
                response.EnsureSuccessStatusCode();
                var state = await response.Content.ReadFromJsonAsync<DirectorState>(JsonOptions, cancellationToken);
                if (state is not null)
                {
                    foreach (var packet in state.Packets)
                    {
                        _lastSequence = Math.Max(_lastSequence, packet.Sequence);
                        PacketReceived?.Invoke(packet);
                    }
                    PacketReceived?.Invoke(new DirectorPacket { Kind = "state", HostBoardOpen = state.HostBoardOpen, Mode = state.Mode });
                }
                await Task.Delay(650, cancellationToken);
            }
            if (!cancellationToken.IsCancellationRequested) StatusChanged?.Invoke("The Host closed the connection");
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception exception)
        {
            StatusChanged?.Invoke($"Connection error: {exception.Message}");
        }
    }

    private sealed class DirectorState
    {
        public List<DirectorPacket> Packets { get; set; } = [];
        public bool HostBoardOpen { get; set; }
        public string Mode { get; set; } = "director";
    }
}
