# 无我待办（woo-todo）

一个为“今晚规划，明早开干”设计的轻量跨端待办应用，首要支持 macOS 与 Android。

## 产品原则

- **不打扰，但始终可见**：macOS 使用可置顶、可毛玻璃、可鼠标穿透的原生悬浮任务板。
- **手机负责规划**：Android 在睡前提醒规划明日任务，三星桌面 Widget 直接展示今日任务。
- **本地优先**：所有操作先落本地，断网不影响使用，联网后异步同步。
- **保持简单**：任务只有一句话；时间类型与任务级别相互独立，不引入笔记、附件和复杂项目管理。
- **资源克制**：双端原生实现，不使用 Electron、Flutter 或常驻前台服务。

## 首版能力

- 时间类型：每日、每周、每月、闲时
- 任务级别：主线、支线、外传
- 一次性任务与周期重复任务
- 完成、Pass、历史与履约统计
- macOS 原生透明悬浮任务板
- Android 桌面 Widget 与 23:10 睡前提醒
- 无传统账号的设备配对与端到端加密同步
- 加密备份导入导出，可手动保存到夸克网盘

## 新架构

| 目录 | 说明 |
|---|---|
| `macos/` | Swift + AppKit/SwiftUI 原生客户端 |
| `android/` | Kotlin + Android Views/RemoteViews 原生客户端 |
| `backend/` | Cloudflare Workers + D1 增量同步服务 |
| `shared/` | JSON Schema、跨端契约与测试样例 |
| `docs/` | 产品规格、架构、执行计划与 ADR |

## 当前阶段

`v0.1.0` 已具备自动化双端安装包发布链路。应用功能、本地/同步/备份主链路与 CI 已完成；公共同步服务尚未部署，目标真机验收和长期性能测量仍需继续。进度见 [执行计划](docs/EXECUTION_PLAN.md)。

详细文档：

- [产品规格](docs/PRODUCT_SPEC.md)
- [架构设计](docs/ARCHITECTURE.md)
- [执行计划](docs/EXECUTION_PLAN.md)
- [同步与安全](docs/SYNC_AND_SECURITY.md)
- [加密备份与恢复](docs/BACKUP_AND_RESTORE.md)
- [个人安装与首次使用](docs/INSTALLATION.md)
- [发版与签名维护](docs/RELEASING.md)

## 许可

[MIT License](LICENSE)
