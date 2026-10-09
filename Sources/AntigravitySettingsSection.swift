import SwiftUI

struct AntigravitySettingsSection: View {
    let plugin: MiMoASRPlugin
    @State private var acceptedRisk = false
    @State private var loginTask: Task<Void, Never>?
    @State private var testTask: Task<Void, Never>?
    @State private var working = false
    @State private var testing = false
    @State private var status = ""
    @State private var failed = false
    @State private var signedIn = false
    @State private var model = AntigravityCore.defaultModel
    @State private var project = ""
    @State private var preview = ""

    var body: some View {
        Section("Antigravity OAuth 润色（非官方）") {
            Text("Google 条款禁止第三方调用 Antigravity，可能导致账号暂停或终止。授权可被拒绝，接口也可能随时失效。")
                .font(.caption).foregroundStyle(.orange)
            Text("使用社区公开的桌面 OAuth 客户端，授权页名称可能不是 TypeWhisper。会申请 Google Cloud 等权限，请仔细查看授权范围。")
                .font(.caption).foregroundStyle(.secondary)
            Link("查看 Google 条款", destination: URL(string: "https://antigravity.google/terms")!)
            Toggle("我理解风险，仍希望使用非官方接入", isOn: $acceptedRisk)
                .font(.caption)
            HStack {
                Button(signedIn ? "重新登录 Google" : "登录 Google / Antigravity") {
                    working = true; status = "请在浏览器中完成授权（3 分钟内）。"; failed = false
                    loginTask = Task { @MainActor in
                        defer { working = false; loginTask = nil }
                        do {
                            try plugin.saveAntigravityOptions(model: model, project: project)
                            try await plugin.loginAntigravity()
                            signedIn = plugin.isAvailable
                            status = "授权已保存。请点击测试润色，确认模型可调用。"
                        } catch is CancellationError { status = "登录已取消。" }
                        catch { failed = true; status = error.localizedDescription }
                    }
                }.disabled(!acceptedRisk || working || testing)
                if working {
                    ProgressView().controlSize(.small)
                    Button("取消") { loginTask?.cancel() }
                }
                if signedIn {
                    Button("本地退出", role: .destructive) {
                        loginTask?.cancel(); testTask?.cancel()
                        Task { @MainActor in
                            do {
                                try await plugin.logoutAntigravity()
                                signedIn = false; preview = ""; failed = false
                                status = "本插件的凭据已清除。远端授权需在 Google 账号页面撤销。"
                            } catch { failed = true; status = error.localizedDescription }
                        }
                    }.disabled(working || testing)
                }
            }
            if signedIn {
                Text("已授权：" + (plugin.antigravityEmail ?? "Google 账号"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            TextField("润色模型 ID", text: $model)
            Text("默认尝试 gemini-3-flash；模型是否可用以你的账号和测试结果为准。可以填写其他 Gemini 文本模型 ID。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("项目 ID（可选；优先自动发现）", text: $project)
            HStack {
                Button("保存模型 / 项目") {
                    do {
                        try plugin.saveAntigravityOptions(model: model, project: project)
                        failed = false; status = "模型和项目选项已保存。"
                    } catch { failed = true; status = error.localizedDescription }
                }.disabled(working || testing)
                Button("测试润色") {
                    testing = true; failed = false; status = "正在发送一段固定测试文本……"
                    testTask = Task { @MainActor in
                        defer { testing = false; testTask = nil }
                        do {
                            try plugin.saveAntigravityOptions(model: model, project: project)
                            preview = try await plugin.process(systemPrompt: AntigravityCore.polishPrompt,
                                userText: "嗯，那个，今天下午三点开会，今天下午三点开会，请大家准时参加。", model: model)
                            status = "测试成功。请在工作流里选择 Antigravity OAuth（非官方）进行润色。"
                        } catch is CancellationError { status = "测试已取消。" }
                        catch { failed = true; status = error.localizedDescription }
                    }
                }.disabled(!signedIn || !acceptedRisk || working || testing)
                if testing { ProgressView().controlSize(.small); Button("取消测试") { testTask?.cancel() } }
            }
            if !preview.isEmpty { Text(preview).font(.caption).textSelection(.enabled) }
            Link("管理 / 撤销 Google 授权", destination: URL(string: "https://myaccount.google.com/connections")!)
            Text("登录不代表模型已经可用。此插件不会自动开通项目、切换账号或绕过限制；凭据与 MiMo 密钥分别保存在钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
            Text("自动润色：设置 → 工作流，为听写添加文本整理流程，并选择此 LLM 提供商。仅登录不会自动改写所有听写。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            signedIn = plugin.isAvailable
            model = plugin.antigravityModel
            project = plugin.antigravityProject
        }
        .onDisappear { loginTask?.cancel(); testTask?.cancel() }
    }
}
