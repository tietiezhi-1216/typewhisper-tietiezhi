import Foundation
import TypeWhisperPluginSDK

actor AntigravityService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport
    private var epoch = 0
    private var loginRunning = false
    private var refreshTask: Task<AntigravityCredentials, any Error>?
    private var projectTask: Task<String?, any Error>?
    private var projectCheckedUntil = Date.distantPast
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
    private func data(_ request: URLRequest, stage: AntigravityRequestStage) async throws -> Data {
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AntigravityError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AntigravityHTTPError(status: http.statusCode, stage: stage, diagnostic: AntigravityHTTPError.safeDiagnostic(data))
        }
        return data
    }
    private func json(_ request: URLRequest, stage: AntigravityRequestStage) async throws -> [String: Any] {
        let data = try await self.data(request, stage: stage)
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AntigravityError.invalidResponse }
        return value
    }
    private func checkEpoch(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == epoch else { throw CancellationError() }
    }
    // Never rotate accounts/endpoints in response to an authorization denial or
    // quota limit. Read-only metadata compatibility probes may try another
    // documented endpoint after a missing method, server failure or timeout.
    private func canProbeAnotherEndpoint(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let http = error as? AntigravityHTTPError { return [404, 405, 408, 500, 502, 503, 504].contains(http.status) }
        if let network = error as? URLError { return network.code != .cancelled }
        return error is AntigravityError || error is DecodingError
    }
    func invalidate() {
        epoch += 1
        refreshTask?.cancel(); refreshTask = nil
        projectTask?.cancel(); projectTask = nil
        projectCheckedUntil = .distantPast
    }
    func logout(host: any HostServices) throws {
        invalidate()
        try host.storeSecret(key: AntigravityCore.secretKey, value: "")
    }
    func login(host: any HostServices) async throws -> AntigravityCredentials {
        guard !loginRunning else { throw AntigravityError.busy }
        loginRunning = true
        defer { loginRunning = false }
        invalidate()
        let expected = epoch
        let verifier = try AntigravityCore.random(), state = try AntigravityCore.random()
        let code = try await OAuthLoopback.authenticate(url: AntigravityCore.authorizationURL(verifier: verifier, state: state), state: state)
        try checkEpoch(expected)
        return try await completeAuthorization(code: code, verifier: verifier, host: host)
    }
    // Successful OAuth is independent of project discovery/model availability.
    // No onboarding or Cloud project creation is performed at login or later.
    func completeAuthorization(code: String, verifier: String, host: any HostServices) async throws -> AntigravityCredentials {
        let expected = epoch
        let tokens = try await json(AntigravityCore.tokenRequest(code: code, verifier: verifier), stage: .exchange)
        guard let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              let seconds = tokens["expires_in"] as? Double, seconds.isFinite, seconds > 0 else { throw AntigravityError.invalidResponse }
        try checkEpoch(expected)
        let expiresAt = Date().addingTimeInterval(seconds)
        var userInfo = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v1/userinfo?alt=json")!, timeoutInterval: 8)
        userInfo.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        let profile = try? await json(userInfo, stage: .profile)
        try checkEpoch(expected)
        let email = profile?["email"] as? String
        // If profile lookup fails, use an installation/account-specific seed;
        // unlike a shared default, it is not accidentally shared by all users.
        let seed = email ?? AntigravityCore.challenge(refresh)
        let credentials = AntigravityCredentials(accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
            projectID: AntigravityCore.stableProjectID(seed: seed), email: email, projectIsFallback: true)
        try host.storeSecret(key: AntigravityCore.secretKey, value: credentials.encoded())
        return credentials
    }
    private func discoverProject(access: String) async throws -> String? {
        let expected = epoch
        for action in ["loadCodeAssist", "listCloudAICompanionProjects"] {
            for endpoint in AntigravityCore.endpoints {
                do {
                    let body: [String: Any] = action == "loadCodeAssist" ? ["metadata": ["ideType": "ANTIGRAVITY"]] : [:]
                    let response = try await json(AntigravityCore.apiRequest(action: action, token: access, body: body, endpoint: endpoint), stage: .project)
                    try checkEpoch(expected)
                    if let project = AntigravityCore.project(from: response) { return project }
                    break // A valid empty response moves on to the project-list method.
                } catch {
                    try checkEpoch(expected)
                    if !canProbeAnotherEndpoint(error) { return nil }
                }
            }
        }
        return nil
    }
    private func credentials(host: any HostServices) async throws -> AntigravityCredentials {
        guard let stored = AntigravityCredentials.decode(host.loadSecret(key: AntigravityCore.secretKey)) else { throw AntigravityError.notLoggedIn }
        guard stored.expiresAt.timeIntervalSinceNow < 60 else { return stored }
        if let refreshTask { return try await refreshTask.value }
        let expected = epoch
        let task = Task { () throws -> AntigravityCredentials in
            let response = try await self.json(AntigravityCore.refreshRequest(stored.refreshToken), stage: .refresh)
            guard let access = response["access_token"] as? String, !access.isEmpty,
                  let seconds = response["expires_in"] as? Double, seconds.isFinite, seconds > 0 else { throw AntigravityError.invalidResponse }
            try self.checkEpoch(expected)
            guard var updated = AntigravityCredentials.decode(host.loadSecret(key: AntigravityCore.secretKey)) else { throw AntigravityError.notLoggedIn }
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
    private func routedCredentials(host: any HostServices) async throws -> AntigravityCredentials {
        let expected = epoch
        let stored = try await credentials(host: host)
        try checkEpoch(expected)
        if !stored.projectID.isEmpty && stored.projectIsFallback != true { return stored } // Preserve pre-0.4.0 managed projects.
        if projectCheckedUntil > Date() { return stored }
        let task: Task<String?, any Error>
        if let projectTask { task = projectTask }
        else {
            task = Task { try await self.discoverProject(access: stored.accessToken) }
            projectTask = task
        }
        defer { if expected == epoch { projectTask = nil } }
        let project = try await task.value
        try checkEpoch(expected)
        // Reload after awaits so a concurrent refresh cannot be overwritten with
        // old tokens. Epoch validation prevents an old login resurrecting logout.
        guard var current = AntigravityCredentials.decode(host.loadSecret(key: AntigravityCore.secretKey)) else { throw AntigravityError.notLoggedIn }
        if let project { current.projectID = project; current.projectIsFallback = false }
        else if current.projectID.isEmpty {
            current.projectID = AntigravityCore.stableProjectID(seed: current.email ?? AntigravityCore.challenge(current.refreshToken))
            current.projectIsFallback = true
        }
        try host.storeSecret(key: AntigravityCore.secretKey, value: current.encoded())
        projectCheckedUntil = Date().addingTimeInterval(1800)
        return current
    }
    func models(host: any HostServices) async throws -> [AntigravityModel] {
        guard !loginRunning else { throw AntigravityError.busy }
        let expected = epoch
        let credentials = try await routedCredentials(host: host)
        try checkEpoch(expected)
        var catalogs: [[AntigravityModel]] = [], lastError: (any Error)?
        for endpoint in AntigravityCore.endpoints {
            do {
                let response = try await json(AntigravityCore.apiRequest(action: "fetchAvailableModels", token: credentials.accessToken, body: ["project": credentials.projectID], endpoint: endpoint), stage: .models)
                try checkEpoch(expected)
                catalogs.append(try AntigravityCatalog.parse(response, endpoint: endpoint))
            } catch {
                try checkEpoch(expected)
                lastError = error
                if !canProbeAnotherEndpoint(error) { throw error }
            }
        }
        let models = AntigravityCatalog.merge(catalogs)
        guard !models.isEmpty else { throw lastError ?? AntigravityError.noModels }
        return models
    }
    func generate(host: any HostServices, model: String, system: String, text: String,
                  thinking: AntigravityThinking = .auto) async throws -> String {
        guard !loginRunning else { throw AntigravityError.busy }
        let expected = epoch
        let credentials = try await routedCredentials(host: host)
        try checkEpoch(expected)
        let catalog = (host.userDefault(forKey: AntigravityCore.catalogKey) as? Data).flatMap { try? JSONDecoder().decode([AntigravityModel].self, from: $0) } ?? []
        let selected = catalog.first { $0.id == model }
        let effectiveThinking = selected.map { $0.efforts.contains(thinking) ? thinking : .auto } ?? thinking
        let runtime = selected?.route(effectiveThinking) ?? catalog.compactMap { item in
            (item.runtime?.id == model ? item.runtime : nil) ?? item.variants?.values.first(where: { $0.id == model })
        }.first ?? AntigravityRuntime(id: model)
        let body = AntigravityCore.generationBody(project: credentials.projectID, model: runtime.id, system: system, text: text,
            thinking: effectiveThinking, modelEnum: runtime.modelEnum)
        let request = try AntigravityCore.apiRequest(action: "streamGenerateContent", token: credentials.accessToken, body: body, endpoint: runtime.endpoint ?? AntigravityCore.endpoint)
        let response = try await data(request, stage: .generate)
        try checkEpoch(expected)
        return try AntigravityCore.streamText(response)
    }
}
