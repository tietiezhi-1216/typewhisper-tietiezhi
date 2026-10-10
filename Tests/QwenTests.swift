import Foundation
import TypeWhisperPluginSDK

private actor QwenHTTPFixture {
    var requests: [URLRequest] = []
    let wire: QwenWire
    var pollCount = 0
    let id = "12345678-1234-4234-8234-123456789abc"
    init(wire: QwenWire) { self.wire = wire }
    func call(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        let object: [String: Any]
        var status = 200
        if path == "/api/v1/uploads" {
            object = ["output": ["upload_host": "http://dashscope-upload.oss-cn-beijing.aliyuncs.com", "upload_dir": "temporary/inference",
                "oss_access_key_id": "temporary-id", "signature": "temporary-signature", "policy": "temporary-policy",
                "x_oss_object_acl": "private", "x_oss_forbid_overwrite": "true"]]
        } else if request.url!.host!.contains("dashscope-upload.") {
            object = [:]; status = 204
        } else if path.hasSuffix("/transcription") {
            object = ["output": ["task_id": id, "task_status": "PENDING"]]
        } else if path.contains("/tasks/") {
            pollCount += 1
            let result = "http://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/results/test.json?Signature=temporary"
            if pollCount == 1 { object = ["output": ["task_id": id, "task_status": "RUNNING"]] }
            else if wire == .qwenFile { object = ["output": ["task_id": id, "task_status": "SUCCEEDED", "result": ["transcription_url": result]]] }
            else { object = ["output": ["task_id": id, "task_status": "SUCCEEDED", "results": [["subtask_status": "SUCCEEDED", "transcription_url": result]]]] }
        } else { object = ["transcripts": [["channel_id": 0, "text": "测试转写。"]]] }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

// Simulates the two distinct WebSocket wire protocols, including handshake,
// binary PCM vs base64 append, finish acknowledgement and resource cleanup.
private final class QwenSocketFixture: QwenSocketTransport, @unchecked Sendable {
    private struct State {
        var queue: [Data] = []
        var sent: [QwenSocketMessage] = []
        var closed = false
    }
    private let lock = NSLock()
    private var state = State()
    let wire: QwenWire
    let binaryDelay: Duration
    var closeBeforeFinish = false
    init(wire: QwenWire, binaryDelay: Duration = .zero) { self.wire = wire; self.binaryDelay = binaryDelay }
    func send(_ message: QwenSocketMessage) async throws {
        if case .binary = message, binaryDelay > .zero { try await Task.sleep(for: binaryDelay) }
        try lock.withLock {
            guard !state.closed else { throw CancellationError() }
            state.sent.append(message)
            guard case .text(let text) = message else { return }
            let o = try QwenCore.object(Data(text.utf8))
            if wire == .realtime {
                switch o["type"] as? String {
                case "session.update": try enqueue(["type": "session.updated"])
                case "session.finish":
                    if closeBeforeFinish { state.closed = true; return }
                    try enqueue(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item-1", "transcript": "实时结果。"])
                    try enqueue(["type": "session.finished"])
                default: break
                }
            } else {
                let h = o["header"] as! [String: Any]
                let id = h["task_id"] as! String
                if h["action"] as? String == "run-task" { try enqueue(["header": ["task_id": id, "event": "task-started"]]) }
                else if h["action"] as? String == "finish-task" {
                    if closeBeforeFinish { state.closed = true; return }
                    try enqueue(["header": ["task_id": id, "event": "result-generated"], "payload": ["output": ["sentence": ["sentence_id": 1, "text": "实时结果。", "sentence_end": true]]]])
                    try enqueue(["header": ["task_id": id, "event": "task-finished"]])
                }
            }
        }
    }
    private func enqueue(_ o: [String: Any]) throws { state.queue.append(try JSONSerialization.data(withJSONObject: o)) }
    func receive() async throws -> Data {
        while true {
            try Task.checkCancellation()
            let data: Data? = try lock.withLock {
                if !state.queue.isEmpty { return state.queue.removeFirst() }
                if state.closed { throw QwenError.network }
                return nil
            }
            if let data { return data }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func close() { lock.withLock { state.closed = true } }
    var sent: [QwenSocketMessage] { lock.withLock { state.sent } }
    var closed: Bool { lock.withLock { state.closed } }
}

extension Tests {
    static func qwenTests() async throws {
        expect(QwenCore.models.count == 10 && Set(QwenCore.models.map(\.id)).count == 10, "Ten distinct officially documented Qwen cloud ASR models")
        expectError("Reject nonexistent Qwen model") { _ = try QwenCore.model("qwen-made-up-asr") }
        expect(QwenCore.language("zh_CN", wire: .flash) == "zh" && QwenCore.language("zh-HK", wire: .realtime) == "yue", "Qwen language and Cantonese mapping")
        expect(QwenCore.language("auto", wire: .chat) == nil && QwenCore.language("unknown", wire: .flash) == nil, "Omit automatic or unknown Qwen language")
        expect(QwenCore.language("fil", wire: .flash) == "tl" && QwenCore.language("tl", wire: .realtime) == "fil", "Protocol-specific Filipino codes")
        let wav = try MiMoCore.wav([Float(0.5), -0.5][...])
        for model in QwenCore.models where model.wire == .chat || model.wire == .flash {
            let r = try QwenCore.synchronous(model: model, wav: wav, key: " test-key \n", region: .beijing, language: "zh", prompt: "专用词")
            let o = try QwenCore.object(r.httpBody!)
            expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer test-key" && o["model"] as? String == model.id, "Qwen sync model/key: " + model.id)
            if model.wire == .chat {
                expect(r.url?.path == "/compatible-mode/v1/chat/completions" && o["asr_options"] != nil && o["input"] == nil, "Qwen3 OpenAI-compatible protocol")
                expect((o["messages"] as? [[String: Any]])?.first?["role"] as? String == "system", "Qwen3 context is system content")
            } else {
                expect(r.url?.path == "/api/v1/services/aigc/multimodal-generation/generation" && o["parameters"] != nil && o["messages"] == nil, "Qwen-Audio Flash DashScope protocol: " + model.id)
                let messages = (o["input"] as! [String: Any])["messages"] as! [[String: Any]]
                expect(messages.count == 2 && messages.last?["role"] as? String == "user", "Audio follows context: " + model.id)
            }
        }
        let sync = try QwenCore.synchronousText(Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"你好"}}]}"#.utf8), wire: .chat)
        expect(sync == "你好", "Qwen3 final synchronous text")
        expectError("Qwen3 rejects truncated output") { _ = try QwenCore.synchronousText(Data(#"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#.utf8), wire: .chat) }
        let flash = try QwenCore.synchronousText(Data(#"{"output":{"text":"你好"}}"#.utf8), wire: .flash)
        expect(flash == "你好", "Qwen-Audio output.text parsing")
        expectError("Qwen sync rejects raw service error") { _ = try QwenCore.synchronousText(Data(#"{"code":"InvalidApiKey","message":"private-secret"}"#.utf8), wire: .flash) }
        expectError("Qwen sync enforces base64 limit") { _ = try QwenCore.synchronous(model: QwenCore.model(QwenCore.defaultModel), wav: Data(count: 7_500_001), key: "test", region: .beijing, language: nil, prompt: nil) }
        expectError("Reject bearer header injection") { _ = try QwenCore.request(region: .beijing, path: "/api/v1/uploads", key: "foo\r\nbar") }
        let intl = try QwenCore.request(region: .singapore, path: "/api/v1/uploads", key: "test")
        expect(intl.url?.host == "dashscope-intl.aliyuncs.com", "Explicit Singapore routing without fallback")
        for value in ["https://evil.example/audio", "https://127.0.0.1/audio", "https://evil.oss-cn-beijing.aliyuncs.com.evil.example/a", "https://u:p@bucket.oss-cn-beijing.aliyuncs.com/a", "https://bucket.oss-cn-beijing.aliyuncs.com:1234/a"] {
            expectError("Reject untrusted storage URL: " + value) { _ = try QwenCore.storageURL(value) }
        }
        let secure = try QwenCore.storageURL("http://bucket.oss-cn-beijing.aliyuncs.com/a?Signature=test")
        expect(secure.scheme == "https" && secure.query == "Signature=test", "Upgrade official HTTP OSS URL without altering signature")
        for model in QwenCore.models where model.wire == .file || model.wire == .qwenFile {
            let fixture = QwenHTTPFixture(wire: model.wire)
            let service = QwenService(transport: { try await fixture.call($0) }, pollDelay: .zero)
            let text = try await service.transcribe(samples: [0, 0.5], model: model, key: "test-key", region: .beijing, language: "zh", prompt: "专业词")
            expect(text == "测试转写。", "Complete upload/submit/poll/download: " + model.id)
            let requests = await fixture.requests
            expect(requests.count == 6, "One upload and one paid submission, two queries: " + model.id)
            expect(requests.filter { $0.url!.host!.contains(".oss-") }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.url!.scheme == "https" }, "No API Key sent to OSS: " + model.id)
            let uploaded = requests.first { $0.url!.host!.contains("dashscope-upload.") }!
            let form = uploaded.httpBody!
            expect(["success_action_status", "x-oss-content-type", "audio/wav"].allSatisfy { form.range(of: Data($0.utf8)) != nil }, "Official OSS policy form fields: " + model.id)
            let submit = requests.first { $0.url!.path.hasSuffix("/transcription") }!
            let input = try QwenCore.object(submit.httpBody!)["input"] as! [String: Any]
            expect(submit.value(forHTTPHeaderField: "X-DashScope-Async") == "enable" && submit.value(forHTTPHeaderField: "X-DashScope-OssResourceResolve") == "enable", "Async and temporary resource headers: " + model.id)
            expect(model.wire == .qwenFile ? input["file_url"] != nil && input["file_urls"] == nil : input["file_urls"] != nil && input["file_url"] == nil, "Correct singular/plural file input: " + model.id)
        }
        expectError("Reject successful task with failed subtask") { _ = try QwenCore.resultURL(["results": [["subtask_status": "FAILED", "transcription_url": "https://bucket.oss-cn-beijing.aliyuncs.com/a"]]], wire: .file) }
        let denied = QwenService(transport: { r in (Data("private-key and transcript".utf8), HTTPURLResponse(url: r.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!) })
        do { _ = try await denied.transcribe(samples: [0], model: QwenCore.model(QwenCore.defaultModel), key: "test", region: .beijing, language: nil, prompt: nil); fatalError("Denied Qwen accepted") }
        catch { expect(!error.localizedDescription.contains("private-key") && error.localizedDescription.contains("403"), "Qwen diagnostics redact server secrets") }

        let taskID = "test-task"
        var results = QwenSocketResults()
        func event(_ event: String, sentence: [String: Any]? = nil, id: String = "test-task") throws -> Data {
            var o: [String: Any] = ["header": ["event": event, "task_id": id]]
            if let sentence { o["payload"] = ["output": ["sentence": sentence]] }
            return try JSONSerialization.data(withJSONObject: o)
        }
        try results.consume(event("task-started"), wire: .streaming, taskID: taskID)
        try results.consume(event("result-generated", sentence: ["sentence_id": 1, "sentence_end": false, "text": "错误"]), wire: .streaming, taskID: taskID)
        try results.consume(event("result-generated", sentence: ["sentence_id": 1, "sentence_end": true, "text": "正确。"]), wire: .streaming, taskID: taskID)
        try results.consume(event("result-generated", sentence: ["sentence_id": 1, "sentence_end": true, "text": "正确。"]), wire: .streaming, taskID: taskID)
        try results.consume(event("result-generated", sentence: ["sentence_id": 0, "heartbeat": true]), wire: .streaming, taskID: taskID)
        expect(results.text == "正确。" && !results.hasUnfinished, "Replace revisions, deduplicate finals, ignore heartbeat")
        expectError("Reject stale cross-task WebSocket event") { try results.consume(event("task-finished", id: "old-task"), wire: .streaming, taskID: taskID) }
        var rt = QwenSocketResults()
        try rt.consume(Data(#"{"type":"conversation.item.input_audio_transcription.text","item_id":"1","text":"你","stash":"好"}"#.utf8), wire: .realtime, taskID: "")
        expect(rt.progress == "你好" && rt.text.isEmpty && rt.hasUnfinished, "Qwen realtime provisional text/stash excluded from final")
        try rt.consume(Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"1","transcript":"你好。"}"#.utf8), wire: .realtime, taskID: "")
        expect(rt.text == "你好。" && !rt.hasUnfinished, "Qwen realtime completed transcript replaces hypothesis")
        for model in QwenCore.models where model.wire.live {
            let request = try QwenCore.socketRequest(model: model, key: "test", region: .singapore)
            expect(request.url?.scheme == "wss" && request.url?.host == "dashscope-intl.aliyuncs.com" && (model.wire == .realtime ? request.value(forHTTPHeaderField: "OpenAI-Beta") == "realtime=v1" && request.url?.path == "/api-ws/v1/realtime" : request.url?.path == "/api-ws/v1/inference"), "Verified socket endpoint/headers: " + model.id)
            let fixture = QwenSocketFixture(wire: model.wire)
            let live = QwenLiveSession(model: model, transport: fixture, onProgress: { _ in true })
            try await live.start(language: "zh", prompt: "词表")
            try await live.appendAudio(samples: Array(repeating: 0.5, count: 1700))
            let result = try await live.finish()
            expect(result.text == "实时结果。" && fixture.closed, "Live socket handshake/audio/finish/cleanup: " + model.id)
            if model.wire == .realtime {
                let json = try fixture.sent.compactMap { m -> [String: Any]? in if case .text(let s) = m { return try QwenCore.object(Data(s.utf8)) }; return nil }
                let config = json.first { $0["type"] as? String == "session.update" }?["session"] as? [String: Any]
                expect((config?["turn_detection"] as? [String: Any])?["type"] as? String == "server_vad" && !json.contains { $0["type"] as? String == "input_audio_buffer.commit" } && json.contains { $0["type"] as? String == "session.finish" }, "Qwen3 VAD streaming flushes final utterance without forbidden manual commit")
            } else {
                let frames = fixture.sent.compactMap { m -> Data? in if case .binary(let d) = m { return d }; return nil }
                expect(frames.reduce(0) { $0 + $1.count } == 3400 && frames.first?.prefix(2) == Data([0, 64]), "Little-endian mono PCM and exact audio tail: " + model.id)
            }
        }
        let drainingFixture = QwenSocketFixture(wire: .streaming, binaryDelay: .milliseconds(50))
        let draining = QwenLiveSession(model: try QwenCore.model("qwen-audio-3.1-asr-flash-streaming"), transport: drainingFixture, onProgress: { _ in true })
        try await draining.start(language: nil, prompt: nil)
        let preview = Task { try await draining.appendAudio(samples: Array(repeating: Float(0), count: 1700)) }
        try await Task.sleep(for: .milliseconds(10))
        preview.cancel()
        try await preview.value
        let drained = try await draining.finish()
        expect(drained.text == "实时结果。", "Host preview-loop cancellation drains accepted audio and allows tail/final flush")
        let broken = QwenSocketFixture(wire: .streaming); broken.closeBeforeFinish = true
        let live = QwenLiveSession(model: try QwenCore.model("qwen-audio-3.1-asr-flash-streaming"), transport: broken, onProgress: { _ in true })
        try await live.start(language: nil, prompt: nil)
        try await live.appendAudio(samples: [0])
        do { _ = try await live.finish(); fatalError("Incomplete live result accepted") }
        catch { expect(broken.closed, "Incomplete WebSocket never returns partial success and releases resources") }
        let cancelFixture = QwenSocketFixture(wire: .realtime)
        let cancelled = QwenLiveSession(model: try QwenCore.model("qwen3-asr-flash-realtime"), transport: cancelFixture, onProgress: { _ in true })
        try await cancelled.start(language: nil, prompt: nil)
        await cancelled.cancel()
        expect(cancelFixture.closed, "Live cancellation closes socket")
    }
}
