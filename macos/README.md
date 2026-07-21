# Woo Todo macOS 原生客户端

这是面向 macOS Tahoe 26 的轻量原生客户端，使用 AppKit、SwiftUI 和系统 SQLite，未引入第三方运行时。Package 最低兼容 macOS 15，当前目标设备为 Apple M4 MacBook Air。

## 当前能力

- 每日、每周、每月、闲时四种时间维度；主线、支线、外传三级任务。
- 一次性与重复任务；跨周期后惰性补齐实例，未完成项自动记为 Pass。
- SQLite 本地优先仓储和今日任务 `TodayStore`。
- 透明毛玻璃 `NSPanel`、始终置顶、跨桌面空间和鼠标穿透。
- 四项可自定义全局快捷键：默认 `Shift + Option + N` 快速新增、`Shift + Option + L` 显隐任务板、`Shift + Option + T` 置顶、`Control + Option + Space` 穿透；菜单栏始终保留恢复入口。
- 今日任务新增、编辑、勾选完成、删除及同级排序基础。
- 菜单栏“任务详情与统计…”按需打开管理窗口，关闭后释放窗口资源。
- 管理窗口包含今日、本周、本月、闲时、历史和统计六个任务分区，并提供独立同步分区。
- 管理窗口的同步分区优先支持坚果云 WebDAV 自动同步，也可创建自建 Worker 加密空间并显示 Android 配对二维码与六位核对码。
- 无传统账号的设备绑定；同步凭据与 vault key 仅保存在本机 Keychain，或用户主动导出的加密备份中。
- SQLite 加密 outbox、WebDAV applied 记录、Worker 增量 cursor、幂等远端应用和 tombstone 删除同步。
- 启动、本地修改和 15 分钟低频兜底触发坚果云同步；Worker 另在系统唤醒和网络恢复时触发。失败不阻塞本地操作。
- 已绑定设备列表和远端撤销；当前设备不能撤销自身。
- 完整编辑器保持一句话任务，支持时间范围、目标周期、级别、同周期重复和任务级本地通知。
- 已结束周期履约率、主线履约率、按时间范围/级别计数和最近历史。
- 重复实例使用跨端确定性 SHA-256 UUID，避免离线设备生成重复记录。
- 同步页支持 PBKDF2 + AES-256-GCM `.wootodo` 离线接力与恢复备份；接力可合并已有库，恢复仅允许空白安装。

## 构建与测试

```bash
cd macos
swift build
swift test
swift run woo-todo-mac
```

命令行工具链与系统 SDK 必须匹配。如果机器上同时存在多套 SDK，可通过 `xcode-select` 选择已配套的 Xcode 或 Command Line Tools。

## 代码分层

- `WooTodoCore`：领域模型、周期引擎、确定性实例 ID、统计引擎、仓储协议、`TodayStore` 与 `DashboardStore`。
- `WooTodoStorage`：SQLite 表结构、迁移与仓储实现。
- `WooTodoSync`：Keychain 凭据、AES-GCM/X25519、配对深链、API 客户端、同步协调器与运行时状态机。
- `WooTodoMacApp`：AppKit 生命周期、悬浮面板、按需管理窗口、菜单栏、全局快捷键、同步运行时和 SwiftUI 界面。
- 三组测试覆盖周期边界、重复补齐、确定性 ID、统计、持久化、加密协议、同步分页与配对状态机。

应用安装后默认纯离线，不需要部署服务。跨端自动同步可直接使用坚果云 WebDAV，也可主动交换加密接力包；自建 Cloudflare Workers + D1 是另一项可选方案。GitHub Release 产物使用 ad-hoc 签名且没有 Apple 公证；macOS 与 Android 都会为设置了提醒时间的待办安排各自的本地通知。
