import Foundation
import TypeWhisperPluginSDK

final class TestBus: EventBusProtocol, @unchecked Sendable {
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
    func unsubscribe(id: UUID) {}
    func emit(_ event: TypeWhisperEvent) async {}
}
final class TestHost: HostServices, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var defaults: [String: Any] = [:]
    var pluginDataDirectory: URL { URL(fileURLWithPath: "/tmp/typewhisper-mimo-offline-tests") }
    var eventBus: any EventBusProtocol { TestBus() }
    var activeAppBundleId: String? { nil }
    var activeAppName: String? { nil }
    var availableRuleNames: [String] { [] }
    var availableWorkflows: [PluginWorkflowInfo] { [] }
    func storeSecret(key: String, value: String) throws { lock.withLock { secrets[key] = value } }
    func loadSecret(key: String) -> String? { lock.withLock { secrets[key] } }
    func userDefault(forKey: String) -> Any? { lock.withLock { defaults[forKey] } }
    func setUserDefault(_ value: Any?, forKey: String) { lock.withLock { defaults[forKey] = value } }
    func notifyCapabilitiesChanged() {}
    func setStreamingDisplayActive(_ active: Bool) {}
}
actor MockTransport {
    private var responses: [(Int, Data)]
    private var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses.map { ($0.0, Data($0.1.utf8)) } }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { fatalError("Unexpected HTTP request") }
        let (status, data) = responses.removeFirst()
        // Permit actor reentrancy, exercising concurrent refresh coalescing.
        try await Task.sleep(for: .milliseconds(20))
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func count() -> Int { requests.count }
    func allRequests() -> [URLRequest] { requests }
}

extension Tests {
    @MainActor static func antigravityTests() async throws {
        expect(AntigravityCore.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE RFC 7636 vector")
        let random = try AntigravityCore.random()
        expect(random.count == 43 && !random.contains("="), "Cryptographic OAuth nonce")
        let url = AntigravityCore.authorizationURL(verifier: "private-verifier", state: "nonce")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        expect(query.first(where: { $0.name == "state" })?.value == "nonce" && !url.absoluteString.contains("private-verifier"), "OAuth state does not expose PKCE verifier")
        expect(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256", "PKCE challenge required")
        let code = try AntigravityCore.callback("/oauth-callback?state=nonce&code=a%2Bb", expectedState: "nonce")
        expect(code == "a+b", "Validate and decode OAuth callback")
        expectError("Reject forged OAuth state") { _ = try AntigravityCore.callback("/oauth-callback?state=wrong&code=a", expectedState: "nonce") }
        expectError("Reject duplicate OAuth state") { _ = try AntigravityCore.callback("/oauth-callback?state=nonce&state=wrong&code=a", expectedState: "nonce") }
        expectError("Reject wrong callback path") { _ = try AntigravityCore.callback("/other?state=nonce&code=a", expectedState: "nonce") }
        expectError("Reject denied consent") { _ = try AntigravityCore.callback("/oauth-callback?state=nonce&error=access_denied", expectedState: "nonce") }
        expect(String(decoding: AntigravityCore.form(["a": "a+b c&d"]), as: UTF8.self) == "a=a%2Bb%20c%26d", "Correct form escaping")
        expect(AntigravityCore.project(from: ["cloudaicompanionProject": ["id": "managed"]]) == "managed", "Managed project response")
        let generated: [String: Any] = ["response": ["candidates": [["finishReason": "STOP", "content": ["parts": [["thought": true, "text": "private reasoning"], ["text": "润色结果"]]]]]]]
        let output = try AntigravityCore.generatedText(generated)
        expect(output == "润色结果", "Never insert reasoning into user text")
        expectError("Reject truncated polishing") {
            _ = try AntigravityCore.generatedText(["candidates": [["finishReason": "MAX_TOKENS", "content": ["parts": [["text": "partial"]]]]]])
        }

        let host = TestHost()
        try host.storeSecret(key: "api-key", value: "fake-mimo-key")
        let loginMock = MockTransport([
            (200, #"{"access_token":"fake-access","refresh_token":"fake-refresh","expires_in":3600}"#),
            (200, #"{"cloudaicompanionProject":{"id":"fake-project"}}"#),
            (200, #"{"email":"offline@example.invalid"}"#)
        ])
        let service = AntigravityService(transport: { try await loginMock.send($0) })
        let credentials = try await service.completeAuthorization(code: "fake-code", verifier: "fake-verifier", host: host, projectOverride: "")
        expect(credentials.projectID == "fake-project", "Discover account project after authorization")
        expect(AntigravityCredentials.decode(host.loadSecret(key: AntigravityCore.secretKey))?.email == "offline@example.invalid", "OAuth credentials stored through host secret API")
        expect(host.loadSecret(key: "api-key") == "fake-mimo-key", "OAuth leaves MiMo key untouched")
        let loginRequests = await loginMock.allRequests()
        expect(loginRequests[0].url?.host == "oauth2.googleapis.com", "Exchange only at Google token endpoint")
        expect(loginRequests[1].url?.path == "/v1internal:loadCodeAssist", "Read account without automatic onboarding")

        var expired = credentials
        expired.expiresAt = Date(timeIntervalSince1970: 0)
        try host.storeSecret(key: AntigravityCore.secretKey, value: expired.encoded())
        let refreshMock = MockTransport([
            (200, #"{"access_token":"new-fake-access","expires_in":3600}"#),
            (200, #"{"response":{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"第一段"}]}}]}}"#),
            (200, #"{"response":{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"第二段"}]}}]}}"#)
        ])
        let refresher = AntigravityService(transport: { try await refreshMock.send($0) })
        async let first = refresher.generate(host: host, model: "gemini-3-flash", system: "polish", text: "one")
        async let second = refresher.generate(host: host, model: "gemini-3-flash", system: "polish", text: "two")
        let results = try await [first, second]
        expect(Set(results) == Set(["第一段", "第二段"]), "Concurrent polishing requests succeed")
        let refreshRequests = await refreshMock.allRequests()
        expect(refreshRequests.count == 3 && refreshRequests.filter { $0.url?.host == "oauth2.googleapis.com" }.count == 1, "Coalesce concurrent OAuth refresh")
        expect(AntigravityCredentials.decode(host.loadSecret(key: AntigravityCore.secretKey))?.refreshToken == "fake-refresh", "Keep refresh token when Google omits replacement")
        let generationRequests = refreshRequests.filter { $0.url?.path.contains("generateContent") == true }
        expect(generationRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer new-fake-access" }, "Generation uses refreshed access token")
        let generationBody = try JSONSerialization.jsonObject(with: generationRequests[0].httpBody!) as! [String: Any]
        expect(generationBody["project"] as? String == "fake-project", "Generation uses account project, not a shared project")
        expect((generationBody["request"] as? [String: Any])?["tools"] == nil, "Polishing has no file or shell tools")

        let blockedMock = MockTransport([(403, #"{"error":"blocked"}"#)])
        let blocked = AntigravityService(transport: { try await blockedMock.send($0) })
        do {
            _ = try await blocked.generate(host: host, model: "gemini-3-flash", system: "polish", text: "one")
            fatalError("403 accepted")
        } catch AntigravityError.http(403) { print("PASS: explicit access-denied error") }
        let blockedCount = await blockedMock.count()
        expect(blockedCount == 1, "No account or endpoint rotation on 403")
        try await refresher.logout(host: host)
        expect(AntigravityCredentials.decode(host.loadSecret(key: AntigravityCore.secretKey)) == nil, "Local logout clears OAuth credentials")
        expect(host.loadSecret(key: "api-key") == "fake-mimo-key", "Logout preserves MiMo key")
        do {
            _ = try await refresher.generate(host: host, model: "gemini-3-flash", system: "polish", text: "one")
            fatalError("Logged-out generation accepted")
        } catch AntigravityError.notLoggedIn { print("PASS: logged-out calls do not reach network") }

        let failedHost = TestHost()
        let missingProjectMock = MockTransport([
            (200, #"{"access_token":"a","refresh_token":"r","expires_in":3600}"#), (200, "{}")
        ])
        let incomplete = AntigravityService(transport: { try await missingProjectMock.send($0) })
        do {
            _ = try await incomplete.completeAuthorization(code: "fake", verifier: "fake", host: failedHost, projectOverride: "")
            fatalError("Missing project accepted")
        } catch AntigravityError.noProject { print("PASS: require project; never provision without consent") }
        expect(failedHost.loadSecret(key: AntigravityCore.secretKey) == nil, "Failed login does not persist incomplete credentials")

        try host.storeSecret(key: AntigravityCore.secretKey, value: expired.encoded())
        let lateMock = MockTransport([(200, #"{"access_token":"late","expires_in":3600}"#)])
        let lateService = AntigravityService(transport: { try await lateMock.send($0) })
        let lateCall = Task {
            try await lateService.generate(host: host, model: "gemini-3-flash", system: "polish", text: "one")
        }
        for _ in 0..<100 {
            if await lateMock.count() > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await lateService.logout(host: host)
        do { _ = try await lateCall.value; fatalError("Late refresh survived logout") }
        catch is CancellationError { print("PASS: logout invalidates an in-flight token refresh") }
        expect(AntigravityCredentials.decode(host.loadSecret(key: AntigravityCore.secretKey)) == nil, "Late OAuth response cannot recreate logged-out credentials")
    }
}
