# Woo Todo Windows 原生客户端

Windows 客户端使用 Rust、`windows-rs`、`windows-sys`、Win32 和 WinRT 通知 API 实现，不包含 Electron、WebView、跨端 UI 框架或 .NET 桌面运行时。Windows crate 直接依赖 `shared/core-rust/`，领域、SQLite 仓储与通知计划不经过 C ABI 或 JSON。任务读写始终落在本地 SQLite；网络不可用不会阻塞本地操作。

## 系统要求

- 运行：Windows 10 版本 2004（build 19041）或更高版本，x64 架构。
- 开发：Windows x64 与 Rust stable（包含 `rustfmt`、`clippy` 和 MSVC 工具链）。

GitHub Release 提供 x64 免安装 ZIP，解压后直接运行根目录的 `WooTodo.exe`。Release 可执行文件静态链接 MSVC CRT，直接使用 Windows 自带的 Win32/WinRT 系统组件，目标机器不需要安装 Woo Todo、.NET 或 Visual C++ Runtime。

当前程序未做代码签名，Windows SmartScreen 可能在首次下载或启动时显示来源提示。

应用数据保存在 `%LOCALAPPDATA%\Woo Todo`：

- SQLite：`%LOCALAPPDATA%\Woo Todo\woo-todo.sqlite3`
- 设置：`%LOCALAPPDATA%\Woo Todo\settings.json`

托盘菜单可直接检查更新。发现新版本后，应用会下载免安装 ZIP、核对 GitHub Release 的 SHA-256 digest，再由临时 helper 在主进程退出后替换 `WooTodo.exe` 并重启；失败时保留当前程序。手动替换或移动 `WooTodo.exe` 也不会删除本地任务和设置；Rust 版本继续兼容旧客户端的数据库路径和 PascalCase 设置字段。

## 构建与测试

从仓库根目录在 Windows PowerShell 运行：

```powershell
cargo fmt --manifest-path windows/Cargo.toml --all -- --check
cargo test --manifest-path windows/Cargo.toml --locked --all-targets
cargo clippy --manifest-path windows/Cargo.toml --locked --all-targets -- -D warnings
cargo run --manifest-path windows/Cargo.toml
```

## 生成发布包

`package.ps1` 会锁定 `Cargo.lock`，为 MSVC x64 目标构建 Release，并生成只包含一个原生 `WooTodo.exe` 的 ZIP：

```powershell
pwsh -NoProfile -File windows/scripts/package.ps1
pwsh -NoProfile -File windows/scripts/package.ps1 -Version 0.1.14
```

输出文件为：

```text
windows/dist/Woo-Todo-v0.1.14-windows-x64.zip
```

正式 tag 发布会在 Windows Runner 上重新执行格式、测试、Clippy 和 Release 构建，再对最终 ZIP 执行真实 Win32 交互烟测，覆盖 AMD64 PE、启动、原生窗口、单实例、开始菜单身份、协议激活、快速新增、完成/取消完成、透明度与穿透独立变化、托盘退出及重启持久化。通过烟测的同一份 ZIP 会与 Android APK、macOS ZIP 一起发布；无论成功或失败，Runner 都会上传诊断日志、桌面截图、Windows Application 事件、隔离 SQLite 与设置文件。

## 首版范围

Windows 首版提供本地 SQLite 任务、日/周/月/闲时、重复与 Pass、历史统计、任务级系统提醒、悬浮任务板、托盘和固定全局快捷键。当前周期内误点完成后，可取消复选框或使用“取消完成”恢复为待办；周期结束后的历史与 Pass 不可改写。坚果云/Worker 同步和加密备份不作为首版范围。

悬浮板透明度和鼠标穿透是两个独立设置：透明度可在 35%～100% 调整，开启或关闭穿透不会改写透明度。

## 代码分层

- `shared/core-rust`：任务校验、周期结算、统计、SQLite 仓储语义与稳定通知计划。
- `windows/src/native`：Win32 窗口、任务板、原生控件、托盘、全局快捷键、单实例和协议激活。
- `windows/src/notifications.rs`：WinRT Toast 调度队列对齐。
- `windows/src/settings.rs`：兼容旧版 `settings.json` 的本机设置持久化。
- `windows/src/integration.rs`：免安装程序的当前用户通知身份与 `wootodo://` 协议注册。
- `windows/src/update.rs`：Release 解析、WinHTTP 下载、SHA-256 校验和免安装自替换 helper。
- `windows/scripts`：可复现的 ZIP 打包与 Windows Runner 烟测入口。

首次运行会为当前用户创建带 `stophemo.WooTodo` AppUserModelID 的开始菜单身份，并注册 `wootodo://` 协议；它不会复制程序、创建卸载项或请求管理员权限。移动程序后重新运行一次即可刷新路径。系统提醒被点击时，协议参数会转发给已经运行的单实例应用。
