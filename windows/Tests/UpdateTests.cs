using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using TypeWhisper.Plugin.Tietiezhi;

internal static class UpdateTests
{
    internal static async Task Run(Action<bool,string> check, Action<Action,string> throws, Func<Func<Task>,string,Task> throwsAsync, string[] args)
    {
        JsonObject Release(string version)
        {
            var name = $"tietiezhi-{version}-windows-x64.zip"; string prefix = WindowsUpdateCore.Repository + "/releases/download/windows-v" + version + "/";
            return new() { ["tag_name"] = "windows-v" + version, ["draft"] = false, ["prerelease"] = true,
                ["assets"] = new JsonArray(new JsonObject { ["name"] = name, ["browser_download_url"] = prefix + name }, new JsonObject { ["name"] = name + ".sha256", ["browser_download_url"] = prefix + name + ".sha256" }) };
        }
        var releases = new JsonArray(new JsonObject { ["tag_name"] = "v9.0.0" }, Release("0.1.2"), Release("0.1.3"));
        var latest = WindowsUpdateCore.Latest(releases.ToJsonString(), "0.1.2")!;
        check(latest.Version == "0.1.3", "Windows update selects newest Windows preview, not Mac latest");
        check(WindowsUpdateCore.Latest(releases.ToJsonString(), "0.1.3") == null, "same version is not an update");
        var malformed = Release("0.1.4"); malformed["assets"]![0]!["browser_download_url"] = "https://evil.invalid/update.zip";
        check(WindowsUpdateCore.Latest(new JsonArray(malformed).ToJsonString(), "0.1.2") == null, "reject foreign release download URL");
        var draft = Release("0.1.5"); draft["draft"] = true;
        check(WindowsUpdateCore.Latest(new JsonArray(draft).ToJsonString(), "0.1.2") == null, "ignore draft releases");
        check(!WindowsUpdates.Trusted(new("http://github.com/file")) && !WindowsUpdates.Trusted(new("https://github.com.evil.invalid/file")), "reject HTTP and lookalike update hosts");
        check(!WindowsUpdates.Trusted(new("https://github.com:8443/file")) && !WindowsUpdates.Trusted(new("https://user@github.com/file")), "reject nondefault port and userinfo");
        string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
        var bytes = Package("0.1.3"); var digest = Hash(bytes);
        check(WindowsUpdateCore.Digest(digest + "  " + latest.ArchiveName + "\n", latest.ArchiveName) == digest, "strict checksum format");
        throws(() => WindowsUpdateCore.Digest(digest + "  wrong.zip", latest.ArchiveName), "reject checksum for another archive");
        var temp = Path.Combine(Path.GetTempPath(), "tietiezhi-update-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            var success = Path.Combine(temp, "valid"); WindowsUpdateCore.Extract(bytes, digest, success, "0.1.3");
            check(File.Exists(Path.Combine(success, "Install-tietiezhi.exe")) && File.Exists(Path.Combine(success, "plugin", "manifest.json")), "extract complete verified installer");
            throws(() => WindowsUpdateCore.Extract(bytes, new string('0',64), Path.Combine(temp,"hash"), "0.1.3"), "reject SHA mismatch before extraction");
            throws(() => WindowsUpdateCore.Extract(bytes, digest, success, "0.1.3"), "refuse overwrite of staging directory");
            throws(() => WindowsUpdateCore.Extract(bytes, digest, Path.Combine(temp,"version"), "0.1.4"), "reject archive version mismatch");
            check(!Directory.Exists(Path.Combine(temp,"version")), "remove staging after validation failure");
            var incompatible = Package("0.1.3", "1.2.1");
            throws(() => WindowsUpdateCore.Extract(incompatible, Hash(incompatible), Path.Combine(temp,"incompatible"), "0.1.3"), "reject update incompatible with host contract");
            var traversal = Package("0.1.3", extra: "../escape.exe");
            throws(() => WindowsUpdateCore.Extract(traversal, Hash(traversal), Path.Combine(temp,"traversal"), "0.1.3"), "reject ZIP path traversal");
            var duplicate = Package("0.1.3", extra: "README.md");
            throws(() => WindowsUpdateCore.Extract(duplicate, Hash(duplicate), Path.Combine(temp,"duplicate"), "0.1.3"), "reject duplicate ZIP entry");
            var symlink = Package("0.1.3", symlink: true);
            throws(() => WindowsUpdateCore.Extract(symlink, Hash(symlink), Path.Combine(temp,"symlink"), "0.1.3"), "reject ZIP symlink");
            var corrupt = Package("0.1.3", corrupt: true);
            throws(() => WindowsUpdateCore.Extract(corrupt, Hash(corrupt), Path.Combine(temp,"corrupt"), "0.1.3"), "reject corrupt inner plugin even when outer hash matches");
            int requests = 0;
            using var http = new HttpClient(new Handler((request, ct) => {
                requests++; check(request.Headers.Authorization == null, "updater does not send OAuth or MiMo credentials");
                byte[] body = request.RequestUri!.Host == "api.github.com" ? Encoding.UTF8.GetBytes(releases.ToJsonString())
                    : request.RequestUri.AbsolutePath.EndsWith(".sha256") ? Encoding.UTF8.GetBytes(digest + "  " + latest.ArchiveName) : bytes;
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(body) });
            }));
            var service = new WindowsUpdates(http); var found = await service.Check("0.1.2", default);
            var prepared = await service.Prepare(found!, temp, default);
            check(requests == 3 && File.Exists(Path.Combine(prepared, "Install-tietiezhi.exe")), "online check checksum download and safe staging");
            using var redirectHttp = new HttpClient(new Handler((request, ct) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Redirect) {
                Headers = { Location = new Uri("https://evil.invalid/update") }
            })));
            await throwsAsync(() => new WindowsUpdates(redirectHttp).Check("0.1.2", default), "reject redirect to untrusted host");
            if (OperatingSystem.IsWindows() && args.Length == 2 && args[0] == "--packaged-smoke")
                await AutomaticSmoke(args[1], temp, check);
        }
        finally { Directory.Delete(temp, true); }
        if (args.Contains("--public-update-smoke"))
        {
            // Explicit opt-in only; CI/offline tests never contact the real service.
            using var publicHttp = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(120) };
            var updater = new WindowsUpdates(publicHttp);
            var release = await updater.Check("0.1.1", default);
            check(release != null && Version.Parse(release.Version) >= new Version(0,1,2), "public GitHub feed discovers Windows update");
            var publicRoot = Path.Combine(Path.GetTempPath(), "tietiezhi-public-update-" + Guid.NewGuid().ToString("N"));
            try
            {
                var staged = await updater.Prepare(release!, publicRoot, default);
                check(File.Exists(Path.Combine(staged,"Install-tietiezhi.exe")), "public download redirect SHA ZIP and inner hashes verified");
            }
            finally { if (Directory.Exists(publicRoot)) Directory.Delete(publicRoot,true); }
        }
    }
    private static byte[] Package(string version, string minimum = "1.1.6", string? extra = null, bool symlink = false, bool corrupt = false)
    {
        var files = new Dictionary<string,byte[]>();
        foreach (var file in WindowsUpdateCore.InstallerFiles) files[file] = Encoding.UTF8.GetBytes(file.EndsWith(".exe") ? "MZfixture" : "fixture");
        foreach (var file in WindowsUpdateCore.PluginFiles) files["plugin/" + file] = Encoding.UTF8.GetBytes("fixture");
        files["plugin/manifest.json"] = Encoding.UTF8.GetBytes(new JsonObject {
            ["id"] = "com.tietiezhi.mimo-antigravity", ["version"] = version, ["minHostVersion"] = minimum
        }.ToJsonString());
        files["plugin/SHA256SUMS"] = Encoding.UTF8.GetBytes(string.Join('\n', WindowsUpdateCore.PluginFiles.Select(f => Convert.ToHexString(SHA256.HashData(files["plugin/" + f])) + "  " + f)));
        if (corrupt) files["plugin/TypeWhisper.Plugin.Tietiezhi.dll"] = Encoding.UTF8.GetBytes("damaged");
        using var output = new MemoryStream();
        using (var zip = new ZipArchive(output, ZipArchiveMode.Create, true))
        {
            foreach (var (name, data) in files)
            {
                var entry = zip.CreateEntry(name);
                if (symlink && name == "README.md") entry.ExternalAttributes = unchecked((int)0xA1FF0000);
                using var stream = entry.Open(); stream.Write(data);
            }
            if (extra != null) { using var file = zip.CreateEntry(extra).Open(); file.WriteByte(0); }
        }
        return output.ToArray();
    }
    private static async Task AutomaticSmoke(string package, string root, Action<bool,string> check)
    {
        if (Process.GetProcessesByName("TypeWhisper").Length > 0) throw new Exception("Smoke test refuses to run alongside a real TypeWhisper instance.");
        var directory = Path.Combine(root, "automatic"); Directory.CreateDirectory(directory);
        var staged = Path.Combine(directory, "staged"); ZipFile.ExtractToDirectory(Path.GetFullPath(package), staged);
        var profile = Path.Combine(directory, "profile"); Directory.CreateDirectory(Path.Combine(profile,"PluginPackages"));
        var index = Path.Combine(profile,"PluginPackages","installed.json");
        File.WriteAllText(index, """{"com.example.existing":{"directory":"old","version":"1.0.0"}}""");
        var fixture = Path.Combine(AppContext.BaseDirectory, "TypeWhisper.exe");
        File.Copy(Path.Combine(AppContext.BaseDirectory,"Tietiezhi.Tests.exe"), fixture, true);
        var marker = Path.Combine(directory,"restarted");
        Process? parent = null;
        try
        {
            var parentStart = new ProcessStartInfo(fixture) { UseShellExecute = false, CreateNoWindow = true }; parentStart.ArgumentList.Add("--fixture-host");
            parent = Process.Start(parentStart)!;
            var updaterStart = new ProcessStartInfo(Path.Combine(staged,"Install-tietiezhi.exe")) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in new[] { "--update-after-exit", parent.Id.ToString(), "--profile", profile, "--restart", fixture }) updaterStart.ArgumentList.Add(arg);
            updaterStart.Environment["TIETIEZHI_UPDATE_SMOKE_RESTART_MARKER"] = marker;
            using var updater = Process.Start(updaterStart)!;
            await Task.Delay(500);
            check(!File.ReadAllText(index).Contains("com.tietiezhi"), "automatic updater does not modify host index while host is running");
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
            await updater.WaitForExitAsync(timeout.Token);
            var result = JsonNode.Parse(File.ReadAllText(Path.Combine(staged,"update-result.json")))!;
            check(updater.ExitCode == 0 && result["success"]!.GetValue<bool>(), "Windows detached updater waits for host exit then installs");
            for (int i=0; i<50 && !File.Exists(marker); i++) await Task.Delay(100);
            check(File.Exists(marker), "Windows updater automatically restarts host after install");
            var registry = JsonNode.Parse(File.ReadAllText(index))!;
            var expectedVersion = JsonNode.Parse(File.ReadAllText(Path.Combine(staged,"plugin","manifest.json")))!["version"]!.GetValue<string>();
            check(registry["com.tietiezhi.mimo-antigravity"]?["version"]?.GetValue<string>() == expectedVersion && registry["com.example.existing"] != null, "automatic update preserves other providers and installs new version");
            for (int i=0; i<30 && Process.GetProcessesByName("TypeWhisper").Length != 0; i++) await Task.Delay(100);
        }
        finally
        {
            if (parent != null) { if (!parent.HasExited) parent.Kill(); parent.Dispose(); }
            if (File.Exists(fixture)) File.Delete(fixture);
        }
    }
}
