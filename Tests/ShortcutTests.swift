import AppKit
import Carbon
import TypeWhisperPluginSDK

extension Tests {
    @MainActor static func shortcutTests() throws {
        let binding = AppShortcut(keyCode: 79, modifiers: AppShortcut.control | AppShortcut.option | AppShortcut.shift | AppShortcut.command,
            keyLabel: "F18", applicationID: "com.example.ShortcutTest", applicationName: "Test", enabled: true)
        try AppShortcut.validate([binding])
        expect(binding.shortcutLabel == "⌃⌥⇧⌘F18", "Display saved modifier combination accurately")
        let encoded = try JSONEncoder().encode([binding])
        let decoded = try JSONDecoder().decode([AppShortcut].self, from: encoded)
        expect(decoded == [binding], "Persist complete shortcut/application configuration")
        var invalid = binding
        invalid.modifiers = AppShortcut.shift
        expectError("Reject Shift-only/bare-letter global shortcut") { try AppShortcut.validate([invalid]) }
        invalid = binding; invalid.keyCode = 59
        expectError("Reject modifier-only global shortcut") { try AppShortcut.validate([invalid]) }
        invalid = binding; invalid.modifiers |= 1
        expectError("Reject unsupported modifier bits") { try AppShortcut.validate([invalid]) }
        invalid = binding; invalid.applicationID = "https://evil.invalid"
        expectError("Application target is a bundle identifier, not shell command/URL") { try AppShortcut.validate([invalid]) }
        var duplicate = binding; duplicate.id = UUID()
        expectError("Reject duplicate configured shortcut") { try AppShortcut.validate([binding, duplicate]) }
        expectError("Bound configuration size") { try AppShortcut.validate(Array(repeating: binding, count: 21)) }

        let host = TestHost()
        host.setUserDefault(encoded, forKey: AppShortcut.settingsKey)
        var launched: [AppShortcut] = []
        let controller = AppShortcutController(launcher: { launched.append($0) })
        controller.attach(host: host, identity: UUID(), active: { true })
        expect(controller.registeredIDs.count == 1, "Actual Carbon global shortcut registration succeeds")
        let originalID = controller.registeredIDs[0]
        let status = try sendShortcutEvent(originalID)
        expect(status == noErr && launched == [binding], "Real Carbon hotkey event dispatches selected application only")

        let conflictHost = TestHost()
        conflictHost.setUserDefault(encoded, forKey: AppShortcut.settingsKey)
        let conflicting = AppShortcutController(launcher: { _ in fatalError("Conflict must not launch") })
        conflicting.attach(host: conflictHost, identity: UUID(), active: { true })
        expect(conflicting.registeredIDs.isEmpty && conflicting.states[binding.id]?.contains("占用") == true, "Exclusive registration reports conflict without silently taking over")
        conflicting.stop()

        controller.pauseForRecording(true)
        _ = try sendShortcutEvent(originalID)
        expect(controller.registeredIDs.isEmpty && launched.count == 1, "Recorder temporarily releases shortcut instead of launching target")
        controller.pauseForRecording(false)
        expect(controller.registeredIDs.count == 1 && controller.registeredIDs[0] != originalID, "Resume registration with fresh event identity")
        _ = try sendShortcutEvent(originalID)
        expect(launched.count == 1, "Stale queued event cannot trigger edited/resumed binding")
        _ = try sendShortcutEvent(controller.registeredIDs[0])
        expect(launched.count == 2, "Resumed binding handles its current event")
        controller.setEnabled(binding.id, false)
        expect(controller.registeredIDs.isEmpty, "Disabling a binding unregisters global shortcut")
        let stored = try JSONDecoder().decode([AppShortcut].self, from: host.userDefault(forKey: AppShortcut.settingsKey) as! Data)
        expect(stored.first?.enabled == false, "Disabled state persists via plugin-scoped host defaults")
        controller.setEnabled(binding.id, true)
        controller.stop()
        expect(controller.registeredIDs.isEmpty, "Plugin stop removes handler and shortcut registrations")
        let replacement = AppShortcutController(launcher: { _ in })
        replacement.attach(host: conflictHost, identity: UUID(), active: { true })
        expect(replacement.registeredIDs.count == 1, "Previously registered combination is reusable after cleanup")
        replacement.stop()
        var transient: AppShortcutController? = AppShortcutController(launcher: { _ in })
        transient?.attach(host: conflictHost, identity: UUID(), active: { true })
        weak var released = transient
        transient = nil
        expect(released == nil, "Carbon bridge does not retain destroyed plugin/controller")
        let afterDeinit = AppShortcutController(launcher: { _ in })
        afterDeinit.attach(host: conflictHost, identity: UUID(), active: { true })
        expect(afterDeinit.registeredIDs.count == 1, "RAII cleanup releases shortcut even without explicit stop")
        afterDeinit.stop()

        let inactive = AppShortcutController(launcher: { _ in fatalError("Inactive plugin must not launch") })
        inactive.attach(host: conflictHost, identity: UUID(), active: { false })
        expect(inactive.registeredIDs.isEmpty, "Inactive lifecycle cannot register shortcuts")
        inactive.test(binding)
        expect(inactive.message.contains("未启用"), "Inactive lifecycle refuses application launch")
        let freshHost = TestHost()
        let fresh = AppShortcutController()
        fresh.attach(host: freshHost, identity: UUID(), active: { true })
        expect(fresh.bindings.allSatisfy { !$0.enabled } && fresh.registeredIDs.isEmpty, "WeChat preset is disabled; no silent Ctrl+W takeover")
        fresh.stop()
    }
    @MainActor static func sendShortcutEvent(_ id: UInt32) throws -> OSStatus {
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr, let event else { throw AppShortcutError.invalid }
        defer { ReleaseEvent(event) }
        var identifier = EventHotKeyID(signature: AppShortcutController.signature, id: id)
        guard SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &identifier) == noErr else { throw AppShortcutError.invalid }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }
}
