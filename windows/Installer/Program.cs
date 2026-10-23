using System.Diagnostics;
using System.Text;
using Tietiezhi.Install;

if (args.FirstOrDefault() == "--update-after-exit")
{
    if (!OperatingSystem.IsWindows()) { Environment.ExitCode = 1; return; }
    await AutomaticUpdate.Run(args); return;
}
Console.OutputEncoding = Encoding.UTF8;
try
{
    if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("此安装工具仅支持 Windows。");
    if (Process.GetProcessesByName("TypeWhisper").Length > 0)
        throw new InvalidOperationException("请从托盘菜单完全退出 TypeWhisper，再运行安装工具。不要只关闭设置窗口。");
    var profile = args.Length == 2 && args[0] == "--profile" ? Path.GetFullPath(args[1])
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TypeWhisper-WinUI");
    Console.WriteLine("tietiezhi Windows 0.1.2 安装\n需要 TypeWhisper Windows 1.2.1+（官网/GitHub 桌面版）。\n目标：" + profile);
    Console.WriteLine("将安装 MiMo ASR 和非官方 Antigravity OAuth 插件，保留已有插件、Key 和工作流。\n仅当安装包来自 tietiezhi-1216/typewhisper-tietiezhi 时继续。\n输入 YES 确认安装：");
    if (Console.ReadLine() != "YES") return;
    var backup = InstallCore.Install(profile, Path.Combine(AppContext.BaseDirectory, "plugin"));
    Console.WriteLine("安装完成。索引备份：" + backup + "\n重新打开 TypeWhisper，在插件设置中启用 tietiezhi。");
}
catch (Exception e)
{
    Console.Error.WriteLine("安装未完成：" + e.Message); Environment.ExitCode = 1;
}
Console.WriteLine("按回车关闭。"); Console.ReadLine();
