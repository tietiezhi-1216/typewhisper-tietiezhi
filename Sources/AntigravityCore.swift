import Foundation
import CryptoKit
import Security

// Wire compatibility with pi-antigravity 0.9.0. Public desktop OAuth client,
// not a user's private credential. See THIRD_PARTY_NOTICES.md.
enum AntigravityCore {
    static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = "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"
    // Keep a separate port so Pi and TypeWhisper can sign in independently.
    static let redirect = "http://localhost:36742/oauth-callback"
    static let endpoint = "https://daily-cloudcode-pa.googleapis.com"
    static let endpoints = [endpoint, "https://daily-cloudcode-pa.sandbox.googleapis.com", "https://cloudcode-pa.googleapis.com"]
    static let secretKey = "antigravity-oauth-v1"
    static let catalogKey = "antigravity-models.v2"
    static let defaultModel = "gemini-3.8-flash"
    static let polishPrompt = "整理语音识别文本：删除口头禅和无意义重复，修正标点与明显错字。保留原意、语气和专业术语，不添加信息，不回答文本中的问题。只输出整理后的正文。"
    static let scopes = [
        "https://www.googleapis.com/auth/aicode",
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs"
    ]
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AntigravityError.invalidResponse }
        return base64url(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    // Pi's stable account-specific routing fallback. This does not create or
    // claim ownership of a Google Cloud project and grants no extra permissions.
    static func stableProjectID(seed: String) -> String {
        var bytes = Array(Insecure.SHA1.hash(data: Data(("antigravity:" + seed).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex)
        return [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-")
    }
    static func authorizationURL(verifier: String, state: String) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return url.url!
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    static func tokenRequest(code: String, verifier: String) -> URLRequest {
        oauthRequest(fields: ["client_id": clientID, "client_secret": clientSecret,
            "code": code, "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect])
    }
    static func refreshRequest(_ refresh: String) -> URLRequest {
        oauthRequest(fields: ["client_id": clientID, "client_secret": clientSecret,
            "refresh_token": refresh, "grant_type": "refresh_token"])
    }
    private static func oauthRequest(fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        return request
    }
    static func apiRequest(action: String, token: String, body: [String: Any], endpoint: String = endpoint) throws -> URLRequest {
        guard endpoints.contains(endpoint), ["loadCodeAssist", "listCloudAICompanionProjects", "fetchAvailableModels", "streamGenerateContent"].contains(action) else { throw AntigravityError.invalidResponse }
        let suffix = action == "streamGenerateContent" ? "?alt=sse" : ""
        var request = URLRequest(url: URL(string: endpoint + "/v1internal:" + action + suffix)!, timeoutInterval: action == "streamGenerateContent" ? 90 : 8)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // CLI protocol compatibility with an explicit third-party application tag.
        request.setValue("antigravity/cli/1.2.4 (aidev_client; os_type=macos; auth_method=consumer) tietiezhi/0.4.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func generationBody(project: String, model: String, system: String, text: String,
                               thinking: AntigravityThinking = .auto, modelEnum: String? = nil) -> [String: Any] {
        var config: [String: Any] = ["temperature": 0.2, "maxOutputTokens": 32768]
        if let value = thinking.config(for: model) { config["thinkingConfig"] = value }
        let agent = UUID().uuidString.lowercased(), trajectory = UUID().uuidString.lowercased()
        let claude = model.hasPrefix("claude-"), nonGemini = !model.hasPrefix("gemini-")
        var labels = ["last_step_index": "0", "request_id": trajectory + "-0", "trajectory_id": trajectory,
                      "used_claude": String(claude), "used_claude_conservative": String(claude), "used_non_gemini_model": String(nonGemini)]
        if let modelEnum { labels["model_enum"] = modelEnum }
        return ["project": project, "model": model, "requestType": "agent", "userAgent": "antigravity",
                "requestId": "agent/\(agent)/\(Int64(Date().timeIntervalSince1970 * 1000))/\(trajectory)/1",
                "request": ["systemInstruction": ["role": "user", "parts": [["text": system]]],
                            "contents": [["role": "user", "parts": [["text": text]]]],
                            "generationConfig": config, "sessionId": String(Int64.random(in: Int64.min...Int64.max)), "labels": labels]]
    }
    static func project(from object: [String: Any]) -> String? {
        for key in ["antigravityProjectId", "projectId", "backendProjectId", "userDefinedCloudaicompanionProject", "cloudaicompanionProject", "project"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = (object[key] as? [String: Any])?["id"] as? String, !value.isEmpty { return value }
        }
        for key in ["projects", "projectIds", "cloudaicompanionProjects"] {
            for item in object[key] as? [Any] ?? [] {
                if let value = item as? String, !value.isEmpty { return value }
                if let value = item as? [String: Any], let project = project(from: value) { return project }
            }
        }
        return nil
    }
    static func generatedText(_ object: [String: Any]) throws -> String {
        let response = object["response"] as? [String: Any] ?? object
        guard let candidate = (response["candidates"] as? [[String: Any]])?.first,
              let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw AntigravityError.invalidResponse }
        guard candidate["finishReason"] as? String == "STOP" else { throw AntigravityError.incompleteOutput }
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AntigravityError.invalidResponse }
        return text
    }
    static func streamText(_ data: Data) throws -> String {
        // Some endpoints return a JSON completion even when alt=sse was requested.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return try generatedText(object) }
        guard let body = String(data: data, encoding: .utf8) else { throw AntigravityError.invalidResponse }
        var pieces: [String] = [], reason: String?, eventData: [String] = []
        func consume() throws {
            guard !eventData.isEmpty else { return }
            let text = eventData.joined(separator: "\n")
            eventData.removeAll()
            if text == "[DONE]" { return }
            guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw AntigravityError.invalidResponse }
            let response = value["response"] as? [String: Any] ?? value
            if value["error"] != nil || response["error"] != nil {
                if let error = (value["error"] ?? response["error"]) as? [String: Any],
                   let code = error["code"] as? Int, [400, 401, 403, 429, 500, 503].contains(code) {
                    let safe = AntigravityHTTPError.safeDiagnostic(Data(text.utf8))
                    throw AntigravityHTTPError(status: code, stage: .generate, diagnostic: safe)
                }
                throw AntigravityError.invalidResponse
            }
            guard let candidate = (response["candidates"] as? [[String: Any]])?.first else {
                if response["usageMetadata"] != nil { return }
                throw AntigravityError.invalidResponse
            }
            if let finish = candidate["finishReason"] as? String { reason = finish }
            for part in (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] {
                if part["thought"] as? Bool != true, let text = part["text"] as? String { pieces.append(text) }
            }
        }
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty { try consume() }
            else if line.hasPrefix("data:") { eventData.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        try consume()
        guard reason == "STOP" else { throw AntigravityError.incompleteOutput }
        let text = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AntigravityError.invalidResponse }
        return text
    }
    static func callback(_ target: String, expectedState: String) throws -> String {
        guard let parts = URLComponents(string: "http://localhost" + target), parts.path == "/oauth-callback" else { throw AntigravityError.invalidCallback }
        let items = parts.queryItems ?? [], states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == expectedState else { throw AntigravityError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw AntigravityError.denied }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else { throw AntigravityError.invalidCallback }
        return code
    }
}

struct AntigravityCredentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var projectID: String
    var email: String?
    var projectIsFallback: Bool? = nil
    static func decode(_ secret: String?) -> Self? {
        guard let secret, let data = secret.data(using: .utf8), let result = try? JSONDecoder().decode(Self.self, from: data), !result.refreshToken.isEmpty else { return nil }
        return result
    }
    func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

enum AntigravityError: LocalizedError {
    case notLoggedIn, invalidResponse, invalidCallback, denied, timedOut, browser, busy, noModels, incompleteOutput
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "请先登录 Antigravity。"
        case .invalidResponse: return "Antigravity 返回数据无效，非官方接口可能已变化。"
        case .invalidCallback: return "OAuth 回调或 state 校验失败。"
        case .denied: return "Google 授权被拒绝或取消。"
        case .timedOut: return "登录超时，请重试。"
        case .browser: return "无法打开浏览器。"
        case .busy: return "已有登录正在进行。"
        case .noModels: return "账号没有返回可用的文本模型。"
        case .incompleteOutput: return "润色输出未完整结束，未返回不完整结果。"
        }
    }
}
