import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

final class QwenASREngine: TranscriptionEnginePlugin, LiveTranscriptionCapablePlugin, LiveTranscriptionProgressModeProviding, @unchecked Sendable {
    static let pluginId = MiMoASRPlugin.pluginId
    static let pluginName = MiMoASRPlugin.pluginName
    private struct State {
        var host: (any HostServices)?
        var key = ""
        var model = QwenCore.defaultModel
        var region = QwenRegion.beijing
        var identity = UUID()
        var live: [UUID: QwenLiveSession] = [:]
        var tasks: [UUID: Task<String, Error>] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let service = QwenService()
    required init() {}
    var providerId: String { "alibaba-qwen-asr" }
    var providerDisplayName: String { "千问 ASR（百炼）" }
    var isConfigured: Bool { state.withLock { $0.host != nil && !$0.key.isEmpty } }
    var selectedModelId: String? { state.withLock { $0.model } }
    var region: QwenRegion { state.withLock { $0.region } }
    var transcriptionModels: [PluginModelInfo] { QwenCore.models.map { PluginModelInfo(id: $0.id, displayName: $0.name) } }
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { (try? QwenCore.model(selectedModelId ?? "").wire.live) ?? false }
    var liveTranscriptionProgressMode: LiveTranscriptionProgressMode { .completeSnapshot }
    var supportedLanguages: [String] { QwenCore.languages(wire: (try? QwenCore.model(selectedModelId ?? "").wire) ?? .flash) }
    func activate(host: any HostServices) {
        deactivate()
        state.withLock {
            $0.host = host
            $0.key = host.loadSecret(key: QwenCore.secretKey) ?? ""
            let saved = host.userDefault(forKey: QwenCore.modelKey) as? String ?? QwenCore.defaultModel
            $0.model = (try? QwenCore.model(saved))?.id ?? QwenCore.defaultModel
            $0.region = QwenRegion(rawValue: host.userDefault(forKey: QwenCore.regionKey) as? String ?? "") ?? .beijing
        }
    }
    func deactivate() {
        let old = state.withLock { value in let old = value; value = State(); return old }
        old.tasks.values.forEach { $0.cancel() }
        for live in old.live.values { Task { await live.cancel() } }
    }
    deinit { deactivate() }
    func selectModel(_ modelId: String) {
        guard (try? QwenCore.model(modelId)) != nil else { return }
        let host = state.withLock { s -> (any HostServices)? in
            guard s.host != nil else { return nil }
            s.model = modelId; return s.host
        }
        host?.setUserDefault(modelId, forKey: QwenCore.modelKey)
        host?.notifyCapabilitiesChanged()
    }
    @MainActor func saveKey(_ value: String) throws {
        guard let host = state.withLock({ $0.host }) else { throw QwenError.missingKey }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.utf8.contains(13), !key.utf8.contains(10) else { throw QwenError.missingKey }
        try host.storeSecret(key: QwenCore.secretKey, value: key)
        let old = state.withLock { s -> State in
            let old = s; s.identity = UUID(); s.key = key; s.tasks = [:]; s.live = [:]; return old
        }
        old.tasks.values.forEach { $0.cancel() }
        for live in old.live.values { Task { await live.cancel() } }
        host.notifyCapabilitiesChanged()
    }
    @MainActor func saveRegion(_ region: QwenRegion) {
        let host = state.withLock { s -> (any HostServices)? in s.region = region; return s.host }
        host?.setUserDefault(region.rawValue, forKey: QwenCore.regionKey)
        host?.notifyCapabilitiesChanged()
    }
    private func configuration(translate: Bool) throws -> (String, QwenModel, QwenRegion, UUID) {
        guard !translate else { throw QwenError.failed("翻译（本接口仅支持转录）") }
        return try state.withLock {
            guard $0.host != nil, !$0.key.isEmpty else { throw QwenError.missingKey }
            return ($0.key, try QwenCore.model($0.model), $0.region, $0.identity)
        }
    }
    func createLiveTranscriptionSession(language: String?, translate: Bool, prompt: String?,
        onProgress: @escaping @Sendable (String) -> Bool) async throws -> any LiveTranscriptionSession {
        let (key, model, region, identity) = try configuration(translate: translate)
        guard model.wire.live else { throw QwenError.notRealtime }
        let transport = try QwenWebSocket(model: model, key: key, region: region)
        let id = UUID()
        let live = QwenLiveSession(model: model, transport: transport, onProgress: onProgress, onClose: { [weak self] in
            _ = self?.state.withLock { $0.live.removeValue(forKey: id) }
        })
        let active = state.withLock { s in
            guard s.identity == identity, s.host != nil else { return false }
            s.live[id] = live; return true
        }
        guard active else { transport.close(); throw CancellationError() }
        try await withTaskCancellationHandler {
            try await live.start(language: language, prompt: prompt)
        } onCancel: { transport.close(); Task { await live.cancel() } }
        return live
    }
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt, onProgress: { _ in true })
    }
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?,
                    onProgress: @escaping @Sendable (String) -> Bool) async throws -> PluginTranscriptionResult {
        let (key, model, region, identity) = try configuration(translate: translate)
        guard !audio.samples.isEmpty, audio.samples.count <= QwenCore.maxSamples,
              audio.samples.allSatisfy({ $0.isFinite }) else { throw QwenError.audio }
        if model.wire.live {
            let live = try await createLiveTranscriptionSession(language: language, translate: translate, prompt: prompt, onProgress: onProgress)
            return try await withTaskCancellationHandler {
                do {
                    for start in stride(from: 0, to: audio.samples.count, by: 1600) {
                        try Task.checkCancellation()
                        let end = min(start + 1600, audio.samples.count)
                        try await live.appendAudio(samples: Array(audio.samples[start..<end]))
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    return try await live.finish()
                } catch { await live.cancel(); throw error }
            } onCancel: { Task { await live.cancel() } }
        }
        let id = UUID()
        let task: Task<String, Error> = try state.withLock { s in
            guard s.identity == identity, s.host != nil else { throw CancellationError() }
            let task = Task { try await self.service.transcribe(samples: audio.samples, model: model, key: key, region: region, language: language, prompt: prompt) }
            s.tasks[id] = task; return task
        }
        defer { _ = state.withLock { $0.tasks.removeValue(forKey: id) } }
        let text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard state.withLock({ $0.identity == identity && $0.host != nil }) else { throw CancellationError() }
        return PluginTranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @MainActor var settingsView: AnyView? { AnyView(QwenSettingsSection(engine: self)) }
}
