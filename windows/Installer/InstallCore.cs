using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace Tietiezhi.Install;

internal static class InstallCore
{
    internal const string Id = "com.tietiezhi.mimo-antigravity";
    internal static string Install(string profile, string source)
    {
        var root = Path.Combine(profile, "PluginPackages");
        var index = Path.Combine(root, "installed.json");
        // Never create an empty index before the host bootstraps its own bundled providers.
        if (!File.Exists(index)) throw new InvalidOperationException("请先运行 TypeWhisper Windows 1.2.1 或更新版一次，再完全退出，然后运行安装工具。未找到宿主插件索引。");
        var original = File.ReadAllBytes(index);
        var registry = JsonNode.Parse(original) as JsonObject ?? throw new InvalidDataException("插件索引无效，未修改。");
        var manifest = JsonNode.Parse(File.ReadAllText(Path.Combine(source, "manifest.json")))!;
        var version = manifest["version"]?.GetValue<string>() ?? "";
        if (manifest["id"]?.GetValue<string>() != Id || !Version.TryParse(version, out var nextVersion)) throw new InvalidDataException("安装包身份或版本错误。");
        if (registry[Id] is JsonObject old)
        {
            var oldVersion = old["pendingVersion"]?.GetValue<string>() ?? old["version"]?.GetValue<string>();
            if (Version.TryParse(oldVersion, out var previous) && previous > nextVersion) throw new InvalidOperationException("不支持降级，请使用较新的安装包。");
        }
        // Local checksums detect corruption, not publisher identity. Download only from our GitHub release.
        var checksums = File.ReadAllLines(Path.Combine(source, "SHA256SUMS"));
        var allow = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "manifest.json", "TypeWhisper.Plugin.Tietiezhi.dll", "TypeWhisper.Plugin.Tietiezhi.deps.json", "LICENSE", "THIRD_PARTY_NOTICES.md"
        };
        var checkedFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in checksums.Where(l => !string.IsNullOrWhiteSpace(l)))
        {
            var parts = line.Split("  ", 2, StringSplitOptions.None);
            if (parts.Length != 2 || !allow.Contains(parts[1]) || !checkedFiles.Add(parts[1])) throw new InvalidDataException("校验清单无效。");
            var actual = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.Combine(source, parts[1]))));
            if (!actual.Equals(parts[0], StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安装文件校验失败：" + parts[1]);
        }
        if (!checkedFiles.SetEquals(allow)) throw new InvalidDataException("安装文件不完整。");
        var token = Guid.NewGuid().ToString("N"); var destination = Path.Combine(root, "packages", token);
        Directory.CreateDirectory(destination);
        var temporary = Path.Combine(root, "installed." + Guid.NewGuid().ToString("N") + ".tmp");
        bool committed = false;
        try
        {
            foreach (var name in allow) File.Copy(Path.Combine(source, name), Path.Combine(destination, name));
            // Preserve every other provider and its pending update. Keep old directories for rollback/host GC.
            registry[Id] = new JsonObject { ["directory"] = token, ["version"] = version };
            File.WriteAllText(temporary, registry.ToJsonString(new() { WriteIndented = true }));
            if (!File.ReadAllBytes(index).SequenceEqual(original)) throw new IOException("宿主插件索引发生变化，请完全退出 TypeWhisper 后重试。");
            var backups = Path.Combine(profile, "tietiezhi-install-backups"); Directory.CreateDirectory(backups);
            var backup = Path.Combine(backups, "installed-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + token + ".json");
            // Replace is atomic on Windows; keep backup outside package GC's directory.
            File.Replace(temporary, index, backup);
            committed = true;
            return backup;
        }
        finally
        {
            if (!committed && Directory.Exists(destination)) Directory.Delete(destination, true);
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
