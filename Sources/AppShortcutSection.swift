import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppShortcutSection: View {
    @ObservedObject var controller: AppShortcutController
    @State private var editing: AppShortcut?
    @State private var showingEditor = false
    var body: some View {
        Section("快捷启动") {
            ForEach(controller.bindings) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Toggle("启用", isOn: Binding(get: { item.enabled }, set: { controller.setEnabled(item.id, $0) })).labelsHidden()
                        Text(item.shortcutLabel + " → " + item.applicationName).lineLimit(1)
                        Spacer()
                        Button("编辑") { editing = item; showingEditor = true }
                        Button("测试") { controller.test(item) }
                        Button("删除", role: .destructive) { controller.remove(item.id) }
                    }
                    Text(item.enabled ? (controller.states[item.id] ?? "暂停中") : "未启用")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("添加快捷启动") { editing = nil; showingEditor = true }
                .disabled(controller.bindings.count >= 20)
            Text("组合键可打开或切换到应用。启用后占用该组合键，请避开系统、工作流和其他软件的快捷键。仅在 TypeWhisper 运行且插件启用时生效。")
                .font(.caption).foregroundStyle(.secondary)
            if !controller.message.isEmpty { Text(controller.message).font(.caption).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showingEditor, onDismiss: { controller.pauseForRecording(false) }) {
            AppShortcutEditor(controller: controller, initial: editing)
        }
    }
}

private struct AppShortcutEditor: View {
    @ObservedObject var controller: AppShortcutController
    @Environment(\.dismiss) private var dismiss
    @State private var item: AppShortcut?
    @State private var recording = false
    @State private var hasShortcut = false
    @State private var error = ""
    private let initial: AppShortcut?
    init(controller: AppShortcutController, initial: AppShortcut?) {
        self.controller = controller; self.initial = initial
        _item = State(initialValue: initial); _hasShortcut = State(initialValue: initial != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(initial == nil ? "添加快捷启动" : "编辑快捷启动").font(.headline)
            HStack {
                Text(item?.applicationName ?? "未选择应用")
                Spacer()
                Button("选择应用…") { selectApplication() }.disabled(recording)
            }
            if recording {
                Text("请按组合键（如 Control + W）；Esc 取消")
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(ShortcutCaptureView { code, modifiers, label in
                        guard var value = item else { return }
                        value.keyCode = code; value.modifiers = modifiers; value.keyLabel = label
                        do {
                            try AppShortcut.validate([value])
                            item = value; hasShortcut = true; error = ""; endRecording()
                        } catch { self.error = error.localizedDescription }
                    } onCancel: { endRecording() })
            } else {
                HStack {
                    Text(hasShortcut ? item?.shortcutLabel ?? "" : "未设置快捷键")
                    Spacer()
                    Button("录入快捷键") {
                        recording = true; controller.pauseForRecording(true)
                    }.disabled(item == nil)
                }
            }
            if item != nil {
                Toggle("启用此快捷启动", isOn: Binding(get: { item?.enabled ?? false }, set: { item?.enabled = $0 }))
            }
            Text("使用 Control、Option 或 Command 加一个按键。不发送模拟键盘输入、不执行脚本，也不需要辅助功能权限。")
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { endRecording(); dismiss() }
                Button("保存") {
                    guard let item else { return }
                    var items = controller.bindings.filter { $0.id != item.id }
                    items.append(item)
                    do { endRecording(); try controller.save(items); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(!hasShortcut || item == nil || recording)
            }
        }.padding(20).frame(width: 440)
            .onDisappear { controller.pauseForRecording(false) }
    }
    private func endRecording() { recording = false; controller.pauseForRecording(false) }
    private func selectApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        if item == nil {
            item = AppShortcut(keyCode: 13, modifiers: AppShortcut.control, keyLabel: "W", applicationID: id, applicationName: name, applicationPath: url.path)
        } else { item?.applicationID = id; item?.applicationName = name; item?.applicationPath = url.path }
        error = ""
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: @MainActor (UInt32, UInt32, String) -> Void
    let onCancel: @MainActor () -> Void
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(); view.onCapture = onCapture; view.onCancel = onCancel; return view
    }
    func updateNSView(_ view: CaptureView, context: Context) { view.onCapture = onCapture; view.onCancel = onCancel }
    final class CaptureView: NSView {
        var onCapture: ((UInt32, UInt32, String) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) { capture(event) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            capture(event); return true
        }
        private func capture(_ event: NSEvent) {
            var modifiers: UInt32 = 0
            if event.modifierFlags.contains(.control) { modifiers |= AppShortcut.control }
            if event.modifierFlags.contains(.option) { modifiers |= AppShortcut.option }
            if event.modifierFlags.contains(.shift) { modifiers |= AppShortcut.shift }
            if event.modifierFlags.contains(.command) { modifiers |= AppShortcut.command }
            if event.keyCode == 53 && modifiers == 0 { onCancel?(); return }
            let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "⌫", 53: "Esc", 76: "Enter", 123: "←", 124: "→", 125: "↓", 126: "↑",
                122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
                105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
            let label = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            onCapture?(UInt32(event.keyCode), modifiers, label)
        }
    }
}
