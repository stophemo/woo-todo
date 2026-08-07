<p align="center">
  <img src="web/assets/app-icon.svg" width="76" alt="无我待办图标">
</p>

<h1 align="center">无我待办（Woo Todo）</h1>

<p align="center">
  <strong>今晚规划，明早开干。</strong><br>
  一款安静待在桌面和手机上的本地优先待办应用。
</p>

<p align="center">
  <a href="https://woo-todo.vercel.app/">产品主页</a> ·
  <a href="https://github.com/stophemo/woo-todo/releases/tag/v0.1.28">下载 v0.1.28</a> ·
  <a href="#装好以后从这里开始">安装指南</a> ·
  <a href="https://github.com/stophemo/woo-todo/issues">反馈问题</a>
</p>

## 别让“管理任务”变成另一项任务

很多待办工具擅长收集，却让清单越积越长。Woo Todo 更关心另一件事：**下一段时间，你真正准备完成什么？**

它把一天压缩成一个自然的节奏：晚上用手机列好明日任务，第二天在电脑桌面直接开工。一次性任务不会因为跨日而消失，会一直留到你完成或手动 `Pass`；重复任务的旧周期才会自动结算，让历史保留真实结果。

没有 Woo Todo 账号，没有联网门槛，也没有为了跨平台塞进来的浏览器运行时。任务先写入本地 SQLite；要不要同步、用哪种同步方式，都由你决定。

## 一天怎么流过 Woo Todo

### 23:10 · 把明天交代清楚

在 Android 切到“明日”，写下真正要做的几件事，分成主线、支线和外传。睡前规划提醒可以叫你回来，但不会替你制造一套复杂流程。

### 第二天 · 打开电脑直接开始

macOS 的原生任务小组件停留在桌面层，也可切换为普通或置顶任务板，并支持毛玻璃、鼠标穿透和拖动调整宽高；Android Widget 留在手机桌面；Windows 则提供托盘与可置顶、可穿透的悬浮任务板。三个平台各自贴近系统，不把浏览器运行时带进日常工作流。

### 周期结束 · 完成，或者诚实 Pass

重复的日、周、月任务会按周期结算；一次性任务则持续保留，直到完成或手动 `Pass`。你可以回看历史与履约趋势，也不会因为错过一天而丢掉还没处理的普通待办。

## 它刻意做少，但把这些做好

- **本地优先**：新增、编辑、完成、排序都只依赖本机数据库，断网照常使用。
- **原生而轻量**：macOS 使用 AppKit/SwiftUI，Android 使用 Kotlin/RemoteViews，Windows 使用 Rust、`windows-rs` 与 Win32；领域规则由 Rust 共享，没有 Electron、Flutter、WebView 或 .NET 桌面运行时。
- **适合真实生活的周期**：支持日、周、月、闲时，一次性或重复任务，以及主线、支线、外传。
- **看见真实结果，也允许纠错**：完成、`Pass`、历史与履约统计都会保留；当前周期内误点完成时，再点一次即可撤销。
- **设置跟着设备走**：三端的今日标题、副标题和计时模板可随任务一起加密同步，更新应用后不用重设。
- **升级不再来回下载**：Android 从 `v0.1.14` 起、macOS 从 `v0.1.15` 起可在应用内完成后续正式版更新；Android 仍保留系统安装确认。Windows 实验版需要手动下载替换。
- **数据边界清楚**：默认只保存在设备上；启用同步时，任务正文以 AES-256-GCM 密文离开设备。

## 现在可以在哪里用

当前稳定版是 [`v0.1.28`](https://github.com/stophemo/woo-todo/releases/tag/v0.1.28)，正式提供 macOS ZIP 与 Android APK。Windows 同步提供独立的实验版免安装 ZIP，但不属于正式发布通道，也不保证能够正常启动或使用。

| 平台 | 最适合的场景 | 状态 |
| --- | --- | --- |
| macOS 15+、Apple Silicon | 桌面层任务小组件、悬浮任务板、完整任务管理与统计 | `v0.1.28` 正式版 |
| Android 13+ | 睡前规划、任务提醒、今日 Widget 与移动查看 | `v0.1.28` 正式版 |
| Windows 10 build 19041+ / Windows 11（仅 x64） | 原生悬浮任务板、完整任务管理、统计与加密同步 | `v0.1.28` 实验版（不保证可用） |

Windows 已支持自建服务、同一网络与第三方 WebDAV 三种互斥同步方式，以及设备配对和撤销。同步凭据保存在 Windows Credential Manager，不写入 `settings.json`。

> **Windows 实验版（不保证可用）：** 该构建仅用于开发测试，可能无法启动、功能不完整，并可能存在稳定性或数据兼容风险。请勿用于唯一或重要任务数据。它发布到独立 GitHub Prerelease，文件名带 `windows-x64-experimental`，不会混入 macOS/Android 正式 Release，也不走正式版自动更新通道。

## 下载 v0.1.28

| 平台 | 发布文件 | 使用提示 |
| --- | --- | --- |
| macOS | [Woo-Todo-v0.1.28-macos-arm64.zip](https://github.com/stophemo/woo-todo/releases/download/v0.1.28/Woo-Todo-v0.1.28-macos-arm64.zip) | ZIP 内是 `Woo Todo.app`；解压后可直接运行，也可移入“应用程序”。当前为 ad-hoc 签名且未经过 Apple 公证，首次打开可能需要在“隐私与安全性”中允许。 |
| Android | [Woo-Todo-v0.1.28-android.apk](https://github.com/stophemo/woo-todo/releases/download/v0.1.28/Woo-Todo-v0.1.28-android.apk) | 从系统文件管理器打开并允许本次来源安装。正式 APK 使用项目长期 Release 签名，可直接覆盖升级。 |
| Windows 实验版 | [Woo-Todo-v0.1.28-windows-x64-experimental.zip](https://github.com/stophemo/woo-todo/releases/download/windows-v0.1.28-experimental/Woo-Todo-v0.1.28-windows-x64-experimental.zip) | **不保证可用。** ZIP 内含 `WooTodo.exe` 与 `WINDOWS-EXPERIMENTAL.txt`；当前程序未签名，SmartScreen 可能提示来源未知。请先备份重要数据。 |
| 正式版校验 | [SHA256SUMS.txt](https://github.com/stophemo/woo-todo/releases/download/v0.1.28/SHA256SUMS.txt) | 校验 macOS 与 Android 正式包。 |
| Windows 实验版校验 | [SHA256SUMS-windows-experimental.txt](https://github.com/stophemo/woo-todo/releases/download/windows-v0.1.28-experimental/SHA256SUMS-windows-experimental.txt) | 校验独立 Windows 实验包。 |

`v0.1.28` 重新设计 macOS 的更新提示，并让检查结果气泡按文案自适应宽高，减少多余留白；发布流程也改为强制使用手写更新说明。macOS 与 Android 的 `v0.1.27` 可在应用内升级；Windows 仅提供独立实验包，不参与正式版自动更新。

不要先卸载、清除应用数据，或用不同签名的 Debug APK 覆盖正式版。macOS 当前没有 Developer ID 签名，自建服务或同一网络身份在更新后仍可能再次请求 Keychain 授权；第三方 WebDAV 配置会在首次迁移后改由本机加密文件自动回填。Sparkle 的下载签名可以验证更新包，但不能替代 Apple 的代码签名。

## 装好以后，从这里开始

### macOS

1. 启动后在菜单栏找到 Woo Todo；它不会占用 Dock 位置。
2. 打开“任务详情与统计…”管理今日、本周、本月、闲时、历史与设置。
3. 任务板默认以桌面小组件模式停留在桌面层；菜单栏可切换为普通或始终置顶，右下角可拖动调整小组件宽高。用“快速新增任务”或完整任务窗口新增待办；点击圆圈完成，当前周期内再点一次可撤销完成，双击编辑，右键删除，同一任务线内可以拖动排序。

### Android

1. 首次打开后按需授予通知权限，在顶部切换今日、明日、本周、本月与闲时。
2. 点击右下角 `+` 新建任务，也可以设置重复规则和指定时间提醒；误点完成时再次勾选即可撤销。
3. 可在 Android 桌面的“微件”或“组件”入口添加 Woo Todo 今日 Widget；入口名称因系统桌面而异。

### Windows

1. Windows 当前仅提供 `Woo-Todo-v0.1.28-windows-x64-experimental.zip` 实验包；它不保证可用。备份数据后解压并运行 `WooTodo.exe`，若 SmartScreen 拦截，请核对独立实验版校验和。
2. 在悬浮任务板快速新增、完成或编辑任务；选中已完成任务后可“取消完成”，右键也可 `Pass` 或删除。
3. 托盘菜单负责完整窗口、任务板显隐、鼠标穿透和检查更新；默认全局快捷键为 `Ctrl + Alt + 1` 至 `Ctrl + Alt + 6`，其中 `5/6` 调整任务板不透明度。完整窗口的“同步”可配置三种同步方式。任务提醒由 Windows 系统调度，应用退出后仍可触发。

## 同步，按自己的信任边界选

Woo Todo 不要求先配置同步。单设备使用时，什么都不用做；任务始终留在本地。

- **同一网络，最快开始**：由 Mac 或 Windows PC 开启局域网同步服务，Android 扫码连接，适合设备经常处于同一网络的场景。
- **第三方 WebDAV，跨网络使用**：填写服务商提供的 HTTPS WebDAV 根目录。Woo Todo 只上传端到端加密的增量对象，服务商无法读取任务正文。
- **Cloudflare Worker + D1，自己托管**：适合希望掌控在线服务端与设备授权的人；服务端仍接触不到任务明文。

三种同步方式互斥，但都不会成为本地操作的前置条件。macOS 与 Windows 会分别保留已配置的局域网/自建服务和 WebDAV 身份，切回时无需重填；macOS 的 WebDAV 完整配置使用本机 AES-256-GCM 加密文件保存并自动回填。切换同时保留本地任务和显示配置，并从远端 Lamport 水位之后建立加密基线。同一网络同步会在三端绕过系统 HTTP 代理，避免 `.local` 或私有地址被错误转发；全局 TUN/VPN 模式仍需把局域网配置为直连。配置二维码和配对链接可能含有完整凭据或一次性 secret，只应在自己的设备旁展示，用完立即隐藏或清理剪贴板。

## 数据归你，不是口号

- 本地任务保存在设备 SQLite 中，启动和编辑不依赖网络。
- WebDAV、自建服务与同一网络同步只传输 AES-256-GCM 密文及收敛所需元数据，远端不保存任务明文或 Woo Todo 登录凭据。
- 同步密钥只保存在设备安全存储中；如果所有设备和密钥同时丢失，服务端密文无法解密恢复。
- 撤销设备会阻止它继续同步，但无法远程删除已经下载到该设备的本地数据。

## 开发

三端保持原生 UI、彼此不直接依赖；领域、SQLite 语义与通知计划逐步收敛到 `shared/core-rust/`，同步协议继续通过 `shared/schema/` 与 `shared/fixtures/` 对齐。常用检查命令：

```bash
npm install
npm run validate:contracts
npm run test:crypto
npm run test:backend
cargo test --manifest-path shared/core-rust/Cargo.toml --locked --all-targets
./android/gradlew -p android testDebugUnitTest
swift test --package-path macos
cargo test --manifest-path windows/Cargo.toml --locked --all-targets
```

修改共享协议时，需要同时更新 JSON Schema、fixture、Swift/Kotlin 模型和后端校验。

## 许可

[MIT License](LICENSE)
