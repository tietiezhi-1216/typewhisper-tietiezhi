import Foundation
import TypeWhisperPluginSDK

extension Tests {
    // Synthetic catalog based on runtime IDs/examples in pi-antigravity 0.9.0,
    // not a live account response and not a claim of account availability.
    static let piCatalog = #"{"models":{"gemini-3.8-flash-low":{"displayName":"Gemini 3.8 Flash (Low)","model":"MODEL_PLACEHOLDER_M320"},"gemini-3.8-flash-medium":{"displayName":"Gemini 3.8 Flash (Medium)","model":"MODEL_PLACEHOLDER_M319"},"gemini-3.8-flash-high":{"displayName":"Gemini 3.8 Flash (High)","model":"MODEL_PLACEHOLDER_M318"},"gemini-3.5-flash-extra-low":{"displayName":"Gemini 3.5 Flash (Low)"},"gemini-3.5-flash-low":{"displayName":"Gemini 3.5 Flash (Medium)"},"gemini-3-flash-agent":{"displayName":"Gemini 3.5 Flash (High)"},"gemini-3.1-pro-low":{"displayName":"Gemini 3.1 Pro (Low)"},"gemini-3.1-pro-high":{"displayName":"Gemini 3.1 Pro (High)"},"claude-opus-4-6-thinking":{"label":"Claude Opus 4.6 (Thinking)","supportsThinking":true},"claude-sonnet-4-6":{"modelName":"Claude Sonnet 4.6","supportsThinking":true},"gpt-oss-120b-medium":{"displayName":"GPT-OSS 120B (Medium)"},"gemini-internal":{"isInternal":true},"gemini-image":{"displayName":"Image"},"gemini-tts":{"displayName":"Voice"},"MODEL_PLACEHOLDER_M320":{},"tab_gemini-3.8-flash":{}}}"#

    @MainActor static func modelTests() async throws {
        let raw = try JSONSerialization.jsonObject(with: Data(piCatalog.utf8)) as! [String: Any]
        let models = try AntigravityCatalog.parse(raw)
        expect(Set(models.map(\.id)) == Set(["gemini-3.8-flash", "gemini-3.5-flash", "gemini-3.1-pro", "claude-opus-4-6", "claude-sonnet-4-6", "gpt-oss-120b"]), "Group public families; exclude internal/image/audio/enums")
        let flash = models.first { $0.id == "gemini-3.8-flash" }!
        expect(flash.name == "Gemini 3.8 Flash", "Picker does not duplicate model effort variants")
        expect(flash.efforts == [.auto, .off, .low, .medium, .high], "Offer actual advertised effort tiers")
        expect(flash.route(.auto).id == "gemini-3.8-flash-low", "Default routes to real low runtime")
        expect(flash.route(.high).id == "gemini-3.8-flash-high", "High selects actual backend variant")
        expect(flash.route(.high).modelEnum == "MODEL_PLACEHOLDER_M318", "Preserve dynamically discovered model enum")
        var tiered = flash
        tiered.runtime = AntigravityRuntime(id: "gemini-3.8-flash-tiered")
        expect(tiered.route(.off).id == "gemini-3.8-flash-low", "Default/off prefers low variant over tiered runtime")
        let spaced = try AntigravityCatalog.parse(["models": ["gemini-3.5-flash-low": ["displayName": "Gemini 3.5 Flash ( Medium )"]]])
        expect(spaced[0].route(.medium).id == "gemini-3.5-flash-low" && spaced[0].name == "Gemini 3.5 Flash", "Whitespace in display effort is parsed and removed")
        let legacyFlash = models.first { $0.id == "gemini-3.5-flash" }!
        expect(legacyFlash.route(.medium).id == "gemini-3.5-flash-low", "Display level overrides misleading runtime suffix")
        expect(legacyFlash.route(.high).id == "gemini-3-flash-agent", "Route known agent alias to public Flash family")
        expect(models.first { $0.id == "claude-opus-4-6" }?.route(.high).id == "claude-opus-4-6-thinking", "Claude thinking maps to actual runtime")
        expect(models.first { $0.id == "gpt-oss-120b" }?.route(.medium).id == "gpt-oss-120b-medium", "GPT-OSS is a supported text family")
        let disabled = try AntigravityCatalog.parse(["models": ["claude-test": ["supportsThinking": false]]])
        expect(disabled[0].efforts == [.auto, .off], "Honor explicit non-thinking capability")
        expectError("Missing catalog is not fabricated") { _ = try AntigravityCatalog.parse([:]) }
        expectError("Empty catalog is reported") { _ = try AntigravityCatalog.parse(["models": [:]]) }
        let roundtrip = try JSONDecoder().decode([AntigravityModel].self, from: JSONEncoder().encode(models))
        expect(roundtrip == models, "Persist runtime routing, enums and capabilities")
        let old = try JSONDecoder().decode([AntigravityModel].self, from: Data(#"[{"id":"gemini-3-flash","name":"Old Flash"}]"#.utf8))
        expect(old[0].id == "gemini-3-flash", "Old model cache schema remains decodable")

        let budgetCases: [(String, AntigravityThinking, Int)] = [
            ("claude-sonnet-4-6", .high, 1024), ("claude-opus-4-6-thinking", .low, 1024),
            ("gpt-oss-120b-medium", .medium, 8192), ("gemini-3.5-flash-low", .medium, 4000),
            ("gemini-3-flash-agent", .high, 10000), ("gemini-3.1-pro-low", .low, 1001),
            ("gemini-pro-agent", .high, 10001), ("gemini-3.8-flash-high", .high, -1)
        ]
        for (id, level, budget) in budgetCases {
            let config = level.config(for: id)!
            expect(config["thinkingBudget"] as? Int == budget && config["includeThoughts"] as? Bool == true, "Pi budget: \(id)/\(level.rawValue)")
            expect(config["thinkingLevel"] == nil, "No public Gemini thinkingLevel on CLI wire")
        }
        for level in [AntigravityThinking.auto, .off] {
            let config = level.config(for: "gemini-3.8-flash-low")!
            expect(config["thinkingBudget"] as? Int == 0 && config["includeThoughts"] as? Bool == false, "Default/off suppresses thought output")
        }

        let host = TestHost()
        let credentials = AntigravityCredentials(accessToken: "fake", refreshToken: "fake", expiresAt: Date().addingTimeInterval(3600), projectID: "managed-project")
        try host.storeSecret(key: AntigravityCore.secretKey, value: credentials.encoded())
        let mock = MockTransport(perHost: [
            "daily-cloudcode-pa.googleapis.com": [(200, piCatalog)],
            "daily-cloudcode-pa.sandbox.googleapis.com": [(403, "{}")],
            "cloudcode-pa.googleapis.com": [(200, #"{"models":{"gemini-3.8-flash-high":{"displayName":"Gemini 3.8 Flash (High)"},"gemini-3.7-flash-low":{"displayName":"Gemini 3.7 Flash (Low)"}}}"#)]
        ])
        let service = AntigravityService(transport: { try await mock.send($0) })
        let fetched = try await service.models(host: host)
        expect(fetched.contains { $0.id == "gemini-3.7-flash" }, "Merge successful catalogs even when sandbox returns 403")
        expect(fetched.first { $0.id == "gemini-3.8-flash" }?.route(.high).endpoint == AntigravityCore.endpoint, "Duplicate routing keeps primary endpoint")
        expect(fetched.first { $0.id == "gemini-3.7-flash" }?.route(.auto).endpoint == AntigravityCore.endpoints[2], "Endpoint-specific runtime retains source")
        let requests = await mock.allRequests()
        let body = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
        expect(requests.count == 3 && body["project"] as? String == "managed-project", "Catalog probes use account project and three fixed endpoints")
        expect(requests[0].timeoutInterval == 8 && requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fake", "Bound metadata probes and authenticate")
        let productionMock = MockTransport(perHost: [
            "daily-cloudcode-pa.googleapis.com": [(403, "{}")],
            "daily-cloudcode-pa.sandbox.googleapis.com": [(403, "{}")],
            "cloudcode-pa.googleapis.com": [(200, piCatalog)]
        ])
        let productionService = AntigravityService(transport: { try await productionMock.send($0) })
        let productionModels = try await productionService.models(host: host)
        expect(productionModels.first { $0.id == "gemini-3.8-flash" }?.route(.high).endpoint == AntigravityCore.endpoints[2], "Daily/sandbox denial does not discard an authorized production catalog")
        try host.setCatalog(fetched)
        let generationMock = MockTransport([(200, #"{"response":{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"done"}]}}]}}"#)])
        let generator = AntigravityService(transport: { try await generationMock.send($0) })
        _ = try await generator.generate(host: host, model: "gemini-3.8-flash", system: "s", text: "t", thinking: .high)
        let sent = await generationMock.allRequests()
        let sentBody = try JSONSerialization.jsonObject(with: sent[0].httpBody!) as! [String: Any]
        let request = sentBody["request"] as! [String: Any]
        let sentConfig = request["generationConfig"] as! [String: Any]
        expect(sentBody["model"] as? String == "gemini-3.8-flash-high", "Service uses chosen effort's real runtime, not UI base ID")
        expect((sentConfig["thinkingConfig"] as! [String: Any])["thinkingBudget"] as? Int == -1, "Service sends selected effort budget")
        expect(sent[0].url?.path == "/v1internal:streamGenerateContent" && sent[0].url?.query == "alt=sse", "Use Pi's actual stream generation endpoint")
        expect(sentBody["requestType"] as? String == "agent" && (sentBody["requestId"] as? String)?.hasPrefix("agent/") == true, "Include CLI request envelope")
        let labels = request["labels"] as! [String: String]
        expect(labels["model_enum"] == "MODEL_PLACEHOLDER_M318" && labels["used_non_gemini_model"] == "false", "Send discovered enum and model-family telemetry labels")
        expect(request["sessionId"] is String && request["tools"] == nil, "Polishing has session identifier but no tools")
        expect(sent[0].value(forHTTPHeaderField: "User-Agent")?.contains("tietiezhi/") == true, "Compatibility header identifies third-party app")
    }
}

extension TestHost {
    func setCatalog(_ models: [AntigravityModel]) throws {
        setUserDefault(try JSONEncoder().encode(models), forKey: AntigravityCore.catalogKey)
    }
}
