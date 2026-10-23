using System.Diagnostics;
using System.Net;
using System.Text;

namespace TypeWhisper.Plugin.Tietiezhi;

internal sealed class WindowsUpdates(HttpClient http)
{
    internal static bool Trusted(Uri uri) => uri.Scheme == "https" && uri.Port == 443 && string.IsNullOrEmpty(uri.UserInfo)
        && new[] { "api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com" }.Contains(uri.Host);
    private async Task<byte[]> Download(Uri uri, int maximum, CancellationToken ct)
    {
        for (int redirect = 0; redirect < 6; redirect++)
        {
            if (!Trusted(uri)) throw new InvalidDataException("更新下载跳转到不受信任的地址，已停止。");
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.UserAgent.ParseAdd("tietiezhi-windows-updater/0.1.2");
            // This transport never attaches MiMo/Google credentials to GitHub.
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if (response.StatusCode is HttpStatusCode.MovedPermanently or HttpStatusCode.Redirect or HttpStatusCode.SeeOther or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect)
            {
                uri = response.Headers.Location is { } target ? new Uri(uri, target) : throw new InvalidDataException("下载重定向无效。"); continue;
            }
            if (!response.IsSuccessStatusCode) throw new HttpRequestException("GitHub 更新下载失败。", null, response.StatusCode);
            if (response.Content.Headers.ContentLength > maximum) throw new InvalidDataException("更新响应超过大小限制。");
            using var output = new MemoryStream(); await using var source = await response.Content.ReadAsStreamAsync(ct);
            var buffer = new byte[8192]; int read;
            while ((read = await source.ReadAsync(buffer, ct)) != 0)
            {
                if (output.Length + read > maximum) throw new InvalidDataException("更新响应超过大小限制。");
                output.Write(buffer, 0, read);
            }
            return output.ToArray();
        }
        throw new InvalidDataException("更新下载重定向次数过多。");
    }
    public async Task<WindowsRelease?> Check(string current, CancellationToken ct) => WindowsUpdateCore.Latest(
        Encoding.UTF8.GetString(await Download(new Uri(WindowsUpdateCore.Feed), 2_000_000, ct)), current);
    public async Task<string> Prepare(WindowsRelease release, string dataDirectory, CancellationToken ct)
    {
        var checksum = Encoding.UTF8.GetString(await Download(release.Checksum, 512, ct));
        var digest = WindowsUpdateCore.Digest(checksum, release.ArchiveName);
        var bytes = await Download(release.Archive, 16_000_000, ct);
        ct.ThrowIfCancellationRequested();
        var destination = Path.Combine(dataDirectory, "updates", Guid.NewGuid().ToString("N"));
        WindowsUpdateCore.Extract(bytes, digest, destination, release.Version);
        return destination;
    }
}
internal sealed record PendingWindowsUpdate(string Directory, int ProcessId, string Version);
public sealed partial class TietiezhiPlugin
{
    private WindowsRelease? availableUpdate;
    private async Task<string> CheckUpdate(CancellationToken ct)
    {
        string previous = "";
        var pending = host!.GetSetting<PendingWindowsUpdate>("windows-update-pending");
        if (pending != null)
        {
            var result = Path.Combine(pending.Directory, "update-result.json");
            if (File.Exists(result) && new FileInfo(result).Length < 16_384)
            {
                try
                {
                    var status = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(result));
                    previous = status?["success"]?.GetValue<bool>() == false ? "上次更新未完成，请重新点击安装更新。 " : "";
                }
                catch (System.Text.Json.JsonException) { previous = "上次更新状态无效，请重试。 "; }
            }
        }
        availableUpdate = await new WindowsUpdates(http).Check(PluginVersion, ct);
        if (availableUpdate != null) return previous + $"发现 Windows {availableUpdate.Version}，点击“安装更新”。";
        return previous + $"当前 Windows {PluginVersion} 已是最新版本。";
    }
    private async Task<string> InstallUpdate(CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows()) return "在线安装仅支持 Windows。";
        var pending = host!.GetSetting<PendingWindowsUpdate>("windows-update-pending");
        if (pending != null)
        {
            try
            {
                using var process = Process.GetProcessById(pending.ProcessId);
                if (!process.HasExited && process.ProcessName.Equals("Install-tietiezhi", StringComparison.OrdinalIgnoreCase))
                    return "更新程序已就绪，请从托盘完全退出 TypeWhisper；安装完成会自动重新打开。";
            }
            catch (ArgumentException) { }
        }
        var release = await new WindowsUpdates(http).Check(PluginVersion, ct);
        if (release == null) return $"当前 Windows {PluginVersion} 已是最新版本。";
        var data = Path.GetFullPath(host.PluginDataDirectory);
        var parent = Path.GetDirectoryName(data);
        if (parent == null || !Path.GetFileName(parent).Equals("PluginData", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("无法确认宿主配置目录，未进行自动安装。请使用手动安装包。");
        var profile = Path.GetDirectoryName(parent)!;
        using var current = Process.GetCurrentProcess();
        var executable = current.MainModule?.FileName;
        if (executable == null || !Path.GetFileName(executable).Equals("TypeWhisper.exe", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("在线更新须在 TypeWhisper 设置页中执行。");
        var directory = await new WindowsUpdates(http).Prepare(release, data, ct);
        ct.ThrowIfCancellationRequested();
        var start = new ProcessStartInfo(Path.Combine(directory, "Install-tietiezhi.exe")) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = directory };
        foreach (var arg in new[] { "--update-after-exit", current.Id.ToString(), "--profile", profile, "--restart", executable }) start.ArgumentList.Add(arg);
        using var updater = Process.Start(start) ?? throw new InvalidOperationException("无法启动更新程序，未修改当前插件。");
        host.SetSetting("windows-update-pending", new PendingWindowsUpdate(directory, updater.Id, release.Version));
        return $"Windows {release.Version} 已下载并校验。请从托盘完全退出 TypeWhisper，退出后自动安装并重新打开；Key、登录与工作流保留。";
    }
}
