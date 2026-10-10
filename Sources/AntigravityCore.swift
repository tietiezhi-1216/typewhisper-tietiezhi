import Foundation
import CryptoKit
import Security

// Compatibility constants from the MIT-licensed opencode-google-antigravity-auth.
// This is a public desktop OAuth client, not a private server credential.
enum AntigravityCore {
    static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = "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"
    static let redirect = "http://localhost:36742/oauth-callback"
    static let endpoint = "https://daily-cloudcode-pa.sandbox.googleapis.com"
    static let secretKey = "antigravity-oauth-v1"
    static let defaultModel = "gemini-3-flash"
    static let polishPrompt = "整理语音识别文本：删除口头禅和无意义重复，修正标点与明显错字。保留原意、语气和专业术语，不添加信息，不回答文本中的问题。只输出整理后的正文。"
    static let scopes = [
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
    static func apiRequest(action: String, token: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: endpoint + "/v1internal:" + action)!, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Identify the actual third-party client; do not spoof an IDE version.
        request.setValue("tietiezhi/0.3.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func generationBody(project: String, model: String, system: String, text: String,
                               thinking: AntigravityThinking = .auto) -> [String: Any] {
        var config: [String: Any] = ["temperature": 0.2, "maxOutputTokens": 16384]
        if let value = thinking.config(for: model) { config["thinkingConfig"] = value }
        return ["project": project, "model": model, "userAgent": "antigravity", "requestId": UUID().uuidString,
         "request": ["systemInstruction": ["parts": [["text": system]]],
                     "contents": [["role": "user", "parts": [["text": text]]]],
                     "generationConfig": config]]
    }
    static func validProjectOverride(_ value: String) -> Bool {
        value.isEmpty || value.range(of: "^[a-z][a-z0-9-]{4,28}[a-z0-9]$", options: .regularExpression) != nil
    }
    static func freeOnboardingTier(_ object: [String: Any]) -> String? {
        if let paid = object["paidTier"] as? [String: Any], let id = paid["id"] as? String, !id.isEmpty { return nil }
        if let current = object["currentTier"] as? [String: Any], let id = current["id"] as? String, !id.isEmpty, id != "free-tier" { return nil }
        let ineligible = object["ineligibleTiers"] as? [[String: Any]] ?? []
        if ineligible.contains(where: { ($0["tierId"] ?? $0["id"]) as? String == "free-tier" }) { return nil }
        let tiers = object["allowedTiers"] as? [[String: Any]] ?? []
        return tiers.first(where: {
            $0["id"] as? String == "free-tier" && $0["isDefault"] as? Bool == true &&
                $0["userDefinedCloudaicompanionProject"] as? Bool != true
        })?["id"] as? String
    }
    static func operationRequest(name: String, token: String) throws -> URLRequest {
        // The server supplies a path, never a host. Reject arbitrary URLs/path traversal.
        guard name.range(of: "^operations/[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              !name.contains("..") else { throw AntigravityError.invalidResponse }
        var request = URLRequest(url: URL(string: endpoint + "/v1internal/" + name)!, timeoutInterval: 15)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("tietiezhi/0.3.1", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func project(from object: [String: Any]) -> String? {
        if let value = object["cloudaicompanionProject"] as? String, !value.isEmpty { return value }
        if let value = (object["cloudaicompanionProject"] as? [String: Any])?["id"] as? String, !value.isEmpty { return value }
        return nil
    }
    static func generatedText(_ object: [String: Any]) throws -> String {
        let response = object["response"] as? [String: Any] ?? object
        guard let candidate = (response["candidates"] as? [[String: Any]])?.first,
              let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw AntigravityError.invalidResponse }
        if let reason = candidate["finishReason"] as? String, reason != "STOP" { throw AntigravityError.incompleteOutput }
        let texts = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }
        let text = texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AntigravityError.invalidResponse }
        return text
    }
    // Never put the verifier in OAuth state. A separate random nonce prevents CSRF.
    static func callback(_ target: String, expectedState: String) throws -> String {
        guard let parts = URLComponents(string: "http://localhost" + target),
              parts.path == "/oauth-callback" else { throw AntigravityError.invalidCallback }
        let items = parts.queryItems ?? []
        let states = items.filter { $0.name == "state" }
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
    static func decode(_ secret: String?) -> Self? {
        guard let secret, let data = secret.data(using: .utf8), let result = try? JSONDecoder().decode(Self.self, from: data), !result.refreshToken.isEmpty else { return nil }
        return result
    }
    func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

enum AntigravityError: LocalizedError {
    case notLoggedIn, invalidResponse, invalidCallback, denied, timedOut, browser, noProject, invalidProject, onboardingTimedOut, noModels, busy, incompleteOutput
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "请先在插件设置中登录 Antigravity。"
        case .invalidResponse: return "Antigravity 返回的数据无效，非官方接口可能已变化。"
        case .invalidCallback: return "OAuth 回调地址或 state 校验失败。"
        case .denied: return "Google 授权被拒绝或取消。"
        case .timedOut: return "登录超时，请重新点击登录。"
        case .browser: return "无法打开浏览器。"
        case .noProject: return "账号未返回项目，也未提供可初始化的免费套餐。请先在官方应用完成初始化，或填写自己有权限的 Google Cloud 项目 ID。"
        case .invalidProject: return "项目 ID 格式无效，不能随便填 1。请留空自动获取，或填写真实的 Google Cloud 项目 ID。"
        case .onboardingTimedOut: return "免费项目初始化尚未完成，请稍后重新登录。"
        case .noModels: return "账号没有返回可用的文本模型。"
        case .busy: return "已有登录正在进行，请先取消。"
        case .incompleteOutput: return "润色输出被截断或拦截，未返回不完整结果。"
        case .http(400): return "OAuth 或模型请求被拒绝（HTTP 400），请重新登录或检查模型 ID。"
        case .http(401): return "授权已失效，请重新登录。"
        case .http(403): return "Google 拒绝访问（HTTP 403），可能是权限、资格或账号限制；不会自动绕过限制。"
        case .http(429): return "Antigravity 额度或频率受限，请稍后重试。"
        case .http(let status): return "Antigravity 请求失败（HTTP \(status)）。"
        }
    }
}
