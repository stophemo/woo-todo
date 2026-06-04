# 无我待办 (woo-todo)

跨端透明桌面待办应用 — 桌面端悬浮窗 + 移动端全功能，实时双向同步。

## 设计理念

**不打扰，但随时可见。** 桌面端以透明悬浮窗形式浮于顶层，支持鼠标穿透模式——看到待办但不阻挡任何操作。需要编辑时一键切换交互模式。移动端数据实时同步，出门在外也能查看和编辑。

## 平台支持

| 端 | 框架 | 优先支持 | 后续扩展 |
|---|---|---|---|
| 桌面端 | Electron + Vue 3 | macOS | Windows, Linux |
| 移动端 | Flutter | Android | HarmonyOS, iOS |
| 服务端 | Node.js | — | — |

## 架构概览

```
┌──────────────────┐       ┌──────────────┐       ┌──────────────────┐
│     桌面端        │◄─────►│  Sync Server  │◄─────►│     移动端        │
│ Electron + Vue 3 │  WS   │  Node.js      │  WS   │     Flutter      │
│ macOS / Win      │       │  SQLite       │       │ Android · 鸿蒙   │
│ 透明悬浮 · 穿透   │       │               │       │ iOS              │
└──────────────────┘       └──────────────┘       └──────────────────┘
```

## 功能矩阵

| 功能 | 桌面端 | 移动端 |
|------|--------|--------|
| 透明悬浮显示 | ✓ | - |
| 鼠标穿透模式 | ✓ | - |
| 窗口置顶 | ✓ | - |
| 全局快捷键 | ✓ | - |
| 新增待办 | ✓ | ✓ |
| 勾选完成 | ✓ | ✓ |
| 删除待办 | ✓ | ✓ |
| 离线使用 | ✓ | ✓ |
| 实时双向同步 | ✓ | ✓ |

## 快速开始

### 桌面端

```bash
cd desktop
pnpm install
pnpm dev        # 开发模式 (Vite HMR)
pnpm build      # 构建生产包
```

### 移动端

```bash
cd mobile
flutter pub get
flutter run      # 连接设备运行
```

### 同步服务

```bash
cd server
pnpm install
pnpm dev        # 启动同步服务 (localhost:3001)
```

## 项目结构

```
woo-todo/
├── desktop/        # Electron + Vue 3 桌面端
│   ├── electron/   # Electron 主进程（透明窗口、快捷键）
│   └── src/        # Vue 3 渲染进程（待办 UI）
├── mobile/         # Flutter 移动端 (Android · HarmonyOS · iOS)
│   ├── lib/        # Dart 源码
│   ├── android/    # Android 平台配置
│   ├── ios/        # iOS 平台配置
│   └── ohos/       # HarmonyOS 平台配置
├── server/         # Node.js 同步服务
├── shared/         # 共享类型定义
└── docs/           # 设计文档
```

## 技术栈

- **桌面端**: Electron 28+ / Vue 3 / TypeScript / Vite — 跨 macOS, Windows, Linux
- **移动端**: Flutter 3.2+ / Dart — 跨 Android, HarmonyOS, iOS
- **服务端**: Node.js / Express / ws / better-sqlite3
- **同步**: WebSocket 实时推送 + REST 增量拉取，时间戳版本冲突解决

---

详细设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
