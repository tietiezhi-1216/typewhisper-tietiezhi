using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace TypeWhisper.Plugin.Tietiezhi;

// Only collects a callback in memory. Token exchange and secret/settings writes stay
// in an explicit host configuration action, never in this background listener.
internal sealed class OAuthLoginSession : IDisposable
{
    private sealed record CallbackResult(string? Code = null, string? Error = null, bool Denied = false);
    private readonly CancellationTokenSource timeout;
    private readonly TcpListener? listener;
    private readonly Task<CallbackResult>? callback;
    private int disposed;
    public string Verifier { get; } = Protocol.Base64Url(RandomNumberGenerator.GetBytes(32));
    private string State { get; } = Protocol.Base64Url(RandomNumberGenerator.GetBytes(32));
    private string Id { get; } = Guid.NewGuid().ToString("N");
    public string LinkSettingId => "oauth-link-" + Id;
    public string CallbackSettingId => "oauth-callback-" + Id;
    public Uri Authorization { get; }
    public bool ManualOnly => listener == null;
    public bool Expired => timeout.IsCancellationRequested;
    public OAuthLoginSession(CancellationToken lifetime, TimeSpan? duration = null)
    {
        timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        timeout.CancelAfter(duration ?? TimeSpan.FromMinutes(10));
        Authorization = Antigravity.Authorization(Verifier, State);
        var local = new TcpListener(IPAddress.Loopback, 36742);
        try { local.Start(); listener = local; }
        catch (SocketException) { local.Stop(); } // A busy port must not prevent manual cross-device login.
        if (listener != null) callback = Receive(timeout.Token);
    }
    public bool IsSetting(string id) => id == LinkSettingId || id == CallbackSettingId;
    public string? GetCode(string? pastedCallback)
    {
        if (Expired) throw new InvalidOperationException("登录会话已取消或超时，请重新点击登录。链接有效期为 10 分钟。");
        if (!string.IsNullOrWhiteSpace(pastedCallback))
        {
            if (pastedCallback.Length > 16_384 || !Uri.TryCreate(pastedCallback.Trim(), UriKind.Absolute, out var uri))
                throw new InvalidOperationException("请粘贴完整的 localhost 回调链接，不是 Google 登录链接或单独的授权码。");
            return Protocol.Callback(uri, State);
        }
        if (callback is not { IsCompletedSuccessfully: true }) return null;
        var result = callback.Result;
        if (result.Denied) throw new OAuthDeniedException();
        if (result.Error != null) throw new InvalidOperationException(result.Error);
        return result.Code;
    }
    private async Task<CallbackResult> Receive(CancellationToken ct)
    {
        try
        {
            while (true)
            {
                using var client = await listener!.AcceptTcpClientAsync(ct);
                using var perClient = CancellationTokenSource.CreateLinkedTokenSource(ct);
                perClient.CancelAfter(TimeSpan.FromSeconds(5));
                CallbackResult? result = null;
                try
                {
                    var stream = client.GetStream();
                    var request = new List<byte>(); var b = new byte[1];
                    while (request.Count < 16_384)
                    {
                        if (await stream.ReadAsync(b, perClient.Token) == 0) break;
                        request.Add(b[0]);
                        if (request.Count >= 4 && request.TakeLast(4).SequenceEqual(new byte[] { 13, 10, 13, 10 })) break;
                    }
                    var line = Encoding.ASCII.GetString(request.ToArray()).Split("\r\n")[0].Split(' ');
                    try
                    {
                        if (request.Count >= 16_384 || line.Length != 3 || line[0] != "GET" || !line[1].StartsWith('/') || line[1].StartsWith("//"))
                            throw new InvalidOperationException();
                        result = new(Protocol.Callback(new Uri("http://localhost:36742" + line[1]), State));
                    }
                    catch (OAuthDeniedException) { result = new(Denied: true); }
                    catch (Exception e) when (e is InvalidOperationException or UriFormatException) { }
                    var valid = result?.Code != null;
                    var body = valid ? "Authorization callback received. Return to TypeWhisper and click Complete login."
                        : "Invalid or denied callback. Return to TypeWhisper to check the login status.";
                    var bytes = Encoding.UTF8.GetBytes(body);
                    var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {(valid ? "200 OK" : "400 Bad Request")}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {bytes.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
                    await stream.WriteAsync(header, perClient.Token); await stream.WriteAsync(bytes, perClient.Token);
                }
                // A scanner, disconnected browser or slow client must not end the whole login.
                catch (Exception e) when (e is IOException or SocketException or OperationCanceledException) { ct.ThrowIfCancellationRequested(); }
                if (result != null) return result;
            }
        }
        catch (Exception e) when (e is OperationCanceledException or SocketException or ObjectDisposedException)
        {
            return new(Error: ct.IsCancellationRequested ? "登录会话已取消或超时，请重新登录。" : "本机回调监听失败，请粘贴回调链接完成登录。");
        }
        finally { listener!.Stop(); }
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        timeout.Cancel(); listener?.Stop(); timeout.Dispose();
    }
}
