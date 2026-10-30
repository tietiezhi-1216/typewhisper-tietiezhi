using System.ComponentModel;
using System.Net.Sockets;
using TypeWhisper.PluginSDK;

namespace TypeWhisper.Plugin.Tietiezhi;

public sealed partial class TietiezhiPlugin
{
    // A single-profile editor lets explicit actions run without committing unrelated
    // drafts. The generic host editor blocks every action whenever any field is dirty.
    public string ProfileSelectorId => "configuration";
    public string? AddProfileActionId => null;
    public string? RemoveProfileActionId => null;
    private static void RequireProfile(string profileId)
    {
        if (profileId != "default") throw new ArgumentException("设置页已变化，请重新打开插件设置。");
    }
    public Task SaveProfileSettingsAsync(string profileId, IReadOnlyDictionary<string, string> values, string? apiKey, CancellationToken cancellationToken) => Locked(async ct => {
        RequireProfile(profileId);
        if (values.Keys.Any(k => k is not "selected-model" and not "thinking" && !IsLoginSetting(k))) throw new ArgumentException("未知设置。");
        string nextModel = values.GetValueOrDefault("selected-model", selected);
        string nextEffort = values.GetValueOrDefault("thinking", effort);
        if (models.Count > 0 && !models.Any(m => m.Id == nextModel)) throw new ArgumentException("请先选择有效模型。");
        if (!Efforts(nextModel).Contains(nextEffort)) throw new ArgumentException("当前模型不支持这个思考等级。");
        var normalized = apiKey?.Trim();
        if (normalized != null && (normalized.Length > 4096 || normalized.Any(char.IsControl))) throw new ArgumentException("API Key 格式无效。");
        // Validate all drafts first. OAuth fields remain in memory, never in settings.
        RememberLoginDraft(values);
        if (normalized != null)
        {
            if (normalized.Length == 0) await host!.DeleteSecretAsync("mimo-api-key");
            else await host!.StoreSecretAsync("mimo-api-key", normalized);
        }
        host!.SetSetting("selected-model", nextModel);
        host.SetSetting("thinking", nextEffort);
        if (normalized != null) key = normalized;
        selected = nextModel; effort = nextEffort;
        host.NotifyCapabilitiesChanged(); return true;
    }, cancellationToken);
    public Task<PluginProfileActionResult> ExecuteProfileActionAsync(string profileId, string actionId,
        IReadOnlyDictionary<string, string> values, string? apiKey, CancellationToken cancellationToken) => Locked(async ct => {
        RequireProfile(profileId);
        // Do not persist pending MiMo keys/model/reasoning edits just to sign in or update.
        var message = await RunActionSafely(actionId, ct, values) ?? "完成。";
        if (apiKey != null) message += " MiMo 密钥草稿尚未保存，请点击保存设置。";
        return new PluginProfileActionResult(message);
    }, cancellationToken);
    private async Task<string?> RunActionSafely(string id, CancellationToken ct, IReadOnlyDictionary<string, string>? values = null)
    {
        try { return await RunAction(id, ct, values); }
        catch (OperationCanceledException) { throw; }
        catch (ApiException e) { return e.Message; }
        catch (SocketException e) { return $"无法监听登录回调端口 36742（错误码 {e.ErrorCode}）。请关闭另一个登录窗口或占用端口的软件后重试。"; }
        catch (Win32Exception e) { return $"无法打开浏览器或更新程序（Windows 错误码 {e.NativeErrorCode}）。请检查默认浏览器和系统安全提示。"; }
        catch (InvalidOperationException e) { return e.Message; }
        catch (InvalidDataException e) { return e.Message; }
        catch (HttpRequestException e) { return e.StatusCode is { } status ? $"网络请求失败：HTTP {(int)status}。" : "无法连接服务，请检查网络或代理后重试。"; }
        catch (Exception e) { host!.Log(TypeWhisper.PluginSDK.Models.PluginLogLevel.Warning, $"Settings action {id} failed ({e.GetType().Name})"); return "操作未完成，请检查网络及插件设置后重试。"; }
    }
}
