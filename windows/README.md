# tietiezhi for TypeWhisper Windows — 0.1.1 Preview

Windows 原生托管插件，不需要运行 Pi、Python 或本地代理。Mac 版与 Windows 版源码同仓库，安装包互不通用。

## 功能

- MiMo V2.5 ASR：宿主录音 → WAV 上传 → 转录；长音频按 180 秒/大小限制分段。
- Antigravity OAuth：浏览器授权、PKCE、state 校验、自动刷新、退出登录。
- 登录后获取模型列表，选择模型和思考等级；保留各目录端点的运行路由。
- API Key 和 OAuth 凭据使用 TypeWhisper 的 Windows DPAPI 加密存储。
- 设置 UI 由 TypeWhisper 渲染；润色指令仍在宿主工作流配置。
- 调用日志记录模型、耗时与成功/失败，不记录录音、正文或 Token。

**Antigravity 为非官方集成，可能失效或导致账号受限，不代表 Google 授权支持第三方使用。** OAuth 登录独立于 Pi，不读取 Pi/浏览器已有凭据。录音发送到小米云端，工作流文本发送到 Google 服务。

## 安装

兼容声明使用宿主的**插件契约版本 1.1.6**，不是软件展示的产品版本 1.2.1。0.1.0 混用了两者，导致最新版也显示需要更新宿主；0.1.1 已修正，无需升级主程序。

首版以 **GitHub/官网桌面版 TypeWhisper Windows 1.2.1+、Windows x64、.NET 10 Runtime** 为目标。请先用 [官方 Windows 安装程序](https://github.com/TypeWhisper/typewhisper-win/releases) 安装/运行一次；旧版 1.0 插件架构不兼容。仅安装 Windows SDK/编译通过不代表通过真实桌面验收。

1. 从本仓库 Releases 下载 `tietiezhi-0.1.1-windows-x64.zip`，完整解压。
2. 从系统托盘**完全退出 TypeWhisper**。
3. 双击 `Install-tietiezhi.exe`，核对路径后输入 `YES`。不需要管理员权限。
4. 重开 TypeWhisper，在插件设置启用 **tietiezhi**。
5. 填写 **MiMo API Key**，点击 **登录 Antigravity**，浏览器授权后返回软件。
6. 等待模型列表，选择润色模型和思考等级；点击 **测试润色**。
7. 在听写中选择 **MiMo ASR**，在工作流中选择 **Antigravity OAuth（非官方）** 作为 LLM 提供商，并配置润色指令与快捷键。

安装工具使用 Windows 1.2.1 的插件索引契约：校验安装文件，复制到不可变目录，备份并原子替换索引，保留其他插件及其待更新信息。不会删除密钥、工作流或旧包。**安装工具不是官方安装器，宿主升级改变索引格式时需要适配。** 每次安装前必须退出宿主。

默认配置位置：`%LOCALAPPDATA%\TypeWhisper-WinUI`。Microsoft Store、Beta、ARM 原生版首版未验收，不应盲目安装到默认目录。测试/自定义配置可在确认正确路径后运行：

```powershell
.\Install-tietiezhi.exe --profile '你的 TypeWhisper 配置目录'
```

包内 `SHA256SUMS` 和发布的 SHA-256 用于传输完整性，不是发布者数字签名。当前未签名；只从本仓库 Release 下载，不要关闭全局安全防护或绕过企业策略。

首版不包含 Mac 的一键自更新。更新 Windows 版时下载新安装包、退出宿主、重新运行安装工具，Key 与设置保留。纯 `windows-plugin.zip` 是供开发者/未来目录分发的 ZIP（文件直接位于根目录），不是可以双击执行的安装器。

## 构建与测试

安装 .NET 10 SDK 后，无需 Windows SDK，可跨平台构建托管插件：

```sh
dotnet run --project windows/Tests/Tietiezhi.Tests.csproj -c Release
python windows/package.py
```

`DOTNET` 环境变量可指定 dotnet 可执行文件。打包会跨编译 Windows x64 framework-dependent 安装器（需要 .NET 10 Runtime）。SDK 来自 `vendor/README.md` 中锁定的官方版本，SDK DLL 不随插件分发。

离线测试覆盖协议、凭据刷新、403 目录合并、禁止生成失败后切换端点、WAV 分段、设置/密钥持久化和安装索引备份。真实 Google 授权、MiMo 请求和 Windows TypeWhisper UI/录音插入仍需手动验收。
