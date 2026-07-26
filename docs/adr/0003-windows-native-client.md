# ADR-0003：增加 Windows 原生客户端与 EXE 安装包

- 状态：已接受；领域与通知边界由 ADR-0004 修订
- 日期：2026-07-24

## 背景

项目需要支持 Windows 桌面环境，同时继续满足悬浮任务板、系统托盘、全局快捷键、本地优先和低常驻开销要求。Windows 交付还需要避免用户为了运行应用单独配置开发工具链。

## 决策

- Windows 客户端使用 .NET 10、WPF 和必要的 Win32/Windows Forms 系统 API，不引入 Electron、WebView 或跨端 UI 框架。
- `WooTodo.Core`、`WooTodo.Storage` 和 `WooTodo.WindowsApp` 保持分层；C# 通过窄 FFI 依赖 `shared/core-rust/`，不依赖其他客户端实现。
- 本地 SQLite 是 Windows UI 的唯一数据来源，用户操作不以网络同步为前置条件；任务明文不交给云端。
- 首个交付目标固定为 Windows 10 build 19041 及以上的 `win-x64`。
- GitHub Actions 使用 .NET 10 SDK 在 Windows Runner 上测试，并通过现有 `WooTodo.WindowsApp.csproj` 执行 self-contained `dotnet publish`。
- 使用 Inno Setup 将 self-contained `win-x64` 应用目录封装为一个 EXE 安装包，不要求目标机器预装 .NET Runtime。
- 安装目标覆盖 Windows 10 build 19041 及以上版本和 Windows 11；首版不提供 ARM64 原生包与代码签名。
- 首版以本地任务闭环为范围，不把在线同步和加密备份作为 Windows 发布门禁；任务通知按 ADR-0004 使用 Rust 计划与 Windows 原生调度。
- 正式 Release 必须等待 Android、macOS、Windows 三个平台构建成功，再统一生成 SHA-256 校验文件并发布。

## 结果

Windows 用户只需运行一个安装程序，应用能够直接访问原生窗口、托盘和快捷键能力，运行时也不依赖浏览器内核。代价是自包含安装包体积较大，且未签名 EXE 可能触发 Windows SmartScreen 提示。

Windows 的周期、重复任务、状态迁移和 SQLite 仓储语义由 Rust 共享核心提供，C# 保留薄模型适配。后续如果增加 ARM64、同步或签名，应作为独立交付决策。
