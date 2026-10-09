# TypeWhisper MiMo ASR 原生插件

为 TypeWhisper 1.7.1 / Apple Silicon 编译的本地 Swift + SwiftUI 插件，无代理服务。

## 使用

1. 完全退出并重新打开 TypeWhisper（不是仅关闭设置窗口）。
2. 设置 → 集成 → 我的插件，启用 **MiMo ASR**。
3. 打开插件设置，填写小米 MiMo API Key，点击“保存密钥”。
4. 在应用模型选择处选择 **MiMo V2.5 ASR**。
5. 使用已有录音快捷键，停止录音后等待文字。

密钥使用 TypeWhisper 提供的插件隔离系统钥匙串接口保存，不存入配置文件，不回显。删除密钥请点击插件设置中的“清除密钥”。

## 能力与限制

- 固定请求地址：https://api.xiaomimimo.com/v1/chat/completions
- 固定模型：mimo-v2.5-asr
- 16 kHz 单声道 PCM → 16-bit WAV → Base64 音频消息。
- 语言选中文、英文时显式传 zh/en；其他选项或未选择时传 auto。
- 不支持实时字幕、翻译、词典热词提示或自定义地址。
- 180 秒分段、顺序请求，不自动重试，避免额外付费。
- 长录音在分段边界可能漏字或降低准确率。面向短听写。
- 任一分段失败时整个调用失败，不返回不完整的成功结果。
- 插件不记录音频、文字、密钥，也不写入自己的磁盘缓存；TypeWhisper 自身的历史保存政策仍然适用。
- **音频发送到小米云端，联网和 API 额度是必需的。**
- 使用本机 ad-hoc 签名，不是经过 Apple 公证的公开发行包。
- 目前只构建 arm64，最低 macOS 14，宿主版本升级后需要再次确认兼容性。

## 构建与测试

需要 Swift 命令行工具及 /Applications/TypeWhisper.app 1.7.1。
`upstream/` 为官方仓库 v1.7.1（commit 2137334f7f70a92f154b4f6e2ecfa737c9da7f3f），只用于生成 SDK 编译元数据，插件运行时使用宿主已有 SDK，不内嵌另一个 SDK。

```sh
git clone --depth 1 --branch v1.7.1 https://github.com/TypeWhisper/typewhisper-mac.git upstream
./build.sh
./test.sh
./install.sh
```

测试覆盖请求结构、WAV 编码、大小限制、返回解析、错误及分段拼接，另将实际 bundle 加载到测试进程并验证与已安装宿主 SDK 的协议转换、模型及 SwiftUI 设置。没有 API Key，尚未进行真实云端识别或宿主 UI 人工验证。

## 文件

- Sources/MiMoCore.swift：音频编码、MiMo API 格式和解析。
- Sources/MiMoASRPlugin.swift：TypeWhisper 插件、钥匙串设置 UI、网络调用。
- build/MiMoASR.bundle：编译产物。
- Tests/Tests.swift：无真实网络请求的测试。

## 卸载

退出 TypeWhisper，把下列目录移出 Plugins 文件夹，然后重新打开应用：

`~/Library/Application Support/TypeWhisper/Plugins/MiMoASR.bundle`

卸载前可在插件设置中清除密钥。

## 参考

- https://github.com/TypeWhisper/typewhisper-mac/tree/v1.7.1/TypeWhisperPluginSDK
- https://mimo.mi.com/docs/en/asr/mimo-v2.5-asr

OpenLess 仓库曾用于核对协议行为，不是本插件运行依赖，未复制其实现。
