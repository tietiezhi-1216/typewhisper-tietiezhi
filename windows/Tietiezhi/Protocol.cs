using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace TypeWhisper.Plugin.Tietiezhi;

internal sealed class OAuthDeniedException() : InvalidOperationException("Google 授权已取消或拒绝。");
internal sealed record Route(string Id, string Endpoint, string? ModelEnum);
internal sealed record Model(string Id, string Name, Route? Default, Dictionary<string, Route> Variants)
{
    public Route Resolve(string effort)
    {
        string[] preferred = effort switch
        {
            "high" => ["high", "medium", "low", "minimal"],
            "xhigh" => ["xhigh", "high", "medium", "low"],
            "medium" => ["medium", "low", "high", "minimal"],
            "minimal" => ["minimal", "low", "medium", "high"],
            _ => ["low", "minimal", "medium", "high", "xhigh"]
        };
        return preferred.Select(e => Variants.GetValueOrDefault(e)).FirstOrDefault(r => r != null)
            ?? Default ?? throw new InvalidOperationException("模型缺少运行路由。");
    }
}
internal static class Protocol
{
    public static string Base64Url(byte[] value) => Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    public static string Challenge(string value) => Base64Url(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    public static string StableProject(string seed)
    {
        var bytes = SHA1.HashData(Encoding.UTF8.GetBytes("antigravity:" + seed))[..16];
        bytes[6] = (byte)((bytes[6] & 15) | 0x50); bytes[8] = (byte)((bytes[8] & 63) | 0x80);
        var h = Convert.ToHexString(bytes).ToLowerInvariant();
        return $"{h[..8]}-{h[8..12]}-{h[12..16]}-{h[16..20]}-{h[20..]}";
    }
    public static string Callback(Uri uri, string expectedState)
    {
        var fields = uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Split('=', 2)).Select(p => (Key: Uri.UnescapeDataString(p[0]), Value: p.Length == 2 ? Uri.UnescapeDataString(p[1].Replace('+', ' ')) : "")).ToList();
        if (uri.AbsolutePath != "/oauth-callback" || fields.Count(p => p.Key == "state") != 1 || fields.Single(p => p.Key == "state").Value != expectedState)
            throw new InvalidOperationException("OAuth 回调 state 校验失败。");
        if (fields.Any(p => p.Key == "error")) throw new OAuthDeniedException();
        if (fields.Count(p => p.Key == "code") != 1 || string.IsNullOrEmpty(fields.Single(p => p.Key == "code").Value))
            throw new InvalidOperationException("OAuth 回调缺少唯一授权码。");
        return fields.Single(p => p.Key == "code").Value;
    }
    public static string? Project(JsonObject obj)
    {
        foreach (var key in new[] { "antigravityProjectId", "projectId", "backendProjectId", "userDefinedCloudaicompanionProject", "cloudaicompanionProject", "project" })
        {
            var node = obj[key];
            if (node is JsonValue && node.GetValue<string>() is { Length: > 0 } s) return s;
            if (node is JsonObject nested && nested["id"]?.GetValue<string>() is { Length: > 0 } id) return id;
        }
        foreach (var key in new[] { "projects", "projectIds", "cloudaicompanionProjects" })
            foreach (var item in obj[key] as JsonArray ?? [])
            {
                if (item is JsonValue && item.GetValue<string>() is { Length: > 0 } s) return s;
                if (item is JsonObject o && Project(o) is { } id) return id;
            }
        return null;
    }
    public static List<Model> Catalog(JsonObject root, string endpoint)
    {
        var map = (root["response"] as JsonObject ?? root)["models"] as JsonObject ?? throw new InvalidOperationException("模型目录格式无效。");
        var models = new Dictionary<string, Model>();
        foreach (var (id, value) in map.OrderBy(p => p.Key, StringComparer.Ordinal))
        {
            if (!(id.StartsWith("gemini-") || id.StartsWith("claude-") || id.StartsWith("gpt-oss-")) || id.Any(char.IsWhiteSpace)
                || new[] { "image", "tts", "embedding", "live", "audio", "computer-use" }.Any(id.Contains)
                || value is not JsonObject info || info["isInternal"]?.GetValue<bool>() == true) continue;
            var name = (info["displayName"] ?? info["label"] ?? info["modelName"] ?? info["name"])?.GetValue<string>() ?? id;
            string family = id; string? level = null;
            if (id == "gemini-3-flash-agent") { family = "gemini-3.5-flash"; level = "high"; }
            else if (id == "gemini-pro-agent") { family = "gemini-3.1-pro"; level = "high"; }
            else
            {
                var match = Regex.Match(id, @"-(extra-low|extra-high|thinking|minimal|medium|high|low)$");
                if (match.Success) { family = id[..match.Index]; level = Normalize(match.Groups[1].Value); }
                else if (id.EndsWith("-tiered")) family = id[..^7];
                var display = Regex.Match(name, @"\(\s*(extra\s*low|extra\s*high|thinking|minimal|medium|high|low)\s*\)", RegexOptions.IgnoreCase);
                if (display.Success) level = Normalize(Regex.Replace(display.Groups[1].Value.ToLowerInvariant(), @"\s+", "-"));
            }
            var cleanName = Regex.Replace(name, @"\s*\(\s*(extra\s*low|extra\s*high|thinking|minimal|medium|high|low)\s*\)\s*$", "", RegexOptions.IgnoreCase);
            var model = models.GetValueOrDefault(family) ?? new Model(family, cleanName, null, []);
            var route = new Route(id, endpoint, info["model"]?.GetValue<string>());
            if (level != null) model.Variants[level] = route;
            else model = model with { Default = route };
            models[family] = model;
        }
        return models.Values.OrderBy(m => m.Name, StringComparer.Ordinal).ToList();
    }
    private static string Normalize(string value) => value switch { "extra-low" => "low", "extra-high" => "xhigh", "thinking" => "high", _ => value };
    public static List<Model> Merge(IEnumerable<List<Model>> catalogs)
    {
        var result = new Dictionary<string, Model>();
        foreach (var model in catalogs.SelectMany(c => c))
        {
            if (!result.TryGetValue(model.Id, out var old)) { result[model.Id] = model; continue; }
            foreach (var pair in model.Variants) old.Variants.TryAdd(pair.Key, pair.Value);
            result[model.Id] = old with { Default = old.Default ?? model.Default };
        }
        return result.Values.OrderBy(m => m.Name, StringComparer.Ordinal).ToList();
    }
    public static JsonObject Thinking(string model, string effort)
    {
        bool off = effort is "auto" or "off";
        int budget = 0;
        if (!off)
        {
            bool high = effort is "high" or "xhigh";
            budget = model.StartsWith("claude-") ? 1024 : model.StartsWith("gpt-oss-") ? 8192
                : model.StartsWith("gemini-3.5-flash") || model == "gemini-3-flash-agent" ? high ? 10000 : effort == "medium" ? 4000 : 1000
                : model.StartsWith("gemini-3.1-pro") || model == "gemini-pro-agent" ? high ? 10001 : 1001
                : high ? -1 : effort == "medium" ? 4000 : 1000;
        }
        return new JsonObject { ["thinkingBudget"] = budget, ["includeThoughts"] = !off };
    }
    public static string GeneratedText(string body)
    {
        var output = new StringBuilder(); string? finish = null;
        void Consume(string data)
        {
            if (data == "[DONE]") return;
            var obj = JsonNode.Parse(data) as JsonObject ?? throw new InvalidOperationException("润色响应格式无效。");
            var response = obj["response"] as JsonObject ?? obj;
            if (obj["error"] != null || response["error"] != null) throw new InvalidOperationException("润色流返回错误，未输出不完整文本。");
            if (response["candidates"] is not JsonArray candidates || candidates.Count == 0)
            {
                if (response["usageMetadata"] != null) return;
                throw new InvalidOperationException("润色响应缺少候选内容。");
            }
            var candidate = candidates[0]!;
            if (candidate["finishReason"] is { } reason) finish = reason.GetValue<string>();
            foreach (var part in candidate["content"]?["parts"] as JsonArray ?? [])
                if (part?["thought"]?.GetValue<bool>() != true) output.Append(part?["text"]?.GetValue<string>());
        }
        if (body.TrimStart().StartsWith('{')) Consume(body);
        else
        {
            var data = new List<string>();
            foreach (var line in body.Replace("\r\n", "\n").Split('\n').Append(""))
            {
                if (line.Length == 0) { if (data.Count > 0) { Consume(string.Join("\n", data)); data.Clear(); } }
                else if (line.StartsWith("data:")) data.Add(line[5..].TrimStart());
            }
        }
        if (finish != "STOP" || string.IsNullOrWhiteSpace(output.ToString())) throw new InvalidOperationException("润色未完整结束，未返回不完整结果。");
        return output.ToString().Trim();
    }
}

internal sealed record WavChunks(List<byte[]> Chunks, double Duration)
{
    // Host capture is PCM16; also accept stereo/other rates, retaining format per chunk.
    public static WavChunks Parse(byte[] wav)
    {
        static uint U32(byte[] b, int i) => BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(i, 4));
        static ushort U16(byte[] b, int i) => BinaryPrimitives.ReadUInt16LittleEndian(b.AsSpan(i, 2));
        if (wav.Length < 44 || Encoding.ASCII.GetString(wav, 0, 4) != "RIFF" || Encoding.ASCII.GetString(wav, 8, 4) != "WAVE" || U32(wav, 4) != wav.Length - 8)
            throw new InvalidOperationException("仅支持有效 PCM16 WAV 录音。");
        byte[]? format = null, audio = null;
        for (int offset = 12; offset + 8 <= wav.Length;)
        {
            uint size = U32(wav, offset + 4);
            if (size > int.MaxValue || size > wav.Length - offset - 8) throw new InvalidOperationException("WAV 数据被截断。");
            var id = Encoding.ASCII.GetString(wav, offset, 4);
            if (id == "fmt ") format = wav.AsSpan(offset + 8, (int)size).ToArray();
            if (id == "data") audio = wav.AsSpan(offset + 8, (int)size).ToArray();
            offset = checked(offset + 8 + (int)size + (int)(size % 2));
        }
        if (format is not { Length: >= 16 } || audio is not { Length: > 0 } || U16(format, 0) != 1 || U16(format, 14) != 16)
            throw new InvalidOperationException("需要 PCM16 WAV，暂不支持此音频格式。");
        int channels = U16(format, 2), align = U16(format, 12); uint rate = U32(format, 4), byteRate = U32(format, 8);
        if (channels is < 1 or > 2 || rate is < 8000 or > 192000 || align != channels * 2 || byteRate != rate * align || audio.Length % align != 0)
            throw new InvalidOperationException("WAV 格式参数无效。");
        int chunkSize = (int)(Math.Min((long)byteRate * 180, 7_000_000) / align * align);
        var chunks = new List<byte[]>();
        for (int offset = 0; offset < audio.Length; offset += chunkSize)
        {
            int count = Math.Min(chunkSize, audio.Length - offset);
            using var stream = new MemoryStream(); using var writer = new BinaryWriter(stream);
            writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + count); writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
            writer.Write(16); writer.Write(format, 0, 16); writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(count); writer.Write(audio, offset, count);
            chunks.Add(stream.ToArray());
        }
        return new(chunks, audio.Length / (double)byteRate);
    }
}
