# ADR-0003：Windows 使用 Rust、windows-rs 与 Win32

- 状态：已接受；2026-07-27 修订 Windows UI 与发布技术栈
- 日期：2026-07-24
- 修订：ADR-0004 中 Windows 使用 C# 薄适配层的部分

## 背景

项目需要支持 Windows 桌面环境，同时继续满足悬浮任务板、系统托盘、全局快捷键、本地优先和低常驻开销要求。早期 WPF 自包含交付需要携带 .NET 桌面运行时，安装包体积明显高于 macOS 与 Android；这与轻量目标不一致。

Windows 所需的窗口、控件、托盘、全局快捷键、鼠标穿透、单实例和 Toast 都能由 Win32/WinRT 直接提供。共享领域和 SQLite 仓储本身已经是 Rust，因此 Windows 外壳改为 Rust 后也不再需要跨语言 FFI、JSON 编解码与动态库生命周期层。

## 决策

- Windows 客户端使用 Rust、`windows-rs`/`windows-sys`、Win32 和 WinRT，不引入 .NET、Electron、WebView 或跨端 UI 框架。
- `windows` crate 直接依赖 `shared/core-rust`，以 Rust 类型调用任务、统计、SQLite 仓储和通知计划能力。
- 本地 SQLite 是 Windows UI 的唯一数据来源，固定路径为 `%LOCALAPPDATA%\Woo Todo\woo-todo.sqlite3`；用户操作不以网络同步为前置条件。
- 保持旧 `%LOCALAPPDATA%\Woo Todo\settings.json` 的 PascalCase 字段兼容，覆盖升级不改变用户任务、窗口位置、透明度、置顶或穿透设置。
- 透明度与鼠标穿透是独立状态；透明度范围为 35%～100%，切换穿透不得隐式改写透明度。
- 首个交付目标固定为 Windows 10 build 19041 及以上的 x64；Release 使用 MSVC 目标并静态链接 CRT。
- GitHub Actions 在 Windows Runner 上执行 Cargo 格式、测试、Clippy 与 Release 构建。
- GitHub Release 只提供包含单个原生 `WooTodo.exe` 的 x64 ZIP，目标机器不需要安装 Woo Todo、.NET 或 Visual C++ Runtime。
- 首次运行在当前用户范围创建 AppUserModelID 开始菜单身份并注册 `wootodo://` 协议，以保留 Toast 展示和点击激活；移动程序后再次运行会刷新路径。
- 首版不提供 ARM64 原生包、代码签名、在线同步或加密备份。
- 正式 Release 必须等待 Android、macOS、Windows 三个平台构建成功，再统一生成 SHA-256 校验文件并发布。

## 结果

Windows 用户解压 ZIP 后即可直接运行，应用直接访问系统窗口、托盘、快捷键和通知能力；发布文件不携带 .NET 桌面运行时，进程也没有 CLR 或浏览器内核基线。

代价是没有卸载器；直接删除程序不会自动清理首次运行创建的开始菜单入口和当前用户协议注册。UI 控件、布局、DPI、IME、辅助功能和消息生命周期也需要在 Win32 层显式处理，Windows 真机测试的重要性更高。后续增加 ARM64、同步、签名或更复杂的无障碍支持，应作为独立交付决策。
