# ADR-0001：双端采用原生客户端

- 状态：已接受；领域逻辑共享方式由 ADR-0004 修订
- 日期：2026-07-15

## 背景

应用需要在 macOS 长期显示透明悬浮窗口，并在 Samsung One UI 提供可靠的桌面 Widget。用户明确要求低内存、低 CPU 和低耗电。

## 决策

- macOS 使用 Swift + AppKit/SwiftUI。
- Android 使用 Kotlin + Android Views/RemoteViews。
- 两端不共享 UI 运行时；领域、仓储语义和通知计划按 ADR-0004 渐进迁移到 Rust 共享核心。

## 结果

优点是平台能力直接、后台开销可控、安装包无需携带浏览器或跨端引擎。原决策要求 Swift 和 Kotlin 分别维护领域逻辑；ADR-0004 已将这部分调整为共享 Rust 核心，迁移期间继续用 JSON Schema 和 golden fixtures 保证一致。

旧 Tauri/React Native/Node.js 原型停止维护并从仓库移除。
