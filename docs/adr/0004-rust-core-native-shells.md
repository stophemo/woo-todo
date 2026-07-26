# ADR-0004：Rust 共享核心与三端原生外壳

- 状态：已接受
- 日期：2026-07-26
- 修订：ADR-0001、ADR-0003 中“领域逻辑分别维护”的部分

## 背景

Woo Todo 同时要求轻量、高性能、交互优雅，以及 macOS、Android、Windows 的可靠系统通知。AppKit/SwiftUI、Android Views/RemoteViews、WPF/Win32 能直接覆盖悬浮窗口、Widget、托盘、全局快捷键和通知生命周期；但继续用 Swift、Kotlin、C# 各写一份周期、重复、结算和统计逻辑，会扩大行为漂移与测试成本。

Tauri 2 能共享 Web 前端和 Rust 后端，但 WebView 仍会改变桌面端的内存基线、输入与窗口语义，也不能消除 Android Widget、AlarmManager、macOS `NSPanel`、Windows 托盘等原生实现。因此它不作为本项目的 UI 运行时。

## 决策

- `shared/core-rust/` 是跨端领域核心，负责任务校验、周期计算、重复实例 ID、幂等结算、统计、SQLite 仓储语义和稳定通知计划。
- 核心通过窄 C ABI 暴露 UTF-8 JSON 请求/响应；外壳不直接依赖 Rust 内部类型，也不让 Rust 持有平台 UI 对象。
- macOS 继续使用 Swift + AppKit/SwiftUI，Android 继续使用 Kotlin + Views/RemoteViews，Windows 继续使用 C# + WPF/Win32。
- 原生外壳负责 UI、应用生命周期、安全存储、权限、通知的系统调度与展示、Widget、托盘、快捷键和平台更新流程。
- 通知采用两阶段模型：Rust 只生成包含稳定 ID、触发日期时间和 deep link 的计划；各端使用 `UNUserNotificationCenter`、`AlarmManager`/`NotificationManager`、Windows Toast Scheduler 执行。
- 本地 SQLite 仍是 UI 的唯一数据来源，网络同步不得成为用户操作前置条件；Rust 共享不改变端到端加密与云端不接触明文的边界。
- 不引入 Electron、Flutter、React Native、Tauri/WebView UI 运行时或 Android 前台常驻服务。

## 迁移方式

迁移按能力切片进行，不重写已经稳定的原生 UI：

1. Windows 先以 C# 薄适配层消费 Rust 领域、仓储和通知计划，验证 ABI、动态库打包与系统通知链路。
2. macOS 与 Android 保留现有生产实现，同时用同一 fixture 和 Rust 测试锁定行为；随后分别接入 Swift C interop 与 Kotlin/JNI 薄绑定。
3. 每迁移一项能力，先做旧实现与 Rust 的等价测试，再切换调用方，最后删除对应的重复领域实现。
4. 同步、Keychain/Keystore、Widget 和平台通知调度始终留在原生层，不作为共享核心迁移目标。

## 结果

领域规则只维护一份，三端仍保留直接使用系统能力的交互质量和后台可靠性。代价是发布流程需要为各目标架构构建并打包 Rust 库，FFI 必须保持内存所有权、JSON 字段和错误语义稳定；macOS 与 Android 完成渐进迁移前还需运行双实现一致性测试。
