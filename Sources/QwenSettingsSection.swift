import SwiftUI

struct QwenSettingsSection: View {
    let engine: QwenASREngine
    @State private var key = ""
    @State private var model = QwenCore.defaultModel
    @State private var region = QwenRegion.beijing
    @State private var status = ""
    @State private var failed = false
    var body: some View {
        Section("千问 ASR（阿里云百炼）") {
            SecureField("百炼 API Key", text: $key)
            HStack {
                Button("保存") { save(key) }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("清除", role: .destructive) { save("") }
            }
            Text(status.isEmpty ? (engine.isConfigured ? "已配置（10 个云端 ASR 模型共用此 Key）" : "未配置") : status)
                .font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
            Picker("模型", selection: Binding(get: { model }, set: { model = $0; engine.selectModel($0) })) {
                ForEach(QwenCore.models) { Text($0.name).tag($0.id) }
            }
            Text(model).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Picker("API Key 所属地域", selection: Binding(get: { region }, set: { region = $0; engine.saveRegion($0) })) {
                ForEach(QwenRegion.allCases, id: \.rawValue) { Text($0.name).tag($0) }
            }
            Text("保存后，在 TypeWhisper 的识别引擎中选择「千问 ASR（百炼）」。模型可用性和费用以你的百炼账户为准，不会自动切换模型或重试付费请求。")
                .font(.caption).foregroundStyle(.secondary)
            if let selected = try? QwenCore.model(model) {
                if selected.wire == .file || selected.wire == .qwenFile {
                    Text("Filetrans 会自动将录音上传至阿里云临时 OSS，再提交任务并轮询；无需另配 OSS。临时文件按阿里云策略过期（通常 48 小时）。取消等待不保证取消云端任务或计费。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if selected.wire.live {
                    Text("支持录音时流式识别。若宿主使用录后转写路径，将按实时速率发送录音，避免过快投喂。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("同步模型超过 180 秒时分段处理，分段边界可能影响连续语句。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("仅转录；单次录音最长 30 分钟。开源本地权重和时间戳对齐器不属于 API Key 云端模型。")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { model = engine.selectedModelId ?? QwenCore.defaultModel; region = engine.region }
    }
    private func save(_ value: String) {
        do {
            try engine.saveKey(value)
            key = ""; failed = false; status = value.isEmpty ? "已清除" : "已保存"
        } catch { failed = true; status = error.localizedDescription }
    }
}
