using System.Diagnostics;
using System.Text.Json;

namespace Tietiezhi.Install;

internal static class AutomaticUpdate
{
    internal static async Task Run(string[] args)
    {
        var result = Path.Combine(AppContext.BaseDirectory, "update-result.json");
        bool installed = false;
        try
        {
            if (args.Length != 6 || args[0] != "--update-after-exit" || args[2] != "--profile" || args[4] != "--restart"
                || !int.TryParse(args[1], out var parentId) || parentId <= 0)
                throw new ArgumentException("自动更新参数无效。");
            var profile = Path.GetFullPath(args[3]); var executable = Path.GetFullPath(args[5]);
            if (!Path.GetFileName(executable).Equals("TypeWhisper.exe", StringComparison.OrdinalIgnoreCase) || !File.Exists(executable))
                throw new InvalidDataException("宿主程序路径无效。");
            Process? parent = null;
            try { parent = Process.GetProcessById(parentId); } catch (ArgumentException) { }
            using (parent)
            {
                if (parent != null)
                {
                    if (!parent.ProcessName.Equals("TypeWhisper", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("宿主进程已变化。");
                    using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(10));
                    await parent.WaitForExitAsync(timeout.Token);
                }
            }
            if (Process.GetProcessesByName("TypeWhisper").Length != 0)
                throw new InvalidOperationException("TypeWhisper 仍在运行。请完全退出后重试更新。");
            var backup = InstallCore.Install(profile, Path.Combine(AppContext.BaseDirectory, "plugin"));
            installed = true;
            File.WriteAllText(result, JsonSerializer.Serialize(new { success = true, message = "更新安装成功。", backup }));
            Process.Start(new ProcessStartInfo(executable) { UseShellExecute = false });
        }
        catch (Exception e)
        {
            var message = installed ? "更新已安装，但自动重开失败，请手动打开 TypeWhisper。"
                : e is OperationCanceledException ? "等待退出超时（10 分钟），未安装更新。请再次点击安装更新。"
                : "更新未完成（" + e.GetType().Name + "）。请完全退出 TypeWhisper 后重试，或使用安装包。";
            File.WriteAllText(result, JsonSerializer.Serialize(new { success = installed, message }));
            Environment.ExitCode = installed ? 0 : 1;
        }
    }
}
