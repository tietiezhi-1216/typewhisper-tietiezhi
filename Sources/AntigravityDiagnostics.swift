import Foundation

enum AntigravityRequestStage: String, Sendable {
    case exchange = "授权码换取 Token"
    case refresh = "刷新登录凭据"
    case project = "查询账号项目（loadCodeAssist）"
    case generate = "调用润色模型（generateContent）"
    case profile = "读取账号信息"
}

struct AntigravityHTTPError: LocalizedError, Sendable {
    let status: Int
    let stage: AntigravityRequestStage
    let diagnostic: String
    var errorDescription: String? {
        let explanation: String
        switch status {
        case 400: explanation = "请求参数被 Google 拒绝。"
        case 401: explanation = "登录凭据已失效，请重新登录。"
        case 403: explanation = "Google 拒绝访问，可能是权限、资格或账号限制。"
        case 429: explanation = "额度或频率受限，请稍后重试。"
        default: explanation = "Google 请求失败。"
        }
        return "\(stage.rawValue)失败（HTTP \(status)）。\(explanation)" + (diagnostic.isEmpty ? "" : "\n" + diagnostic)
    }
    // Only display fixed, allowlisted error codes and field names. Never show the
    // arbitrary response message, token exchange body or callback URL.
    static func safeDiagnostic(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let allowed = Set(["invalid_grant", "invalid_client", "invalid_request", "unauthorized_client", "unsupported_grant_type", "access_denied", "INVALID_ARGUMENT", "UNAUTHENTICATED", "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "NOT_FOUND", "FAILED_PRECONDITION", "INTERNAL", "UNAVAILABLE"])
        var pieces: [String] = []
        if let code = object["error"] as? String, allowed.contains(code) {
            pieces.append("Google 错误码：" + code)
            if code == "invalid_grant" { pieces.append("授权码可能已过期、被重复使用或 PKCE 校验不一致；请重新发起登录，不要刷新旧回调页面。") }
            if code == "invalid_client" { pieces.append("OAuth 桌面客户端被拒绝，可能是客户端凭据或 Google 政策已变化。") }
        }
        if let error = object["error"] as? [String: Any] {
            if let code = error["status"] as? String, allowed.contains(code) { pieces.append("Google 错误码：" + code) }
            let allowedFields = Set(["metadata", "metadata.plugin_type", "metadata.pluginType", "metadata.ide_type", "metadata.ideType", "metadata.platform", "cloudaicompanion_project", "cloudaicompanionProject", "model", "project", "request", "request.generation_config", "request.generationConfig"])
            for detail in error["details"] as? [[String: Any]] ?? [] {
                for violation in detail["fieldViolations"] as? [[String: Any]] ?? [] {
                    if let field = violation["field"] as? String, allowedFields.contains(field) { pieces.append("无效字段：" + field) }
                }
            }
        }
        return Array(Set(pieces)).sorted().joined(separator: "\n")
    }
}
