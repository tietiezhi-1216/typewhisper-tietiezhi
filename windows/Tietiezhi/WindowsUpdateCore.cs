using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace TypeWhisper.Plugin.Tietiezhi;

internal sealed record WindowsRelease(string Version, string ArchiveName, Uri Archive, Uri Checksum);
internal static class WindowsUpdateCore
{
    internal const string Repository = "https://github.com/tietiezhi-1216/typewhisper-tietiezhi";
    internal const string Feed = "https://api.github.com/repos/tietiezhi-1216/typewhisper-tietiezhi/releases?per_page=50";
    internal static readonly string[] PluginFiles = ["manifest.json", "TypeWhisper.Plugin.Tietiezhi.dll", "TypeWhisper.Plugin.Tietiezhi.deps.json", "LICENSE", "THIRD_PARTY_NOTICES.md"];
    internal static readonly string[] InstallerFiles = ["Install-tietiezhi.exe", "Install-tietiezhi.dll", "Install-tietiezhi.deps.json", "Install-tietiezhi.runtimeconfig.json", "README.md"];
    internal static WindowsRelease? Latest(string json, string current)
    {
        var list = JsonNode.Parse(json) as JsonArray ?? throw new InvalidDataException("GitHub 更新列表格式无效。");
        var candidates = new List<WindowsRelease>();
        foreach (var release in list.OfType<JsonObject>())
        {
            if (release["draft"]?.GetValue<bool>() == true) continue;
            var tag = release["tag_name"]?.GetValue<string>() ?? "";
            if (!tag.StartsWith("windows-v", StringComparison.Ordinal)) continue;
            var number = tag[9..];
            if (!Version.TryParse(number, out var version) || version.Build < 0 || version.Revision >= 0 || version.ToString() != number || version <= Version.Parse(current)) continue;
            string name = $"tietiezhi-{number}-windows-x64.zip";
            var assets = release["assets"] as JsonArray ?? [];
            Uri? Asset(string filename)
            {
                var matches = assets.OfType<JsonObject>().Where(a => a["name"]?.GetValue<string>() == filename).ToArray();
                string expected = Repository + "/releases/download/" + tag + "/" + filename;
                if (matches.Length != 1 || matches[0]["browser_download_url"]?.GetValue<string>() != expected) return null;
                return new Uri(expected);
            }
            var archive = Asset(name); var checksum = Asset(name + ".sha256");
            if (archive != null && checksum != null) candidates.Add(new(number, name, archive, checksum));
        }
        return candidates.OrderByDescending(c => Version.Parse(c.Version)).FirstOrDefault();
    }
    internal static string Digest(string text, string filename)
    {
        var match = Regex.Match(text.Trim(), @"\A([a-fA-F0-9]{64})  " + Regex.Escape(filename) + @"\z");
        if (!match.Success) throw new InvalidDataException("更新包校验文件格式错误。");
        return match.Groups[1].Value;
    }
    internal static void Extract(byte[] archive, string digest, string destination, string version)
    {
        if (archive.Length > 16_000_000 || !Convert.ToHexString(SHA256.HashData(archive)).Equals(digest, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("更新包 SHA-256 校验失败，未安装。");
        var allowed = new HashSet<string>(InstallerFiles.Concat(PluginFiles.Select(f => "plugin/" + f)).Append("plugin/SHA256SUMS"), StringComparer.Ordinal);
        using var stream = new MemoryStream(archive); using var zip = new ZipArchive(stream, ZipArchiveMode.Read);
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase); long total = 0;
        foreach (var entry in zip.Entries)
        {
            if (!allowed.Contains(entry.FullName) || !names.Add(entry.FullName) || (entry.ExternalAttributes >> 16 & 0xF000) == 0xA000
                || entry.Length > 8_000_000 || (total += entry.Length) > 16_000_000)
                throw new InvalidDataException("更新 ZIP 含有非法路径、重复文件或超限内容，未安装。");
        }
        if (!names.SetEquals(allowed)) throw new InvalidDataException("更新包文件不完整，未安装。");
        if (Directory.Exists(destination)) throw new InvalidDataException("更新暂存目录已存在，请重试。");
        Directory.CreateDirectory(destination);
        try
        {
            foreach (var entry in zip.Entries)
            {
                var output = Path.Combine(destination, entry.FullName.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(output)!);
                using var source = entry.Open(); using var file = new FileStream(output, FileMode.CreateNew); source.CopyTo(file);
            }
            var plugin = Path.Combine(destination, "plugin");
            var manifest = JsonNode.Parse(File.ReadAllText(Path.Combine(plugin, "manifest.json")))!;
            if (manifest["id"]?.GetValue<string>() != "com.tietiezhi.mimo-antigravity" || manifest["version"]?.GetValue<string>() != version
                || !Version.TryParse(manifest["minHostVersion"]?.GetValue<string>(), out var minimum) || minimum > new Version(1, 1, 6))
                throw new InvalidDataException("更新包插件身份、版本或宿主要求不匹配，未安装。");
            var checksums = File.ReadAllLines(Path.Combine(plugin, "SHA256SUMS")); var verified = new HashSet<string>();
            foreach (var line in checksums.Where(l => !string.IsNullOrWhiteSpace(l)))
            {
                var parts = line.Split("  ", 2, StringSplitOptions.None);
                if (parts.Length != 2 || !PluginFiles.Contains(parts[1]) || !verified.Add(parts[1])) throw new InvalidDataException("插件校验清单无效。");
                if (!Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.Combine(plugin, parts[1])))).Equals(parts[0], StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("插件文件校验失败。");
            }
            if (!verified.SetEquals(PluginFiles)) throw new InvalidDataException("插件校验清单不完整。");
            using var exe = File.OpenRead(Path.Combine(destination, "Install-tietiezhi.exe"));
            if (exe.ReadByte() != 'M' || exe.ReadByte() != 'Z') throw new InvalidDataException("更新程序不是 Windows 可执行文件。");
        }
        catch { Directory.Delete(destination, true); throw; }
    }
}
