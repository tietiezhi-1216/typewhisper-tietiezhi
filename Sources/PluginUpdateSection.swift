import SwiftUI

struct PluginUpdateSection: View {
    let plugin: MiMoASRPlugin
    @State private var release: PluginRelease?
    @State private var busy = false
    @State private var status = ""
    @State private var failed = false
    @State private var restartRequired = false
    @State private var confirmInstall = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Section("插件更新") {
            HStack {
                Text("tietiezhi " + plugin.installedPluginVersion)
                Spacer()
                if let release {
                    Button("安装 " + release.version) { confirmInstall = true }
                } else {
                    Button("检查更新") {
                        run {
                            release = try await plugin.updater.check(current: plugin.installedPluginVersion)
                            status = release == nil ? "已是最新版本" : "发现新版本 " + release!.version
                        }
                    }
                }
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy || restartRequired)
            if busy { Button("取消") { task?.cancel() } }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
            }
            Link("GitHub 发布页", destination: PluginRelease.page).font(.caption)
        }
        .alert("安装插件更新？", isPresented: $confirmInstall) {
            Button("取消", role: .cancel) {}
            Button("下载并安装") {
                guard let release else { return }
                run {
                    status = "正在下载、校验并安装…"
                    try await plugin.updater.install(release, currentBundle: plugin.installedPluginBundle.bundleURL,
                        hostVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    restartRequired = true
                    status = "更新已安装，旧版已备份。请完全退出并重开 TypeWhisper。"
                }
            }
        } message: {
            Text("从本项目 GitHub 下载并校验安装包，备份旧版后替换。保留 Key、登录和工作流；重启后生效。安装包采用本地开发签名，未经 Apple 公证。")
        }
        .onDisappear { task?.cancel() }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failed = false; status = ""
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do { try await operation() }
            catch is CancellationError { status = "已取消" }
            catch { failed = true; status = error.localizedDescription }
        }
    }
}
