using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Tietiezhi.Install;
using TypeWhisper.Plugin.Tietiezhi;
using TypeWhisper.PluginSDK;
using TypeWhisper.PluginSDK.Models;

// Windows-only fixture used to test deferred updates without the real application.
if (Path.GetFileNameWithoutExtension(Environment.ProcessPath)?.Equals("TypeWhisper", StringComparison.OrdinalIgnoreCase) == true)
{
    if (args.Contains("--fixture-host")) await Task.Delay(3000);
    else if (Environment.GetEnvironmentVariable("TIETIEZHI_UPDATE_SMOKE_RESTART_MARKER") is { } marker) File.WriteAllText(marker, "restarted");
    return;
}
int passed = 0;
void Check(bool ok, string name) { if (!ok) throw new Exception("FAIL " + name); passed++; Console.WriteLine("PASS " + name); }
void Throws(Action action, string name) { try { action(); } catch { Check(true, name); return; } throw new Exception("FAIL expected throw " + name); }
async Task ThrowsAsync(Func<Task> action, string name) { try { await action(); } catch { Check(true, name); return; } throw new Exception("FAIL expected throw " + name); }
JsonObject Obj(string json) => JsonNode.Parse(json)!.AsObject();
Check(Protocol.Challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC7636 PKCE");
Check(Protocol.StableProject("user") == Protocol.StableProject("user") && Protocol.StableProject("user") != Protocol.StableProject("other"), "stable account routing");
var auth = Antigravity.Authorization("verifier", "state").AbsoluteUri;
Check(auth.Contains("code_challenge_method=S256") && auth.Contains("aicode") && auth.Contains("access_type=offline"), "OAuth scopes and PKCE");
Check(Protocol.Callback(new("http://localhost:36742/oauth-callback?code=hello&state=s"), "s") == "hello", "valid callback");
Throws(() => Protocol.Callback(new("http://localhost:36742/oauth-callback?code=c&state=wrong"), "s"), "reject bad state");
Throws(() => Protocol.Callback(new("http://localhost:36742/oauth-callback?code=c&state=s&state=s"), "s"), "reject duplicate state");
Throws(() => Protocol.Callback(new("http://localhost:36742/oauth-callback?code=c&code=d&state=s"), "s"), "reject duplicate code");
Throws(() => Protocol.Callback(new("http://localhost:36742/oauth-callback?error=denied&state=s"), "s"), "reject denied callback");
Throws(() => Protocol.Callback(new("http://localhost:36742/wrong?code=c&state=s"), "s"), "reject wrong path");
var catalogJson = """{"models":{"gemini-a-low":{"displayName":"Gemini A (Low)","model":"A_LOW"},"gemini-a-high":{"displayName":"Gemini A (High)"},"gemini-pro-agent":{"displayName":"Pro"},"gemini-a-image":{},"gemini-hidden":{"isInternal":true}}}""";
var catalog = Protocol.Catalog(Obj(catalogJson), Antigravity.Endpoints[2]);
Check(catalog.Count == 2, "catalog filters image and internal");
var a = catalog.Single(m => m.Id == "gemini-a");
Check(a.Variants.Count == 2 && a.Name == "Gemini A", "group reasoning variants");
Check(a.Resolve("off").Id == "gemini-a-low" && a.Resolve("high").Id == "gemini-a-high", "runtime variant routing");
Check(catalog.Single(m => m.Id == "gemini-3.1-pro").Resolve("high").Id == "gemini-pro-agent", "agent alias");
Check(a.Resolve("medium").Endpoint == Antigravity.Endpoints[2], "preserve successful endpoint");
var merged = Protocol.Merge([catalog, Protocol.Catalog(Obj(catalogJson), Antigravity.Endpoints[0])]);
Check(merged.Single(m => m.Id == "gemini-a").Resolve("low").Endpoint == Antigravity.Endpoints[2], "merge preserves first route");
Check(Protocol.Project(Obj("""{"projects":[{"projectId":"p"}]}""")) == "p", "nested project");
Check(Protocol.Project(Obj("{}")) == null, "missing project");
Check(Protocol.Thinking("gemini-3.1-pro", "high")["thinkingBudget"]!.GetValue<int>() == 10001, "pro budget");
Check(Protocol.Thinking("gemini-3.5-flash", "medium")["thinkingBudget"]!.GetValue<int>() == 4000, "flash budget");
Check(Protocol.Thinking("claude-opus", "high")["thinkingBudget"]!.GetValue<int>() == 1024, "claude budget");
Check(Protocol.Thinking("gemini-a", "off")["thinkingBudget"]!.GetValue<int>() == 0, "off budget");
string completion = """{"response":{"candidates":[{"content":{"parts":[{"thought":true,"text":"secret thought"},{"text":"正文"}]},"finishReason":"STOP"}]}}""";
Check(Protocol.GeneratedText(completion) == "正文", "JSON completion excludes thoughts");
Check(Protocol.GeneratedText("data: " + completion + "\r\n\r\ndata: [DONE]\r\n\r\n") == "正文", "SSE completion");
Throws(() => Protocol.GeneratedText(completion.Replace("STOP", "MAX_TOKENS")), "reject truncated output");
Throws(() => Protocol.GeneratedText("data: {\"error\":{\"code\":403}}\n\n"), "reject SSE error");
Throws(() => Protocol.GeneratedText(""), "reject empty output");
byte[] Wav(int seconds)
{
    using var stream = new MemoryStream(); using var writer = new BinaryWriter(stream); int count = seconds * 32000;
    writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(count + 36); writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
    writer.Write(16); writer.Write((ushort)1); writer.Write((ushort)1); writer.Write(16000); writer.Write(32000); writer.Write((ushort)2); writer.Write((ushort)16);
    writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(count); writer.Write(new byte[count]); return stream.ToArray();
}
Check(WavChunks.Parse(Wav(1)).Duration == 1, "WAV duration");
var longWav = WavChunks.Parse(Wav(181));
Check(longWav.Chunks.Count == 2 && WavChunks.Parse(longWav.Chunks[0]).Duration == 180, "long recording split");
Throws(() => WavChunks.Parse([]), "reject invalid WAV");
Throws(() => WavChunks.Parse(Wav(1)[..^1]), "reject truncated WAV");
var host = new FakeHost(); int calls = 0;
using var plugin = new TietiezhiPlugin(new HttpClient(new Handler(async (request, ct) => {
    calls++;
    if (request.RequestUri!.AbsolutePath.EndsWith("/models")) return Reply("{}");
    var body = Obj(await request.Content!.ReadAsStringAsync(ct));
    Check(request.Headers.Authorization?.Parameter == "mimo-test", "MiMo auth header");
    Check(body["asr_options"]?["language"]?.GetValue<string>() == "zh", "MiMo language normalization");
    Check(body["messages"]?[0]?["content"]?[0]?["input_audio"]?["data"]?.GetValue<string>().StartsWith("data:audio/wav;base64,") == true, "MiMo audio format");
    return Reply("""{"choices":[{"message":{"content":"你好"}}]}""");
})));
await plugin.ActivateAsync(host);
Check(!plugin.IsConfigured && !plugin.IsAvailable, "initial unconfigured state");
// Official Windows v1.2.1 LocalCtcVocabulary.HostVersion is 1.1.6, not 1.2.1.
var packagedManifest = JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "manifest.json")))!;
var minimumHost = Version.Parse(packagedManifest["minHostVersion"]!.GetValue<string>());
Check(minimumHost == new Version(1, 1, 6), "manifest uses plugin contract version, not product version");
Check(minimumHost <= new Version(1, 1, 6), "official Windows 1.2.1 passes compatibility gate");
Check(packagedManifest["version"]!.GetValue<string>() == plugin.PluginVersion, "manifest and plugin versions match");
await ThrowsAsync(() => plugin.TranscribeAsync(Wav(1), "zh", false, null, default), "missing key fails locally");
Check(calls == 0, "no audio upload without key");
await plugin.SetApiKeyAsync(" mimo-test ");
Check(host.Secrets["mimo-api-key"] == "mimo-test", "key uses host secret store");
await ThrowsAsync(() => plugin.SetApiKeyAsync("bad\nkey"), "reject control chars in key");
Check(host.Secrets["mimo-api-key"] == "mimo-test", "invalid key preserves previous");
await plugin.ValidateConfigurationAsync(default);
var result = await plugin.TranscribeAsync(Wav(1), "zh-CN", false, null, default);
Check(result.Text == "你好" && result.DurationSeconds == 1, "MiMo transcription result");
await ThrowsAsync(() => plugin.TranscribeAsync(Wav(1), "zh", true, null, default), "translation unsupported");
await plugin.DeactivateAsync();
await ThrowsAsync(() => plugin.SetApiKeyAsync("later"), "no mutation after deactivate");

var agHost = new FakeHost();
agHost.Secrets["antigravity-oauth-v1"] = JsonSerializer.Serialize(new Credentials("access", "refresh", DateTimeOffset.UtcNow.AddHours(1), "project", null, false));
var routes = new List<string>();
using var agHttp = new HttpClient(new Handler((request, ct) => {
    routes.Add(request.RequestUri!.Host);
    return Task.FromResult(request.RequestUri.Host == "cloudcode-pa.googleapis.com" ? Reply(catalogJson) : new HttpResponseMessage(HttpStatusCode.Forbidden));
}));
var ag = new Antigravity(agHttp, agHost); await ag.Load();
Check(ag.LoggedIn, "loads stored OAuth");
var discovered = await ag.Models(default);
Check(discovered.Count == 2 && routes.Count == 3, "403 on daily does not erase production catalog");
await ag.Logout(); Check(!ag.LoggedIn && !agHost.Secrets.ContainsKey("antigravity-oauth-v1"), "logout clears secret");
await ThrowsAsync(() => ag.Models(default), "logout prevents model request");

var refreshHost = new FakeHost();
refreshHost.Secrets["antigravity-oauth-v1"] = JsonSerializer.Serialize(new Credentials("expired", "old-refresh", DateTimeOffset.UtcNow.AddHours(-1), "p", null, false));
int refreshCalls = 0, generationCalls = 0;
using var refreshHttp = new HttpClient(new Handler((request, ct) => {
    if (request.RequestUri!.Host == "oauth2.googleapis.com") { refreshCalls++; return Task.FromResult(Reply("""{"access_token":"new","refresh_token":"rotated","expires_in":3600}""")); }
    generationCalls++;
    Check(request.Headers.Authorization?.Parameter == "new", "generation uses refreshed token");
    return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden));
}));
var refreshing = new Antigravity(refreshHttp, refreshHost); await refreshing.Load();
await ThrowsAsync(() => refreshing.Generate(a, "low", "system", "text", default), "generation 403 surfaces");
Check(refreshCalls == 1 && generationCalls == 1, "no generation retry after denial");
Check(refreshHost.Secrets["antigravity-oauth-v1"].Contains("rotated"), "rotated refresh token saved");

await OAuthTests.Run(Check, Throws, ThrowsAsync, catalogJson);

var temp = Path.Combine(Path.GetTempPath(), "tietiezhi-tests-" + Guid.NewGuid().ToString("N"));
try
{
    var source = Path.Combine(temp, "source"); var profile = Path.Combine(temp, "profile"); Directory.CreateDirectory(source);
    File.WriteAllText(Path.Combine(source, "manifest.json"), """{"id":"com.tietiezhi.mimo-antigravity","version":"0.1.0"}""");
    foreach (var name in new[] { "TypeWhisper.Plugin.Tietiezhi.dll", "TypeWhisper.Plugin.Tietiezhi.deps.json", "LICENSE", "THIRD_PARTY_NOTICES.md" }) File.WriteAllText(Path.Combine(source, name), "fixture");
    File.WriteAllLines(Path.Combine(source, "SHA256SUMS"), Directory.GetFiles(source).Select(f => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(f))) + "  " + Path.GetFileName(f)).ToArray());
    Throws(() => InstallCore.Install(profile, source), "installer refuses uninitialized profile");
    Directory.CreateDirectory(Path.Combine(profile, "PluginPackages"));
    var index = Path.Combine(profile, "PluginPackages", "installed.json");
    File.WriteAllText(index, """{"com.example.existing":{"directory":"old","version":"1.0.0","pendingDirectory":"pending","pendingVersion":"1.1.0"}}""");
    var backup = InstallCore.Install(profile, source); var after = Obj(File.ReadAllText(index));
    Check(File.Exists(backup), "installer backs up index");
    Check(after["com.example.existing"]?["pendingDirectory"]?.GetValue<string>() == "pending", "preserves other pending updates");
    var location = after[InstallCore.Id]?["directory"]?.GetValue<string>();
    Check(File.Exists(Path.Combine(profile, "PluginPackages", "packages", location!, "manifest.json")), "installer places complete package");
    File.WriteAllText(Path.Combine(source, "TypeWhisper.Plugin.Tietiezhi.dll"), "corrupt"); var before = File.ReadAllText(index);
    Throws(() => InstallCore.Install(profile, source), "reject corrupt package");
    Check(File.ReadAllText(index) == before, "failed install preserves index");
}
finally { if (Directory.Exists(temp)) Directory.Delete(temp, true); }
await UpdateTests.Run(Check, Throws, ThrowsAsync, args);
Console.WriteLine($"All {passed} checks passed.");

static HttpResponseMessage Reply(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> callback) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => callback(request, cancellationToken);
}
sealed class FakeHost : IPluginHostServices
{
    public Dictionary<string, string> Secrets = []; public Dictionary<string, string> Settings = [];
    public List<string> Logs = [];
    public Task StoreSecretAsync(string key, string value) { Secrets[key] = value; return Task.CompletedTask; }
    public Task<string?> LoadSecretAsync(string key) => Task.FromResult(Secrets.GetValueOrDefault(key));
    public Task DeleteSecretAsync(string key) { Secrets.Remove(key); return Task.CompletedTask; }
    public T? GetSetting<T>(string key) => Settings.TryGetValue(key, out var value) ? JsonSerializer.Deserialize<T>(value) : default;
    public void SetSetting<T>(string key, T value) => Settings[key] = JsonSerializer.Serialize(value);
    public string PluginDataDirectory => "unused";
    public string? ActiveAppProcessName => null; public string? ActiveAppName => null;
    public IPluginEventBus EventBus => throw new NotSupportedException();
    public IPluginLocalization Localization => throw new NotSupportedException();
    public IReadOnlyList<string> AvailableProfileNames => [];
    public void Log(PluginLogLevel level, string message) { Logs.Add(message); }
    public void NotifyCapabilitiesChanged() { }
}
