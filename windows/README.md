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
- Worker、局域网与坚果云同步凭据：Windows Credential Manager
- 局域网主机状态：`%LOCALAPPDATA%\Woo Todo\local-sync\<vaultId>.json`

`settings.json` 只保存窗口、显示、快捷键和本机是否承载局域网服务等非敏感设置，不写入设备令牌、应用密码或同步密钥。

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
pwsh -NoProfile -File windows/scripts/package.ps1 -Version 0.1.16
```

输出文件为：

```text
windows/dist/Woo-Todo-v0.1.16-windows-x64.zip
```

正式 tag 发布会在 Windows Runner 上重新执行格式、测试、Clippy 和 Release 构建，再对最终 ZIP 执行真实 Win32 交互烟测，覆盖 AMD64 PE、启动、原生窗口、单实例、开始菜单身份、协议激活、快速新增、完成/取消完成、显示设置、同步入口、透明度与穿透独立变化、托盘退出及重启持久化。通过烟测的同一份 ZIP 会与 Android APK、macOS ZIP 一起发布；无论成功或失败，Runner 都会上传诊断日志、桌面截图、Windows Application 事件、隔离 SQLite 与设置文件。

## 功能范围

Windows 提供本地 SQLite 任务、日/周/月/闲时、重复与 Pass、截止日期、历史统计、任务级系统提醒、悬浮任务板、托盘和可自定义全局快捷键。一次性任务跨周期保留到完成或手动 Pass；当前重复周期和一次性任务误点完成后，可取消复选框或使用“取消完成”恢复为待办，已结束的重复实例历史与 Pass 不可改写。

“同步”支持三种互斥方式：自建 Worker、由本机承载的同一网络同步、坚果云 WebDAV。可以从当前方式直接切换，切换前先验证新端点或 WebDAV 目录；本地任务和显示配置会保留并在新空间建立基线。Worker 与同一网络方式支持 10 分钟配对二维码、六位码核对、设备列表和撤销；坚果云保存后可生成或复制供 Android 扫描的完整配置二维码。配置二维码含坚果云应用密码和 `vault key`，离开“同步”或关闭窗口会从界面和内存清除。

同一网络模式固定监听 TCP `48473`，需要允许 Windows Defender 防火墙中的专用网络访问；休眠唤醒或本机 IP 变化后会刷新地址并恢复服务。局域网服务只适合可信网络，不提供公网 TLS。

同步凭据保存在 Windows Credential Manager，不会写入 `settings.json`。任务始终先写入本地 SQLite，网络不可用时仍可继续编辑。

悬浮板透明度和鼠标穿透是两个独立设置：透明度可在 20%～100% 调整，开启或关闭穿透不会改写透明度。

## 代码分层

- `shared/core-rust`：任务校验、周期结算、统计、SQLite 仓储语义与稳定通知计划。
- `windows/src/native`：Win32 窗口、任务板、原生控件、托盘、全局快捷键、单实例和协议激活。
- `windows/src/notifications.rs`：WinRT Toast 调度队列对齐。
- `windows/src/settings.rs`：兼容旧版 `settings.json` 的本机设置持久化。
- `windows/src/credentials.rs`：Worker、局域网与坚果云凭据校验及 Windows Credential Manager 持久化。
- `windows/src/sync_runtime.rs`：后台同步调度、方式切换和共享 SQLite 同步核心接入。
- `windows/src/worker.rs`、`windows/src/webdav.rs`：Worker/局域网 REST 与坚果云 WebDAV 客户端。
- `windows/src/local_server.rs`：同一网络主机、设备授权、配对与增量同步 HTTP 服务。
- `windows/src/integration.rs`：免安装程序的当前用户通知身份与 `wootodo://` 协议注册。
- `windows/src/update.rs`：Release 解析、WinHTTP 下载、SHA-256 校验和免安装自替换 helper。
- `windows/scripts`：可复现的 ZIP 打包与 Windows Runner 烟测入口。

首次运行会为当前用户创建带 `stophemo.WooTodo` AppUserModelID 的开始菜单身份，并注册 `wootodo://` 协议；它不会复制程序、创建卸载项或请求管理员权限。移动程序后重新运行一次即可刷新路径。系统提醒被点击时，协议参数会转发给已经运行的单实例应用。
