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
  <a href="https://github.com/stophemo/woo-todo/releases/tag/v0.1.12">下载 v0.1.12</a> ·
  <a href="docs/INSTALLATION.md">安装指南</a> ·
  <a href="https://github.com/stophemo/woo-todo/issues">反馈问题</a>
</p>

## 别让“管理任务”变成另一项任务

很多待办工具擅长收集，却让清单越积越长。Woo Todo 更关心另一件事：**下一段时间，你真正准备完成什么？**

它把一天压缩成一个自然的节奏：晚上用手机列好明日任务，第二天在电脑桌面直接开工；周期结束后，完成就是完成，没有完成就诚实地记为 `Pass`。任务不会无休止地滚到明天，历史会留下真实结果。

没有 Woo Todo 账号，没有联网门槛，也没有为了跨平台塞进来的浏览器运行时。任务先写入本地 SQLite；要不要同步、用哪种同步方式，都由你决定。

## 一天怎么流过 Woo Todo

### 23:10 · 把明天交代清楚

在 Android 切到“明日”，写下真正要做的几件事，分成主线、支线和外传。睡前规划提醒可以叫你回来，但不会替你制造一套复杂流程。

### 第二天 · 打开电脑直接开始

macOS 的原生悬浮任务板常驻桌面，可置顶、毛玻璃或鼠标穿透；Android Widget 留在手机桌面；Windows 则提供托盘与可置顶、可穿透的悬浮任务板。三个平台各自贴近系统，不把浏览器运行时带进日常工作流。

### 周期结束 · 完成，或者诚实 Pass

日、周、月任务会按周期结算。你可以回看历史与履约趋势，而不是面对一张永远清不完、也说不清从何而来的旧清单。

## 它刻意做少，但把这些做好

- **本地优先**：新增、编辑、完成、排序都只依赖本机数据库，断网照常使用。
- **原生而轻量**：macOS 使用 AppKit/SwiftUI，Android 使用 Kotlin/RemoteViews，Windows 使用 Rust、`windows-rs` 与 Win32；领域规则由 Rust 共享，没有 Electron、Flutter、WebView 或 .NET 桌面运行时。
- **适合真实生活的周期**：支持日、周、月、闲时，一次性或重复任务，以及主线、支线、外传。
- **看见真实结果**：完成、`Pass`、历史与履约统计都被认真记录，不靠无限顺延粉饰计划。
- **提醒不抢方向盘**：支持睡前规划、任务级提醒和非阻塞更新提示，不用强制弹窗打断当前工作。
- **数据边界清楚**：默认只保存在设备上；启用同步时，任务正文以 AES-256-GCM 密文离开设备。

## 现在可以在哪里用

当前稳定版是 [`v0.1.12`](https://github.com/stophemo/woo-todo/releases/tag/v0.1.12)，提供 macOS ZIP、Android APK 与 Windows 免安装 ZIP。三端都坚持原生、轻量和本地优先，但 Windows 首版的功能范围与 macOS/Android 不完全相同。

| 平台 | 最适合的场景 | 状态 |
| --- | --- | --- |
| macOS 15+、Apple Silicon | 工作时常驻桌面的悬浮任务板、完整任务管理与统计 | `v0.1.12` 可下载 |
| Android 13+ | 睡前规划、任务提醒、今日 Widget 与移动查看 | `v0.1.12` 可下载 |
| Windows 10 build 19041+ / Windows 11（仅 x64） | 本地任务、历史统计、系统托盘与可置顶/穿透的悬浮任务板 | `v0.1.12` 可下载 |

Windows 首版聚焦本地任务闭环和系统任务提醒，不包含现有 macOS/Android 的同步与加密备份。

## 下载 v0.1.12

| 平台 | 发布文件 | 使用提示 |
| --- | --- | --- |
| macOS | [Woo-Todo-v0.1.12-macos-arm64.zip](https://github.com/stophemo/woo-todo/releases/download/v0.1.12/Woo-Todo-v0.1.12-macos-arm64.zip) | 解压后可直接运行 `Woo Todo.app`，也可自行移入“应用程序”。当前为 ad-hoc 签名且未经过 Apple 公证，首次打开可能需要在“隐私与安全性”中允许。 |
| Android | [Woo-Todo-v0.1.12-android.apk](https://github.com/stophemo/woo-todo/releases/download/v0.1.12/Woo-Todo-v0.1.12-android.apk) | 从系统文件管理器打开并允许本次来源安装。正式 APK 使用项目长期 Release 签名，可直接覆盖升级。 |
| Windows | [Woo-Todo-v0.1.12-windows-x64.zip](https://github.com/stophemo/woo-todo/releases/download/v0.1.12/Woo-Todo-v0.1.12-windows-x64.zip) | 解压后直接运行 `WooTodo.exe`，无需安装且无需管理员权限。当前程序未签名，SmartScreen 可能提示来源未知，请核对校验和后再运行。 |
| 完整性校验 | [SHA256SUMS.txt](https://github.com/stophemo/woo-todo/releases/download/v0.1.12/SHA256SUMS.txt) | 下载后用 `shasum -a 256 <文件>` 或系统等价工具核对。 |

macOS/Android 更新会保留任务、同步身份与配对状态，**普通更新不需要重新配对**；Windows 退出程序后替换 `WooTodo.exe` 也会保留本地任务与设置。不要先卸载、清除应用数据，或用不同签名的 Debug APK 覆盖正式版；这些操作可能删除本地数据库或 Android Keystore。

## 装好以后，从这里开始

### macOS

1. 启动后在菜单栏找到 Woo Todo；它不会占用 Dock 位置。
2. 打开“任务详情与统计…”管理今日、本周、本月、闲时、历史与设置。
3. 用任务板右上角 `+` 新增任务；点击圆圈完成，双击编辑，右键删除，同一任务线内可以拖动排序。

### Android

1. 首次打开后按需授予通知权限，在顶部切换今日、明日、本周、本月与闲时。
2. 点击右下角 `+` 新建任务，也可以设置重复规则和指定时间提醒。
3. 三星设备可长按桌面空白处，从“组件”中添加 Woo Todo 今日 Widget。

### Windows

1. 解压 `Woo-Todo-v0.1.12-windows-x64.zip`，运行其中的 `WooTodo.exe`；若 SmartScreen 拦截，请先确认文件来自本仓库 Release 并核对校验和。
2. 在悬浮任务板快速新增、完成或编辑任务，右键可 `Pass` 或删除。
3. 托盘菜单负责完整窗口、任务板显隐与穿透恢复；默认全局快捷键为 `Ctrl + Alt + 1` 至 `Ctrl + Alt + 4`。任务提醒由 Windows 系统调度，应用退出后仍可触发。

更完整的安装、权限和首次验收步骤见[安装指南](docs/INSTALLATION.md)。

## 同步，按自己的信任边界选

Woo Todo 不要求先配置同步。单设备使用时，什么都不用做；任务始终留在本地。

- **同一网络，最快开始**：`v0.1.12` 支持由 Mac 提供局域网同步，Android 扫码连接，适合两台设备经常处于同一网络的场景。
- **坚果云 WebDAV，推荐长期使用**：不需要部署服务器。Woo Todo 直接上传端到端加密的增量对象，坚果云只保存密文。
- **Cloudflare Worker + D1，自己托管**：适合希望掌控在线服务端与设备授权的人；服务端仍接触不到任务明文。

三种同步方式互斥，但都不会成为本地操作的前置条件。配置二维码和配对链接可能含有完整凭据或一次性 secret，只应在自己的设备旁展示，用完立即隐藏或清理剪贴板。

[坚果云配置](docs/JIANGUOYUN_SYNC.md) · [Worker 配对](docs/PAIRING.md) · [同步与安全设计](docs/SYNC_AND_SECURITY.md)

## 数据归你，不是口号

- 本地任务保存在设备 SQLite 中，启动和编辑不依赖网络。
- 坚果云与 Worker 同步只传输 AES-256-GCM 密文及收敛所需元数据，云端不保存任务明文或 Woo Todo 登录凭据。
- 加密备份使用 `.wootodo` 格式；恢复口令无法找回，请把它和备份文件分开保管。
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

修改共享协议时，需要同时更新 JSON Schema、fixture、Swift/Kotlin 模型和后端校验。环境要求与完整测试矩阵见[开发指南](docs/DEVELOPMENT.md)和[测试与验收](docs/TESTING.md)。

## 继续了解

| 文档 | 你会找到什么 |
| --- | --- |
| [安装与首次使用](docs/INSTALLATION.md) | 各平台安装、权限、升级和首次验收 |
| [产品规格](docs/PRODUCT_SPEC.md) | 任务周期、状态、显示变量与提醒规则 |
| [坚果云自动同步](docs/JIANGUOYUN_SYNC.md) | 不自建服务器的跨端同步 |
| [可选在线配对同步](docs/PAIRING.md) | Worker 配对、核对码与设备撤销 |
| [同步与安全](docs/SYNC_AND_SECURITY.md) | 加密、凭据、威胁边界与收敛规则 |
| [加密备份与恢复](docs/BACKUP_AND_RESTORE.md) | `.wootodo` 格式与恢复限制 |
| [架构说明](docs/ARCHITECTURE.md) | 原生客户端、领域层与本地优先设计 |
| [发版指南](docs/RELEASING.md) | CI、签名、发布文件与 Release 流程 |

## 许可

[MIT License](LICENSE)
