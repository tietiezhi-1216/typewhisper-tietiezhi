using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TypeWhisper.PluginSDK;

namespace TypeWhisper.Plugin.Tietiezhi;

internal sealed record Credentials(string AccessToken, string RefreshToken, DateTimeOffset ExpiresAt, string Project, string? Email, bool Fallback);
internal sealed class ApiException(string stage, int status) : Exception($"{stage}：HTTP {status}。请检查账号权限、额度或服务状态。")
{
    public int Status { get; } = status;
}
internal sealed class Antigravity(HttpClient http, IPluginHostServices host, Action<Uri>? openBrowser = null)
{
    internal const string ClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com";
    // Public desktop OAuth client from pi-antigravity, not a user credential.
    private const string ClientSecret = "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";
    internal const string Redirect = "http://localhost:36742/oauth-callback";
    internal static readonly string[] Endpoints = ["https://daily-cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.sandbox.googleapis.com", "https://cloudcode-pa.googleapis.com"];
    private const string Secret = "antigravity-oauth-v1";
    private Credentials? credentials;
    private DateTimeOffset projectCheckedUntil;
    public bool LoggedIn => credentials != null;
    public async Task Load()
    {
        try
        {
            var saved = JsonSerializer.Deserialize<Credentials>(await host.LoadSecretAsync(Secret) ?? "null");
            credentials = saved is not null && !string.IsNullOrWhiteSpace(saved.RefreshToken) && !string.IsNullOrWhiteSpace(saved.Project) ? saved : null;
        }
        catch (JsonException) { credentials = null; } // A damaged OAuth record must not disable MiMo.
    }
    private async Task Save(Credentials value) { await host.StoreSecretAsync(Secret, JsonSerializer.Serialize(value)); credentials = value; }
    public async Task Logout() { await host.DeleteSecretAsync(Secret); credentials = null; projectCheckedUntil = default; }
    private async Task<string> Read(HttpResponseMessage response, string stage, CancellationToken ct)
    {
        if (!response.IsSuccessStatusCode) throw new ApiException(stage, (int)response.StatusCode);
        // Responses and provider diagnostics can contain sensitive data: never log them.
        if (response.Content.Headers.ContentLength > 16_000_000) throw new InvalidOperationException(stage + "：响应过大。");
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var output = new MemoryStream(); var buffer = new byte[8192]; int n;
        while ((n = await stream.ReadAsync(buffer, ct)) > 0)
        {
            if (output.Length + n > 16_000_000) throw new InvalidOperationException(stage + "：响应过大。");
            output.Write(buffer, 0, n);
        }
        return Encoding.UTF8.GetString(output.ToArray());
    }
    private async Task<JsonObject> Token(Dictionary<string, string> fields, CancellationToken ct)
    {
        fields["client_id"] = ClientId; fields["client_secret"] = ClientSecret;
        using var response = await http.PostAsync("https://oauth2.googleapis.com/token", new FormUrlEncodedContent(fields), ct);
        return JsonNode.Parse(await Read(response, "Google 授权", ct)) as JsonObject ?? throw new InvalidOperationException("授权响应无效。");
    }
    private static (string Access, double Seconds) TokenValues(JsonObject token)
    {
        var access = token["access_token"]?.GetValue<string>(); var seconds = token["expires_in"]?.GetValue<double>() ?? 0;
        if (string.IsNullOrWhiteSpace(access) || !double.IsFinite(seconds) || seconds <= 0 || seconds > 31_536_000) throw new InvalidOperationException("授权响应无效。");
        return (access, seconds);
    }
    internal static Uri Authorization(string verifier, string state)
    {
        var scopes = new[] { "aicode", "cloud-platform", "userinfo.email", "userinfo.profile", "cclog", "experimentsandconfigs" };
        var fields = new Dictionary<string, string> {
            ["client_id"] = ClientId, ["response_type"] = "code", ["redirect_uri"] = Redirect,
            ["scope"] = string.Join(' ', scopes.Select(s => "https://www.googleapis.com/auth/" + s)),
            ["code_challenge"] = Protocol.Challenge(verifier), ["code_challenge_method"] = "S256", ["state"] = state,
            ["access_type"] = "offline", ["prompt"] = "consent"
        };
        return new Uri("https://accounts.google.com/o/oauth2/v2/auth?" + string.Join('&', fields.Select(p => Uri.EscapeDataString(p.Key) + "=" + Uri.EscapeDataString(p.Value))));
    }
    public async Task Login(CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromMinutes(3));
        var token = timeout.Token;
        var verifier = Protocol.Base64Url(RandomNumberGenerator.GetBytes(32)); var state = Protocol.Base64Url(RandomNumberGenerator.GetBytes(32));
        // Bind before opening browser, only to loopback. No elevated URL ACL or firewall exception.
        using var listener = new TcpListener(IPAddress.Loopback, 36742); listener.Start();
        var authorization = Authorization(verifier, state);
        if (openBrowser != null) openBrowser(authorization);
        else Process.Start(new ProcessStartInfo(authorization.AbsoluteUri) { UseShellExecute = true });
        string? code = null;
        while (code == null)
        {
            using var client = await listener.AcceptTcpClientAsync(token);
            using var perClient = CancellationTokenSource.CreateLinkedTokenSource(token); perClient.CancelAfter(TimeSpan.FromSeconds(5));
            var stream = client.GetStream();
            var requestBytes = new List<byte>();
            // Bound untrusted request headers (including a line without a newline).
            while (requestBytes.Count < 16_384)
            {
                var b = new byte[1]; if (await stream.ReadAsync(b, perClient.Token) == 0) break;
                requestBytes.Add(b[0]);
                if (requestBytes.Count >= 4 && requestBytes.TakeLast(4).SequenceEqual(new byte[] { 13, 10, 13, 10 })) break;
            }
            var line = Encoding.ASCII.GetString(requestBytes.ToArray()).Split("\r\n")[0].Split(' ');
            bool valid = false, denied = false;
            try
            {
                if (requestBytes.Count >= 16_384 || line.Length != 3 || line[0] != "GET" || !line[1].StartsWith('/')) throw new InvalidOperationException();
                code = Protocol.Callback(new Uri("http://localhost:36742" + line[1]), state); valid = true;
            }
            catch (OAuthDeniedException) { denied = true; }
            catch (Exception e) when (e is InvalidOperationException or UriFormatException) { }
            var body = valid ? "Authorization callback received. Return to TypeWhisper to check the result." : "Invalid callback. Return to TypeWhisper and try again.";
            var bytes = Encoding.UTF8.GetBytes(body);
            var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {(valid ? "200 OK" : "400 Bad Request")}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {bytes.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
            await stream.WriteAsync(header, token); await stream.WriteAsync(bytes, token);
            if (denied) throw new OAuthDeniedException();
        }
        var response = await Token(new() { ["code"] = code, ["code_verifier"] = verifier, ["grant_type"] = "authorization_code", ["redirect_uri"] = Redirect }, token);
        var (access, seconds) = TokenValues(response); var refresh = response["refresh_token"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(refresh)) throw new InvalidOperationException("Google 未返回刷新凭据，请重新授权。");
        string? email = null;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://www.googleapis.com/oauth2/v1/userinfo?alt=json");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", access);
            using var result = await http.SendAsync(request, token);
            email = JsonNode.Parse(await Read(result, "账号信息", token))?["email"]?.GetValue<string>();
        }
        catch (Exception e) when (e is not OperationCanceledException) { }
        token.ThrowIfCancellationRequested();
        await Save(new(access, refresh, DateTimeOffset.UtcNow.AddSeconds(seconds), Protocol.StableProject(email ?? Protocol.Challenge(refresh)), email, true));
        projectCheckedUntil = default;
    }
    private async Task<Credentials> Current(CancellationToken ct)
    {
        var value = credentials ?? throw new InvalidOperationException("请先登录 Antigravity。");
        if (value.ExpiresAt < DateTimeOffset.UtcNow.AddSeconds(60))
        {
            var token = await Token(new() { ["refresh_token"] = value.RefreshToken, ["grant_type"] = "refresh_token" }, ct);
            var (access, seconds) = TokenValues(token);
            value = value with { AccessToken = access, RefreshToken = token["refresh_token"]?.GetValue<string>() ?? value.RefreshToken, ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(seconds) };
            ct.ThrowIfCancellationRequested(); await Save(value);
        }
        if (value.Fallback && projectCheckedUntil < DateTimeOffset.UtcNow)
        {
            string? project = null;
            foreach (var action in new[] { "loadCodeAssist", "listCloudAICompanionProjects" })
            {
                bool success = false;
                foreach (var endpoint in Endpoints)
                {
                    try
                    {
                        var body = action == "loadCodeAssist" ? new JsonObject { ["metadata"] = new JsonObject { ["ideType"] = "ANTIGRAVITY" } } : new JsonObject();
                        var obj = JsonNode.Parse(await Api(endpoint, action, body, value.AccessToken, ct)) as JsonObject ?? new();
                        success = true; project ??= Protocol.Project(obj);
                    }
                    catch (Exception e) when (e is not OperationCanceledException) { }
                }
                if (project != null || !success) break;
            }
            if (project != null) { value = value with { Project = project, Fallback = false }; ct.ThrowIfCancellationRequested(); await Save(value); }
            projectCheckedUntil = DateTimeOffset.UtcNow.AddMinutes(30);
        }
        return value;
    }
    private async Task<string> Api(string endpoint, string action, JsonObject body, string access, CancellationToken ct)
    {
        if (!Endpoints.Contains(endpoint) || !new[] { "loadCodeAssist", "listCloudAICompanionProjects", "fetchAvailableModels", "streamGenerateContent" }.Contains(action)) throw new InvalidOperationException("不受信任的 API 路由。");
        var suffix = action == "streamGenerateContent" ? "?alt=sse" : "";
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint + "/v1internal:" + action + suffix);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", access);
        request.Headers.TryAddWithoutValidation("User-Agent", "antigravity/1.20.5 windows/x64");
        request.Headers.TryAddWithoutValidation("X-Goog-Api-Client", "google-cloud-sdk vscode_cloudshelleditor/0.1");
        request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        return await Read(response, action, ct);
    }
    public async Task<List<Model>> Models(CancellationToken ct)
    {
        var value = await Current(ct); var catalogs = new List<List<Model>>(); var failures = new List<string>();
        foreach (var endpoint in Endpoints)
        {
            try
            {
                var obj = JsonNode.Parse(await Api(endpoint, "fetchAvailableModels", new() { ["project"] = value.Project }, value.AccessToken, ct)) as JsonObject ?? new();
                catalogs.Add(Protocol.Catalog(obj, endpoint));
            }
            catch (ApiException e) when (e.Status is 401 or 429) { throw; }
            catch (Exception e) when (e is not OperationCanceledException) { failures.Add(new Uri(endpoint).Host + ": " + (e is ApiException a ? "HTTP " + a.Status : "无有效模型")); }
        }
        var merged = Protocol.Merge(catalogs);
        if (merged.Count == 0) throw new InvalidOperationException("没有可用模型。" + string.Join("；", failures));
        return merged;
    }
    public async Task<string> Generate(Model model, string effort, string system, string text, CancellationToken ct)
    {
        var value = await Current(ct); var route = model.Resolve(effort);
        var trajectory = Guid.NewGuid().ToString(); bool claude = route.Id.StartsWith("claude-");
        var labels = new JsonObject { ["last_step_index"] = "0", ["request_id"] = trajectory + "-0", ["trajectory_id"] = trajectory,
            ["used_claude"] = claude ? "true" : "false", ["used_claude_conservative"] = claude ? "true" : "false", ["used_non_gemini_model"] = route.Id.StartsWith("gemini-") ? "false" : "true" };
        if (route.ModelEnum != null) labels["model_enum"] = route.ModelEnum;
        var body = new JsonObject {
            ["project"] = value.Project, ["model"] = route.Id, ["requestType"] = "agent", ["userAgent"] = "antigravity",
            ["requestId"] = $"agent/{Guid.NewGuid()}/{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}/{trajectory}/1",
            ["request"] = new JsonObject {
                ["systemInstruction"] = new JsonObject { ["role"] = "user", ["parts"] = new JsonArray(new JsonObject { ["text"] = system }) },
                ["contents"] = new JsonArray(new JsonObject { ["role"] = "user", ["parts"] = new JsonArray(new JsonObject { ["text"] = text }) }),
                ["generationConfig"] = new JsonObject { ["temperature"] = 0.2, ["maxOutputTokens"] = 32768, ["thinkingConfig"] = Protocol.Thinking(route.Id, effort) },
                ["sessionId"] = Random.Shared.NextInt64().ToString(), ["labels"] = labels
            }
        };
        // One generation request only: no endpoint/account switching on denial.
        return Protocol.GeneratedText(await Api(route.Endpoint, "streamGenerateContent", body, value.AccessToken, ct));
    }
}
