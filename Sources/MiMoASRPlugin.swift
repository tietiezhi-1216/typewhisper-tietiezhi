import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

@objc(MiMoASRPlugin)
final class MiMoASRPlugin: NSObject, TranscriptionEnginePlugin, LLMProviderPlugin, LLMModelSelectable, LLMEffortControllableProvider, @unchecked Sendable {
    static let pluginId = "com.tietiezhi.typewhisper.mimo-asr"
    static let pluginName = "tietiezhi"
    private struct State {
        var host: (any HostServices)?
        var key = ""
        var antigravityLoggedIn = false
        var antigravityEmail: String?
        var antigravityModel = AntigravityCore.defaultModel
        var antigravityModels: [AntigravityModel] = []
        var thinking: AntigravityThinking = .auto
        var lifecycle = UUID()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let antigravity = AntigravityService()
    // No cookies/cache, no audio or transcript logs. No automatic paid retries.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 180
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()
    required override init() { super.init() }
    func activate(host: any HostServices) {
        let key = host.loadSecret(key: "api-key") ?? ""
        let credentials = AntigravityCredentials.decode(host.loadSecret(key: AntigravityCore.secretKey))
        let model = host.userDefault(forKey: "antigravity-model") as? String ?? AntigravityCore.defaultModel
        let models = (host.userDefault(forKey: "antigravity-models") as? Data).flatMap { try? JSONDecoder().decode([AntigravityModel].self, from: $0) } ?? []
        let thinking = AntigravityThinking(rawValue: host.userDefault(forKey: "antigravity-thinking") as? String ?? "auto") ?? .auto
        state.withLock {
            $0.host = host; $0.key = key
            $0.antigravityLoggedIn = credentials != nil
            $0.antigravityEmail = credentials?.email
            $0.antigravityModel = model
            $0.antigravityModels = models
            $0.thinking = thinking
        }
    }
    func deactivate() {
        state.withLock { $0 = State() }
        Task { await antigravity.invalidate() }
    }
    var providerId: String { "xiaomi-mimo-asr" }
    var providerDisplayName: String { "MiMo ASR" }
    var isConfigured: Bool { state.withLock { !$0.key.isEmpty } }
    var transcriptionModels: [PluginModelInfo] {
        [PluginModelInfo(id: MiMoCore.model, displayName: "MiMo V2.5 ASR")]
    }
    var selectedModelId: String? { MiMoCore.model }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] { ["zh", "en"] }

    @MainActor func saveKey(_ key: String) throws {
        guard let host = state.withLock({ $0.host }) else { throw MiMoError.missingKey }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try host.storeSecret(key: "api-key", value: trimmed)
        state.withLock { $0.key = trimmed }
        host.notifyCapabilitiesChanged()
    }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard !translate else { throw MiMoError.translationUnsupported }
        let key = state.withLock { $0.key }
        guard !key.isEmpty else { throw MiMoError.missingKey }
        guard !audio.samples.isEmpty else { throw MiMoError.invalidAudio }
        var texts: [String] = []
        // Fixed non-overlapping segments: best suited to short dictation. Long
        // recordings may have reduced accuracy around the 180-second boundary.
        for start in stride(from: 0, to: audio.samples.count, by: MiMoCore.chunkSamples) {
            try Task.checkCancellation()
            let end = min(start + MiMoCore.chunkSamples, audio.samples.count)
            let wav = try MiMoCore.wav(audio.samples[start..<end])
            let request = try MiMoCore.request(wav: wav, key: key, language: language)
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw MiMoError.invalidResponse }
            texts.append(try MiMoCore.text(from: data, status: http.statusCode))
        }
        return PluginTranscriptionResult(text: MiMoCore.join(texts))
    }

    // LLM provider is separate from MiMo ASR; TypeWhisper workflows decide when
    // to invoke it. Plain dictation is never silently sent to a second service.
    var providerName: String { "Antigravity OAuth（非官方）" }
    var isAvailable: Bool { state.withLock { $0.antigravityLoggedIn } }
    var antigravityEmail: String? { state.withLock { $0.antigravityEmail } }
    var antigravityModel: String { state.withLock { $0.antigravityModel } }
    @objc var preferredModelId: String? { antigravityModel }
    @objc var defaultModelId: String? { AntigravityCore.defaultModel }
    var antigravityModels: [AntigravityModel] { state.withLock { $0.antigravityModels } }
    var antigravityThinking: AntigravityThinking { state.withLock { $0.thinking } }
    var supportedModels: [PluginModelInfo] {
        let models = antigravityModels
        if models.isEmpty { return [PluginModelInfo(id: antigravityModel, displayName: antigravityModel)] }
        return models.map { PluginModelInfo(id: $0.id, displayName: $0.name) }
    }
    func supportedEfforts(for model: String?) -> [PluginLLMEffortInfo] {
        AntigravityThinking.options(for: model ?? antigravityModel).map {
            PluginLLMEffortInfo(id: $0.rawValue, displayName: $0.title)
        }
    }
    func defaultEffortId(for model: String?) -> String? {
        let options = AntigravityThinking.options(for: model ?? antigravityModel)
        return options.contains(antigravityThinking) ? antigravityThinking.rawValue : "auto"
    }
    private func antigravityHost() throws -> any HostServices {
        guard let host = state.withLock({ $0.host }) else { throw AntigravityError.notLoggedIn }
        return host
    }
    @MainActor var antigravityProject: String {
        (try? antigravityHost().userDefault(forKey: "antigravity-project") as? String) ?? ""
    }
    @MainActor func saveAntigravityOptions(model: String, project: String? = nil, thinking: AntigravityThinking? = nil) throws {
        let host = try antigravityHost()
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AntigravityError.invalidResponse }
        host.setUserDefault(model, forKey: "antigravity-model")
        if let project {
            let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AntigravityCore.validProjectOverride(project) else { throw AntigravityError.invalidProject }
            host.setUserDefault(project, forKey: "antigravity-project")
        }
        let selectedThinking = thinking ?? antigravityThinking
        let resolvedThinking = AntigravityThinking.options(for: model).contains(selectedThinking) ? selectedThinking : .auto
        host.setUserDefault(resolvedThinking.rawValue, forKey: "antigravity-thinking")
        state.withLock { $0.antigravityModel = model; $0.thinking = resolvedThinking }
        host.notifyCapabilitiesChanged()
    }
    @MainActor func refreshAntigravityModels() async throws {
        let host = try antigravityHost()
        let lifecycle = state.withLock { $0.lifecycle }
        let models = try await antigravity.models(host: host)
        try Task.checkCancellation()
        guard state.withLock({ $0.lifecycle == lifecycle }) else { throw CancellationError() }
        host.setUserDefault(try JSONEncoder().encode(models), forKey: "antigravity-models")
        state.withLock { $0.antigravityModels = models }
        let selected = models.contains(where: { $0.id == antigravityModel }) ? antigravityModel :
            (models.first(where: { $0.id.contains("flash") })?.id ?? models[0].id)
        try saveAntigravityOptions(model: selected)
    }
    @MainActor func loginAntigravity(allowFreeOnboarding: Bool = false) async throws {
        let host = try antigravityHost()
        let lifecycle = state.withLock { $0.lifecycle }
        let credentials = try await antigravity.login(host: host, projectOverride: antigravityProject, allowFreeOnboarding: allowFreeOnboarding)
        try Task.checkCancellation()
        guard state.withLock({ $0.lifecycle == lifecycle }) else { throw CancellationError() }
        state.withLock { $0.antigravityLoggedIn = true; $0.antigravityEmail = credentials.email }
        host.notifyCapabilitiesChanged()
    }
    @MainActor func logoutAntigravity() async throws {
        let host = try antigravityHost()
        try await antigravity.logout(host: host)
        state.withLock { $0.antigravityLoggedIn = false; $0.antigravityEmail = nil }
        host.notifyCapabilitiesChanged()
    }
    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await process(systemPrompt: systemPrompt, userText: userText, model: model, effort: nil)
    }
    func process(systemPrompt: String, userText: String, model: String?, effort: String?) async throws -> String {
        let host = try antigravityHost()
        let thinking = effort.flatMap(AntigravityThinking.init(rawValue:)) ?? antigravityThinking
        return try await antigravity.generate(host: host, model: model ?? antigravityModel, system: systemPrompt, text: userText, thinking: thinking)
    }

    @MainActor var settingsView: AnyView? { AnyView(MiMoSettingsView(plugin: self)) }
}

private struct MiMoSettingsView: View {
    let plugin: MiMoASRPlugin
    @State private var key = ""
    @State private var status = ""
    @State private var failed = false
    var body: some View {
        Form {
            Section("MiMo") {
                SecureField("API Key", text: $key)
                HStack {
                    Button("保存") {
                        do {
                            try plugin.saveKey(key)
                            key = ""; failed = false; status = "已保存"
                        } catch {
                            failed = true; status = "保存失败：" + error.localizedDescription
                        }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("清除", role: .destructive) {
                        do {
                            try plugin.saveKey("")
                            key = ""; failed = false; status = "已清除"
                        } catch {
                            failed = true; status = "清除失败：" + error.localizedDescription
                        }
                    }
                }
                Text(status.isEmpty ? (plugin.isConfigured ? "已配置" : "未配置") : status)
                    .font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
            }
            AntigravitySettingsSection(plugin: plugin)
        }.formStyle(.grouped).frame(minWidth: 420, minHeight: 340)
    }
}
