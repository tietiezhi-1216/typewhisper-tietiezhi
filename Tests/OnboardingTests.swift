import Foundation

extension Tests {
    @MainActor static func onboardingTests() async throws {
        expect(AntigravityCore.validProjectOverride(""), "Blank project uses automatic discovery")
        expect(AntigravityCore.validProjectOverride("my-google-project-123"), "Accept real-format Google Cloud project ID")
        expect(!AntigravityCore.validProjectOverride("1"), "Reject arbitrary numeric project placeholder")
        let offer: [String: Any] = ["allowedTiers": [["id": "free-tier", "isDefault": true]]]
        expect(AntigravityCore.freeOnboardingTier(offer) == "free-tier", "Only use server-offered default free tier")
        expect(AntigravityCore.freeOnboardingTier(["allowedTiers": [["id": "standard-tier", "isDefault": true]]]) == nil, "Never choose a paid onboarding tier")
        expect(AntigravityCore.freeOnboardingTier(["allowedTiers": [["id": "free-tier", "isDefault": true, "userDefinedCloudaicompanionProject": true]]]) == nil, "Do not provision user-defined Cloud projects")
        expect(AntigravityCore.freeOnboardingTier(["allowedTiers": [["id": "free-tier", "isDefault": true]], "ineligibleTiers": [["tierId": "free-tier"]]]) == nil, "Respect explicit free-tier ineligibility")
        expect(AntigravityCore.freeOnboardingTier(["allowedTiers": [["id": "free-tier", "isDefault": true]], "paidTier": ["id": "standard-tier"]]) == nil, "Never alter an existing paid plan")
        expectError("Reject operation URLs pointing outside Google") { _ = try AntigravityCore.operationRequest(name: "https://evil.invalid/token", token: "fake") }
        expectError("Reject operation path traversal") { _ = try AntigravityCore.operationRequest(name: "operations/../token", token: "fake") }
        let poll = try AntigravityCore.operationRequest(name: "operations/cmpf.abc-123", token: "fake")
        expect(poll.url?.host == "daily-cloudcode-pa.sandbox.googleapis.com" && poll.httpMethod == "GET", "Poll operations only at the fixed Google endpoint")

        let mock = MockTransport([
            (200, #"{"access_token":"fake","refresh_token":"fake-refresh","expires_in":3600}"#),
            (200, #"{"allowedTiers":[{"id":"free-tier","isDefault":true}]}"#),
            (200, #"{"name":"operations/cmpf.test","done":false}"#),
            (200, #"{"done":true,"response":{"cloudaicompanionProject":{"id":"managed-free-project"}}}"#),
            (200, #"{"email":"test@example.invalid"}"#)
        ])
        let service = AntigravityService(transport: { try await mock.send($0) })
        let host = TestHost()
        let credentials = try await service.completeAuthorization(code: "fake", verifier: "fake", host: host, projectOverride: "", allowFreeOnboarding: true)
        expect(credentials.projectID == "managed-free-project", "First login can complete explicitly consented free onboarding")
        let requests = await mock.allRequests()
        expect(requests[2].url?.path == "/v1internal:onboardUser", "Initialize via onboardUser rather than invent a project")
        let body = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
        expect(body["tierId"] as? String == "free-tier" && body["cloudaicompanionProject"] == nil, "Free onboarding does not send a user project or paid tier")
        expect(requests[3].httpMethod == "GET" && requests[3].url?.path == "/v1internal/operations/cmpf.test", "Poll the returned operation instead of retrying project creation")
        expect(AntigravityCredentials.decode(host.loadSecret(key: AntigravityCore.secretKey))?.projectID == "managed-free-project", "Persist OAuth only after successful project initialization")

        let denied = MockTransport([
            (200, #"{"access_token":"fake","refresh_token":"fake-refresh","expires_in":3600}"#),
            (200, #"{"allowedTiers":[{"id":"free-tier","isDefault":true}]}"#)
        ])
        let noConsent = AntigravityService(transport: { try await denied.send($0) })
        do {
            _ = try await noConsent.completeAuthorization(code: "fake", verifier: "fake", host: TestHost(), projectOverride: "")
            fatalError("Onboarding without consent accepted")
        } catch AntigravityError.noProject { print("PASS: project initialization requires explicit consent") }
        let count = await denied.count()
        expect(count == 2, "No provisioning request without consent")
    }
}
