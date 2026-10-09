import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

@objc(MiMoASRPlugin)
final class MiMoASRPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.tietiezhi.typewhisper.mimo-asr"
    static let pluginName = "MiMo ASR"
    private struct State {
        var host: (any HostServices)?
        var key = ""
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
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
        state.withLock { $0.host = host; $0.key = key }
    }
    func deactivate() { state.withLock { $0 = State() } }
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
            Section("使用说明") {
                Text("保存后，在 TypeWhisper 的模型选择中选 MiMo V2.5 ASR。停止录音后返回文字，不提供实时字幕或翻译。")
                Text("跟随应用的语言选择；其他语言按自动检测处理。超过 3 分钟的录音自动分段，段落边界可能影响识别。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(minWidth: 430, minHeight: 370)
    }
}
