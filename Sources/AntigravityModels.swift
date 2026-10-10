import Foundation

struct AntigravityModel: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
}

enum AntigravityThinking: String, CaseIterable, Sendable {
    case auto, minimal, low, medium, high
    var title: String {
        switch self {
        case .auto: return "默认"
        case .minimal: return "最低"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
    static func options(for model: String) -> [Self] {
        let id = model.lowercased()
        // Some catalog IDs encode fixed effort; do not offer a misleading override.
        if id.hasSuffix("-high") || id.hasSuffix("-low") { return [.auto] }
        if id.contains("gemini-3") {
            return id.contains("flash") ? [.auto, .minimal, .low, .medium, .high] : [.auto, .low, .high]
        }
        if id.contains("gemini-2.5") || id.contains("claude") && id.contains("thinking") {
            return [.auto, .low, .medium, .high]
        }
        return [.auto]
    }
    func config(for model: String) -> [String: Any]? {
        guard self != .auto, Self.options(for: model).contains(self) else { return nil }
        if model.lowercased().contains("gemini-3") {
            return ["thinkingLevel": rawValue, "includeThoughts": false]
        }
        let budget: Int
        switch self {
        case .low: budget = 1024
        case .medium: budget = 4096
        case .high: budget = 8192
        default: return nil
        }
        return ["thinkingBudget": budget, "includeThoughts": false]
    }
}

enum AntigravityCatalog {
    static func parse(_ object: [String: Any]) throws -> [AntigravityModel] {
        let payload = object["response"] as? [String: Any] ?? object
        guard let map = payload["models"] as? [String: Any] else { throw AntigravityError.invalidResponse }
        // Only text-generating Gemini/Claude models are supported by this plugin.
        let models = map.compactMap { id, value -> AntigravityModel? in
            let normalized = id.lowercased()
            guard normalized.contains("gemini") || normalized.contains("claude"),
                  !["image", "tts", "embedding", "live", "audio", "computer-use"].contains(where: normalized.contains),
                  let details = value as? [String: Any] else { return nil }
            let name = details["displayName"] as? String ?? details["name"] as? String ?? id
            return AntigravityModel(id: id, name: name)
        }
        guard !models.isEmpty else { throw AntigravityError.noModels }
        return models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
