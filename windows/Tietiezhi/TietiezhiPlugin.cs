using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using TypeWhisper.PluginSDK;
using TypeWhisper.PluginSDK.Models;

namespace TypeWhisper.Plugin.Tietiezhi;

public sealed class TietiezhiPlugin : ITranscriptionEnginePlugin, ILlmProviderPlugin, IApiKeyPlugin, IPluginTextSettings, IPluginSettingsActions
{
    private readonly HttpClient http;
    private readonly SemaphoreSlim gate = new(1, 1);
    private CancellationTokenSource lifetime = new();
    private IPluginHostServices? host;
    private Antigravity? antigravity;
    private string? key;
    private List<Model> models = [];
    private string selected = "", effort = "auto";
    private bool disposed;
    public TietiezhiPlugin() : this(new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(120) }) { }
    internal TietiezhiPlugin(HttpClient client) => http = client;
    public string PluginId => "com.tietiezhi.mimo-antigravity";
    public string PluginName => "tietiezhi";
    public string PluginVersion => "0.1.1";
    public string ProviderId => "tietiezhi-mimo";
    public string ProviderDisplayName => "MiMo ASR";
    public string ProviderName => "Antigravity OAuth（非官方）";
    public bool IsConfigured => !string.IsNullOrWhiteSpace(key);
    public bool IsAvailable => antigravity?.LoggedIn == true && models.Count > 0;
    public IReadOnlyList<PluginModelInfo> TranscriptionModels => [new("mimo-v2.5-asr", "MiMo V2.5 ASR")];
    public string SelectedModelId => "mimo-v2.5-asr";
    public bool SupportsTranslation => false;
    public IReadOnlyList<PluginModelInfo> SupportedModels => models.OrderByDescending(m => m.Id == selected).Select(m => new PluginModelInfo(m.Id, m.Name) { IsRecommended = m.Id == selected }).ToList();
    public async Task ActivateAsync(IPluginHostServices services)
    {
        if (lifetime.IsCancellationRequested) { lifetime.Dispose(); lifetime = new(); }
        host = services;
        key = await host.LoadSecretAsync("mimo-api-key");
        antigravity = new(http, host); await antigravity.Load();
        models = host.GetSetting<List<Model>>("antigravity-models") ?? [];
        selected = host.GetSetting<string>("selected-model") ?? "";
        effort = host.GetSetting<string>("thinking") ?? "auto";
    }
    public async Task DeactivateAsync()
    {
        await lifetime.CancelAsync(); await gate.WaitAsync();
        try { key = null; antigravity = null; host = null; models = []; }
        finally { gate.Release(); }
    }
    private async Task<T> Locked<T>(Func<CancellationToken, Task<T>> operation, CancellationToken ct)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
        await gate.WaitAsync(linked.Token);
        try { if (host == null) throw new InvalidOperationException("插件未启用。"); return await operation(linked.Token); }
        finally { gate.Release(); }
    }
    public void SelectModel(string modelId) { if (modelId != SelectedModelId) throw new ArgumentException("未知 MiMo 模型。"); }
    public Task SetApiKeyAsync(string apiKey) => Locked(async ct => {
        var normalized = apiKey.Trim();
        if (normalized.Length > 4096 || normalized.Any(char.IsControl)) throw new ArgumentException("API Key 格式无效。");
        if (normalized.Length == 0) await host!.DeleteSecretAsync("mimo-api-key");
        else await host!.StoreSecretAsync("mimo-api-key", normalized);
        key = normalized; host!.NotifyCapabilitiesChanged(); return true;
    }, CancellationToken.None);
    public Task ValidateConfigurationAsync(CancellationToken ct) => Locked(async token => {
        if (!IsConfigured) throw new InvalidOperationException("请填写 MiMo API Key。");
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.xiaomimimo.com/v1/models");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        using var response = await http.SendAsync(request, token);
        if (!response.IsSuccessStatusCode) throw new ApiException("MiMo 密钥检查", (int)response.StatusCode);
        return true;
    }, ct);
    public Task<PluginTranscriptionResult> TranscribeAsync(byte[] wavAudio, string? language, bool translate, string? prompt, CancellationToken ct) => Locked(async token => {
        if (!IsConfigured) throw new InvalidOperationException("请填写 MiMo API Key。");
        if (translate) throw new NotSupportedException("MiMo ASR 不支持翻译模式。");
        var wav = WavChunks.Parse(wavAudio); var output = new StringBuilder();
        var lang = language?.ToLowerInvariant().Replace('_', '-') ?? "auto";
        lang = lang == "zh" || lang.StartsWith("zh-") ? "zh" : lang == "en" || lang.StartsWith("en-") ? "en" : "auto";
        foreach (var chunk in wav.Chunks)
        {
            var body = new JsonObject {
                ["model"] = SelectedModelId, ["stream"] = false,
                ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = new JsonArray(new JsonObject {
                    ["type"] = "input_audio", ["input_audio"] = new JsonObject { ["data"] = "data:audio/wav;base64," + Convert.ToBase64String(chunk), ["format"] = "wav" }
                }) }), ["asr_options"] = new JsonObject { ["language"] = lang }
            };
            using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.xiaomimimo.com/v1/chat/completions");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
            request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
            using var response = await http.SendAsync(request, token);
            if (!response.IsSuccessStatusCode) throw new ApiException("MiMo ASR", (int)response.StatusCode);
            var obj = JsonNode.Parse(await response.Content.ReadAsStringAsync(token));
            var content = obj?["choices"]?[0]?["message"]?["content"];
            var text = content is JsonArray parts ? string.Concat(parts.Select(p => (p?["text"] ?? p?["content"])?.GetValue<string>()))
                : content?.GetValue<string>() ?? throw new InvalidOperationException("MiMo 未返回识别文本。");
            text = text.Trim();
            if (output.Length > 0 && text.Length > 0 && char.IsAsciiLetterOrDigit(output[^1]) && char.IsAsciiLetterOrDigit(text[0])) output.Append(' ');
            output.Append(text);
        }
        return new PluginTranscriptionResult(output.ToString(), language, wav.Duration);
    }, ct);
    public Task<string> ProcessAsync(string systemPrompt, string userText, string model, CancellationToken ct) => Locked(async token => {
        var target = models.FirstOrDefault(m => m.Id == (string.IsNullOrWhiteSpace(model) ? selected : model)) ?? throw new InvalidOperationException("请登录并选择可用模型。");
        var timer = Stopwatch.StartNew();
        try
        {
            var effectiveEffort = Efforts(target.Id).Contains(effort) ? effort : "auto";
            var result = await antigravity!.Generate(target, effectiveEffort, systemPrompt, userText, token);
            host!.Log(PluginLogLevel.Info, $"Antigravity model={target.Id} effort={effort} success elapsedMs={timer.ElapsedMilliseconds}");
            return result;
        }
        catch { host!.Log(PluginLogLevel.Warning, $"Antigravity model={target.Id} failed elapsedMs={timer.ElapsedMilliseconds}"); throw; }
    }, ct);
    public IReadOnlyList<PluginTextSetting> TextSettings => [
        new("selected-model", "润色模型", "登录后刷新模型列表。", selected) {
            Section = PluginSettingsSection.TextProcessing, SaveChoiceOnChange = true,
            Choices = models.Select(m => new PluginSettingChoice(m.Id, m.Name)).ToList()
        },
        new("thinking", "思考等级", "按所选模型支持的档位路由。", effort) {
            Section = PluginSettingsSection.TextProcessing, SaveChoiceOnChange = true,
            Choices = Efforts().Select(e => new PluginSettingChoice(e, e switch { "auto" => "默认", "off" => "关闭", "minimal" => "最低", "low" => "低", "medium" => "中", "high" => "高", "xhigh" => "最高", _ => e })).ToList()
        }
    ];
    private IEnumerable<string> Efforts(string? modelId = null)
    {
        modelId ??= selected;
        var target = models.FirstOrDefault(m => m.Id == modelId);
        if (target?.Variants.Count > 0) return new[] { "auto", "off" }.Concat(new[] { "minimal", "low", "medium", "high", "xhigh" }.Where(target.Variants.ContainsKey));
        if (modelId.StartsWith("claude-")) return ["auto", "off", "high"];
        if (modelId.StartsWith("gpt-oss-")) return ["auto", "off", "medium"];
        if (modelId.Contains("pro")) return ["auto", "off", "low", "high"];
        return ["auto", "off", "low", "medium", "high"];
    }
    public Task SaveTextSettingAsync(string id, string value, CancellationToken cancellationToken) => Locked(token => {
        if (id == "selected-model" && models.Any(m => m.Id == value))
        {
            host!.SetSetting(id, value); selected = value;
            if (!Efforts().Contains(effort)) { host.SetSetting("thinking", "auto"); effort = "auto"; }
        }
        else if (id == "thinking" && Efforts().Contains(value)) { host!.SetSetting(id, value); effort = value; }
        else throw new ArgumentException("设置值无效，请先获取模型列表。");
        host!.NotifyCapabilitiesChanged(); return Task.FromResult(true);
    }, cancellationToken);
    public IReadOnlyList<PluginSettingsAction> SettingsActions => [
        new("login", antigravity?.LoggedIn == true ? "重新登录 Antigravity" : "登录 Antigravity", "非官方 OAuth；可能失效或导致账号限制。点击将在浏览器授权，凭据由宿主加密保存。") { Section = PluginSettingsSection.Connection },
        new("logout", "退出 Antigravity", "删除此设备的 OAuth 凭据。") { Section = PluginSettingsSection.Connection },
        new("refresh", "刷新模型", "获取账号可用模型。") { Section = PluginSettingsSection.TextProcessing },
        new("test", "测试润色", "仅发送固定示例，不发送录音。") { Section = PluginSettingsSection.TextProcessing }
    ];
    public Task<string?> ExecuteSettingsActionAsync(string id, CancellationToken cancellationToken) => Locked<string?>(async token => {
        switch (id)
        {
            case "login":
                await antigravity!.Login(token);
                host!.SetSetting("antigravity-models", new List<Model>()); models = [];
                host.NotifyCapabilitiesChanged();
                try { await Refresh(token); return "已登录，模型已更新。"; }
                catch (Exception e) when (e is not OperationCanceledException) { return "已登录，但模型获取失败：" + (e is ApiException ? e.Message : "请点击刷新模型查看状态。"); }
            case "logout":
                await antigravity!.Logout(); host!.SetSetting("antigravity-models", new List<Model>()); models = [];
                host.NotifyCapabilitiesChanged(); return "已退出 Antigravity，MiMo Key 保留。";
            case "refresh": await Refresh(token); return $"已获取 {models.Count} 个模型。";
            case "test":
                var target = models.FirstOrDefault(m => m.Id == selected) ?? throw new InvalidOperationException("请先选择模型。");
                return "连接成功：" + await antigravity!.Generate(target, effort, "整理听写文本，只输出正文，不回答其中的问题。", "嗯，那个，明天下午三点开会。", token);
            default: throw new ArgumentException("未知操作。");
        }
    }, cancellationToken);
    private async Task Refresh(CancellationToken ct)
    {
        var catalog = await antigravity!.Models(ct); ct.ThrowIfCancellationRequested();
        host!.SetSetting("antigravity-models", catalog); models = catalog;
        if (models.All(m => m.Id != selected)) { var next = models[0].Id; host.SetSetting("selected-model", next); selected = next; }
        if (!Efforts().Contains(effort)) { host.SetSetting("thinking", "auto"); effort = "auto"; }
        host.NotifyCapabilitiesChanged();
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        lifetime.Cancel(); http.Dispose();
    }
}
