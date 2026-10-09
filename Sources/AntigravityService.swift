import Foundation
import TypeWhisperPluginSDK

actor AntigravityService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport
    private var epoch = 0
    private var loginRunning = false
    private var refreshTask: Task<AntigravityCredentials, any Error>?
    init(transport: Transport? = nil) {
        if let transport { self.transport = transport }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.timeoutIntervalForResource = 120
            let session = URLSession(configuration: config)
            self.transport = { request in try await session.data(for: request) }
        }
    }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AntigravityError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AntigravityError.http(http.statusCode) }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AntigravityError.invalidResponse }
        return value
    }
    private func checkEpoch(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == epoch else { throw CancellationError() }
    }
    func invalidate() {
        epoch += 1
        refreshTask?.cancel(); refreshTask = nil
    }
    func logout(host: any HostServices) throws {
        invalidate()
        try host.storeSecret(key: AntigravityCore.secretKey, value: "")
    }
    func login(host: any HostServices, projectOverride: String) async throws -> AntigravityCredentials {
        guard !loginRunning else { throw AntigravityError.busy }
        loginRunning = true
        defer { loginRunning = false }
        invalidate()
        let expected = epoch
        let verifier = try AntigravityCore.random()
        let state = try AntigravityCore.random()
        let url = AntigravityCore.authorizationURL(verifier: verifier, state: state)
        let code = try await OAuthLoopback.authenticate(url: url, state: state)
        try checkEpoch(expected)
        return try await completeAuthorization(code: code, verifier: verifier, host: host, projectOverride: projectOverride)
    }
    // Split out the post-callback operation for offline transport testing.
    func completeAuthorization(code: String, verifier: String, host: any HostServices, projectOverride: String) async throws -> AntigravityCredentials {
        let expected = epoch
        let tokens = try await json(AntigravityCore.tokenRequest(code: code, verifier: verifier))
        guard let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              let seconds = tokens["expires_in"] as? Double, seconds.isFinite, seconds > 0 else { throw AntigravityError.invalidResponse }
        let project = try await discoverProject(access: access, override: projectOverride)
        try checkEpoch(expected)
        var credentials = AntigravityCredentials(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(seconds), projectID: project)
        var userInfo = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v1/userinfo?alt=json")!, timeoutInterval: 15)
        userInfo.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        if let object = try? await json(userInfo) { credentials.email = object["email"] as? String }
        try checkEpoch(expected)
        try host.storeSecret(key: AntigravityCore.secretKey, value: credentials.encoded())
        return credentials
    }
    private func discoverProject(access: String, override: String) async throws -> String {
        let override = override.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata: [String: String] = ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "ANTIGRAVITY"]
        var body: [String: Any] = [:]
        if !override.isEmpty { metadata["duetProject"] = override; body["cloudaicompanionProject"] = override }
        body["metadata"] = metadata
        let request = try AntigravityCore.apiRequest(action: "loadCodeAssist", token: access, body: body)
        let response = try await json(request)
        if let project = AntigravityCore.project(from: response) { return project }
        if !override.isEmpty { return override }
        // Do not provision a project, select a paid tier, or rotate endpoints.
        throw AntigravityError.noProject
    }
    private func credentials(host: any HostServices) async throws -> AntigravityCredentials {
        guard let stored = AntigravityCredentials.decode(host.loadSecret(key: AntigravityCore.secretKey)) else { throw AntigravityError.notLoggedIn }
        guard stored.expiresAt.timeIntervalSinceNow < 60 else { return stored }
        if let refreshTask { return try await refreshTask.value }
        let expected = epoch
        let task = Task { () throws -> AntigravityCredentials in
            let response = try await self.json(AntigravityCore.refreshRequest(stored.refreshToken))
            guard let access = response["access_token"] as? String, !access.isEmpty,
                  let seconds = response["expires_in"] as? Double, seconds.isFinite, seconds > 0 else { throw AntigravityError.invalidResponse }
            var updated = stored
            updated.accessToken = access
            updated.expiresAt = Date().addingTimeInterval(seconds)
            if let rotated = response["refresh_token"] as? String, !rotated.isEmpty { updated.refreshToken = rotated }
            try self.checkEpoch(expected)
            try host.storeSecret(key: AntigravityCore.secretKey, value: updated.encoded())
            return updated
        }
        refreshTask = task
        defer { if expected == epoch { refreshTask = nil } }
        return try await task.value
    }
    func generate(host: any HostServices, model: String, system: String, text: String) async throws -> String {
        guard !loginRunning else { throw AntigravityError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let expected = epoch
        let credentials = try await credentials(host: host)
        try checkEpoch(expected)
        let override = (host.userDefault(forKey: "antigravity-project") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = override.isEmpty ? credentials.projectID : override
        guard !project.isEmpty else { throw AntigravityError.noProject }
        let body = AntigravityCore.generationBody(project: project, model: model, system: system, text: text)
        let response = try await json(AntigravityCore.apiRequest(action: "generateContent", token: credentials.accessToken, body: body))
        try checkEpoch(expected)
        return try AntigravityCore.generatedText(response)
    }
}
