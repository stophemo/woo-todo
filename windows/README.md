# Woo Todo Windows 原生客户端

Windows 客户端使用 .NET 10、WPF、Win32 和 WinRT 通知 API 实现，不包含 Electron、WebView 或跨端 UI 运行时。C# 是原生外壳与薄适配层，领域、SQLite 仓储语义和通知计划由 `shared/core-rust/` 提供。任务读写始终落在本地 SQLite；网络不可用不会阻塞本地操作。

## 系统要求

- 运行：Windows 10 版本 2004（build 19041）或更高版本，x64 架构。
- 开发：Windows x64、.NET 10 SDK 与 Rust stable；生成安装包还需要 Inno Setup 6。

GitHub Release 提供一个 `win-x64` 自包含 EXE 安装包，使用时不需要另行安装 .NET Runtime。安装程序支持当前用户安装、开始菜单快捷方式、可选桌面快捷方式、覆盖升级和标准卸载。

当前安装包未做代码签名，Windows SmartScreen 可能在首次下载或启动时显示来源提示。

应用数据保存在 `%LOCALAPPDATA%\Woo Todo`，替换程序目录升级不会删除本地任务和设置。

## 构建与测试

从仓库根目录运行：

```powershell
dotnet restore windows/WooTodo.sln
dotnet build windows/WooTodo.sln --configuration Release --no-restore
dotnet test windows/WooTodo.sln --configuration Release --no-restore
dotnet run --project windows/src/WooTodo.WindowsApp/WooTodo.WindowsApp.csproj
```

## 生成发布包

安装 Inno Setup 6 后，`package.ps1` 会先发布 `win-x64` 自包含应用，再生成单个 EXE 安装包：

```powershell
pwsh -NoProfile -File windows/scripts/package.ps1
pwsh -NoProfile -File windows/scripts/package.ps1 -Version 0.1.12
```

输出文件为：

```text
windows/dist/Woo-Todo-v0.1.12-windows-x64-setup.exe
```

正式 tag 发布会在 Windows Runner 上重新执行测试，用 Inno Setup 生成安装器，并把该 EXE 与 Android APK、macOS ZIP 一起发布。

## 首版范围

Windows 首版提供本地 SQLite 任务、日/周/月/闲时、重复与 Pass、历史统计、任务级系统提醒、悬浮任务板、托盘和固定全局快捷键。坚果云/Worker 同步和加密备份不作为首版范围。

## 代码分层

- `shared/core-rust`：任务校验、周期结算、统计、SQLite 仓储语义与稳定通知计划。
- `WooTodo.Core`：C# 领域模型和 Rust C ABI/JSON 薄适配。
- `WooTodo.Storage`：Rust SQLite 仓储句柄的 C# 生命周期封装。
- `WooTodo.WindowsApp`：WPF 窗口、任务板、系统托盘、全局快捷键、WinRT 通知调度与本机设置。
- `WooTodo.Core.Tests`：FFI 字段、周期边界、重复任务幂等性、通知计划和真实 SQLite 仓储测试。

安装器会为开始菜单快捷方式写入 `stophemo.WooTodo` AppUserModelID，并注册 `wootodo://` 协议。系统提醒被点击时，协议参数通过当前用户命名管道转发给已经运行的单实例应用。
