# tietiezhi for TypeWhisper Windows — 0.1.3 Preview

Windows 原生托管插件，不需要运行 Pi、Python 或本地代理。Mac 版与 Windows 版源码同仓库，安装包互不通用。

## 功能

- MiMo V2.5 ASR：宿主录音 → WAV 上传 → 转录；长音频按 180 秒/大小限制分段。
- Antigravity OAuth：非阻塞分步登录、取消登录、可复制 Google 授权链接、跨设备粘贴 localhost 回调、PKCE/state 校验、自动刷新、退出登录。
- 登录后获取模型列表，选择模型和思考等级；保留各目录端点的运行路由。
- API Key 和 OAuth 凭据使用 TypeWhisper 的 Windows DPAPI 加密存储。
- 设置 UI 由 TypeWhisper 渲染；润色指令仍在宿主工作流配置。
- 独立操作接口：未保存的模型/思考等级/Key 草稿不再拦截登录或更新，也不会被静默保存；空模型目录不显示可编辑空字段。
- 在线检查、下载与校验更新，等待宿主完全退出后安装并自动重开。
- 调用日志记录模型、耗时与成功/失败，不记录录音、正文或 Token。

**Antigravity 为非官方集成，可能失效或导致账号受限，不代表 Google 授权支持第三方使用。** OAuth 登录独立于 Pi，不读取 Pi/浏览器已有凭据。录音发送到小米云端，工作流文本发送到 Google 服务。

## 安装

兼容声明使用宿主的**插件契约版本 1.1.6**，不是软件展示的产品版本 1.2.1。0.1.0 混用了两者，导致最新版也显示需要更新宿主；0.1.1 已修正，无需升级主程序。

首版以 **GitHub/官网桌面版 TypeWhisper Windows 1.2.1+、Windows x64、.NET 10 Runtime** 为目标。请先用 [官方 Windows 安装程序](https://github.com/TypeWhisper/typewhisper-win/releases) 安装/运行一次；旧版 1.0 插件架构不兼容。仅安装 Windows SDK/编译通过不代表通过真实桌面验收。

1. 从 [Windows 0.1.3 Release](https://github.com/tietiezhi-1216/typewhisper-tietiezhi/releases/tag/windows-v0.1.3) 下载 `tietiezhi-0.1.3-windows-x64.zip` 并完整解压，或使用插件内“检查更新 → 安装更新”（0.1.2 起支持）。
2. 从系统托盘**完全退出 TypeWhisper**。
3. 双击 `Install-tietiezhi.exe`，核对路径后输入 `YES`。不需要管理员权限。
4. 重开 TypeWhisper，在插件设置启用 **tietiezhi**。
5. 填写 **MiMo API Key** 后点击 **保存设置**。点击 **登录 Google**，浏览器授权后返回软件，点击 **完成登录**。两个凭据互不依赖；直接登录不会保存尚未提交的 MiMo Key。
6. 等待模型列表，选择润色模型和思考等级并保存；点击 **测试**。
7. 在听写中选择 **MiMo ASR**，在工作流中选择 **Antigravity OAuth（非官方）** 作为 LLM 提供商，并配置润色指令与快捷键。

安装工具使用 Windows 1.2.1 的插件索引契约：校验安装文件，复制到不可变目录，备份并原子替换索引，保留其他插件及其待更新信息。不会删除密钥、工作流或旧包。**安装工具不是官方安装器，宿主升级改变索引格式时需要适配。** 每次安装前必须退出宿主。

默认配置位置：`%LOCALAPPDATA%\TypeWhisper-WinUI`。Microsoft Store、Beta、ARM 原生版首版未验收，不应盲目安装到默认目录。测试/自定义配置可在确认正确路径后运行：

```powershell
.\Install-tietiezhi.exe --profile '你的 TypeWhisper 配置目录'
```

包内 `SHA256SUMS` 和发布的 SHA-256 用于传输完整性，不是发布者数字签名。当前未签名；只从本仓库 Release 下载，不要关闭全局安全防护或绕过企业策略。

## Google 登录与跨设备授权（0.1.3 起）

旧版登录会一直等待本机回调，Windows 宿主在操作结束前会禁用整个设置页，因此只加取消按钮也无法点击。0.1.3 将登录拆成开始和完成两个短操作；等待浏览器授权期间不占用设置页或插件操作锁。

### 在当前设备登录

1. 点击 **登录 Google**：打开默认浏览器，并在设置页显示 **Google 登录链接（选中复制）**。
2. 在浏览器完成授权，回到 TypeWhisper 点击 **完成登录**。本机回调只暂存在内存，点击完成后才交换凭据并刷新模型。
3. 不想继续时点击 **取消登录**，立即释放回调端口。取消重新登录不会删除原有 Google 凭据、模型或 MiMo Key；**退出登录**才会删除已保存的 Google 凭据。

### 在其他设备登录

1. 点击 **获取登录链接**（不启动本机浏览器），或直接复制“登录 Google”后显示的链接。
2. 将完整 Google 链接发送到你自己的另一台设备，在浏览器打开并授权。
3. 浏览器最终跳转到 `http://localhost:36742/oauth-callback?...`。另一台设备显示“无法访问此网站”是正常的；复制地址栏里的**完整最终 URL**，不要只复制 code。
4. 回到当前设备，粘贴到 **localhost 回调链接** 输入框，直接点击 **完成登录**，**无需保存设置**。

登录链接有效期为 **10 分钟**。点击“重新开始登录”或再次“获取登录链接”会使旧链接失效；取消、超时、停用或退出插件也会结束当前会话。超时或 Google 已消费授权码时请重新生成链接。默认浏览器启动失败或本机 36742 端口被占用时，仍可使用复制链接/粘贴回调方式。

只接受本次会话的 localhost/127.0.0.1 回调，检查协议、端口、路径、state 和唯一授权码；PKCE verifier 留在当前设备。授权/回调链接和临时输入不会写入插件设置或日志，仅最终凭据由宿主加密保存。不要将链接发给他人或上传到公开日志。Google 凭据交换与登录后的自动模型刷新各有 30 秒超时，失败会返回可重试提示。

## 在线更新（0.1.2 起）

在插件设置的按钮行点击 **检查更新 → 安装更新**。更新只读取公开 GitHub Windows Releases（包含 Windows 预览版），不读取 Mac latest，不发送 MiMo/Google 凭据，不要求 GitHub 登录。

更新包经过 HTTPS 来源/跳转限制、外层 SHA-256、ZIP 路径/大小/链接/重复文件检查、插件清单/兼容版本与内层文件哈希校验。然后启动独立更新程序等待：**请从托盘完全退出 TypeWhisper，不要马上手动重开**。退出后自动备份并安装，完成后自动重新打开。不会强行结束进程或丢弃未保存文本。10 分钟内没有退出则取消安装，下次重新点击更新。失败时检查更新会提示重试；原包保持不变。手动安装包始终可用。

**0.1.1 及更旧版本还没有更新入口，需要手动安装一次 0.1.2 或更新版本。** API Key、Google 凭据和工作流保留。纯 `windows-plugin.zip` 是供开发者/目录分发的 ZIP（文件直接位于根目录），不是可以双击执行的安装器。

## 构建与测试

安装 .NET 10 SDK 后，无需 Windows SDK，可跨平台构建托管插件：

```sh
dotnet run --project windows/Tests/Tietiezhi.Tests.csproj -c Release
python windows/package.py
```

`DOTNET` 环境变量可指定 dotnet 可执行文件。打包会跨编译 Windows x64 framework-dependent 安装器（需要 .NET 10 Runtime）。SDK 来自 `vendor/README.md` 中锁定的官方版本，SDK DLL 不随插件分发。

离线测试覆盖协议、凭据刷新、403 目录合并、禁止生成失败后切换端点、WAV 分段、登录立即返回、本机与跨设备回调、取消/重试/超时/停用的端口清理、回调来源/state/PKCE 校验、浏览器失败与端口占用的手动回退、失败/取消认证时保留旧凭据、临时链接不落盘、未保存草稿隔离、设置/密钥持久化、更新源过滤与 ZIP/哈希安全检查、安装索引备份。Windows CI 另使用模拟宿主进程验证真实独立更新程序的“等待退出 → 安装 → 自动重开”，不启动用户的真实 TypeWhisper。

真实 Google 授权、MiMo 请求和 Windows TypeWhisper UI/录音插入仍需手动验收。
