using System.ComponentModel;
using TypeWhisper.PluginSDK;

namespace TypeWhisper.Plugin.Tietiezhi;

public sealed partial class TietiezhiPlugin
{
    private OAuthLoginSession? loginSession;
    private string callbackDraft = "";
    private IReadOnlyList<PluginTextSetting> LoginSettings()
    {
        var session = loginSession;
        if (session == null) return [];
        return [
            new(session.LinkSettingId, "Google 登录链接（选中复制）", "本次登录专用，10 分钟有效。可在其他设备打开；无需保存设置，修改此框不会改变登录地址。", session.Authorization.AbsoluteUri, 16384) { Section = PluginSettingsSection.Connection },
            new(session.CallbackSettingId, "localhost 回调链接", "在其他设备完成 Google 授权后，复制地址栏最终的 http://localhost:36742/oauth-callback?... 链接粘贴到这里，再点击完成登录。页面无法访问是正常现象。不要分享此链接。", callbackDraft, 16384) { Section = PluginSettingsSection.Connection }
        ];
    }
    private void ClearLoginSession()
    {
        loginSession?.Dispose(); loginSession = null; callbackDraft = "";
    }
    private bool IsLoginSetting(string id) => loginSession?.IsSetting(id) == true;
    private void RememberLoginDraft(IReadOnlyDictionary<string, string> values)
    {
        if (loginSession != null && values.TryGetValue(loginSession.CallbackSettingId, out var callback))
        {
            if (callback.Length > 16384) throw new ArgumentException("回调链接过长。");
            callbackDraft = callback; // Memory only; never a host setting or secret.
        }
    }
    private string BeginLogin(bool launchBrowser, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        ClearLoginSession();
        loginSession = new(lifetime.Token);
        host!.NotifyCapabilitiesChanged();
        var message = "Google 登录链接已生成（10 分钟有效），可复制到其他设备打开。授权后点击“完成登录”；跨设备请先粘贴 localhost 回调链接。可随时点击“取消登录”。";
        if (loginSession.ManualOnly) message += " 本机回调端口 36742 不可用，请使用粘贴回调方式。";
        if (launchBrowser)
        {
            try { antigravity!.OpenBrowser(loginSession.Authorization); }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException or NotSupportedException)
            { message = "无法自动打开浏览器，请复制设置页的 Google 登录链接手动打开。 " + message; }
        }
        // Do not await the callback here: Windows disables the whole editor until
        // a settings action returns, including any cancel button in that editor.
        return message;
    }
    private async Task<string> FinishLogin(IReadOnlyDictionary<string, string>? values, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var session = loginSession ?? throw new InvalidOperationException("没有进行中的登录，请先点击登录 Google 或获取登录链接。");
        var pasted = values?.GetValueOrDefault(session.CallbackSettingId, callbackDraft) ?? callbackDraft;
        string? code;
        try { code = session.GetCode(pasted); }
        catch (Exception e) when (e is OAuthDeniedException || session.Expired)
        { ClearLoginSession(); host!.NotifyCapabilitiesChanged(); throw; }
        if (code == null) return "尚未收到授权回调。请先在浏览器完成登录，或粘贴完整的 localhost 回调链接后重试；也可取消登录。";
        // Consume once. No stale callback or cancelled session can later overwrite credentials.
        ClearLoginSession(); host!.NotifyCapabilitiesChanged();
        using var exchange = CancellationTokenSource.CreateLinkedTokenSource(ct);
        exchange.CancelAfter(TimeSpan.FromSeconds(30));
        try { await antigravity!.CompleteLogin(code, session.Verifier, exchange.Token); }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        { return "Google 认证请求超时，请检查网络后重新登录；原有凭据未更改。"; }
        host.SetSetting("antigravity-models", new List<Model>()); models = [];
        host.NotifyCapabilitiesChanged();
        using var refresh = CancellationTokenSource.CreateLinkedTokenSource(ct);
        refresh.CancelAfter(TimeSpan.FromSeconds(30));
        try { await Refresh(refresh.Token); return "已登录，模型已更新。"; }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return "已登录，但模型获取超时，请点击刷新模型。"; }
        catch (Exception e) when (e is not OperationCanceledException) { return "已登录，但模型获取失败：" + (e is ApiException ? e.Message : "请点击刷新模型查看状态。"); }
    }
}
