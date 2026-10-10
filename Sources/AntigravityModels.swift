import Foundation

struct AntigravityRuntime: Codable, Sendable, Equatable {
    let id: String
    var endpoint: String? = nil
    var modelEnum: String? = nil
}

struct AntigravityModel: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    var variants: [String: AntigravityRuntime]? = nil
    var runtime: AntigravityRuntime? = nil
    var supportsThinking: Bool? = nil

    var efforts: [AntigravityThinking] {
        guard supportsThinking != false else { return [.auto, .off] }
        if let variants, !variants.isEmpty {
            return [.auto, .off] + AntigravityThinking.allCases.filter { variants[$0.rawValue] != nil }
        }
        return AntigravityThinking.options(for: id)
    }
    func route(_ effort: AntigravityThinking) -> AntigravityRuntime {
        let preferred: [AntigravityThinking]
        switch effort {
        case .auto, .off: preferred = [.low, .minimal, .medium, .high, .xhigh]
        case .minimal: preferred = [.minimal, .low, .medium, .high]
        case .low: preferred = [.low, .minimal, .medium, .high]
        case .medium: preferred = [.medium, .low, .high, .minimal]
        case .high: preferred = [.high, .medium, .low, .minimal]
        case .xhigh: preferred = [.xhigh, .high, .medium, .low]
        }
        for level in preferred {
            if let value = variants?[level.rawValue] { return value }
        }
        return runtime ?? AntigravityRuntime(id: id)
    }
}

enum AntigravityThinking: String, CaseIterable, Sendable {
    case auto, off, minimal, low, medium, high, xhigh
    var title: String {
        switch self {
        case .auto: return "默认"
        case .off: return "关闭"
        case .minimal: return "最低"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "最高"
        }
    }
    static func options(for model: String) -> [Self] {
        if model.hasPrefix("claude-") { return [.auto, .off, .high] }
        if model.hasPrefix("gpt-oss-") { return [.auto, .off, .medium] }
        if model.contains("pro") { return [.auto, .off, .low, .high] }
        if model.hasPrefix("gemini-") { return [.auto, .off, .low, .medium, .high] }
        return [.auto, .off]
    }
    // Antigravity's CLI protocol uses integer budgets, not the public Gemini
    // API's thinkingLevel. Defaults match Pi's reasoning=off behavior.
    func config(for model: String) -> [String: Any]? {
        guard model.hasPrefix("gemini-") || model.hasPrefix("claude-") || model.hasPrefix("gpt-oss-") else { return nil }
        guard self != .auto && self != .off else { return ["thinkingBudget": 0, "includeThoughts": false] }
        let budget: Int
        if model.hasPrefix("claude-") { budget = 1024 }
        else if model.hasPrefix("gpt-oss-") { budget = 8192 }
        else if model.hasPrefix("gemini-3.5-flash") || model == "gemini-3-flash-agent" {
            budget = self == .high || self == .xhigh ? 10000 : self == .medium ? 4000 : 1000
        } else if model.hasPrefix("gemini-3.1-pro") || model == "gemini-pro-agent" {
            budget = self == .high || self == .xhigh ? 10001 : 1001
        } else { budget = self == .high || self == .xhigh ? -1 : self == .medium ? 4000 : 1000 }
        return ["thinkingBudget": budget, "includeThoughts": true]
    }
}

enum AntigravityCatalog {
    static func parse(_ object: [String: Any], endpoint: String = AntigravityCore.endpoint) throws -> [AntigravityModel] {
        let payload = object["response"] as? [String: Any] ?? object
        guard let map = payload["models"] as? [String: Any] else { throw AntigravityError.invalidResponse }
        var groups: [String: AntigravityModel] = [:]
        for (id, value) in map.sorted(by: { $0.key < $1.key }) {
            guard ["gemini-", "claude-", "gpt-oss-"].contains(where: id.hasPrefix),
                  !id.contains(where: \.isWhitespace),
                  !["image", "tts", "embedding", "live", "audio", "computer-use"].contains(where: id.lowercased().contains),
                  let info = value as? [String: Any], info["isInternal"] as? Bool != true else { continue }
            let display = info["displayName"] as? String ?? info["label"] as? String ?? info["modelName"] as? String ?? info["name"] as? String ?? id
            let (base, suffixLevel) = family(id)
            let isAlias = id == "gemini-3-flash-agent" || id == "gemini-pro-agent"
            let level = isAlias ? suffixLevel : displayLevel(display) ?? suffixLevel
            let name = display.replacingOccurrences(of: "\\s*\\(\\s*(?:extra\\s*low|extra\\s*high|minimal|low|medium|high|thinking)\\s*\\)\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
            var group = groups[base] ?? AntigravityModel(id: base, name: name)
            if let thinking = info["supportsThinking"] as? Bool { group.supportsThinking = (group.supportsThinking ?? false) || thinking }
            let runtime = AntigravityRuntime(id: id, endpoint: endpoint, modelEnum: info["model"] as? String)
            if let level {
                var variants = group.variants ?? [:]
                variants[level.rawValue] = runtime
                group.variants = variants
            } else { group.runtime = runtime }
            groups[base] = group
        }
        guard !groups.isEmpty else { throw AntigravityError.noModels }
        return groups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func merge(_ catalogs: [[AntigravityModel]]) -> [AntigravityModel] {
        var groups: [String: AntigravityModel] = [:]
        for catalog in catalogs {
            for model in catalog {
                guard var existing = groups[model.id] else { groups[model.id] = model; continue }
                // Preserve the primary endpoint's routing for duplicate runtime IDs.
                existing.variants = (existing.variants ?? [:]).merging(model.variants ?? [:]) { first, _ in first }
                existing.runtime = existing.runtime ?? model.runtime
                if let flag = model.supportsThinking { existing.supportsThinking = (existing.supportsThinking ?? false) || flag }
                groups[model.id] = existing
            }
        }
        return groups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func family(_ id: String) -> (String, AntigravityThinking?) {
        if id == "gemini-3-flash-agent" { return ("gemini-3.5-flash", .high) }
        if id == "gemini-pro-agent" { return ("gemini-3.1-pro", .high) }
        if id.hasSuffix("-tiered") { return (String(id.dropLast(7)), nil) }
        let suffixes: [(String, AntigravityThinking)] = [("extra-low", .low), ("extra-high", .xhigh), ("thinking", .high), ("minimal", .minimal), ("medium", .medium), ("high", .high), ("low", .low)]
        for (suffix, level) in suffixes where id.hasSuffix("-" + suffix) {
            return (String(id.dropLast(suffix.count + 1)), level)
        }
        return (id, nil)
    }
    private static func displayLevel(_ name: String) -> AntigravityThinking? {
        let labels: [(String, AntigravityThinking)] = [("extra low", .low), ("extra high", .xhigh), ("thinking", .high), ("minimal", .minimal), ("medium", .medium), ("high", .high), ("low", .low)]
        for (label, level) in labels {
            let pattern = "\\(\\s*" + label.replacingOccurrences(of: " ", with: "\\s*") + "\\s*\\)"
            if name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return level }
        }
        return nil
    }
}
