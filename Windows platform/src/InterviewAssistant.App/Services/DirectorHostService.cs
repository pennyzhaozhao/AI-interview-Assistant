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
                    await WriteHtmlAsync(stream, ControllerPageForCurrentLanguage(), cancellationToken);
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

    private static string ControllerPageForCurrentLanguage()
    {
        if (AppServices.Current.DataStore.Data.Preferences.Language.StartsWith("zh", StringComparison.OrdinalIgnoreCase)) return ControllerPage;
        return ControllerPage
            .Replace("lang=\"zh-CN\"", "lang=\"en\"")
            .Replace("Interview AI 导演控制端", "Interview AI Director Controller")
            .Replace("与 Host 同一网络即可实时控制", "Connect on the same network as the Host")
            .Replace("连接中…", "Connecting…")
            .Replace("当前问题 / QUESTION", "CURRENT QUESTION")
            .Replace("等待 Host 捕获问题…", "Waiting for the Host to capture a question…")
            .Replace("发送 MARKDOWN 内容", "SEND MARKDOWN CONTENT")
            .Replace("输入要显示在 Host 提示板上的回答，支持 Markdown…", "Enter an answer for the Host prompter. Markdown is supported…")
            .Replace("准备就绪", "Ready")
            .Replace("发送到提示板", "Send to Prompter")
            .Replace("Host 提示板已打开", "Host prompter is open")
            .Replace("Host 提示板未打开", "Host prompter is closed")
            .Replace("已连接 · ", "Connected · ")
            .Replace("导演模式", "Director mode")
            .Replace("AI 模式", "AI mode")
            .Replace("连接中断，正在重试…", "Connection lost. Retrying…")
            .Replace("发送中…", "Sending…")
            .Replace("已发送到 Host 提示板", "Sent to the Host prompter")
            .Replace("发送失败：", "Send failed: ");
    }
    private const string ControllerPage = """
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Interview AI Director</title>
<style>
*{box-sizing:border-box}body{margin:0;font-family:Inter,"Segoe UI","SimSun","宋体",serif;background:#f4f7fc;color:#142038}.shell{max-width:900px;margin:auto;padding:24px}.hero{display:flex;justify-content:space-between;align-items:center;margin-bottom:18px}.hero h1{font-size:28px;margin:0}.badge{padding:9px 14px;border-radius:999px;background:#eaf0fb;color:#71809a;font-weight:700}.badge.live{background:#e5f8ee;color:#199653}.card{background:#fff;border:1px solid #e3e9f2;border-radius:24px;padding:24px;margin-bottom:18px;box-shadow:0 12px 36px #213b6410}.label{color:#71809a;font-size:13px;font-weight:800;letter-spacing:.08em}.question-row{display:grid;grid-template-columns:46px 1fr 46px;gap:12px;align-items:center;margin-top:14px}.round{width:46px;height:46px;border:0;border-radius:50%;font-size:25px;background:#edf2f9;color:#63728c}.round:disabled{opacity:.35}.question{min-height:92px;padding:18px;border-radius:17px;background:#f5f7fb;font-size:20px;font-weight:700;line-height:1.45}.meta{color:#8290a8;font-size:13px;margin-top:10px;text-align:center}textarea{width:100%;min-height:230px;resize:vertical;border:1px solid #dce3ef;border-radius:17px;padding:17px;font:16px/1.55 inherit;outline:none}textarea:focus{border-color:#3672ff;box-shadow:0 0 0 3px #3672ff18}.actions{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-top:14px}.send{background:#326dff;color:#fff;border:0;border-radius:14px;padding:13px 25px;font-weight:800;font-size:15px}.status{color:#71809a}.empty{color:#99a5b7;font-weight:500}@media(max-width:600px){.shell{padding:14px}.hero h1{font-size:22px}.card{padding:17px;border-radius:19px}.question{font-size:17px}.question-row{grid-template-columns:38px 1fr 38px}.round{width:38px;height:38px}}
</style></head>
<body><main class="shell"><header class="hero"><div><h1>Interview AI 导演控制端</h1><div class="status">与 Host 同一网络即可实时控制</div></div><div id="hostBadge" class="badge">连接中…</div></header>
<section class="card"><div class="label">当前问题 / QUESTION</div><div class="question-row"><button id="prev" class="round" onclick="move(-1)">‹</button><div id="question" class="question"><span class="empty">等待 Host 捕获问题…</span></div><button id="next" class="round" onclick="move(1)">›</button></div><div id="questionMeta" class="meta">0 / 0</div></section>
<section class="card"><div class="label">发送 MARKDOWN 内容</div><textarea id="text" placeholder="输入要显示在 Host 提示板上的回答，支持 Markdown…"></textarea><div class="actions"><div id="status" class="status">准备就绪</div><button class="send" onclick="sendAnswer()">发送到提示板</button></div></section></main>
<script>
let sequence=0, questions=[], index=-1, boardOpen=false;
function render(){let q=questions[index], box=document.getElementById('question');box.innerHTML=q?escapeHtml(q.text):'<span class="empty">等待 Host 捕获问题…</span>';document.getElementById('questionMeta').textContent=q?`${index+1} / ${questions.length}`:`0 / 0`;document.getElementById('prev').disabled=index<=0;document.getElementById('next').disabled=index<0||index>=questions.length-1;let badge=document.getElementById('hostBadge');badge.textContent=boardOpen?'Host 提示板已打开':'Host 提示板未打开';badge.className='badge '+(boardOpen?'live':'');}
function escapeHtml(v){let d=document.createElement('div');d.textContent=v||'';return d.innerHTML.replace(/\n/g,'<br>')}
function move(delta){index=Math.max(0,Math.min(questions.length-1,index+delta));render()}
async function poll(){try{let r=await fetch('/api/state?after='+sequence,{cache:'no-store'});if(!r.ok)throw Error(r.status);let state=await r.json();boardOpen=!!state.hostBoardOpen;for(let p of state.packets||[]){sequence=Math.max(sequence,p.sequence||0);if((p.kind==='question'||p.kind==='snapshot')&&p.text){let existing=questions.findIndex(q=>q.id===(p.questionID||p.questionId));let item={id:p.questionID||p.questionId||String(p.sequence),text:p.text};if(existing>=0)questions[existing]=item;else{questions.push(item);index=questions.length-1}}}render();document.getElementById('status').textContent='已连接 · '+(state.mode==='director'?'导演模式':'AI 模式')}catch(e){document.getElementById('status').textContent='连接中断，正在重试…'}finally{setTimeout(poll,900)}}
async function sendAnswer(){let t=document.getElementById('text'),s=document.getElementById('status'),q=questions[index];if(!t.value.trim())return;s.textContent='发送中…';try{let r=await fetch('/api/send',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'answer',questionID:q?.id,text:t.value})});if(!r.ok)throw Error(r.status);t.value='';s.textContent='已发送到 Host 提示板'}catch(e){s.textContent='发送失败：'+e.message}}
render();poll();
</script></body></html>
""";
}
