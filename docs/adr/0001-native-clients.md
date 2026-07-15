# ADR-0001：双端采用原生客户端

- 状态：已接受
- 日期：2026-07-15

## 背景

应用需要在 macOS 长期显示透明悬浮窗口，并在 Samsung One UI 提供可靠的桌面 Widget。用户明确要求低内存、低 CPU 和低耗电。

## 决策

- macOS 使用 Swift + AppKit/SwiftUI。
- Android 使用 Kotlin + Android Views/RemoteViews。
- 两端不共享 UI 或运行时，只共享数据契约与测试样例。

## 结果

优点是平台能力直接、后台开销可控、安装包无需携带浏览器或跨端引擎。代价是领域逻辑需要在 Swift 和 Kotlin 各实现一次，因此必须用 JSON Schema 和 golden fixtures 保证一致。

旧 Tauri/React Native/Node.js 原型移入 `legacy/`，不再参与 v1 构建。
