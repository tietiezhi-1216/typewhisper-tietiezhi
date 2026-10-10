import SwiftUI

struct AntigravitySettingsSection: View {
    let plugin: MiMoASRPlugin
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var status = ""
    @State private var failed = false
    @State private var signedIn = false
    @State private var model = AntigravityCore.defaultModel
    @State private var models: [AntigravityModel] = []
    @State private var thinking = AntigravityThinking.auto
    @State private var confirmLogin = false

    var body: some View {
        Section("Antigravity") {
            HStack {
                Button(signedIn ? "重新登录" : "登录") { confirmLogin = true }
                if signedIn {
                    Button("退出") {
                        run {
                            try await plugin.logoutAntigravity()
                            signedIn = false
                            status = "已退出"
                        }
                    }
                    Button("刷新模型") { refresh() }
                    Button("测试") {
                        run {
                            let text = try await plugin.process(systemPrompt: AntigravityCore.polishPrompt,
                                userText: "嗯，今天下午三点开会，请大家准时参加。", model: model)
                            status = text
                        }
                    }
                }
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy)
            if busy { Button("取消") { task?.cancel() } }
            if signedIn {
                Picker("模型", selection: $model) {
                    if models.isEmpty {
                        Text("请刷新模型列表").tag(model)
                    } else {
                        ForEach(models) { item in Text(item.name).tag(item.id) }
                    }
                }.disabled(models.isEmpty || busy)
                Picker("思考等级", selection: $thinking) {
                    ForEach(plugin.thinkingOptions(for: model), id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }.disabled(busy || plugin.thinkingOptions(for: model).count < 2)
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            DisclosureGroup("高级") {
                Link("撤销 Google 授权", destination: URL(string: "https://myaccount.google.com/connections")!)
                Link("非官方接入 · 使用条款", destination: URL(string: "https://antigravity.google/terms")!)
            }
        }
        .alert("Antigravity 非官方接入", isPresented: $confirmLogin) {
            Button("取消", role: .cancel) {}
            Button("继续登录") {
                run {
                    try plugin.saveAntigravityOptions(model: model, thinking: thinking)
                    try await plugin.loginAntigravity()
                    status = "已登录，正在获取模型…"
                    signedIn = true
                    // Login and model discovery are distinct, so catalog failure
                    // must not make a successful login appear to have failed.
                    do {
                        try await plugin.refreshAntigravityModels()
                        reload()
                        status = ""
                    } catch is CancellationError { throw CancellationError() }
                    catch { failed = true; status = "已登录；" + error.localizedDescription }
                }
            }
        } message: {
            Text("非官方接入可能导致账号受限，授权包含 Google Cloud 权限。不会创建项目或开通付费套餐。是否继续？")
        }
        .onChange(of: model) { _, _ in
            if !plugin.thinkingOptions(for: model).contains(thinking) { thinking = .auto }
            save()
        }
        .onChange(of: thinking) { _, _ in save() }
        .onAppear {
            reload()
            if signedIn { refresh() }
        }
        .onDisappear { task?.cancel() }
    }

    private func reload() {
        signedIn = plugin.isAvailable
        models = plugin.antigravityModels
        model = plugin.antigravityModel
        thinking = plugin.antigravityThinking
    }
    private func save() {
        do { try plugin.saveAntigravityOptions(model: model, thinking: thinking) }
        catch { failed = true; status = error.localizedDescription }
    }
    private func refresh() {
        run {
            try await plugin.refreshAntigravityModels()
            reload()
            status = ""
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failed = false; status = ""
        task = Task { @MainActor in
            defer { busy = false; task = nil; signedIn = plugin.isAvailable }
            do { try await operation() }
            catch is CancellationError { status = "已取消" }
            catch { failed = true; status = error.localizedDescription }
        }
    }
}
