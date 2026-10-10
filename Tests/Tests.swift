import Foundation
import TypeWhisperPluginSDK

@main struct Tests {
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: " + name) }
        print("PASS: " + name)
    }
    static func expectError(_ name: String, _ body: () throws -> Void) {
        do { try body(); fatalError("FAIL: " + name) }
        catch { print("PASS: " + name) }
    }
    @MainActor static func main() async throws {
        expect(MiMoCore.languageCode("zh-CN") == "zh", "Chinese language mapping")
        expect(MiMoCore.languageCode("en_US") == "en", "English language mapping")
        expect(MiMoCore.languageCode(nil) == "auto", "Automatic language")
        expect(MiMoCore.languageCode("ja") == "auto", "Other languages do not force Chinese")
        let wav = try MiMoCore.wav([Float(-2), 0, 2][...])
        expect(wav.count == 50 && String(data: wav.prefix(4), encoding: .utf8) == "RIFF", "16-bit WAV header and payload")
        expect(wav.suffix(2) == Data([255, 127]), "PCM clipping")
        expectError("Reject invalid samples") { _ = try MiMoCore.wav([Float.nan][...]) }
        expectError("Reject empty audio") { _ = try MiMoCore.wav([][...]) }
        let request = try MiMoCore.request(wav: wav, key: " test-key \n", language: "zh")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        expect(request.url == MiMoCore.endpoint && request.httpMethod == "POST", "MiMo chat endpoint")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Trimmed bearer authentication")
        expect(body["model"] as? String == "mimo-v2.5-asr", "ASR model, not text LLM")
        let messages = body["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        let audio = content[0]["input_audio"] as! [String: String]
        expect(audio["format"] == "wav" && audio["data"] == "data:audio/wav;base64," + wav.base64EncodedString(), "Audio message wire format")
        expect((body["asr_options"] as! [String: String])["language"] == "zh", "ASR language option")
        expectError("Reject missing key") { _ = try MiMoCore.request(wav: wav, key: " ", language: nil) }
        expectError("Enforce base64 size limit") { _ = try MiMoCore.request(wav: Data(count: 7_500_001), key: "test", language: nil) }
        let response = Data(#"{"choices":[{"message":{"content":" 你好。 "}}]}"#.utf8)
        let parsed = try MiMoCore.text(from: response, status: 200)
        expect(parsed == "你好。", "Parse text response")
        let parts = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"你好"},{"text":"。"}]}}]}"#.utf8)
        let parsedParts = try MiMoCore.text(from: parts, status: 200)
        expect(parsedParts == "你好。", "Parse content-array response")
        expectError("Reject malformed response") { _ = try MiMoCore.text(from: Data("{}".utf8), status: 200) }
        expectError("Report authentication errors") { _ = try MiMoCore.text(from: Data(), status: 401) }
        expectError("Report rate limits") { _ = try MiMoCore.text(from: Data(), status: 429) }
        expect(MiMoCore.join(["hello", "world"]) == "hello world", "English chunk joining")
        expect(MiMoCore.join(["你好", "世界"]) == "你好世界", "Chinese chunk joining")
        let longSamples = MiMoCore.chunkSamples + 1
        let ranges = stride(from: 0, to: longSamples, by: MiMoCore.chunkSamples).map { $0..<min($0 + MiMoCore.chunkSamples, longSamples) }
        expect(ranges.count == 2 && ranges.map(\.count).reduce(0, +) == longSamples, "Chunking preserves every sample")

        // Load the actual compiled bundle against the installed application's SDK.
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/tietiezhi.bundle")
        let bundle = Bundle(url: url)!
        try bundle.loadAndReturnError()
        guard let type = NSClassFromString("MiMoASRPlugin") as? any TypeWhisperPlugin.Type,
              let engine = type.init() as? any TranscriptionEnginePlugin else { fatalError("Plugin SDK cast failed") }
        expect(engine.providerId == "xiaomi-mimo-asr", "Real bundle load and host protocol conformance")
        expect(engine.transcriptionModels.first?.id == MiMoCore.model, "Host reads model metadata")
        expect(!engine.isConfigured && !engine.supportsStreaming && !engine.supportsTranslation, "Accurate host capability flags")
        expect(engine.settingsView != nil, "Native SwiftUI settings view")
        do {
            _ = try await engine.transcribe(audio: AudioData(samples: [0], wavData: Data(), duration: 0), language: nil, translate: false, prompt: nil)
            fatalError("Missing key accepted")
        } catch { print("PASS: bundle rejects unconfigured transcription") }
        guard let llm = engine as? any LLMProviderPlugin else { fatalError("LLM provider conformance missing") }
        expect(llm.providerName == "Antigravity OAuth（非官方）" && !llm.isAvailable, "Bundle exposes separately configured LLM provider")
        let host = TestHost()
        try host.storeSecret(key: "api-key", value: "fake-mimo-key")
        let auth = AntigravityCredentials(accessToken: "fake", refreshToken: "fake", expiresAt: Date().addingTimeInterval(3600), projectID: "fake-project")
        try host.storeSecret(key: AntigravityCore.secretKey, value: auth.encoded())
        engine.activate(host: host)
        expect(engine.isConfigured && llm.isAvailable, "Both provider configurations restored through host SDK")
        expect(llm.supportedModels.contains(where: { $0.id == AntigravityCore.defaultModel }), "LLM model catalog visible to workflows")
        engine.deactivate()
        expect(!engine.isConfigured && !llm.isAvailable, "Deactivation clears in-memory configuration")
        guard let effortProvider = engine as? any LLMEffortControllableProvider else { fatalError("Effort protocol missing") }
        expect(effortProvider.supportedEfforts(for: "gemini-3-flash").contains(where: { $0.id == "low" }), "Actual bundle exposes thinking levels to TypeWhisper workflows")
        try await antigravityTests()
        try await modelTests()
        try await loopbackTests()
        print("All tests passed. Only offline mocks and loopback HTTP; no real credentials, browser login, or live API calls.")
    }
}
