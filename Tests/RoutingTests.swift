import Foundation

extension Tests {
    @MainActor static func routingTests() async throws {
        expect(AntigravityCore.stableProjectID(seed: "offline@example.invalid") == "9b4b9ab6-ea95-56e8-8f5d-265d26f829e5", "Stable project matches Node/Pi SHA-1 UUID vector")
        expect(AntigravityCore.stableProjectID(seed: "one@example.invalid") != AntigravityCore.stableProjectID(seed: "two@example.invalid"), "Fallback routing is account-associated, not shared")
        for object: [String: Any] in [["antigravityProjectId": "one"], ["projectId": "one"], ["backendProjectId": "one"], ["projectIds": ["one"]], ["projects": [["project": ["id": "one"]]]]] {
            expect(AntigravityCore.project(from: object) == "one", "Parse Pi project response shape")
        }
        expectError("Never send credentials to arbitrary API hosts") { _ = try AntigravityCore.apiRequest(action: "fetchAvailableModels", token: "fake", body: [:], endpoint: "https://evil.invalid") }
        expectError("No onboarding action is implemented") { _ = try AntigravityCore.apiRequest(action: "onboardUser", token: "fake", body: [:]) }

        let host = TestHost()
        // Legacy advanced preference must not keep blocking users who entered 1.
        host.setUserDefault("1", forKey: "antigravity-project")
        let mock = MockTransport([
            (200, #"{"access_token":"fake","refresh_token":"fake-refresh","expires_in":3600}"#),
            (200, #"{"email":"offline@example.invalid"}"#),
            (200, #"{"allowedTiers":[{"id":"free-tier","isDefault":true}]}"#),
            (200, #"{"projects":[]}"#),
            (200, piCatalog), (404, "{}"), (404, "{}"),
            (200, #"{"response":{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"done"}]}}]}}"#)
        ])
        let service = AntigravityService(transport: { try await mock.send($0) })
        let credentials = try await service.completeAuthorization(code: "fake", verifier: "fake", host: host)
        expect(credentials.projectIsFallback == true && host.loadSecret(key: AntigravityCore.secretKey) != nil, "Commit successful OAuth before metadata discovery")
        let loginCount = await mock.count()
        expect(loginCount == 2, "No project lookup can turn successful login into a failure")
        let models = try await service.models(host: host)
        try host.setCatalog(models)
        let output = try await service.generate(host: host, model: "gemini-3.8-flash", system: "s", text: "t")
        expect(output == "done", "Missing Cloud project does not prevent account-associated model requests")
        let requests = await mock.allRequests()
        let metadata = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
        expect((metadata["metadata"] as? [String: String]) == ["ideType": "ANTIGRAVITY"], "Use actual Pi Antigravity metadata rather than Gemini initialization enums")
        expect(requests[3].url?.path == "/v1internal:listCloudAICompanionProjects", "Try read-only account project list")
        let generation = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
        expect(generation["project"] as? String == credentials.projectID, "Ignore invalid legacy manual preference, use stable fallback")
        expect(requests.count == 8 && requests.filter { $0.url?.path.contains("loadCodeAssist") == true }.count == 1, "Cache project absence for 30 minutes")
        expect(!requests.contains { $0.url?.path.contains("onboard") == true || $0.url?.path.contains("operations") == true }, "No provisioning even when free tier is offered")

        let managedHost = TestHost()
        try managedHost.storeSecret(key: AntigravityCore.secretKey, value: credentials.encoded())
        let managedMock = MockTransport([
            (200, #"{"backendProjectId":"account-project"}"#), (200, piCatalog), (404, "{}"), (404, "{}")
        ])
        let managedService = AntigravityService(transport: { try await managedMock.send($0) })
        _ = try await managedService.models(host: managedHost)
        let discovered = AntigravityCredentials.decode(managedHost.loadSecret(key: AntigravityCore.secretKey))!
        expect(discovered.projectID == "account-project" && discovered.projectIsFallback == false, "Real account project replaces fallback without new login")
        expect(discovered.refreshToken == credentials.refreshToken, "Project update preserves OAuth credentials")

        for status in [401, 403, 429] {
            let deniedHost = TestHost()
            var managed = credentials
            managed.projectID = "account-project"; managed.projectIsFallback = false
            try deniedHost.storeSecret(key: AntigravityCore.secretKey, value: managed.encoded())
            let deniedMock = MockTransport([(status, "{}")])
            let deniedService = AntigravityService(transport: { try await deniedMock.send($0) })
            do { _ = try await deniedService.models(host: deniedHost); fatalError("Denied catalog accepted") }
            catch let error as AntigravityHTTPError { expect(error.status == status && error.stage == .models, "Report catalog denial/limit: \(status)") }
            let count = await deniedMock.count()
            expect(count == 1, "No endpoint rotation for HTTP \(status)")
            expect(AntigravityCredentials.decode(deniedHost.loadSecret(key: AntigravityCore.secretKey)) != nil, "Catalog failure does not erase successful OAuth")
        }
        let blockedHost = TestHost()
        try blockedHost.storeSecret(key: AntigravityCore.secretKey, value: credentials.encoded())
        let blockedMock = MockTransport([(403, "{}"), (403, "{}")])
        let blocked = AntigravityService(transport: { try await blockedMock.send($0) })
        do { _ = try await blocked.models(host: blockedHost); fatalError("Denied model accepted") }
        catch let error as AntigravityHTTPError { expect(error.stage == .models, "Project failure is nonfatal but model permission error remains explicit") }
        let deniedRequests = await blockedMock.allRequests()
        expect(deniedRequests.count == 2 && deniedRequests.allSatisfy { $0.url?.host == "daily-cloudcode-pa.googleapis.com" }, "Do not probe other endpoints after project/model 403")

        let lateHost = TestHost()
        try lateHost.storeSecret(key: AntigravityCore.secretKey, value: credentials.encoded())
        let lateMock = MockTransport([(200, #"{"projectId":"late-project"}"#)])
        let lateService = AntigravityService(transport: { try await lateMock.send($0) })
        let call = Task { try await lateService.models(host: lateHost) }
        for _ in 0..<100 {
            if await lateMock.count() > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await lateService.logout(host: lateHost)
        do { _ = try await call.value; fatalError("Late project lookup survived logout") }
        catch is CancellationError { print("PASS: logout cancels in-flight project discovery") }
        expect(AntigravityCredentials.decode(lateHost.loadSecret(key: AntigravityCore.secretKey)) == nil, "Late project discovery cannot resurrect logged-out credentials")

        var expired = credentials
        expired.expiresAt = .distantPast
        expired.projectID = "old-project"; expired.projectIsFallback = false
        let raceHost = TestHost()
        try raceHost.storeSecret(key: AntigravityCore.secretKey, value: expired.encoded())
        let raceMock = MockTransport([(200, #"{"access_token":"new-fake","expires_in":3600}"#), (200, #"{"response":{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"done"}]}}]}}"#)])
        let raceService = AntigravityService(transport: { try await raceMock.send($0) })
        let raceCall = Task { try await raceService.generate(host: raceHost, model: "gemini-3.8-flash-low", system: "s", text: "t") }
        for _ in 0..<100 {
            if await raceMock.count() > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        expired.projectID = "newly-discovered-project"
        try raceHost.storeSecret(key: AntigravityCore.secretKey, value: expired.encoded())
        _ = try await raceCall.value
        expect(AntigravityCredentials.decode(raceHost.loadSecret(key: AntigravityCore.secretKey))?.projectID == "newly-discovered-project", "Token refresh cannot overwrite a concurrent project update")
    }
}
