# Woo Todo Windows 客户端

Windows 客户端从 `v0.2.0` 起进入正式发布通道，使用 Tauri 2、WebView2 和 Rust。界面由 `ui/` 中的 HTML/CSS/JavaScript 实现，任务、SQLite 仓储、同步运行时、通知和 Windows 系统集成仍由 Rust 负责。前端只通过 Tauri 命令访问领域能力；网络不可用不会阻塞本地操作。

## 系统要求

- 运行：Windows 10 版本 2004（build 19041）或更高版本，x64 架构。
- 需要：WebView2 Runtime。大多数 Windows 10/11 系统已经预装；如果启动失败，请先安装或修复 WebView2 Runtime。
- 开发：Windows x64、Rust stable、Node.js 22+、WebView2 Runtime（包含 `rustfmt`、`clippy` 和 MSVC 工具链）。

GitHub 正式 Release 提供 x64 免安装 ZIP。当前程序未做代码签名，Windows SmartScreen 可能在首次下载或启动时显示来源提示。

应用数据保存在 `%LOCALAPPDATA%\Woo Todo`：

- SQLite：`%LOCALAPPDATA%\Woo Todo\woo-todo.sqlite3`
- 设置：`%LOCALAPPDATA%\Woo Todo\settings.json`
- Worker、局域网与第三方 WebDAV 同步凭据：Windows Credential Manager
- 局域网主机状态：`%LOCALAPPDATA%\Woo Todo\local-sync\<vaultId>.json`

`settings.json` 只保存窗口、显示、快捷键和本机是否承载局域网服务等非敏感设置，不写入设备令牌、应用密码或同步密钥。

Windows 正式版与 macOS、Android 一起进入 GitHub 正式 Release；当前 Tauri 主界面使用正式 ZIP 手动升级，下载新 ZIP 后替换旧的 `WooTodo.exe` 即可。升级不会删除本地任务和设置，Tauri 版本继续兼容旧客户端的数据库路径和 PascalCase 设置字段。

## 构建与测试

从仓库根目录在 Windows PowerShell 运行：

```powershell
cargo fmt --manifest-path windows/Cargo.toml --all -- --check
cargo test --manifest-path windows/Cargo.toml --locked --all-targets
cargo clippy --manifest-path windows/Cargo.toml --locked --all-targets -- -D warnings
npm --prefix windows/ui ci
npm --prefix windows/ui run tauri:dev
```

## 生成发布包

`package.ps1` 会锁定 `Cargo.lock`，为 MSVC x64 目标构建 Tauri 正式免安装 ZIP：

```powershell
pwsh -NoProfile -File windows/scripts/package.ps1
pwsh -NoProfile -File windows/scripts/package.ps1 -Version 0.2.0
```

输出文件为：

```text
windows/dist/Woo-Todo-v0.2.0-windows-x64.zip
```

ZIP 只包含 `WooTodo.exe`，因为应用内更新器会校验并替换这一文件。任务、设置和凭据均保存在用户数据目录，不会被打进发布包。

正式 tag 发布会在 Windows Runner 上重新执行格式、测试、Clippy 和优化构建，之后与 macOS、Android 一起进入同一个 GitHub Release。Windows 界面交互、系统集成和更新流程仍建议在真实 Windows 设备上验证；自动测试通过不能替代真机验收。

## Tauri 迁移范围

当前 Tauri 界面已经接入现有 SQLite，并支持日/周/月/闲时导航、历史与统计、任务新增和编辑、完成与撤销、Pass、删除、同级排序，以及独立悬浮任务板。任务板显示阳历、农历与节气/节日，可调整不透明度、置顶、鼠标穿透和桌面小组件模式。

同步运行时会恢复 Windows Credential Manager 中已有的 Worker、局域网或 WebDAV 凭据，并支持手动触发同步。Tauri 托盘已经提供主窗口、任务板、同步和退出入口；同步页支持粘贴由 Mac、Windows 或 Android 同步空间生成的 `wootodo://pair` 配对链接加入同一 vault。加入前会校验 vaultId，不同同步空间会拒绝替换；本地任务与待同步数据保留。Windows 不应先创建新空间再让 Android 扫码，否则三端会被拆成不同同步空间。

同步凭据保存在 Windows Credential Manager，不会写入 `settings.json`。任务始终先写入本地 SQLite，网络不可用时仍可继续编辑。

悬浮板透明度和鼠标穿透是两个独立设置：透明度可在 20%～100% 调整，开启或关闭穿透不会改写透明度。默认悬浮板尺寸为 500×440、不透明度 80%，背景为平滑的半透明渐变，可透出桌面；主窗口与设置页使用光滑深色渐变风格。桌面小组件模式会把任务板保持在普通窗口底层，并与“始终置顶”和“鼠标穿透”互斥。

运行中的问题排查：GUI 程序没有控制台，未捕获的 panic 会写入 `%LOCALAPPDATA%\Woo Todo\panic.log`。如启动失败，优先检查 WebView2 Runtime、系统事件查看器和该日志文件。

## 代码分层

- `shared/core-rust`：任务校验、周期结算、统计、SQLite 仓储语义与稳定通知计划。
- `windows/src/tauri_app.rs`：Tauri 生命周期、窗口命令、任务命令、悬浮任务板和同步运行时桥接。
- `windows/ui`：Tauri 2 前端、任务列表、设置页面和悬浮任务板视觉层。
- `windows/src/lunar.rs`：农历月日（ICU4X 中文日历）与节气、节日标注，对齐 macOS `TraditionalCalendarInfo`。
- `windows/src/notifications.rs`：WinRT Toast 调度队列对齐。
- `windows/src/settings.rs`：兼容旧版 `settings.json` 的本机设置持久化（原子替换保存）。
- `windows/src/credentials.rs`：Worker、局域网与第三方 WebDAV 凭据校验及 Windows Credential Manager 持久化。
- `windows/src/sync_runtime.rs`：后台同步调度、方式切换和共享 SQLite 同步核心接入。
- `windows/src/worker.rs`、`windows/src/webdav.rs`：Worker/局域网 REST 与通用 WebDAV 客户端。
- `windows/src/local_server.rs`：同一网络主机、设备授权、配对与增量同步 HTTP 服务。
- `windows/src/integration.rs`：免安装程序的当前用户通知身份与 `wootodo://` 协议注册。
- `windows/src/update.rs`：Release 解析、WinHTTP 下载、SHA-256 校验和免安装自替换 helper。
- `windows/scripts`：可复现的 ZIP 打包入口与开发用冒烟测试脚本。

首次运行会为当前用户创建带 `stophemo.WooTodo` AppUserModelID 的开始菜单身份，并注册 `wootodo://` 协议；它不会复制程序、创建卸载项或请求管理员权限。移动程序后重新运行一次即可刷新路径。系统提醒被点击时，协议参数会转发给已经运行的单实例应用。
