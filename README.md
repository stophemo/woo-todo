# 无我待办 (woo-todo)

跨端透明桌面待办应用 — macOS 桌面悬浮 + Android 移动端，实时双向同步。

## 设计理念

**不打扰，但随时可见。** macOS 端以透明悬浮窗形式浮于桌面顶层，支持鼠标穿透模式——看到待办但不阻挡任何操作。需要编辑时一键切换为交互模式。Android 端保持数据同步，出门在外也能查看和编辑。

## 架构概览

```
┌──────────────────┐       ┌──────────────┐       ┌──────────────────┐
│   macOS 桌面端    │◄─────►│  Sync Server  │◄─────►│  Android 移动端   │
│ Electron + Vue 3 │  WS   │  Node.js      │  WS   │ Kotlin + Compose │
│ 透明悬浮 · 穿透   │       │  SQLite       │       │ Material 3 · Room │
└──────────────────┘       └──────────────┘       └──────────────────┘
```

## 功能矩阵

| 功能 | macOS | Android |
|------|-------|---------|
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

### macOS 桌面端

```bash
cd macos
pnpm install
pnpm dev        # 开发模式
pnpm build      # 构建生产包
```

### 同步服务

```bash
cd server
pnpm install
pnpm dev        # 启动同步服务 (localhost:3001)
```

### Android 移动端

用 Android Studio 打开 `android/` 目录，同步 Gradle 后运行。

## 项目结构

```
woo-todo/
├── macos/          # Electron + Vue 3 桌面端
│   ├── electron/   # Electron 主进程（透明窗口、快捷键）
│   └── src/        # Vue 3 渲染进程（待办 UI）
├── android/        # Kotlin + Jetpack Compose 移动端
├── server/         # Node.js 同步服务
├── shared/         # 共享类型定义
└── docs/           # 设计文档
```

## 技术栈

- **macOS**: Electron 28+ / Vue 3 / TypeScript / Vite
- **Android**: Kotlin / Jetpack Compose / Room / OkHttp / Ktor WebSocket
- **Server**: Node.js / Express / ws / better-sqlite3
- **Sync**: WebSocket 实时推送 + REST 全量拉取，时间戳版本冲突解决

---

详细设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
