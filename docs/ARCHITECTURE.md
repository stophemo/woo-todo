# woo-todo 架构设计文档

## 1. 总体架构

### 1.1 系统组成

系统由三个独立进程组成，通过 WebSocket 进行实时双向同步：

- **macOS 桌面端**：Electron 主进程 + Vue 3 渲染进程，以透明悬浮窗形态运行
- **Android 移动端**：原生 Kotlin + Jetpack Compose，Material 3 设计
- **同步服务**：Node.js 轻量服务，提供 REST API 和 WebSocket 通道

### 1.2 数据流

```
[本地操作] → [本地存储] → [Sync Engine] → [WebSocket] → [Server] → [WebSocket] → [Sync Engine] → [本地存储] → [UI 更新]
```

每个客户端维护完整的本地数据副本，离线可正常工作。上线后通过增量同步合并变更。

---

## 2. macOS 桌面端设计

### 2.1 窗口架构

Electron BrowserWindow 配置：

```typescript
const mainWindow = new BrowserWindow({
  width: 320,
  height: 500,
  transparent: true,       // 窗口背景透明
  frame: false,            // 无边框
  alwaysOnTop: true,       // 默认置顶
  resizable: false,
  skipTaskbar: true,       // 不显示在 Dock
  type: 'panel',           // macOS 面板样式
  vibrancy: 'under-window', // macOS 毛玻璃效果
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

### 2.3 全局快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+Shift+T` | 切换窗口置顶 |
| `Cmd+Shift+G` | 切换透明穿透模式 |
| `Cmd+Shift+N` | 快速新增待办（自动切到交互模式） |

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
- **CSS backdrop-filter** 实现毛玻璃效果
- **IPC 通信**：主进程控制窗口属性，渲染进程通过 `contextBridge` 调用

---

## 3. Android 移动端设计

### 3.1 技术选型

| 层级 | 技术 |
|------|------|
| UI | Jetpack Compose + Material 3 |
| 本地存储 | Room Database |
| 网络 | OkHttp (REST) + Ktor Client (WebSocket) |
| 状态管理 | ViewModel + StateFlow |
| DI | Hilt |

### 3.2 数据模型

```kotlin
@Entity(tableName = "todos")
data class Todo(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val title: String,
    val completed: Boolean = false,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val syncedAt: Long = 0,
    val isDeleted: Boolean = false
)
```

### 3.3 同步策略

- Room 作为唯一数据源 (Single Source of Truth)
- 本地变更立即写入 Room，标记 `syncedAt = 0`
- SyncWorker 定期将未同步记录推送到服务器
- WebSocket 接收远程变更，写入 Room 并触发 UI 重组

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
// shared/types/todo.ts
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

---

## 6. 部署方案

### 6.1 开发环境

- macOS 端：`pnpm dev`，Vite HMR 热更新
- Server 端：`pnpm dev`，tsx watch 热重载
- Android 端：Android Studio 直接运行

### 6.2 生产部署

- **macOS 端**：electron-builder 打包为 `.dmg`
- **同步服务**：可部署到任意 VPS（2C2G 即可），或运行在 macOS 本机作为局域网服务
- **Android 端**：Gradle 构建 APK/AAB

---

## 7. 后续规划

- [ ] iOS 端支持（SwiftUI）
- [ ] 待办分类/标签
- [ ] 截止日期提醒
- [ ] iCloud 同步（替代自建服务）
- [ ] 桌面小组件 (macOS Widget)
