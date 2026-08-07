# Woo Todo macOS 原生客户端

这是面向 macOS Tahoe 26 的轻量原生客户端，使用 AppKit、SwiftUI 和系统 SQLite，未引入第三方运行时。Package 最低兼容 macOS 15，当前目标设备为 Apple M4 MacBook Air。

## 当前能力

- 每日、每周、每月、闲时四种时间维度；主线、支线、外传三级任务。
- 一次性与重复任务；一次性任务跨周期保留到完成或手动 Pass，重复实例跨周期后惰性补齐并自动结算。
- SQLite 本地优先仓储和今日任务 `TodayStore`。
- 透明毛玻璃 `NSPanel` 默认作为桌面层小组件，跨桌面空间并记住位置；也可切换为普通或始终置顶任务板，并支持鼠标穿透。
- 七项可自定义全局快捷键：默认 `Shift + Option + 1` 快速新增、`Shift + Option + 2` 显隐任务板、`Shift + Option + 3` 穿透、`Shift + Option + 4` 置顶、`Shift + Option + 5` 小组件模式、`Shift + Option + ↑/↓` 增减透明度；菜单栏始终保留恢复入口。
- 桌面小组件可直接点击勾选完成任务，也可拖动右下角自定义宽高，并自动保存位置与尺寸。
- 今日任务新增、编辑、勾选完成、删除及同级排序基础。
- 菜单栏“任务详情与统计…”按需打开管理窗口，关闭后释放窗口资源。
- 管理窗口包含今日、本周、本月、闲时、历史和统计六个任务分区，并提供独立同步分区。
- 管理窗口的同步分区支持同一网络、第三方 WebDAV 和自建 Worker 三种互斥方式，可显示 Android 配置或配对二维码。
- 无传统账号的设备绑定；自建服务和同一网络的凭据保存在本机 Keychain，第三方 WebDAV 完整配置以本机 AES-256-GCM 加密文件保存并自动回填。
- SQLite 加密 outbox、WebDAV applied 记录、Worker 增量 cursor、幂等远端应用和 tombstone 删除同步。
- 启动、本地修改和 15 分钟低频兜底触发同步；系统唤醒和网络恢复时也会继续积压任务。失败不阻塞本地操作。
- 同一网络与自建服务提供已绑定设备列表和远端撤销；第三方 WebDAV 通过服务商的应用密码或访问令牌管理设备权限。
- 完整编辑器保持一句话任务，支持时间范围、目标周期、级别、同周期重复和任务级本地通知。
- 已结束周期履约率、主线履约率、按时间范围/级别计数和最近历史。
- 重复实例使用跨端确定性 SHA-256 UUID，避免离线设备生成重复记录。

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
- `WooTodoSync`：Keychain 与本机加密凭据、AES-GCM/X25519、配对深链、API 客户端、同步协调器与运行时状态机。
- `WooTodoMacApp`：AppKit 生命周期、悬浮面板、按需管理窗口、菜单栏、全局快捷键、同步运行时和 SwiftUI 界面。
- 三组测试覆盖周期边界、重复补齐、确定性 ID、统计、持久化、加密协议、同步分页与配对状态机。

任务始终先保存到本地，不需要网络或同步服务即可使用。同一网络内可由 Mac/Windows 承载同步；跨网络可使用任意兼容的第三方 HTTPS WebDAV，或自行部署 Cloudflare Workers + D1。macOS 通过 Sparkle 的 Ed25519 签名源完成应用内更新；GitHub Release 在未配置 Developer ID 时仍使用 ad-hoc 签名且没有 Apple 公证，因此自建服务或同一网络身份在更新后可能再次请求 Keychain 授权。WebDAV 配置不依赖 Keychain，首次从旧版本迁移后会直接从本机加密文件回填。macOS 与 Android 都会为设置了提醒时间的待办安排各自的本地通知。
