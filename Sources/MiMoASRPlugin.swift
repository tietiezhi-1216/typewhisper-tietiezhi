import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

@objc(MiMoASRPlugin)
final class MiMoASRPlugin: NSObject, TranscriptionEnginePlugin, LLMProviderPlugin, LLMModelSelectable, @unchecked Sendable {
    static let pluginId = "com.tietiezhi.typewhisper.mimo-asr"
    static let pluginName = "MiMo ASR + Antigravity"
    private struct State {
        var host: (any HostServices)?
        var key = ""
        var antigravityLoggedIn = false
        var antigravityEmail: String?
        var antigravityModel = AntigravityCore.defaultModel
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
        state.withLock {
            $0.host = host; $0.key = key
            $0.antigravityLoggedIn = credentials != nil
            $0.antigravityEmail = credentials?.email
            $0.antigravityModel = model
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
    var supportedModels: [PluginModelInfo] {
        var ids = [AntigravityCore.defaultModel, "gemini-2.5-flash"]
        if !ids.contains(antigravityModel) { ids.append(antigravityModel) }
        return ids.map { PluginModelInfo(id: $0, displayName: $0) }
    }
    private func antigravityHost() throws -> any HostServices {
        guard let host = state.withLock({ $0.host }) else { throw AntigravityError.notLoggedIn }
        return host
    }
    @MainActor var antigravityProject: String {
        (try? antigravityHost().userDefault(forKey: "antigravity-project") as? String) ?? ""
    }
    @MainActor func saveAntigravityOptions(model: String, project: String) throws {
        let host = try antigravityHost()
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AntigravityError.invalidResponse }
        host.setUserDefault(model, forKey: "antigravity-model")
        host.setUserDefault(project.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "antigravity-project")
        state.withLock { $0.antigravityModel = model }
        host.notifyCapabilitiesChanged()
    }
    @MainActor func loginAntigravity() async throws {
        let host = try antigravityHost()
        let lifecycle = state.withLock { $0.lifecycle }
        let credentials = try await antigravity.login(host: host, projectOverride: antigravityProject)
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
        let host = try antigravityHost()
        return try await antigravity.generate(host: host, model: model ?? antigravityModel, system: systemPrompt, text: userText)
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
            Section("小米 MiMo 语音识别") {
                Text("模型：mimo-v2.5-asr · 中文 / 英文 / 自动检测")
                Text("录音将发送至小米云端，并按 API 规则计费。不需要下载模型。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("打开 MiMo 开放平台", destination: URL(string: "https://platform.xiaomimimo.com")!)
            }
            Section("API Key") {
                SecureField("输入或替换 API Key", text: $key)
                HStack {
                    Button("保存密钥") {
                        do {
                            try plugin.saveKey(key)
                            key = ""; failed = false; status = "密钥已保存到系统钥匙串。"
                        } catch {
                            failed = true; status = "保存失败：" + error.localizedDescription
                        }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("清除密钥", role: .destructive) {
                        do {
                            try plugin.saveKey("")
                            key = ""; failed = false; status = "已清除密钥。"
                        } catch {
                            failed = true; status = "清除失败：" + error.localizedDescription
                        }
                    }
                }
                Text(status.isEmpty ? (plugin.isConfigured ? "已配置密钥（不会回显）。" : "尚未配置密钥。") : status)
                    .font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
            }
            AntigravitySettingsSection(plugin: plugin)
            Section("使用说明") {
                Text("保存后，在 TypeWhisper 的模型选择中选 MiMo V2.5 ASR。停止录音后返回文字，不提供实时字幕或翻译。")
                Text("跟随应用的语言选择；其他语言按自动检测处理。超过 3 分钟的录音自动分段，段落边界可能影响识别。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(minWidth: 480, minHeight: 580)
    }
}
