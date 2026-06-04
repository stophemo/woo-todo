# woo-todo 架构设计文档

## 1. 总体架构

### 1.1 系统组成

系统由三个独立进程组成，通过 WebSocket 进行实时双向同步：

- **桌面端**：Electron 主进程 + Vue 3 渲染进程，以透明悬浮窗形态运行。跨 macOS、Windows、Linux，优先支持 macOS
- **移动端**：Flutter 框架，Material 3 设计。跨 Android、HarmonyOS、iOS，优先支持 Android
- **同步服务**：Node.js 轻量服务，提供 REST API 和 WebSocket 通道

### 1.2 数据流

```
[本地操作] → [本地存储] → [Sync Engine] → [WebSocket] → [Server] → [WebSocket] → [Sync Engine] → [本地存储] → [UI 更新]
```

每个客户端维护完整的本地数据副本，离线可正常工作。上线后通过增量同步合并变更。

### 1.3 跨平台策略

| 端 | 框架 | 优先目标 | 扩展目标 |
|---|---|---|---|
| 桌面端 | Electron + Vue 3 + TypeScript | macOS (Apple Silicon) | Windows, Linux |
| 移动端 | Flutter + Dart | Android | HarmonyOS (OpenHarmony), iOS |
| 服务端 | Node.js + Express + SQLite | — | — |

---

## 2. 桌面端设计

### 2.1 窗口架构

Electron BrowserWindow 配置 — 跨 macOS/Windows/Linux 统一接口：

```typescript
const mainWindow = new BrowserWindow({
  width: 320,
  height: 500,
  transparent: true,       // 窗口背景透明
  frame: false,            // 无边框（跨平台有效）
  alwaysOnTop: true,       // 默认置顶
  resizable: false,
  skipTaskbar: true,       // 不显示在任务栏/Dock
  type: process.platform === 'darwin' ? 'panel' : 'toolbar',
  vibrancy: process.platform === 'darwin' ? 'under-window' : undefined,
  webPreferences: {
    preload: path.join(__dirname, 'preload.js'),
    nodeIntegration: false,
    contextIsolation: true,
  },
})
```

### 2.2 双模式设计

#### 透明穿透模式 (Transparent Passthrough)
- `mainWindow.setIgnoreMouseEvents(true, { forward: true })`
- 窗口浮于最顶层，但所有鼠标事件穿透到下层应用
- 仅显示待办文字，无任何交互元素
- 适合日常工作状态，不干扰任何操作

#### 普通交互模式 (Normal Interaction)
- `mainWindow.setIgnoreMouseEvents(false)`
- 窗口可接收鼠标事件，支持完整交互
- 显示勾选框、输入框、删除按钮
- 通过全局快捷键或托盘菜单切换

### 2.3 全局快捷键（macOS 优先）

| 快捷键 | 功能 |
|--------|------|
| `Cmd+Shift+T` | 切换窗口置顶 |
| `Cmd+Shift+G` | 切换透明穿透模式 |
| `Cmd+Shift+N` | 快速新增待办（自动切到交互模式） |

> Windows 对应快捷键：`Ctrl+Shift+T`, `Ctrl+Shift+G`, `Ctrl+Shift+N`

### 2.4 UI 布局

```
┌──────────────────────────┐
│  woo-todo           ⚙ ✕  │  ← 标题栏（穿透模式下隐藏）
├──────────────────────────┤
│                          │
│  ☐ 完成 Q3 报告           │
│  ☑ 回复邮件（已勾选）      │  ← 划线灰色
│  ☐ 提交代码 review         │
│  ☐ 买咖啡                 │
│                          │
│  ──────────────────────  │
│  [添加新待办...    ] [+]  │  ← 输入区域（穿透模式下隐藏）
└──────────────────────────┘
```

穿透模式下，仅显示待办文字（白/灰色），其余区域完全透明。

### 2.5 技术要点

- **Vue 3 Composition API** + `ref`/`reactive` 管理状态
- **electron-store** 持久化本地设置
- **CSS backdrop-filter** 实现毛玻璃效果（macOS） / 降级为纯色背景（Windows）
- **IPC 通信**：主进程控制窗口属性，渲染进程通过 `contextBridge` 调用
- **平台差异处理**：快捷键修饰键 (`Cmd` vs `Ctrl`)、窗口行为、视觉风格

---

## 3. 移动端设计

### 3.1 技术选型

| 层级 | 技术 | 说明 |
|------|------|------|
| UI 框架 | Flutter 3.2+ | 一套代码跨 Android / HarmonyOS / iOS |
| 状态管理 | Provider + ChangeNotifier | 轻量级，适合中等复杂度应用 |
| 本地存储 | sqflite | SQLite 封装，跨平台统一 |
| 网络 (REST) | http | Dart 官方 HTTP 客户端 |
| 网络 (WS) | web_socket_channel | WebSocket 客户端 |
| 平台适配 | Flutter Platform Channels | 需要平台原生能力时使用 |

### 3.2 数据模型

```dart
class Todo {
  final String id;
  final String title;
  final bool completed;
  final int createdAt;
  final int updatedAt;
  final bool isDeleted;

  // 与 shared/types/todo.ts 保持字段完全一致
  // 通过 toJson()/fromJson() 实现与服务器格式兼容
}
```

### 3.3 同步策略

- sqflite 作为唯一数据源 (Single Source of Truth)
- 本地变更立即写入数据库
- WebSocket 接收远程推送 + REST 定期拉取增量
- LWW (Last-Write-Wins) 冲突策略
- 离线队列：网络不可用时暂存变更，恢复后批量提交

### 3.4 平台适配

| 能力 | Android | HarmonyOS | iOS |
|------|---------|-----------|-----|
| Material 3 主题 | ✓ | ✓ | ✓ |
| 本地 SQLite | ✓ | ✓ | ✓ |
| 网络请求 | ✓ | ✓ | ✓ |
| WebSocket | ✓ | ✓ | ✓ |
| 后台同步 | WorkManager | 待适配 | BackgroundTasks |

---

## 4. 同步服务设计

### 4.1 API 设计

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/todos?since={timestamp}` | 获取增量变更 |
| POST | `/api/todos` | 批量提交变更 |
| PUT | `/api/todos/:id` | 更新单条待办 |
| DELETE | `/api/todos/:id` | 软删除待办 |
| WS | `/ws` | WebSocket 实时通道 |

### 4.2 冲突解决

采用 **Last-Write-Wins (LWW)** 策略：
- 每条记录携带 `updatedAt` 时间戳
- 服务器接收时比较时间戳，保留更新的版本
- 客户端同步后以服务器数据为准

### 4.3 数据存储

SQLite 表结构：

```sql
CREATE TABLE todos (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  completed INTEGER DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  is_deleted INTEGER DEFAULT 0
);

CREATE INDEX idx_todos_updated ON todos(updated_at);
```

### 4.4 WebSocket 协议

```
客户端 → 服务器:
  { type: "sync", todos: [...], lastSyncAt: 1234567890 }

服务器 → 客户端:
  { type: "update", todos: [...], serverTime: 1234567890 }
  { type: "ack", syncedIds: [...], serverTime: 1234567890 }
```

---

## 5. 共享类型定义

```typescript
// shared/types/todo.ts — 桌面端与移动端共享的数据契约
interface Todo {
  id: string
  title: string
  completed: boolean
  createdAt: number
  updatedAt: number
  isDeleted: boolean
}

interface SyncPayload {
  type: 'sync' | 'update' | 'ack'
  todos: Todo[]
  lastSyncAt?: number
  serverTime: number
  syncedIds?: string[]
}
```

> 移动端 Dart 的 `Todo.toJson()` / `Todo.fromJson()` 与此结构保持严格一致。

---

## 6. 部署方案

### 6.1 开发环境

- **桌面端**：`cd desktop && pnpm dev`，Vite HMR 热更新
- **移动端**：`cd mobile && flutter run`，支持 hot reload
- **Server 端**：`cd server && pnpm dev`，tsx watch 热重载

### 6.2 生产部署

- **桌面端**：electron-builder 打包 `.dmg`(macOS) / `.exe`(Win) / `.AppImage`(Linux)
- **移动端**：Flutter build — APK/AAB(Android) / HAP(HarmonyOS) / IPA(iOS)
- **同步服务**：可部署到任意 VPS (2C2G)，或运行在局域网内作为个人同步节点

---

## 7. 后续规划

- [ ] Windows 桌面端适配（快捷键、视觉效果降级方案）
- [ ] HarmonyOS 端适配（OpenHarmony Flutter 引擎）
- [ ] iOS 端发布
- [ ] 待办分类/标签
- [ ] 截止日期提醒
- [ ] iCloud / WebDAV 同步（替代自建服务）
- [ ] 桌面小组件 (macOS Widget)
