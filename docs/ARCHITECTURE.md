# woo-todo v1 架构设计

## 1. 总体原则

v1 采用“双原生、共协议、不共享运行时”：macOS 与 Android 分别使用平台原生技术，只共享 JSON 数据契约、加密格式和跨端测试样例。

```text
Android 本地 SQLite ─┐                         ┌─ macOS 本地 SQLite
                     ├─ HTTPS 增量同步 API ───┤
Android Keystore ────┘    Worker + D1         └─ macOS Keychain
                           只保存密文
```

所有 UI 始终读取本地数据库。网络请求失败只会延迟同步，不会阻塞用户操作。

## 2. 客户端

### 2.1 macOS

- Swift 6、AppKit 为应用壳与悬浮窗口基础。
- SwiftUI 只用于适合声明式实现的管理页面和统计图表。
- `NSPanel`：无边框悬浮任务板。
- `NSVisualEffectView`：系统原生毛玻璃。
- `ignoresMouseEvents`：鼠标穿透。
- Carbon Hot Key：无需常驻事件轮询的全局快捷键。
- SQLite：任务、重复规则、同步 outbox 和游标。
- Keychain：设备令牌与同步空间密钥。

静态面板不使用持续动画或高频定时器。同步只在本地修改、启动、唤醒、网络恢复和低频兜底时触发。

### 2.2 Android

- Kotlin、Android Views/XML 与 RecyclerView。
- `AppWidgetProvider + RemoteViews`：由 Launcher 托管的今日 Widget。
- Room/SQLite：本地数据唯一来源。
- WorkManager：可延迟的低频同步；不启用前台服务。
- AlarmManager/广播接收器：本地睡前提醒和重启恢复。
- Android Keystore：包装同步空间密钥与设备令牌。

Widget 进程可随时被系统回收，所有展示状态必须能从本地数据库重建。

## 3. 领域层

### 3.1 实体

- `TaskOccurrence`：某一周期内可完成或 Pass 的历史单位，携带当期标题、级别和重复快照。
- `seriesId`：串联同一重复序列；下一实例由上一实例在结算时惰性生成。
- `OutboxOperation`：尚未被服务端确认的加密变更。
- `SyncState`：设备 ID、同步游标、Lamport 时钟和最后同步状态。

首版不维护独立 `TaskRule` 表。修改一个待办实例只影响它及之后由它生成的实例，不回写已经结束的历史；这样可保持一句话任务模型简单，并减少离线规则合并的歧义。

### 3.2 周期键

- 日：`YYYY-MM-DD`
- 周：ISO week，例如 `2026-W29`
- 月：`YYYY-MM`
- 闲时：`someday`

周期运算以同步空间固定时区执行。跨端通过 `shared/fixtures/period-cases.json` 验证同一输入产生同一结果。

## 4. 同步

同步服务使用 Cloudflare Workers + D1，只提供 REST 接口：

- `GET /health`
- `POST /v1/vaults`
- `POST /v1/pairings`
- `POST /v1/pairings/:id/claim`
- `POST /v1/pairings/:id/confirm`
- `POST /v1/sync`
- `DELETE /v1/devices/:id`

`POST /v1/sync` 在一次请求中上传本地 outbox，并从游标之后拉取远端变更。服务端用 `op_id` 保证重试幂等，成功写入后分配单调递增序号作为新游标。

正文由客户端加密，服务端只能看到：同步空间、设备、实体 ID、操作 ID、逻辑时钟、密文大小和变更序号。

冲突规则：

- 不同实体直接合并。
- 删除使用终态 tombstone，旧设备即使提高 Lamport 也不能用同一 ID 复活任务。
- pending 与已结算快照冲突时保留完整的已结算快照，版本水位推进到较大值。
- 截止前的 completed 与 Pass 冲突时 completed 状态优先，其他字段取 LWW 快照。
- 同一状态及其余冲突使用 `(lamport, device_id)` 做确定性 LWW。
- 周期自动 Pass 使用确定性操作 ID，避免双端重复结算。
- 周期是左闭右开区间，只有严格早于周期结束瞬间的完成才优先于自动 Pass。

## 5. 安全

- HTTPS/TLS 保护传输。
- 任务 payload 使用 AES-256-GCM 加密。
- 设备配对使用 10 分钟一次性会话、X25519 临时密钥和人工短码核对。
- 服务端只保存设备令牌哈希，不保存原始令牌和同步空间密钥。
- `vault_key` 只进入 Keychain/Keystore 和用户主动导出的加密恢复包。
- 丢失全部设备且没有恢复材料时无法恢复数据，这是端到端加密的预期边界。

## 6. 备份

任一客户端都可导出 `.wootodo` 加密包，包含协议版本、加密快照与校验信息。夸克网盘用于手动保存该文件，不参与数据库实时同步。

备份口令经 NFKC 与 PBKDF2-HMAC-SHA256（默认 210000 轮）派生 AES-256-GCM 密钥。解密正文包含任务快照与可选同步恢复凭据；导入只允许空白安装，避免合并两个 vault 或复制活跃设备身份。完整操作说明见 [加密备份与恢复](BACKUP_AND_RESTORE.md)。

## 7. 性能预算

- macOS Release：空闲 RSS 目标不超过 60MB、硬上限 100MB；30 分钟平均 CPU 不超过 0.3%。
- Android：无前台服务、无主动常驻进程；典型使用额外耗电目标不超过 0.5%/天。
- Widget 操作本地反馈不超过 1 秒。
- 无变更时不高频轮询；典型个人使用同步流量不超过 1MB/天。

性能预算必须在目标真机上以 Release 构建测量，Debug 数据不作为结论。

## 8. 旧原型

`legacy/` 保存迁移前的 Tauri/React Native/Node.js 实验代码。它不属于 v1 构建，不得被新客户端或同步服务依赖；完成首个稳定版本后可单独删除。
