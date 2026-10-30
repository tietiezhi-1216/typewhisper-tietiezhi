using System.ComponentModel;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using TypeWhisper.Plugin.Tietiezhi;
using TypeWhisper.PluginSDK;

internal static class OAuthTests
{
    private static HttpResponseMessage Reply(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private static string Field(Uri uri, string name) => Uri.UnescapeDataString(uri.Query.TrimStart('?').Split('&').Single(p => p.StartsWith(name + "="))[(name.Length + 1)..]);
    private static string Callback(Uri authorization, string code = "offline-code") => "http://localhost:36742/oauth-callback?code=" + code + "&state=" + Uri.EscapeDataString(Field(authorization, "state"));
    private static PluginTextSetting Link(TietiezhiPlugin plugin) => plugin.TextSettings.Single(f => f.Id.StartsWith("oauth-link-"));
    private static PluginTextSetting Input(TietiezhiPlugin plugin) => plugin.TextSettings.Single(f => f.Id.StartsWith("oauth-callback-"));
    private static async Task WaitFor(Func<bool> ready)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        while (!ready()) await Task.Delay(10, timeout.Token);
    }
    private static void PortFree(Action<bool, string> check, string name)
    {
        using var probe = new TcpListener(IPAddress.Loopback, 36742); probe.Start(); check(true, name);
    }
    public static async Task Run(Action<bool, string> check, Action<Action, string> throws, Func<Func<Task>, string, Task> throwsAsync, string catalogJson)
    {
        foreach (var origin in new[] { "https://localhost:36742", "http://evil.invalid:36742", "http://localhost:1234", "http://user@localhost:36742" })
            throws(() => Protocol.Callback(new(origin + "/oauth-callback?code=c&state=s"), "s"), "reject untrusted callback origin " + origin);
        throws(() => Protocol.Callback(new("http://localhost:36742/oauth-callback?code=c&state=s#fragment"), "s"), "reject callback fragment");
        check(Protocol.Callback(new("http://127.0.0.1:36742/oauth-callback?code=c&state=s"), "s") == "c", "accept IPv4 loopback callback");

        // Real sockets, fake Google. Callback collection performs no token exchange or host writes.
        var loginHost = new FakeHost();
        int tokenCalls = 0;
        using var loginHttp = new HttpClient(new Handler((request, ct) => {
            if (request.RequestUri!.Host == "oauth2.googleapis.com") tokenCalls++;
            return Task.FromResult(Reply(request.RequestUri.Host == "oauth2.googleapis.com"
                ? """{"access_token":"offline-access","refresh_token":"offline-refresh","expires_in":3600}"""
                : """{"email":"offline@example.invalid"}"""));
        }));
        var login = new Antigravity(loginHttp, loginHost);
        using (var session = new OAuthLoginSession(default))
        {
            using var local = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(10) };
            using var invalid = await local.GetAsync("http://127.0.0.1:36742/oauth-callback?code=bad&state=wrong");
            check(invalid.StatusCode == HttpStatusCode.BadRequest, "invalid state does not end listener");
            // A disconnected client must not kill the session either.
            using (var disconnected = new TcpClient()) { await disconnected.ConnectAsync(IPAddress.Loopback, 36742); }
            var page = await local.GetStringAsync(Callback(session.Authorization));
            check(page.Contains("callback received") && !page.Contains("offline-code"), "loopback page never echoes authorization code");
            await WaitFor(() => session.GetCode(null) != null);
            check(tokenCalls == 0 && loginHost.Secrets.Count == 0 && loginHost.Settings.Count == 0, "background callback has no provider requests or persistence");
            PortFree(check, "received callback releases port before completion");
            await login.CompleteLogin(session.GetCode(null)!, session.Verifier, default);
        }
        check(login.LoggedIn && tokenCalls == 1 && loginHost.Secrets.ContainsKey("antigravity-oauth-v1"), "explicit completion stores OAuth secret");
        loginHost.Secrets["antigravity-oauth-v1"] = "invalid json";
        await login.Load(); check(!login.LoggedIn, "damaged OAuth record does not break activation");
        using (var expired = new OAuthLoginSession(default, TimeSpan.FromMilliseconds(50)))
        {
            await WaitFor(() => expired.Expired);
            throws(() => expired.GetCode(Callback(expired.Authorization)), "expired session rejects otherwise valid callback");
            await WaitFor(() => { try { using var probe = new TcpListener(IPAddress.Loopback, 36742); probe.Start(); return true; } catch (SocketException) { return false; } });
            PortFree(check, "timeout releases callback port");
        }
        using (var occupied = new TcpListener(IPAddress.Loopback, 36742))
        {
            occupied.Start();
            using var manual = new OAuthLoginSession(default);
            check(manual.ManualOnly && manual.GetCode(Callback(manual.Authorization)) == "offline-code", "busy port still permits manual login");
        }

        var profileHost = new FakeHost(); profileHost.Secrets["mimo-api-key"] = "saved-key";
        Uri? opened = null; string? expectedChallenge = null; int browserOpened = 0, profileTokenCalls = 0;
        using var profilePlugin = new TietiezhiPlugin(new HttpClient(new Handler(async (request, ct) => {
            if (request.RequestUri!.Host == "oauth2.googleapis.com")
            {
                profileTokenCalls++;
                var form = await request.Content!.ReadAsStringAsync(ct);
                var fields = new Uri("https://example.invalid/?" + form);
                check(Protocol.Challenge(Field(fields, "code_verifier")) == expectedChallenge, "token exchange uses original session PKCE");
                return Reply("""{"access_token":"access","refresh_token":"refresh","expires_in":3600}""");
            }
            return request.RequestUri.Host == "www.googleapis.com" ? Reply("""{"email":"offline@example.invalid"}""")
                : request.RequestUri.AbsolutePath.EndsWith("fetchAvailableModels") ? Reply(catalogJson) : Reply("{}");
        })), url => { browserOpened++; opened = url; });
        await profilePlugin.ActivateAsync(profileHost);
        check(profilePlugin.TextSettings.Count == 1 && profilePlugin.TextSettings[0].Id == profilePlugin.ProfileSelectorId, "no blank model editor before discovery");
        check(profilePlugin.TextSettings[0].Choices.Count == 1 && profilePlugin.AddProfileActionId == null, "single profile uses draft-action route");
        check(profilePlugin.SettingsActions.All(a => a.Section == PluginSettingsSection.Connection), "connection actions avoid host button overlap");
        check(profilePlugin.SettingsActions.Any(a => a.Id == "check-update") && profilePlugin.SettingsActions.Any(a => a.Id == "install-update"), "updates available before login");
        var drafts = new Dictionary<string, string> { ["selected-model"] = "", ["thinking"] = "high" };
        using (var actionLifetime = new CancellationTokenSource())
        {
            var begin = await profilePlugin.ExecuteProfileActionAsync("default", "login", drafts, "unsaved-key", actionLifetime.Token).WaitAsync(TimeSpan.FromSeconds(2));
            check(browserOpened == 1 && opened != null && !profilePlugin.IsAvailable && begin.Message.Contains("链接已生成"), "begin returns without waiting for browser callback");
            actionLifetime.Cancel(); // A completed host action must not own the pending session lifetime.
        }
        var firstLink = Link(profilePlugin); var firstInput = Input(profilePlugin);
        check(firstLink.Value == opened!.AbsoluteUri && firstLink.Value.StartsWith("https://accounts.google.com/"), "real Google authorization URL exposed for copying");
        check(profilePlugin.SettingsActions.Any(a => a.Id == "cancel-login") && profilePlugin.SettingsActions.Any(a => a.Id == "complete-login"), "cancel and complete actions available while awaiting browser");
        check((await profilePlugin.ExecuteSettingsActionAsync("complete-login", default))!.Contains("尚未收到"), "completion with no callback returns immediately");
        check(profileTokenCalls == 0, "no callback means no token request");
        await profilePlugin.ValidateConfigurationAsync(default).WaitAsync(TimeSpan.FromSeconds(2));
        check(true, "other plugin operations remain available while awaiting browser");
        await profilePlugin.ExecuteProfileActionAsync("default", "cancel-login", drafts, "unsaved-key", default).WaitAsync(TimeSpan.FromSeconds(2));
        check(profilePlugin.TextSettings.Count == 1 && profileTokenCalls == 0, "cancel removes transient UI without token request");
        PortFree(check, "cancel releases callback port immediately");
        check(profileHost.Secrets["mimo-api-key"] == "saved-key" && !profileHost.Settings.ContainsKey("thinking"), "cancel does not persist unrelated drafts");

        await profilePlugin.ExecuteSettingsActionAsync("login-link", default);
        var link = Link(profilePlugin); var input = Input(profilePlugin);
        check(browserOpened == 1 && link.Value != firstLink.Value && input.Id != firstInput.Id, "link-only retry opens no browser and uses fresh state and field IDs");
        var wrong = await profilePlugin.ExecuteProfileActionAsync("default", "complete-login", new Dictionary<string, string> { [input.Id] = Callback(new Uri(firstLink.Value)) }, null, default);
        check(wrong.Message.Contains("state") && profileTokenCalls == 0 && Input(profilePlugin).Id == input.Id, "stale callback rejected without destroying current session");
        foreach (var bad in new[] { link.Value, "bare-code", Callback(new Uri(link.Value)).Replace("localhost", "evil.invalid") })
        {
            await profilePlugin.ExecuteProfileActionAsync("default", "complete-login", new Dictionary<string, string> { [input.Id] = bad }, null, default);
            check(profileTokenCalls == 0 && Input(profilePlugin).Id == input.Id, "invalid pasted URL preserves retryable session");
        }
        var pasted = Callback(new Uri(link.Value));
        await profilePlugin.SaveProfileSettingsAsync("default", new Dictionary<string, string> { [input.Id] = pasted, [link.Id] = link.Value }, null, default);
        check(profileHost.Settings.Keys.All(k => !k.StartsWith("oauth-")) && profileHost.Settings.Values.All(v => !v.Contains("offline-code") && !v.Contains("accounts.google.com")), "saving transient fields never writes OAuth URLs to settings");
        expectedChallenge = Field(new Uri(link.Value), "code_challenge");
        var finished = await profilePlugin.ExecuteProfileActionAsync("default", "complete-login", new Dictionary<string, string> { [input.Id] = "  " + pasted + "  ", ["thinking"] = "high" }, "unsaved-key", default);
        check(profilePlugin.IsAvailable && finished.Message.Contains("已登录") && profileTokenCalls == 1, "cross-device paste completes OAuth and discovers models");
        check(profileHost.Secrets["mimo-api-key"] == "saved-key" && profileHost.GetSetting<string>("thinking") != "high", "completion does not silently save unrelated drafts");
        check(profilePlugin.TextSettings.All(f => f.Choices.Any(c => c.Value == f.Value)), "transient OAuth fields removed after completion");
        var credentials = profileHost.Secrets["antigravity-oauth-v1"];
        await profilePlugin.ExecuteSettingsActionAsync("complete-login", default);
        check(profileTokenCalls == 1, "completed callback cannot be reused");
        await profilePlugin.ExecuteSettingsActionAsync("login-link", default);
        await profilePlugin.ExecuteSettingsActionAsync("cancel-login", default);
        check(profilePlugin.IsAvailable && profileHost.Secrets["antigravity-oauth-v1"] == credentials, "cancel relogin preserves saved credentials and models");
        await profilePlugin.ExecuteSettingsActionAsync("login", default);
        expectedChallenge = Field(opened!, "code_challenge");
        using (var local = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(10) })
            await local.GetStringAsync(Callback(opened!));
        check(profileTokenCalls == 1 && profileHost.Secrets["antigravity-oauth-v1"] == credentials, "local browser callback also waits for explicit completion");
        using (var finishTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)))
        {
            string? localResult;
            do
            {
                localResult = await profilePlugin.ExecuteSettingsActionAsync("complete-login", finishTimeout.Token);
                if (localResult!.Contains("尚未收到")) await Task.Delay(10, finishTimeout.Token);
            } while (localResult!.Contains("尚未收到"));
            check(localResult.Contains("已登录") && profileTokenCalls == 2, "local browser login completes without pasted URL");
        }
        credentials = profileHost.Secrets["antigravity-oauth-v1"];
        check(profileHost.Logs.All(v => !v.Contains("offline-code") && !v.Contains("accounts.google.com") && !v.Contains("code_verifier")), "login diagnostics never contain callback or PKCE data");
        await profilePlugin.SaveProfileSettingsAsync("default", new Dictionary<string, string> { ["selected-model"] = "gemini-a", ["thinking"] = "high" }, "new-key", default);
        check(profileHost.GetSetting<string>("thinking") == "high" && profileHost.Secrets["mimo-api-key"] == "new-key", "explicit profile save persists model reasoning and key");
        await throwsAsync(() => profilePlugin.SaveProfileSettingsAsync("default", new Dictionary<string, string> { ["selected-model"] = "unknown" }, "bad-new-key", default), "invalid profile save rejected");
        check(profileHost.Secrets["mimo-api-key"] == "new-key", "invalid profile save preserves key");
        await profilePlugin.ExecuteSettingsActionAsync("login-link", default);
        var denied = await profilePlugin.ExecuteProfileActionAsync("default", "complete-login", new Dictionary<string, string> { [Input(profilePlugin).Id] = Callback(new Uri(Link(profilePlugin).Value)).Replace("code=offline-code", "error=access_denied") }, null, default);
        check(denied.Message.Contains("取消或拒绝") && !profilePlugin.SettingsActions.Any(a => a.Id == "cancel-login") && profileHost.Secrets["antigravity-oauth-v1"] == credentials, "denied authorization closes only the pending session");
        await profilePlugin.ExecuteSettingsActionAsync("login-link", default);
        await profilePlugin.ExecuteProfileActionAsync("default", "logout", new Dictionary<string, string> { ["thinking"] = "nonsense" }, null, default);
        check(!profilePlugin.IsAvailable && profilePlugin.TextSettings.Count == 1, "logout cancels pending login despite dirty drafts");
        PortFree(check, "logout releases callback port");
        await profilePlugin.ExecuteSettingsActionAsync("login-link", default);
        await profilePlugin.DeactivateAsync().WaitAsync(TimeSpan.FromSeconds(2));
        PortFree(check, "deactivation cancels pending login without waiting");
        await profilePlugin.ActivateAsync(profileHost);
        check(profilePlugin.TextSettings.Count == 1, "reactivation never resurrects a pending OAuth session");
        await profilePlugin.DeactivateAsync();

        var browserHost = new FakeHost();
        using var brokenBrowser = new TietiezhiPlugin(new HttpClient(new Handler((r, ct) => throw new Exception("unexpected network"))), _ => throw new Win32Exception(2));
        await brokenBrowser.ActivateAsync(browserHost);
        var browserError = await brokenBrowser.ExecuteSettingsActionAsync("login", default);
        check(browserError!.Contains("无法自动打开浏览器") && Link(brokenBrowser).Value.Contains("accounts.google.com"), "browser failure retains manual authorization link");
        brokenBrowser.Dispose();
        PortFree(check, "dispose releases pending callback port");

        var failedHost = new FakeHost();
        var oldCredentials = JsonSerializer.Serialize(new Credentials("old", "old-refresh", DateTimeOffset.UtcNow.AddHours(1), "old-project", null, false));
        failedHost.Secrets["antigravity-oauth-v1"] = oldCredentials;
        bool waitForCancellation = false;
        var requestStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var failing = new TietiezhiPlugin(new HttpClient(new Handler(async (request, ct) => {
            if (waitForCancellation) { requestStarted.TrySetResult(); await Task.Delay(Timeout.Infinite, ct); }
            return new HttpResponseMessage(HttpStatusCode.BadRequest);
        })));
        await failing.ActivateAsync(failedHost);
        await failing.ExecuteSettingsActionAsync("login-link", default);
        var failure = await failing.ExecuteProfileActionAsync("default", "complete-login", new Dictionary<string, string> { [Input(failing).Id] = Callback(new Uri(Link(failing).Value)) }, null, default);
        check(failure.Message.Contains("HTTP 400") && failedHost.Secrets["antigravity-oauth-v1"] == oldCredentials, "failed token exchange preserves existing credentials");
        await failing.ExecuteSettingsActionAsync("login-link", default);
        waitForCancellation = true;
        using (var cancelExchange = new CancellationTokenSource())
        {
            var completing = failing.ExecuteProfileActionAsync("default", "complete-login", new Dictionary<string, string> { [Input(failing).Id] = Callback(new Uri(Link(failing).Value)) }, null, cancelExchange.Token);
            await requestStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
            cancelExchange.Cancel();
            await throwsAsync(() => completing, "host cancellation aborts in-flight token exchange");
        }
        check(failedHost.Secrets["antigravity-oauth-v1"] == oldCredentials && !failing.SettingsActions.Any(a => a.Id == "cancel-login"), "cancelled completion cannot later overwrite credentials");
        PortFree(check, "failed or cancelled exchange leaves no listener");
        await failing.DeactivateAsync();
    }
}
