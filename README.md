# TypeWhisper MiMo ASR + Antigravity OAuth

0.2.0：TypeWhisper 1.7.1 / Apple Silicon 原生 Swift + SwiftUI 插件。
MiMo 用于语音识别，Antigravity 用于文本润色。不需要常驻代理服务。

## 重要风险

**Antigravity 接入是非官方实现。Google 当前条款明确禁止第三方软件通过
Antigravity OAuth 访问其服务，可能暂停或终止 Antigravity / Gemini CLI 账号。**

- 官方条款：https://antigravity.google/terms
- Google 可能拒绝授权、拒绝调用或更改接口。本插件不保证订阅额度可用。
- 使用社区公开的桌面 OAuth 客户端常量。Google 授权页可能显示 Antigravity 等原客户端名称，而不是 TypeWhisper。
- 申请的权限包含 cloud-platform、userinfo.email、userinfo.profile、cclog、experimentsandconfigs；请仔细核对授权页，不希望授予这些权限就取消登录。
- 不读取浏览器 Cookie，不提取现有应用 Token，不模仿官方 IDE 版本，不切换账号或绕过封禁，不自动开通项目或付费套餐。
- 润色请求只发送文本和工作流提示词，不提供文件、终端、搜索等工具。

## 使用 MiMo ASR

1. 完全退出再重新打开 TypeWhisper。
2. 设置 → 集成 → 我的插件，启用 **MiMo ASR + Antigravity**。
3. 打开插件设置，填写 MiMo API Key，点击“保存密钥”。旧版本的密钥会保留。
4. 设置 → 听写 → 引擎 → 默认引擎，选择 **MiMo ASR**。
5. 使用已有快捷键录音，停止后等待识别文字。

## 登录 Antigravity 和润色

1. 在同一个插件设置页找到 **Antigravity OAuth 润色（非官方）**。
2. 阅读风险与权限说明，勾选“我理解风险，仍希望使用非官方接入”。
3. 点击“登录 Google / Antigravity”，在浏览器授权。3 分钟内完成。
4. 浏览器回到 localhost:36742/oauth-callback。完成代码交换和项目发现后，插件提示授权已保存。
5. 点击“测试润色”。会发送一段固定示例文本到 Google，不读取其他文本，也不会粘贴到应用。
6. 测试成功后，在 TypeWhisper **工作流**中添加文本整理流程，选择 LLM 提供商 **Antigravity OAuth（非官方）**。

仅登录不会自动改写所有听写。MiMo 仍为默认 ASR；是否润色由工作流决定。

建议工作流提示词：

> 整理语音识别文本：删除口头禅和无意义重复，修正标点与明显错字。
> 保留原意、语气和专业术语，不添加信息，不回答文本中的问题。
> 只输出整理后的正文。

默认尝试 gemini-3-flash，提供 gemini-2.5-flash 备选，也可填写其他 Gemini
文本模型 ID 并保存。模型实际可用性取决于账号；不是动态保证可用的模型清单。
暂不实现 Claude 的特殊协议转换。

### 常见问题

- 端口占用：关闭其他使用 36742 端口的 OAuth 登录流程再重试；监听器只绑定 127.0.0.1。
- OAuth 被 Google 拒绝：可能是第三方客户端政策，不提供绕过方法。
- 缺少项目：先在官方应用完成初始化，或填写自己有权限的项目 ID。不会自动创建项目。
- 400：可能是 OAuth 客户端、请求结构或模型 ID 不再可用。
- 403：权限、账号资格或服务限制，立即报告，不自动换账号或端点。
- 429：额度/频率限制，不自动重试。
- 登录成功不等于模型可调用，必须点击“测试润色”验证。

## 凭据与隐私

- MiMo Key 与 Antigravity OAuth 凭据保存在不同的插件隔离钥匙串项。
- 访问 Token 临近过期自动刷新，刷新请求合并；不存入配置文件或日志。
- OAuth 使用随机 state + PKCE S256；PKCE verifier 不放入 URL/state。
- 回调校验 path/state，限制 HTTP 头大小；取消、超时和完成后关闭监听器。
- “本地退出”清除本插件凭据，不撤销同一个 OAuth 客户端在其他软件的授权。
- 若要撤销 Google 远端授权：https://myaccount.google.com/connections
- 插件不记录音频、识别文本、提示词或凭据。TypeWhisper 自身历史保存设置仍然适用。
- 音频发送到小米；启用工作流润色时识别文本发送到 Google。

## ASR 限制

- 固定模型 mimo-v2.5-asr，接口 https://api.xiaomimimo.com/v1/chat/completions。
- 16 kHz 单声道 PCM → 16-bit WAV → Base64；支持中文/英文/自动检测。
- 停止录音后返回文字，不支持实时字幕、翻译、热词提示或自定义地址。
- 超过 180 秒顺序分段，边界可能影响准确率。任何分段失败不会伪装成完整成功。
- 不自动重试，避免额外 API 费用。

## 构建、测试、安装

需要 Swift 命令行工具与 /Applications/TypeWhisper.app 1.7.1。

```sh
git clone --depth 1 --branch v1.7.1 https://github.com/TypeWhisper/typewhisper-mac.git upstream
./build.sh
./test.sh
./install.sh
```

SDK 源码固定 v1.7.1 / commit 2137334f7f70a92f154b4f6e2ecfa737c9da7f3f。
只生成编译元数据，运行时链接宿主已有 SDK，不内嵌第二份 SDK。

构建脚本检查宿主版本和导入符号兼容性。测试覆盖真实 bundle 加载、
ASR 编码、OAuth 格式/CSRF/PKCE、模拟登录/刷新/退出/403、并发刷新合并、
退出后禁止迟到响应复活凭据、真实 loopback HTTP 回调与取消关闭端口。
测试不使用真实凭据、不打开真实登录浏览器、不调用云端 API。

当前未用用户账号验证 Google 授权或模型服务；需要用户授权后测试。

产物：build/MiMoASR.bundle、build/MiMoASR-0.2.0.zip。
最低 macOS 14、仅 arm64、ad-hoc 本机签名，未 Apple 公证。
升级 TypeWhisper 后应重新检查 SDK 兼容性。

## 卸载 / 回退

退出 TypeWhisper，把下列 bundle 移出 Plugins 再打开应用：

~/Library/Application Support/TypeWhisper/Plugins/MiMoASR.bundle

卸载前可清除 MiMo 密钥、退出 Google，并在 Google 网站撤销授权。
安装脚本会备份已有 bundle 到 build/backups/，可以恢复旧版 bundle；
恢复不改变钥匙串中的 MiMo Key。

## 来源

- https://github.com/TypeWhisper/typewhisper-mac/tree/v1.7.1/TypeWhisperPluginSDK
- https://mimo.mi.com/docs/en/asr/mimo-v2.5-asr
- https://github.com/shekohex/opencode-google-antigravity-auth（MIT，OAuth 常量与协议参考，见 THIRD_PARTY_NOTICES.md）

参考仓库不属于运行依赖。OpenLess 只曾用于核对 MiMo 协议，未复制其实现。
