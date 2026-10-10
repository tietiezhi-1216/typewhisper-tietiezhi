import Foundation
import TypeWhisperPluginSDK

extension Tests {
    @MainActor static func modelTests() async throws {
        let catalog: [String: Any] = ["models": [
            "gemini-3-flash": ["displayName": "Gemini Flash"],
            "claude-sonnet-thinking": ["displayName": "Claude Sonnet"],
            "gemini-image": ["displayName": "Image"],
            "gemini-tts": ["displayName": "Voice"],
            "embedding": ["displayName": "Embedding"]
        ]]
        let models = try AntigravityCatalog.parse(catalog)
        expect(Set(models.map(\.id)) == Set(["gemini-3-flash", "claude-sonnet-thinking"]), "Catalog filters non-text models and preserves API IDs")
        expect(models.first?.name == "Claude Sonnet", "Model picker uses API display names")
        expectError("Missing model catalog is not fabricated") { _ = try AntigravityCatalog.parse([:]) }
        expectError("Empty model catalog is reported") { _ = try AntigravityCatalog.parse(["models": [:]]) }
        expect(AntigravityThinking.options(for: "gemini-3-flash").contains(.minimal), "Gemini Flash offers minimal thinking")
        expect(!AntigravityThinking.options(for: "gemini-3-pro").contains(.medium), "Gemini Pro does not offer unsupported medium tier")
        expect(AntigravityThinking.options(for: "gemini-3-pro-high") == [.auto], "Fixed-effort model IDs do not offer a fake override")
        expect(AntigravityThinking.options(for: "claude-sonnet") == [.auto], "Non-thinking Claude does not offer unsupported effort")
        let flash = AntigravityCore.generationBody(project: "p", model: "gemini-3-flash", system: "s", text: "t", thinking: .high)
        let config = (flash["request"] as! [String: Any])["generationConfig"] as! [String: Any]
        let thinking = config["thinkingConfig"] as! [String: Any]
        expect(thinking["thinkingLevel"] as? String == "high" && thinking["includeThoughts"] as? Bool == false, "Gemini 3 thinking level maps to actual request")
        let budget = AntigravityThinking.high.config(for: "gemini-2.5-flash")!
        expect(budget["thinkingBudget"] as? Int == 8192, "Gemini 2.5 effort uses token budget")
        expect((config["maxOutputTokens"] as! Int) > (budget["thinkingBudget"] as! Int), "Output limit leaves room for thinking and final text")
        expect(AntigravityThinking.auto.config(for: "gemini-3-flash") == nil, "Default effort omits thinking override")

        let host = TestHost()
        let credentials = AntigravityCredentials(accessToken: "fake", refreshToken: "fake", expiresAt: Date().addingTimeInterval(3600), projectID: "managed-project")
        try host.storeSecret(key: AntigravityCore.secretKey, value: credentials.encoded())
        let mock = MockTransport([(200, #"{"models":{"gemini-3-flash":{"displayName":"Gemini Flash"}}}"#)])
        let service = AntigravityService(transport: { try await mock.send($0) })
        let fetched = try await service.models(host: host)
        expect(fetched == [AntigravityModel(id: "gemini-3-flash", name: "Gemini Flash")], "Authenticated model discovery parses catalog")
        let requests = await mock.allRequests()
        let body = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
        expect(requests[0].url?.path == "/v1internal:fetchAvailableModels" && body["project"] as? String == "managed-project", "Catalog request uses real endpoint and account project")
        expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fake", "Catalog request uses OAuth token")

        let generationMock = MockTransport([(200, #"{"response":{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"done"}]}}]}}"#)])
        let generator = AntigravityService(transport: { try await generationMock.send($0) })
        _ = try await generator.generate(host: host, model: "gemini-3-flash", system: "s", text: "t", thinking: .low)
        let sent = await generationMock.allRequests()
        let sentBody = try JSONSerialization.jsonObject(with: sent[0].httpBody!) as! [String: Any]
        let request = sentBody["request"] as! [String: Any]
        let sentConfig = request["generationConfig"] as! [String: Any]
        expect((sentConfig["thinkingConfig"] as! [String: Any])["thinkingLevel"] as? String == "low", "Service forwards selected effort rather than a UI-only setting")
    }
}
