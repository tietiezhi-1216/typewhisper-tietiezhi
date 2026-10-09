import Foundation

@MainActor final class BrowserProbe {
    var port: UInt16?
    var calls = 0
    var requestTask: Task<Void, any Error>?
}

extension Tests {
    @MainActor static func loopbackTests() async throws {
        let probe = BrowserProbe()
        let result = try await OAuthLoopback.authenticate(url: URL(string: "https://example.invalid/test-oauth")!, state: "test-state", port: 0) { _, port in
            probe.port = port; probe.calls += 1
            probe.requestTask = Task { @MainActor in
                let session = URLSession(configuration: .ephemeral)
                // A fragmented HTTP request is handled by the production receive loop;
                // here ordinary URLSession exercises the real loopback listener.
                let invalid = URL(string: "http://127.0.0.1:\(port)/oauth-callback?state=forged&code=bad")!
                let (_, invalidResponse) = try await session.data(from: invalid)
                expect((invalidResponse as? HTTPURLResponse)?.statusCode == 400, "Loopback rejects forged state without cancelling sign-in")
                let valid = URL(string: "http://127.0.0.1:\(port)/oauth-callback?state=test-state&code=offline-code")!
                let (data, response) = try await session.data(from: valid)
                expect((response as? HTTPURLResponse)?.statusCode == 200, "Loopback returns success page")
                expect(!String(decoding: data, as: UTF8.self).contains("offline-code"), "Success page never echoes authorization code")
            }
            return true
        }
        try await probe.requestTask?.value
        expect(result == "offline-code" && probe.calls == 1, "Loopback resumes once with validated authorization code")

        let cancelled = BrowserProbe()
        let task = Task { @MainActor in
            try await OAuthLoopback.authenticate(url: URL(string: "https://example.invalid/test-oauth")!, state: "test-state", port: 0) { _, port in
                cancelled.port = port
                return true
            }
        }
        for _ in 0..<100 where cancelled.port == nil { try await Task.sleep(for: .milliseconds(10)) }
        expect(cancelled.port != nil, "Cancellation test listener starts")
        task.cancel()
        do { _ = try await task.value; fatalError("Cancelled listener returned code") }
        catch is CancellationError { print("PASS: cancel sign-in resumes pending callback") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(cancelled.port!)/oauth-callback?state=test-state&code=late")!)
        request.timeoutInterval = 1
        do {
            _ = try await URLSession.shared.data(for: request)
            fatalError("Cancelled listener remains reachable")
        } catch { print("PASS: cancelled listener closes loopback port") }
    }
}
