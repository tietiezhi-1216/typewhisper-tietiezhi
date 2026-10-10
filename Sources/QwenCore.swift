import Foundation

// Protocols verified against Alibaba's API references, not inferred from names.
// Qwen-Audio 3.x is NOT the OpenAI-compatible Qwen3-ASR protocol.
enum QwenWire: Sendable { case chat, flash, file, qwenFile, streaming, message, realtime
    var live: Bool { self == .streaming || self == .message || self == .realtime }
}
struct QwenModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let wire: QwenWire
}
enum QwenRegion: String, CaseIterable, Sendable {
    case beijing, singapore
    var name: String { self == .beijing ? "北京（默认）" : "新加坡" }
    var host: String { self == .beijing ? "dashscope.aliyuncs.com" : "dashscope-intl.aliyuncs.com" }
    func url(_ path: String, websocket: Bool = false) -> URL {
        URL(string: (websocket ? "wss://" : "https://") + host + path)!
    }
}
enum QwenError: LocalizedError {
    case missingKey, model, audio, response, incomplete, timeout, notRealtime, network
    case http(String, Int), failed(String)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "请先在千问 ASR 设置中保存百炼 API Key。"
        case .model: return "请选择受支持的千问 ASR 模型。"
        case .audio: return "录音为空、无效或超过本插件的 30 分钟限制。"
        case .response: return "千问返回的数据无效或不符合当前模型的协议。"
        case .incomplete: return "千问识别未完整结束，未返回截断结果。"
        case .timeout: return "千问请求超时。不会自动重新提交付费任务。"
        case .notRealtime: return "此模型不支持实时录音；请使用 Flash-Streaming、Flash-Message 或 Flash-Realtime。"
        case .network: return "无法连接千问服务，请检查网络、API Key、所选地域和模型权限。"
        case .failed(let stage): return "千问\(stage)失败，请检查模型权限、音频格式及账户额度。"
        case .http(let stage, let code):
            switch code {
            case 401, 403: return "千问\(stage)认证失败（HTTP \(code)）。请检查 API Key、地域及模型权限。"
            case 429: return "千问\(stage)受限（HTTP 429）。请检查额度并稍后重试。"
            default: return "千问\(stage)失败（HTTP \(code)）。请检查模型权限及服务状态。"
            }
        }
    }
}
enum QwenCore {
    static let secretKey = "qwen-api-key.v1"
    static let modelKey = "qwen-asr-model.v1"
    static let regionKey = "qwen-asr-region.v1"
    static let defaultModel = "qwen-audio-3.1-asr-flash"
    static let maxSamples = 30 * 60 * 16_000
    static let models: [QwenModel] = [
        .init(id: "qwen-audio-3.1-asr-flash", name: "Qwen-Audio 3.1 · Flash（同步）", wire: .flash),
        .init(id: "qwen-audio-3.1-asr-flash-message", name: "Qwen-Audio 3.1 · Message（实时输入法）", wire: .message),
        .init(id: "qwen-audio-3.1-asr-flash-streaming", name: "Qwen-Audio 3.1 · Streaming（实时）", wire: .streaming),
        .init(id: "qwen-audio-3.1-asr-flash-filetrans", name: "Qwen-Audio 3.1 · Filetrans（异步文件）", wire: .file),
        .init(id: "qwen-audio-3.0-asr-flash", name: "Qwen-Audio 3.0 · Flash（同步）", wire: .flash),
        .init(id: "qwen-audio-3.0-asr-flash-streaming", name: "Qwen-Audio 3.0 · Streaming（实时）", wire: .streaming),
        .init(id: "qwen-audio-3.0-asr-flash-filetrans", name: "Qwen-Audio 3.0 · Filetrans（异步文件）", wire: .file),
        .init(id: "qwen3-asr-flash", name: "Qwen3 ASR · Flash（同步）", wire: .chat),
        .init(id: "qwen3-asr-flash-realtime", name: "Qwen3 ASR · Realtime（实时）", wire: .realtime),
        .init(id: "qwen3-asr-flash-filetrans", name: "Qwen3 ASR · Filetrans（异步文件）", wire: .qwenFile)
    ]
    static func model(_ id: String) throws -> QwenModel {
        guard let model = models.first(where: { $0.id == id }) else { throw QwenError.model }
        return model
    }
    static func language(_ value: String?, wire: QwenWire) -> String? {
        var code = value?.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
        if value?.lowercased().replacingOccurrences(of: "_", with: "-").hasPrefix("zh-hk") == true { code = "yue" }
        let qwen3 = wire == .chat || wire == .qwenFile || wire == .realtime
        if code == "yue", !qwen3 { code = "zh" }
        if code == "tl" && (wire == .chat || wire == .qwenFile || wire == .realtime) { code = "fil" }
        if code == "fil" && !(wire == .chat || wire == .qwenFile || wire == .realtime) { code = "tl" }
        return languages(wire: wire).contains(code) ? code : nil
    }
    static func languages(wire: QwenWire) -> [String] {
        let common = ["zh", "en", "ja", "ko", "vi", "th", "id", "ms", "hi", "ar", "fr", "de", "es", "pt", "ru", "it", "sv", "da", "fi", "no", "pl", "cs", "tr", "uk"]
        return common + ((wire == .chat || wire == .qwenFile || wire == .realtime) ? ["yue", "fil", "is"] : ["tl", "nl", "el", "hu"])
    }
    static func request(region: QwenRegion, path: String, key: String, body: [String: Any]? = nil) throws -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.utf8.contains(13), !key.utf8.contains(10) else { throw QwenError.missingKey }
        var r = URLRequest(url: region.url(path), timeoutInterval: 120)
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }
    static func audioMessage(_ data: String) -> [String: Any] {
        ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": data]]]]
    }
    static func context(_ prompt: String?) -> [[String: Any]] {
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [["role": "user", "content": [["type": "input_text", "text": String(prompt.prefix(400))]]]]
    }
    static func synchronous(model: QwenModel, wav: Data, key: String, region: QwenRegion, language: String?, prompt: String?) throws -> URLRequest {
        guard !wav.isEmpty, wav.count * 4 / 3 + 64 <= 10_000_000 else { throw QwenError.audio }
        let uri = "data:audio/wav;base64," + wav.base64EncodedString()
        var body: [String: Any]
        let path: String
        if model.wire == .chat {
            path = "/compatible-mode/v1/chat/completions"
            var options: [String: Any] = ["enable_itn": true]
            if let code = self.language(language, wire: model.wire) { options["language"] = code }
            var messages: [[String: Any]] = []
            if let prompt, !prompt.isEmpty { messages.append(["role": "system", "content": String(prompt.prefix(400))]) }
            messages.append(audioMessage(uri))
            body = ["model": model.id, "stream": false, "messages": messages, "asr_options": options]
        } else {
            guard model.wire == .flash else { throw QwenError.model }
            path = "/api/v1/services/aigc/multimodal-generation/generation"
            var parameters: [String: Any] = ["format": "wav", "sample_rate": "16000"]
            if let code = self.language(language, wire: model.wire) { parameters["language_hints"] = [code] }
            body = ["model": model.id, "input": ["messages": context(prompt) + [audioMessage(uri)]], "parameters": parameters]
        }
        body["model"] = model.id
        return try request(region: region, path: path, key: key, body: body)
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QwenError.response }
        return value
    }
    static func synchronousText(_ data: Data, wire: QwenWire) throws -> String {
        let o = try object(data)
        if o["code"] != nil { throw QwenError.failed("识别") }
        if wire == .flash, let output = o["output"] as? [String: Any], let text = output["text"] as? String { return text }
        if wire == .chat, let choices = o["choices"] as? [[String: Any]], let choice = choices.first,
           choice["finish_reason"] as? String == "stop", let msg = choice["message"] as? [String: Any], let text = msg["content"] as? String { return text }
        throw QwenError.incomplete
    }
    static func submission(model: QwenModel, url: String, key: String, region: QwenRegion, language: String?, prompt: String?) throws -> URLRequest {
        guard model.wire == .file || model.wire == .qwenFile else { throw QwenError.model }
        var input: [String: Any] = model.wire == .qwenFile ? ["file_url": url] : ["file_urls": [url]]
        var parameters: [String: Any] = [:]
        if model.wire == .qwenFile {
            parameters["enable_itn"] = true
            if let code = self.language(language, wire: model.wire) { parameters["language"] = code }
        } else {
            parameters["channel_id"] = [0]
            if let code = self.language(language, wire: model.wire) { parameters["language_hints"] = [code] }
            if !context(prompt).isEmpty { input["context"] = context(prompt) }
        }
        var r = try request(region: region, path: "/api/v1/services/audio/asr/transcription", key: key,
                            body: ["model": model.id, "input": input, "parameters": parameters])
        r.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        r.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
        return r
    }
    // Never send the API Key to storage, follow redirects, or use plaintext HTTP.
    // Some official responses contain HTTP OSS URLs; upgrade those to HTTPS.
    static func storageURL(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value), let host = parts.host?.lowercased(),
              host.range(of: #"^[a-z0-9-]+\.oss-[a-z0-9-]+\.aliyuncs\.com$"#, options: .regularExpression) != nil,
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              parts.fragment == nil, parts.scheme == "https" || parts.scheme == "http" else { throw QwenError.response }
        parts.scheme = "https"
        guard let url = parts.url else { throw QwenError.response }
        return url
    }
    static func resultURL(_ output: [String: Any], wire: QwenWire) throws -> URL {
        let result: [String: Any]?
        if wire == .qwenFile { result = output["result"] as? [String: Any] }
        else {
            let items = output["results"] as? [[String: Any]]
            guard items?.count == 1, items?.first?["subtask_status"] as? String == "SUCCEEDED" else { throw QwenError.failed("文件转写") }
            result = items?.first
        }
        guard let value = result?["transcription_url"] as? String else { throw QwenError.response }
        return try storageURL(value)
    }
    static func fileText(_ data: Data) throws -> String {
        let o = try object(data)
        guard let transcripts = o["transcripts"] as? [[String: Any]],
              transcripts.allSatisfy({ $0["text"] is String }) else { throw QwenError.response }
        return MiMoCore.join(transcripts.compactMap { $0["text"] as? String })
    }
    static func socketRequest(model: QwenModel, key: String, region: QwenRegion) throws -> URLRequest {
        guard model.wire.live else { throw QwenError.notRealtime }
        var r = try request(region: region, path: "/api-ws/v1/inference", key: key)
        if model.wire == .realtime {
            var parts = URLComponents(url: region.url("/api-ws/v1/realtime", websocket: true), resolvingAgainstBaseURL: false)!
            parts.queryItems = [.init(name: "model", value: model.id)]
            r.url = parts.url!
            r.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        } else { r.url = region.url("/api-ws/v1/inference", websocket: true) }
        return r
    }
    static func socketStart(model: QwenModel, taskID: String, language: String?, prompt: String?) throws -> Data {
        guard model.wire.live else { throw QwenError.notRealtime }
        let body: [String: Any]
        if model.wire == .realtime {
            var transcription: [String: Any] = [:]
            if let code = self.language(language, wire: model.wire) { transcription["language"] = code }
            body = ["event_id": UUID().uuidString, "type": "session.update", "session": [
                "modalities": ["text"], "input_audio_format": "pcm", "sample_rate": 16000,
                "input_audio_transcription": transcription,
                "turn_detection": ["type": "server_vad", "threshold": 0.0, "silence_duration_ms": 400]
            ]]
        } else {
            var parameters: [String: Any] = ["format": "pcm", "sample_rate": 16000]
            if model.wire == .message { parameters["intermediate_result_enabled"] = true }
            if let code = self.language(language, wire: model.wire) { parameters["language_hints"] = [code] }
            var input: [String: Any] = [:]
            if !context(prompt).isEmpty { input["context"] = context(prompt) }
            body = ["header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
                    "payload": ["task_group": "audio", "task": "asr", "function": "recognition", "model": model.id,
                                "parameters": parameters, "input": input]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}

// Sentence revisions replace earlier hypotheses; final output excludes unfinished
// hypotheses and heartbeat events. Never concatenate repeated cumulative text.
struct QwenSocketResults: Sendable {
    var started = false
    var finished = false
    private var order: [String] = []
    private var sentences: [String: String] = [:]
    private var finals: Set<String> = []
    var progress: String { MiMoCore.join(order.compactMap { sentences[$0] }) }
    var text: String { MiMoCore.join(order.filter { finals.contains($0) }.compactMap { sentences[$0] }) }
    var hasUnfinished: Bool { order.contains { !finals.contains($0) && !(sentences[$0]?.isEmpty ?? true) } }
    mutating func consume(_ data: Data, wire: QwenWire, taskID: String) throws {
        guard !finished else { throw QwenError.incomplete }
        let o = try QwenCore.object(data)
        if wire == .realtime {
            guard let type = o["type"] as? String else { throw QwenError.response }
            switch type {
            case "error", "conversation.item.input_audio_transcription.failed": throw QwenError.failed("实时识别")
            case "session.updated": started = true
            case "session.finished": finished = true
            case "conversation.item.input_audio_transcription.completed", "conversation.item.input_audio_transcription.text":
                guard let id = o["item_id"] as? String else { throw QwenError.response }
                let final = type.hasSuffix(".completed")
                guard let text = (final ? o["transcript"] : o["text"]) as? String else { throw QwenError.response }
                update(id: id, text: text + (final ? "" : (o["stash"] as? String ?? "")), final: final)
            default: break
            }
        } else {
            guard let header = o["header"] as? [String: Any], header["task_id"] as? String == taskID,
                  let event = header["event"] as? String else { throw QwenError.response }
            switch event {
            case "task-started": started = true
            case "task-finished": finished = true
            case "task-failed": throw QwenError.failed("实时识别")
            case "result-generated":
                guard let payload = o["payload"] as? [String: Any], let output = payload["output"] as? [String: Any],
                      let sentence = output["sentence"] as? [String: Any] else { throw QwenError.response }
                if sentence["heartbeat"] as? Bool == true { return }
                guard let id = sentence["sentence_id"] as? Int, id > 0, let text = sentence["text"] as? String,
                      let final = sentence["sentence_end"] as? Bool else { throw QwenError.response }
                update(id: String(id), text: text, final: final)
            default: break
            }
        }
        guard progress.utf8.count <= 2_000_000 else { throw QwenError.response }
    }
    private mutating func update(id: String, text: String, final: Bool) {
        if sentences[id] == nil { order.append(id) }
        if finals.contains(id), !final { return }
        sentences[id] = text
        if final { finals.insert(id) }
    }
}
