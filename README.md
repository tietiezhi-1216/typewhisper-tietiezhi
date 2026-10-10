# tietiezhi

TypeWhisper 原生 macOS 插件：**MiMo / 千问 ASR + Antigravity OAuth 润色 + 组合键快捷启动**。

设置页包含 MiMo 与千问各自的 API Key、快捷启动、Antigravity 登录、模型与思考等级及更新按钮。登录后自动获取账号的文本模型列表，也可手动刷新。不需要手填项目 ID，不初始化 Cloud 项目。

> Antigravity 是非官方接入，可能被拒绝或导致账号受限：[Google 条款](https://antigravity.google/terms)。登录不保证模型调用成功。

## 在其他 Mac 上安装

支持 **Apple Silicon 与 Intel、macOS 14+**。需要安装 **TypeWhisper 1.7.1+**，已验证版本为 1.7.1；后续宿主版本仍需兼容性验证。不是 Windows/iPhone 插件。

1. 打开本仓库的 **Releases**（公开下载，无需 GitHub 登录）。
2. 下载 `tietiezhi-0.6.0-macos-universal.zip` 并解压。
3. 在终端进入解压后的目录，运行：

   ```sh
   bash install.command
   ```

   不需要 Xcode 或 Swift 编译工具。脚本检查宿主版本和签名，备份旧插件，安装新版。下载隔离标记仅在此插件范围内移除；这是本地开发签名，**未经 Apple 公证**，请先确认来源。
4. 完全退出并重新打开 TypeWhisper，在 **集成 → 我的插件** 启用 **tietiezhi**。
5. 按需保存 MiMo API Key 或百炼 API Key；不需要同时配置。需要 Google 润色时，再点击 Antigravity 登录并在浏览器授权，选择模型和思考等级。
6. 听写引擎选择 **MiMo ASR** 或 **千问 ASR（百炼）**；自动润色在 **工作流**里选择 **Antigravity OAuth（非官方）**。

也可通过 TypeWhisper 的“安装插件”选择解压后的 `tietiezhi.bundle`。升级旧版时推荐用脚本，避免同时保留两个同 ID 的 bundle。

**每台设备分别填写 Key、登录 Google。安装包与 GitHub 不包含用户密钥或 Token。**

## 千问 ASR

插件设置 → **千问 ASR（阿里云百炼）** → 输入并保存 API Key → 选择模型。然后在宿主的识别引擎中选择 **千问 ASR（百炼）**。默认北京；新加坡 Key 需切换所属地域，不必填写接口地址或 OSS 账号。

按官方文档核对的 10 个云端 ASR 主型号（模型名称是官方别名，可用性及价格以你的百炼账户为准）：

| 系列 | 已接入模型 ID |
| --- | --- |
| Qwen-Audio 3.1 | `qwen-audio-3.1-asr-flash`、`qwen-audio-3.1-asr-flash-message`、`qwen-audio-3.1-asr-flash-streaming`、`qwen-audio-3.1-asr-flash-filetrans` |
| Qwen-Audio 3.0 | `qwen-audio-3.0-asr-flash`、`qwen-audio-3.0-asr-flash-streaming`、`qwen-audio-3.0-asr-flash-filetrans` |
| Qwen3 ASR | `qwen3-asr-flash`、`qwen3-asr-flash-realtime`、`qwen3-asr-flash-filetrans` |

- 一个百炼 Key 共用全部型号，独立于 MiMo Key 和 Google 登录；模型/地域选择自动保存。列表不是账号权限探测，不保证每个型号都对你的账号开放。
- **Flash**：Qwen3 使用 OpenAI 兼容 HTTP；Qwen-Audio 3.x 使用 DashScope HTTP。超过 180 秒分段，分段边界可能降低连续语句准确率。
- **Streaming / Message / Realtime**：原生 WebSocket 与宿主实时录音协议。句子修订替换旧结果，最终结果须收到结束确认。Qwen3 使用 VAD 与 Base64 PCM；Qwen-Audio 使用双向任务协议与二进制 PCM。录后转写路径按实时速率发送，耗时会更长。
- **Filetrans**：使用百炼官方临时上传凭证自动上传录音，无需自备 OSS；然后异步提交、轮询、下载结果。Qwen3 使用 `file_url`，Qwen-Audio 使用 `file_urls`。录音临时存储按阿里云策略过期（通常 48 小时）；结果链接通常 24 小时有效。取消本地等待不保证取消云端任务或计费，生产级长文件服务建议自有稳定存储。
- 音频/文字不写入本插件日志；HTTP 不跟随重定向，API Key 仅发往所选百炼端点，不发送到 OSS。错误不展示原始服务端消息、签名 URL 或录音内容。
- 插件仅转录，单次录音最多 **30 分钟**（限制本地内存，低于部分 Filetrans 云端上限）；不自动切换模型、地域或重新提交付费任务。宿主自己的失败回退/历史保存逻辑仍然适用。
- 此处“全系列”指上述官方云端 ASR 主型号，不包括日期快照、未来新型号、通用 Audio/Omni 对话模型。`Qwen3-ASR-0.6B`、`1.7B` 是本地开源权重，ForcedAligner 是对齐器，不能只靠百炼 Key 接入，不列为云端模型。

官方协议：[非实时模型](https://help.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide)、[实时模型](https://help.aliyun.com/zh/model-studio/real-time-speech-recognition-user-guide)、[Qwen3 ASR](https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference)、[Qwen-Audio Flash](https://help.aliyun.com/zh/model-studio/fun-asr-flash-recorded-speech-recognition-http-api)、[Filetrans](https://help.aliyun.com/zh/model-studio/fun-asr-recorded-speech-recognition-http-api)、[Message](https://help.aliyun.com/zh/model-studio/qwen-asr-message-websocket-api)、[Streaming](https://help.aliyun.com/zh/model-studio/qwen-audio-asr-streaming-websocket-api)。

## 组合键快捷启动

打开插件设置的 **快捷启动** 区域。检测到已安装微信时，会出现默认关闭的 `⌃W → 微信`：打开启用开关后，按 **Control + W** 即可打开或切换到微信；这不是 Command + W。

- **测试**：打开所选应用，用于确认目标正常，不要求启用组合键。
- **编辑**：更换应用、录入新组合键并选择是否启用。
- **添加快捷启动**：选择 `.app` → 录入组合键 → 勾选启用 → 保存。最多 20 条。
- 录入时先暂时释放本插件的快捷启动组合键，Esc 可取消。必须包含 Control、Option 或 Command，不支持单独修饰键。
- 只在 TypeWhisper 运行且本插件启用时生效；停用插件或退出宿主会释放快捷键。配置自动保存，重启恢复已启用条目。
- 使用 Carbon 原生组合键注册和 LaunchServices，不捕获全部键盘输入、不发送模拟按键、不执行 shell 或大模型命令，不需要辅助功能权限，也不依赖 MiMo Key/Google 登录。
- 重复组合键会被拒绝；系统注册占用会显示失败。不保证识别所有软件通过事件监控实现的快捷键，请避开宿主工作流和第三方快捷键。启用 `⌃W` 会占用它原本的功能，建议按需要改为 `⌃⌥W`。

升级后必须通过菜单栏 **TypeWhisper → 退出** 再重开，不能只关设置窗口；旧动态库不会在运行过程中卸载换新。

## 插件内更新

打开插件设置底部的 **插件更新 → 检查更新 → 安装新版 → 下载并安装**。安装后完全退出并重开 TypeWhisper 生效，不热加载代码，也不会自动退出宿主。

只从本项目公开 GitHub Release 下载稳定版本，校验 SHA-256、ZIP 路径/体积/符号链接、插件 ID/版本、宿主和 macOS 兼容性、代码签名及 Universal 架构。旧版自动备份，失败时不覆盖旧版；不运行下载包里的脚本，不读写 Keychain 或用户偏好，不需要 Xcode。

SHA-256 用于下载完整性校验；安装包仍是 ad-hoc 签名、未经 Apple 公证，并非独立发布者数字签名。更新信任边界是本项目的 GitHub 发布账号及 HTTPS。首次安装仍使用安装脚本或宿主安装功能；装好 0.4.1 后后续可在插件内更新。

## 位置与升级

- 安装位置：`~/Library/Application Support/TypeWhisper/Plugins/tietiezhi.bundle`
- 旧版备份：`~/Library/Application Support/TypeWhisper/PluginBackups/`
- 原 `MiMoASR.bundle` 安装时会迁移到备份，避免重复加载。
- 内部插件 ID 与提供商 ID 保持不变，原有 Key、Google 登录和工作流不会删除。
- **升级 0.4.0 后请重新登录一次**：新增 Pi 使用的 `aicode` 授权范围，旧 Token 仅刷新不能补齐权限。
- 旧版手填项目偏好不再参与路由；旧的已发现项目仍保留。模型缓存采用新版本，打开设置重新获取。

## 模型与思考等级

- 从 `fetchAvailableModels` 获取模型 ID 和名称，不伪造成功的模型列表。
- 展示 Gemini / Claude / GPT-OSS 文本模型，过滤图片、语音、嵌入与内部模型。
- 合并三个固定 Cloud Code Assist 端点的目录；模型按族展示，保留实际运行 ID、来源端点和 `model_enum`。
- 思考档位会选中对应运行 ID，并使用 Pi 的 CLI `thinkingBudget`，不是公共 Gemini API 的 `thinkingLevel`。优先读取目录宣告的档位和能力。
- “默认”与“关闭”按 Pi 默认行为发送零思考预算，优先选择 low 运行档位。高级思考会消耗更多额度；原始思考文本不会插入润色结果。
- TypeWhisper 工作流也能单独指定思考等级，覆盖插件默认值。
- 可用模型和权限会变化，最终以 Google 后端为准。目录失败不会被伪装成成功，也不会回滚已完成的 OAuth。

## 安全与限制

凭据保存到 TypeWhisper 提供的系统钥匙串，不写入配置或日志。OAuth 使用 PKCE S256、随机 state、本机回调校验。取消/完成/超时后关闭本机监听端口。

使用社区公开桌面 OAuth 客户端，授权页名称可能不是 tietiezhi，权限包含 Google Cloud。首次点击登录会弹出简短风险确认。

“退出”只清除本插件的本地凭据和模型缓存；远端撤销在 **高级 → 撤销 Google 授权**。不轮换账号、不绕过权限或额度限制；生成遇到 401/403/429 不重试。不创建项目、初始化套餐或开通付费服务。

原生 Swift 实现参考本机 `pi-antigravity 0.9.0`，不运行 Pi、不读取 Pi/浏览器的登录凭据。HTTP 使用 CLI 协议兼容头并保留 `tietiezhi` 标记。只读项目和目录发现预先并行查询三个固定 Google 端点，每个来源仅查询一次、无失败重试；局部 403 不再丢弃其他来源已合法返回的模型。全部来源拒绝则明确报错；401/429 保留错误。生成只使用模型已发现的来源端点，不切换或自动重试。

授权成功独立保存；项目发现不是登录前提。先尝试 `loadCodeAssist` 和 `listCloudAICompanionProjects`，未返回项目时使用按账号生成的稳定 UUID 路由，与 Pi 的主要逻辑一致。UUID 不是真实 Cloud 项目、不会赋予额外权限，后端仍可能拒绝。资料读取失败时以本插件新取得的凭据摘要作为账号种子。生成使用 `streamGenerateContent?alt=sse`，只有完整 STOP 结果才交给宿主。

MiMo 只负责转录，停止录音后出结果，不提供实时字幕/翻译；长录音每 180 秒分段，段落边界可能影响准确率。开启润色时，文本发送到 Google。插件不记录音频或文字，TypeWhisper 自身历史设置仍然适用。

## 故障

错误会区分换 Token、查询项目、获取模型和调用模型，并只展示白名单错误码/字段名。

- `invalid_grant`：重新发起登录，不要刷新旧回调页面。
- 旧版“未找到项目”或填了 `1`：升级后重新登录；不再需要这个字段，也不会初始化免费项目。
- 403：错误会列出三个目录端点的状态和可用的白名单权限原因。若全部为 403，尝试重新登录以补齐授权；仍被拒绝需检查 Google 账号资格/权限，插件不伪造可用模型。429：额度/频率受限，不自动绕过。
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

测试包含实际 bundle 加载、独立 MiMo/千问引擎、千问全部型号的请求协议、模拟 OSS 上传/任务轮询与实时音频/修订/取消/完整结束、ASR、OAuth/刷新/退出、HTTP 回调、模型列表解析、思考参数、工作流协议、临时目录内的更新安装，以及真实 Carbon 注册/事件派发/冲突/释放。应用启动派发使用注入的测试目标，不打开真实应用或模拟键盘输入，不用真实账号调用 AI 云端；真实按键与应用窗口行为需在本机确认。

## 两个独立插件仓库

- 本仓库：TypeWhisper 原生 Swift 插件，提供 MiMo/千问 ASR、Antigravity 润色与更新按钮。
- [tietiezhi-paseo](https://github.com/tietiezhi-1216/tietiezhi-paseo)：Paseo 插件，独立安装、发布，不作为本插件的运行依赖。

## 许可与参考

GPL-3.0，第三方 OAuth 兼容常量的 MIT 声明见 `THIRD_PARTY_NOTICES.md`。

- [TypeWhisper SDK](https://github.com/TypeWhisper/typewhisper-mac/tree/v1.7.1/TypeWhisperPluginSDK)
- [MiMo ASR](https://mimo.mi.com/docs/en/asr/mimo-v2.5-asr)
- [Antigravity OAuth 协议参考](https://github.com/shekohex/opencode-google-antigravity-auth)
- [Pi Antigravity 0.9.0 协议参考](https://github.com/Rahularya01/pi-antigravity)
