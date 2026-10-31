using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace InterviewAssistant.Services;

public sealed class DirectorHostService : IAsyncDisposable
{
    private readonly object _gate = new();
    private readonly List<DirectorPacket> _packets = [];
    private TcpListener? _listener;
    private CancellationTokenSource? _cancellation;
    private long _sequence;
    private bool _hostBoardOpen;
    private string _mode = "director";

    public event Action<DirectorPacket>? PacketReceived;
    public event Action<string>? StatusChanged;
    public bool IsRunning => _listener is not null;

    public Task StartAsync(int port = 9999)
    {
        if (IsRunning) return Task.CompletedTask;
        _cancellation = new CancellationTokenSource();
        _listener = new TcpListener(IPAddress.Any, port);
        _listener.Start();
        _ = AcceptLoopAsync(_cancellation.Token);
        StatusChanged?.Invoke($"Host listening on port {port}");
        return Task.CompletedTask;
    }

    public void Publish(DirectorPacket packet)
    {
        lock (_gate)
        {
            packet.Sequence = ++_sequence;
            packet.CreatedAt = DateTimeOffset.UtcNow;
            if (packet.HostBoardOpen is { } open) _hostBoardOpen = open;
            if (!string.IsNullOrWhiteSpace(packet.Mode)) _mode = packet.Mode;
            _packets.Add(packet);
            if (_packets.Count > 300) _packets.RemoveRange(0, _packets.Count - 300);
        }
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        var listener = _listener;
        if (listener is null) return;
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(cancellationToken);
                _ = HandleClientAsync(client, cancellationToken);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { StatusChanged?.Invoke($"Host error: {exception.Message}"); }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken cancellationToken)
    {
        using (client)
        {
            try
            {
                using var stream = client.GetStream();
                using var reader = new StreamReader(stream, Encoding.UTF8, false, 4096, true);
                var requestLine = await reader.ReadLineAsync(cancellationToken);
                if (string.IsNullOrWhiteSpace(requestLine)) return;
                var parts = requestLine.Split(' ');
                if (parts.Length < 2) return;
                var method = parts[0];
                var target = parts[1];
                var contentLength = 0;
                string? line;
                while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync(cancellationToken)))
                {
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) int.TryParse(line[15..].Trim(), out contentLength);
                }
                var body = "";
                if (contentLength > 0)
                {
                    var buffer = new char[contentLength];
                    var read = 0;
                    while (read < contentLength)
                    {
                        var count = await reader.ReadAsync(buffer.AsMemory(read, contentLength - read), cancellationToken);
                        if (count == 0) break;
                        read += count;
                    }
                    body = new string(buffer, 0, read);
                }

                if (method == "GET" && target.StartsWith("/api/state", StringComparison.OrdinalIgnoreCase))
                {
                    var after = ParseAfter(target);
                    List<DirectorPacket> packets;
                    lock (_gate) packets = _packets.Where(item => item.Sequence > after).ToList();
                    await WriteJsonAsync(stream, new { packets, hostBoardOpen = _hostBoardOpen, mode = _mode }, cancellationToken);
                    return;
                }
                if (method == "POST" && target.StartsWith("/api/send", StringComparison.OrdinalIgnoreCase))
                {
                    var packet = JsonSerializer.Deserialize<DirectorPacket>(body, JsonOptions) ?? new DirectorPacket();
                    if (string.IsNullOrWhiteSpace(packet.Kind)) packet.Kind = "answer";
                    Publish(packet);
                    PacketReceived?.Invoke(packet);
                    await WriteJsonAsync(stream, new { ok = true }, cancellationToken);
                    return;
                }
                if (method == "GET")
                {
                    await WriteHtmlAsync(stream, ControllerPage, cancellationToken);
                    return;
                }
                await WriteResponseAsync(stream, "404 Not Found", "text/plain", "Not found", cancellationToken);
            }
            catch { }
        }
    }

    private static long ParseAfter(string target)
    {
        var marker = "after=";
        var index = target.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        return index >= 0 && long.TryParse(target[(index + marker.Length)..].Split('&')[0], out var value) ? value : 0;
    }

    private static Task WriteJsonAsync(Stream stream, object value, CancellationToken token) => WriteResponseAsync(stream, "200 OK", "application/json; charset=utf-8", JsonSerializer.Serialize(value, JsonOptions), token);
    private static Task WriteHtmlAsync(Stream stream, string value, CancellationToken token) => WriteResponseAsync(stream, "200 OK", "text/html; charset=utf-8", value, token);

    private static async Task WriteResponseAsync(Stream stream, string status, string type, string body, CancellationToken token)
    {
        var payload = Encoding.UTF8.GetBytes(body);
        var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nContent-Type: {type}\r\nContent-Length: {payload.Length}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, token);
        await stream.WriteAsync(payload, token);
    }

    public ValueTask DisposeAsync()
    {
        _cancellation?.Cancel();
        _listener?.Stop();
        _listener = null;
        _cancellation?.Dispose();
        _cancellation = null;
        return ValueTask.CompletedTask;
    }

    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
    private const string ControllerPage = """
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Interview AI Director</title><style>body{font-family:Segoe UI,sans-serif;background:#f3f6fb;color:#172238;max-width:760px;margin:40px auto;padding:20px}.card{background:white;border-radius:24px;padding:26px;box-shadow:0 12px 40px #1c315018}textarea{width:100%;min-height:240px;box-sizing:border-box;border:1px solid #dce3ef;border-radius:16px;padding:16px;font:16px Segoe UI}button{margin-top:16px;background:#2f6bff;color:white;border:0;border-radius:14px;padding:13px 24px;font-weight:700}#status{color:#71809a;margin-top:12px}</style></head><body><div class="card"><h1>Interview AI 导演控制端</h1><p>输入要发送到 Host 提示板的 Markdown 回答。</p><textarea id="text" placeholder="输入提示内容…"></textarea><button onclick="send()">发送</button><div id="status">已连接到 Host</div></div><script>async function send(){let t=document.getElementById('text');let s=document.getElementById('status');if(!t.value.trim())return;s.textContent='发送中…';try{let r=await fetch('/api/send',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'answer',text:t.value})});if(!r.ok)throw Error(r.status);t.value='';s.textContent='已发送';}catch(e){s.textContent='发送失败：'+e}}</script></body></html>
""";
}
