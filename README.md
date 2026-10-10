# tietiezhi

TypeWhisper 原生 macOS 插件：**MiMo ASR + Antigravity OAuth 润色**。

设置页只有 MiMo API Key、Antigravity 登录、模型与思考等级。登录后自动获取账号的文本模型列表，也可手动刷新。项目 ID 等放在折叠的“高级”里。

> Antigravity 是非官方接入，可能被拒绝或导致账号受限：[Google 条款](https://antigravity.google/terms)。登录不保证模型调用成功。

## 在其他 Mac 上安装

支持 **Apple Silicon 与 Intel、macOS 14+**。需要安装 **TypeWhisper 1.7.1+**，已验证版本为 1.7.1；后续宿主版本仍需兼容性验证。不是 Windows/iPhone 插件。

1. 登录 GitHub，打开本仓库的 **Releases**。
2. 下载 `tietiezhi-0.3.1-macos-universal.zip` 并解压。
3. 在终端进入解压后的目录，运行：

   ```sh
   bash install.command
   ```

   不需要 Xcode 或 Swift 编译工具。脚本检查宿主版本和签名，备份旧插件，安装新版。下载隔离标记仅在此插件范围内移除；这是本地开发签名，**未经 Apple 公证**，请先确认来源。
4. 完全退出并重新打开 TypeWhisper，在 **集成 → 我的插件** 启用 **tietiezhi**。
5. 保存 MiMo API Key；点击 Antigravity 登录并在浏览器授权。模型列表自动获取，选择模型和思考等级自动保存。
6. 默认听写引擎选择 **MiMo ASR**；自动润色在 **工作流**里选择 **Antigravity OAuth（非官方）**。

也可通过 TypeWhisper 的“安装插件”选择解压后的 `tietiezhi.bundle`。升级旧版时推荐用脚本，避免同时保留两个同 ID 的 bundle。

**每台设备分别填写 Key、登录 Google。安装包与 GitHub 不包含用户密钥或 Token。**

## 位置与升级

- 安装位置：`~/Library/Application Support/TypeWhisper/Plugins/tietiezhi.bundle`
- 旧版备份：`~/Library/Application Support/TypeWhisper/PluginBackups/`
- 原 `MiMoASR.bundle` 安装时会迁移到备份，避免重复加载。
- 内部插件 ID 与提供商 ID 保持不变，原有 Key、Google 登录和工作流继续复用。

## 模型与思考等级

- 从 `fetchAvailableModels` 获取模型 ID 和名称，不伪造成功的模型列表。
- 展示支持的 Gemini/Claude 文本模型，过滤图片、语音、嵌入等模型。
- Gemini 3 使用 `thinkingLevel`；Gemini 2.5 / Claude thinking 使用 token budget。
- 具体选项按模型族提供；固定 high/low 的模型和不支持思考的模型只有“默认”。是否接受参数以 Google 后端为准。
- TypeWhisper 工作流也能单独指定思考等级，覆盖插件默认值。
- 可用模型和权限会变化，选择“默认”不会强制覆盖模型的思考设置。

## 安全与限制

凭据保存到 TypeWhisper 提供的系统钥匙串，不写入配置或日志。OAuth 使用 PKCE S256、随机 state、本机回调校验。取消/完成/超时后关闭本机监听端口。

使用社区公开桌面 OAuth 客户端，授权页名称可能不是 tietiezhi，权限包含 Google Cloud。首次点击登录会弹出简短风险确认。

“退出”只清除本插件的本地凭据；远端撤销在 **高级 → 撤销 Google 授权**。不轮换账号、端点或绕过 403/429，不创建自定义 Cloud 项目或开通付费套餐。首次登录若服务器明确提供默认免费套餐，可在登录确认后初始化托管免费项目，并有限轮询初始化结果。

MiMo 只负责转录，停止录音后出结果，不提供实时字幕/翻译；长录音每 180 秒分段，段落边界可能影响准确率。开启润色时，文本发送到 Google。插件不记录音频或文字，TypeWhisper 自身历史设置仍然适用。

## 故障

错误会区分换 Token、查询项目、获取模型和调用模型，并只展示白名单错误码/字段名。

- `invalid_grant`：重新发起登录，不要刷新旧回调页面。
- 缺少项目：留空项目 ID，重新登录并确认免费初始化。如果服务器没有提供可用的默认免费套餐，仍需在官方应用完成初始化，或填写自己有权限的真实 Google Cloud 项目 ID；不能填 `1`。
- 403：Google 拒绝访问；429：额度/频率受限，不自动绕过。
- 模型列表获取失败：保留已有缓存，仍可点击“刷新模型”重试。

不要公开截图里的浏览器回调地址、API Key 或 Token。

## 源码构建

```sh
git clone https://github.com/tietiezhi-1216/typewhisper-tietiezhi.git
cd typewhisper-tietiezhi
./build.sh
./test.sh
./package.sh
./install.sh
```

需要 Swift 6 命令行工具和 `/Applications/TypeWhisper.app`。
构建自动取得固定 v1.7.1 SDK 源码，只生成编译元数据，运行时链接宿主框架。
安装包是 arm64/x86_64 Universal，构建时校验两种架构的 SDK 导入符号。

测试包含实际 bundle 加载、ASR、OAuth/刷新/退出、HTTP 回调、模型列表解析、思考参数以及工作流协议。测试只用模拟数据与 localhost，不用真实账号调用云端。真实账号/接口变化需在本机验证。

## 许可与参考

GPL-3.0，第三方 OAuth 兼容常量的 MIT 声明见 `THIRD_PARTY_NOTICES.md`。

- [TypeWhisper SDK](https://github.com/TypeWhisper/typewhisper-mac/tree/v1.7.1/TypeWhisperPluginSDK)
- [MiMo ASR](https://mimo.mi.com/docs/en/asr/mimo-v2.5-asr)
- [Antigravity OAuth 协议参考](https://github.com/shekohex/opencode-google-antigravity-auth)
- [Google CLI 首次初始化协议参考](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/setup.ts)
