import Foundation
import TypeWhisperPluginSDK

enum QwenSocketMessage: Sendable { case text(String), binary(Data) }
protocol QwenSocketTransport: Sendable {
    func send(_ message: QwenSocketMessage) async throws
    func receive() async throws -> Data
    func close()
}
final class QwenWebSocket: QwenSocketTransport, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    init(model: QwenModel, key: String, region: QwenRegion) throws {
        let request = try QwenCore.socketRequest(model: model, key: key, region: region)
        session = QwenNoRedirects.session(resourceTimeout: 1900)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 2_000_000
        task.resume()
    }
    func send(_ message: QwenSocketMessage) async throws {
        do {
            switch message {
            case .text(let text): try await task.send(.string(text))
            case .binary(let data): try await task.send(.data(data))
            }
        } catch { throw sanitized(error) }
    }
    func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .string(let text): return Data(text.utf8)
            case .data(let data): return data
            @unknown default: throw QwenError.response
            }
        } catch { throw sanitized(error) }
    }
    private func sanitized(_ error: Error) -> Error {
        if Task.isCancelled { return CancellationError() }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 { return QwenError.http("实时连接", status) }
        return (error as? QwenError) ?? QwenError.network
    }
    func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    deinit { close() }
}

// One socket per recognition. Receiver runs concurrently with audio upload.
// Host LiveTranscriptionSession is used for actual microphone streaming; the
// buffered fallback sends at real-time speed rather than overfeeding the API.
actor QwenLiveSession: LiveTranscriptionSession {
    let model: QwenModel
    let taskID: String
    private let transport: any QwenSocketTransport
    private let onProgress: @Sendable (String) -> Bool
    private let onClose: @Sendable () -> Void
    private var results = QwenSocketResults()
    private var receiver: Task<Void, Never>?
    private var failure: (any Error)?
    private var closed = false
    private var finishing = false
    private var sending = false
    private var sampleCount = 0
    private var pending = Data()
    private let openedAt = ContinuousClock.now
    init(model: QwenModel, taskID: String = UUID().uuidString, transport: any QwenSocketTransport,
         onProgress: @escaping @Sendable (String) -> Bool, onClose: @escaping @Sendable () -> Void = {}) {
        self.model = model; self.taskID = taskID; self.transport = transport
        self.onProgress = onProgress; self.onClose = onClose
    }
    func start(language: String?, prompt: String?) async throws {
        guard receiver == nil, !closed else { throw CancellationError() }
        receiver = Task { [weak self] in await self?.readLoop() }
        do {
            try await sendJSON(QwenCore.socketStart(model: model, taskID: taskID, language: language, prompt: prompt))
            try await waitUntil(start: true)
        } catch { close(); throw error }
    }
    private func readLoop() async {
        do {
            while !closed {
                let data = try await transport.receive()
                guard !closed else { return }
                try results.consume(data, wire: model.wire, taskID: taskID)
                if results.finished {
                    guard finishing else { throw QwenError.incomplete }
                    return
                }
                if !results.progress.isEmpty, !onProgress(results.progress) { throw CancellationError() }
            }
        } catch {
            if !closed { failure = error; close() }
        }
    }
    private func sendJSON(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else { throw QwenError.response }
        try await transfer(.text(text))
    }
    private func transfer(_ message: QwenSocketMessage) async throws {
        // TypeWhisper cancels its preview polling task before flushing the tail.
        // Drain accepted audio independently of that caller's cancellation;
        // explicit session.cancel()/plugin deactivation still closes the socket.
        let transport = self.transport
        let transfer = Task.detached { try await transport.send(message) }
        try await transfer.value
    }
    private func waitUntil(start: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(start ? 20 : 120)
        while start ? !results.started : !results.finished {
            try Task.checkCancellation()
            if let failure { throw failure }
            guard !closed else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw QwenError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let failure { throw failure }
    }
    func appendAudio(samples: [Float]) async throws {
        guard !closed, !finishing, !sending, results.started else { throw CancellationError() }
        guard sampleCount + samples.count <= QwenCore.maxSamples, samples.allSatisfy({ $0.isFinite }),
              ContinuousClock.now - openedAt < .seconds(1800) else { close(); throw QwenError.audio }
        sending = true
        defer { sending = false }
        do {
            if let failure { throw failure }
            sampleCount += samples.count
            for sample in samples {
                var value = Int16((min(1, max(-1, sample)) * 32767).rounded()).littleEndian
                withUnsafeBytes(of: &value) { pending.append(contentsOf: $0) }
            }
            // 100 ms frames; retain a small tail until finish, never raw Float bytes.
            while pending.count >= 3200 {
                let frame = Data(pending.prefix(3200)); pending.removeFirst(3200)
                try await sendAudio(frame)
                guard !closed else { throw CancellationError() }
            }
        } catch { close(); throw error }
    }
    private func sendAudio(_ pcm: Data) async throws {
        if model.wire == .realtime {
            try await sendJSON(JSONSerialization.data(withJSONObject: ["event_id": UUID().uuidString,
                "type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]))
        } else { try await transfer(.binary(pcm)) }
    }
    func finish() async throws -> PluginTranscriptionResult {
        if let failure { throw failure }
        guard !closed, !finishing, !sending else { throw CancellationError() }
        finishing = true
        defer { close() }
        do {
            try Task.checkCancellation()
            if let failure { throw failure }
            guard sampleCount > 0 else { throw QwenError.audio }
            // Preserve a minimum 100 ms frame for very short recordings.
            if model.wire == .realtime, sampleCount < 1600 { pending.append(Data(count: (1600 - sampleCount) * 2)) }
            if !pending.isEmpty { try await sendAudio(pending); pending = Data() }
            if model.wire == .realtime {
                // VAD mode forbids manual commit. Finish flushes the last utterance.
                try await sendJSON(JSONSerialization.data(withJSONObject: ["event_id": UUID().uuidString, "type": "session.finish"]))
            } else {
                try await sendJSON(JSONSerialization.data(withJSONObject: [
                    "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"], "payload": ["input": [:]]
                ]))
            }
            try await waitUntil(start: false)
            guard !results.hasUnfinished else { throw QwenError.incomplete }
            return PluginTranscriptionResult(text: results.text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
    func cancel() { close() }
    private func close() {
        guard !closed else { return }
        closed = true
        receiver?.cancel(); receiver = nil
        transport.close(); pending = Data()
        onClose()
    }
    deinit { receiver?.cancel(); transport.close() }
}
