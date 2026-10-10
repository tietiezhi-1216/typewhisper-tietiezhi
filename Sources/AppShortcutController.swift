import AppKit
import Carbon
import Combine
import TypeWhisperPluginSDK

private final class ShortcutEventBridge: @unchecked Sendable {
    weak var owner: AppShortcutController?
    init(owner: AppShortcutController) { self.owner = owner }
}

// RAII also releases Carbon resources if the plugin instance is destroyed.
private final class ShortcutRegistrations {
    var handler: EventHandlerRef?
    var context: UnsafeMutableRawPointer?
    var keys: [EventHotKeyRef] = []
    func clear() {
        for key in keys { UnregisterEventHotKey(key) }
        keys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        if let context { Unmanaged<ShortcutEventBridge>.fromOpaque(context).release() }
        context = nil
    }
    deinit { clear() }
}

@MainActor final class AppShortcutController: ObservableObject {
    typealias Launcher = @MainActor (AppShortcut) -> Void
    @Published private(set) var bindings: [AppShortcut] = []
    @Published private(set) var states: [UUID: String] = [:]
    @Published var message = ""
    private var host: (any HostServices)?
    private var identity: UUID?
    private var active: @Sendable () -> Bool = { false }
    private var paused = false
    private var dispatchMap: [UInt32: AppShortcut] = [:]
    private let registrations = ShortcutRegistrations()
    private let launcher: Launcher?
    private static var nextID: UInt32 = 0
    static let signature: UInt32 = 0x54545a49 // TTZI

    init(launcher: Launcher? = nil) { self.launcher = launcher }
    func attach(host: any HostServices, identity: UUID, active: @escaping @Sendable () -> Bool) {
        guard self.identity != identity else { return }
        stop()
        self.host = host; self.identity = identity; self.active = active
        if let data = host.userDefault(forKey: AppShortcut.settingsKey) as? Data {
            do {
                let items = try JSONDecoder().decode([AppShortcut].self, from: data)
                try AppShortcut.validate(items)
                bindings = items
            } catch { bindings = []; message = "快捷启动配置无效，请重新配置。" }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.xinWeChat") {
            // Explicitly disabled: never silently steal a user's existing Ctrl+W.
            bindings = [AppShortcut(keyCode: 13, modifiers: AppShortcut.control, keyLabel: "W",
                applicationID: "com.tencent.xinWeChat", applicationName: "微信", applicationPath: url.path)]
        } else { bindings = [] }
        refreshRegistrations()
    }
    func stop() {
        registrations.clear(); dispatchMap.removeAll(); states.removeAll()
        host = nil; identity = nil; active = { false }; paused = false
    }
    func save(_ items: [AppShortcut]) throws {
        guard let host, active() else { throw AppShortcutError.inactive }
        try AppShortcut.validate(items)
        host.setUserDefault(try JSONEncoder().encode(items), forKey: AppShortcut.settingsKey)
        bindings = items; message = ""
        refreshRegistrations()
    }
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        var items = bindings
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].enabled = enabled
        do { try save(items) } catch { message = error.localizedDescription }
    }
    func remove(_ id: UUID) {
        do { try save(bindings.filter { $0.id != id }) } catch { message = error.localizedDescription }
    }
    func pauseForRecording(_ value: Bool) { paused = value; refreshRegistrations() }
    private func refreshRegistrations() {
        registrations.clear(); dispatchMap.removeAll(); states.removeAll()
        guard !paused, host != nil, active(), bindings.contains(where: \.enabled) else { return }
        let context = Unmanaged.passRetained(ShortcutEventBridge(owner: self)).toOpaque()
        registrations.context = context
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == AppShortcutController.signature else { return OSStatus(eventNotHandledErr) }
            let bridge = Unmanaged<ShortcutEventBridge>.fromOpaque(context).takeUnretainedValue()
            let id = identifier.id
            if Thread.isMainThread {
                return MainActor.assumeIsolated { bridge.owner?.dispatch(id) ?? OSStatus(eventNotHandledErr) }
            }
            Task { @MainActor in _ = bridge.owner?.dispatch(id) }
            return noErr
        }, 1, &event, context, &registrations.handler)
        guard status == noErr else {
            message = "无法注册快捷启动监听（\(status)）。"
            registrations.clear(); return
        }
        for item in bindings where item.enabled {
            Self.nextID &+= 1
            if Self.nextID == 0 { Self.nextID = 1 }
            let id = Self.nextID
            var key: EventHotKeyRef?
            let result = RegisterEventHotKey(item.keyCode, item.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &key)
            if result == noErr, let key {
                registrations.keys.append(key); dispatchMap[id] = item; states[item.id] = "已启用"
            } else { states[item.id] = "注册失败：可能已被系统或其他软件占用（\(result)）" }
        }
    }
    @discardableResult private func dispatch(_ id: UInt32) -> OSStatus {
        guard !paused, active(), let binding = dispatchMap[id] else { return OSStatus(eventNotHandledErr) }
        open(binding)
        return noErr
    }
    func test(_ binding: AppShortcut) {
        guard active() else { message = AppShortcutError.inactive.localizedDescription; return }
        open(binding)
    }
    private func open(_ binding: AppShortcut) {
        if let launcher { launcher(binding); return }
        // LaunchServices reuses a running instance and sends the normal reopen
        // request, which also lets apps restore a closed/minimized main window.
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.applicationID)
            ?? binding.applicationPath.map { URL(fileURLWithPath: $0) }
        guard let url = resolved, url.pathExtension.lowercased() == "app", Bundle(url: url)?.bundleIdentifier == binding.applicationID else {
            message = AppShortcutError.missingApplication.localizedDescription; return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.message = "无法打开 " + binding.applicationName + "，请检查应用是否正常安装。" }
        }
    }
    // Test-only observation: tests send a real Carbon event without synthesizing
    // keyboard input, requesting accessibility, or launching another application.
    var registeredIDs: [UInt32] { Array(dispatchMap.keys) }
}
