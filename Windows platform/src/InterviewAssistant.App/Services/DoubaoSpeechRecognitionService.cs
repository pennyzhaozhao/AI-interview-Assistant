using System.IO;
using System.IO.Compression;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using NAudio.Wave;

namespace InterviewAssistant.Services;

internal sealed class DoubaoSpeechRecognitionService : IDisposable
{
    private ClientWebSocket? _socket;
    private IWaveIn? _capture;
    private CancellationTokenSource? _cancellation;
    private int _sequence;
    private double _resamplePosition;
    private readonly SemaphoreSlim _sendGate = new(1, 1);

    public event Action<string>? Recognized;
    public event Action<string>? PartialRecognized;
    public event Action<string>? StatusChanged;

    public async Task<bool> StartAsync(string languageCode, bool systemAudio)
    {
        Stop();
        var store = AppServices.Current.DataStore;
        var appId = AppServices.Current.Credentials.Read("speech-app-id").Trim();
        var token = AppServices.Current.Credentials.Read("speech-access-token").Trim();
        var resource = store.Data.Preferences.SpeechResourceId.Trim();
        if (appId.Length == 0 || token.Length == 0 || resource.Length == 0)
        {
            StatusChanged?.Invoke("Enter the Doubao Voice App ID, Access Token, and recognition model first.");
            return false;
        }

        try
        {
            _cancellation = new CancellationTokenSource();
            _socket = await ConnectAsync(appId, token, resource, TimeSpan.FromSeconds(25), _cancellation.Token);
            await SendInitializationAsync(languageCode.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-CN" : "en-US", _cancellation.Token);
            _ = ReceiveLoopAsync(_cancellation.Token);
            StartCapture(systemAudio);
            StatusChanged?.Invoke(systemAudio ? "Listening to system audio with Doubao Voice…" : "Listening with Doubao Voice…");
            return true;
        }
        catch (Exception exception)
        {
            Stop();
            StatusChanged?.Invoke($"Doubao Voice could not start: {FriendlyError(exception)}");
            return false;
        }
    }

    internal static async Task<ClientWebSocket> ConnectAsync(string appId, string token, string resource, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var socket = new ClientWebSocket();
        var requestId = Guid.NewGuid().ToString("N");
        socket.Options.SetRequestHeader("X-Api-Request-Id", requestId);
        socket.Options.SetRequestHeader("X-Api-Connect-Id", requestId);
        socket.Options.SetRequestHeader("X-Api-Resource-Id", resource);
        socket.Options.SetRequestHeader("X-Api-Sequence", "-1");
        socket.Options.SetRequestHeader("X-Api-App-Key", appId);
        socket.Options.SetRequestHeader("X-Api-Access-Key", token);
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        try
        {
            await socket.ConnectAsync(new Uri("wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"), timeoutSource.Token);
            return socket;
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    internal static string FriendlyError(Exception exception) => exception is OperationCanceledException
        ? "connection timed out. Check that Windows can access openspeech.bytedance.com and that no proxy/firewall is blocking WebSocket traffic."
        : exception.Message;

    internal static async Task TestConnectionAsync(string appId, string token, string resource, CancellationToken cancellationToken)
    {
        using var service = new DoubaoSpeechRecognitionService();
        service._cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        service._socket = await ConnectAsync(appId, token, resource, TimeSpan.FromSeconds(25), service._cancellation.Token);
        await service.SendInitializationAsync("zh-CN", service._cancellation.Token);
        await Task.Delay(900, service._cancellation.Token);
        if (service._socket.State != WebSocketState.Open) throw new WebSocketException("The provider closed the WebSocket after initialization. Check the App ID, token, and selected plan.");
    }

    private async Task SendInitializationAsync(string language, CancellationToken cancellationToken)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(new
        {
            user = new { uid = $"user_{Guid.NewGuid():N}" },
            audio = new { format = "pcm", codec = "raw", rate = 16000, bits = 16, channel = 1, language },
            request = new
            {
                model_name = "bigmodel", enable_itn = true, enable_punc = true, enable_ddc = true,
                show_utterances = true, enable_accelerate_text = true, enable_nonstream = true,
                end_window_size = 900, force_to_speech_time = 1000
            }
        });
        await SendFrameAsync(0x01, 0x01, 0x01, 0x01, Interlocked.Increment(ref _sequence), Gzip(payload), cancellationToken);
    }

    private void StartCapture(bool systemAudio)
    {
        _capture = systemAudio
            ? new WasapiLoopbackCapture()
            : new WaveInEvent { WaveFormat = new WaveFormat(16000, 16, 1), BufferMilliseconds = 200 };
        _capture.DataAvailable += Capture_DataAvailable;
        _capture.RecordingStopped += (_, args) => { if (args.Exception is not null) StatusChanged?.Invoke(args.Exception.Message); };
        _capture.StartRecording();
    }

    private async void Capture_DataAvailable(object? sender, WaveInEventArgs e)
    {
        var capture = _capture;
        var socket = _socket;
        var cancellation = _cancellation;
        if (capture is null || socket?.State != WebSocketState.Open || cancellation is null) return;
        try
        {
            var pcm = capture is WasapiLoopbackCapture loopback
                ? ConvertLoopbackToPcm16(e.Buffer.AsSpan(0, e.BytesRecorded), loopback.WaveFormat)
                : e.Buffer.AsSpan(0, e.BytesRecorded).ToArray();
            if (pcm.Length == 0) return;
            await SendFrameAsync(0x02, 0x01, 0x00, 0x01, Interlocked.Increment(ref _sequence), Gzip(pcm), cancellation.Token);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            StatusChanged?.Invoke($"Doubao audio upload failed: {exception.Message}");
        }
    }

    private byte[] ConvertLoopbackToPcm16(ReadOnlySpan<byte> source, WaveFormat format)
    {
        var channels = Math.Max(1, format.Channels);
        var sourceRate = Math.Max(1, format.SampleRate);
        var frameBytes = format.BitsPerSample / 8 * channels;
        if (frameBytes <= 0) return [];
        var frames = source.Length / frameBytes;
        var ratio = sourceRate / 16000d;
        var samples = new List<short>((int)(frames / ratio) + 1);
        while (_resamplePosition < frames)
        {
            var frame = Math.Min(frames - 1, (int)_resamplePosition);
            double mono = 0;
            for (var channel = 0; channel < channels; channel++)
            {
                var offset = frame * frameBytes + channel * format.BitsPerSample / 8;
                mono += format.Encoding == WaveFormatEncoding.IeeeFloat
                    ? BitConverter.ToSingle(source.Slice(offset, 4))
                    : BitConverter.ToInt16(source.Slice(offset, 2)) / 32768d;
            }
            mono /= channels;
            samples.Add((short)Math.Clamp(mono * short.MaxValue, short.MinValue, short.MaxValue));
            _resamplePosition += ratio;
        }
        _resamplePosition -= frames;
        var bytes = new byte[samples.Count * 2];
        Buffer.BlockCopy(samples.ToArray(), 0, bytes, 0, bytes.Length);
        return bytes;
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        var socket = _socket;
        if (socket is null) return;
        var buffer = new byte[128 * 1024];
        try
        {
            while (!cancellationToken.IsCancellationRequested && socket.State == WebSocketState.Open)
            {
                using var message = new MemoryStream();
                WebSocketReceiveResult result;
                do
                {
                    result = await socket.ReceiveAsync(buffer, cancellationToken);
                    if (result.MessageType == WebSocketMessageType.Close) return;
                    message.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);
                HandleResponse(message.ToArray());
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { StatusChanged?.Invoke($"Doubao Voice disconnected: {exception.Message}"); }
    }

    private void HandleResponse(byte[] frame)
    {
        if (frame.Length < 4) return;
        var type = frame[1] >> 4;
        if (type == 0x0F)
        {
            var message = frame.Length > 12 ? Encoding.UTF8.GetString(frame, 12, frame.Length - 12) : "Unknown provider error";
            StatusChanged?.Invoke($"Doubao Voice error: {message}");
            return;
        }
        var flags = frame[1] & 0x0F;
        var offset = (frame[0] & 0x0F) * 4;
        if ((flags & 0x01) != 0) offset += 4;
        if ((flags & 0x04) != 0) offset += 4;
        if (frame.Length < offset + 4) return;
        var size = ReadInt32(frame, offset);
        offset += 4;
        if (size <= 0 || frame.Length < offset + size) return;
        var payload = frame.AsSpan(offset, size).ToArray();
        if ((frame[2] & 0x0F) == 1) payload = Gunzip(payload);
        try
        {
            using var document = JsonDocument.Parse(payload);
            var root = document.RootElement;
            if (root.TryGetProperty("payload_msg", out var nested) && nested.ValueKind == JsonValueKind.String)
            {
                using var nestedDocument = JsonDocument.Parse(nested.GetString() ?? "{}");
                EmitResult(nestedDocument.RootElement);
            }
            else EmitResult(root);
        }
        catch { }
    }

    private void EmitResult(JsonElement root)
    {
        var text = ExtractText(root);
        if (string.IsNullOrWhiteSpace(text)) return;
        var definite = root.ToString().Contains("\"definite\":true", StringComparison.OrdinalIgnoreCase);
        if (definite) Recognized?.Invoke(text.Trim());
        else PartialRecognized?.Invoke(text.Trim());
    }

    private static string ExtractText(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            if (element.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String) return text.GetString() ?? "";
            if (element.TryGetProperty("result", out var result)) return ExtractText(result);
            if (element.TryGetProperty("utterances", out var utterances)) return ExtractText(utterances);
            foreach (var property in element.EnumerateObject())
            {
                var found = ExtractText(property.Value);
                if (found.Length > 0) return found;
            }
        }
        if (element.ValueKind == JsonValueKind.Array) return string.Concat(element.EnumerateArray().Select(ExtractText));
        return "";
    }

    private async Task SendFrameAsync(byte messageType, byte flags, byte serialization, byte compression, int sequence, byte[] payload, CancellationToken cancellationToken)
    {
        var socket = _socket ?? throw new InvalidOperationException("Doubao socket is not connected.");
        await _sendGate.WaitAsync(cancellationToken);
        try
        {
        using var stream = new MemoryStream();
        stream.WriteByte(0x11);
        stream.WriteByte((byte)((messageType << 4) | flags));
        stream.WriteByte((byte)((serialization << 4) | compression));
        stream.WriteByte(0);
        WriteInt32(stream, sequence);
        WriteInt32(stream, payload.Length);
        stream.Write(payload);
        await socket.SendAsync(stream.ToArray(), WebSocketMessageType.Binary, true, cancellationToken);
        }
        finally
        {
            _sendGate.Release();
        }
    }

    private static byte[] Gzip(byte[] data) { using var output = new MemoryStream(); using (var gzip = new GZipStream(output, CompressionLevel.Fastest, true)) gzip.Write(data); return output.ToArray(); }
    private static byte[] Gunzip(byte[] data) { using var input = new MemoryStream(data); using var gzip = new GZipStream(input, CompressionMode.Decompress); using var output = new MemoryStream(); gzip.CopyTo(output); return output.ToArray(); }
    private static void WriteInt32(Stream stream, int value) { stream.WriteByte((byte)(value >> 24)); stream.WriteByte((byte)(value >> 16)); stream.WriteByte((byte)(value >> 8)); stream.WriteByte((byte)value); }
    private static int ReadInt32(byte[] data, int offset) => (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];

    public void Stop()
    {
        try { _capture?.StopRecording(); } catch { }
        _capture?.Dispose();
        _capture = null;
        _cancellation?.Cancel();
        _cancellation?.Dispose();
        _cancellation = null;
        _socket?.Abort();
        _socket?.Dispose();
        _socket = null;
        _sequence = 0;
        _resamplePosition = 0;
    }

    public void Dispose() => Stop();
}
