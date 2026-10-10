import Foundation

struct AppShortcut: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    var applicationID: String
    var applicationName: String
    var applicationPath: String?
    var enabled = false
    static let settingsKey = "app-shortcuts.v1"
    // Carbon modifier flags. Only actual combinations, never bare modifiers.
    static let command: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096
    static let allowedModifiers = command | shift | option | control
    var shortcutLabel: String {
        (modifiers & Self.control != 0 ? "⌃" : "") + (modifiers & Self.option != 0 ? "⌥" : "") +
        (modifiers & Self.shift != 0 ? "⇧" : "") + (modifiers & Self.command != 0 ? "⌘" : "") + keyLabel
    }
    static func validate(_ items: [Self]) throws {
        guard items.count <= 20, Set(items.map(\.id)).count == items.count else { throw AppShortcutError.invalid }
        var combinations = Set<String>()
        for item in items {
            guard item.keyCode < 128, item.modifiers & ~allowedModifiers == 0,
                  item.modifiers & (command | option | control) != 0,
                  ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(item.keyCode),
                  !item.keyLabel.isEmpty, item.keyLabel.count <= 24,
                  !item.applicationName.isEmpty, item.applicationName.count <= 200,
                  item.applicationID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{1,200}$", options: .regularExpression) != nil else { throw AppShortcutError.invalid }
            guard combinations.insert("\(item.keyCode):\(item.modifiers)").inserted else { throw AppShortcutError.duplicate }
        }
    }
}

enum AppShortcutError: LocalizedError {
    case invalid, duplicate, inactive, missingApplication
    var errorDescription: String? {
        switch self {
        case .invalid: return "快捷启动设置无效：请使用 Control、Option 或 Command 加一个按键，最多 20 条。"
        case .duplicate: return "这个组合键已在快捷启动列表中使用，请修改已有条目。"
        case .inactive: return "插件未启用，不能保存快捷启动设置。"
        case .missingApplication: return "找不到所选应用，请重新选择应用。"
        }
    }
}
