# 无我待办（woo-todo）

一个为“今晚规划，明早开干”设计的轻量跨端待办应用，首要支持 macOS 与 Android。

项目主页：[woo-todo.vercel.app](https://woo-todo.vercel.app) · 安装包：[GitHub Releases](https://github.com/stophemo/woo-todo/releases)

## 产品原则

- **不打扰，但始终可见**：macOS 使用可置顶、可毛玻璃、可鼠标穿透的原生悬浮任务板。
- **手机负责规划**：Android 在睡前提醒规划明日任务，三星桌面 Widget 直接展示今日任务。
- **本地优先**：安装后不注册 Woo Todo 账号，全部操作先落本地 SQLite；需要跨端自动同步时可直接使用坚果云 WebDAV，不必自建服务器。
- **保持简单**：任务只有一句话；时间类型与任务级别相互独立，不引入笔记、附件和复杂项目管理。
- **资源克制**：双端原生实现，不使用 Electron、Flutter 或常驻前台服务。

## 快速上手

### macOS

1. 启动后应用常驻菜单栏，不显示 Dock 图标；点击菜单栏的清单图标可找回任务板或打开“任务详情与统计”。
2. 菜单栏可分别开关“始终置顶”“毛玻璃”和“鼠标穿透”，并选择日常不透明度。置顶与毛玻璃默认开启。
3. 默认按 `Shift + Option + 1` 打开紧凑输入框，`Shift + Option + 2` 显隐任务板，`Shift + Option + 3` 切换置顶，`Shift + Option + 4` 切换鼠标穿透。四项快捷键都可在“任务详情与统计 → 快捷键”自定义；`Enter` 新增一条今日主线一次性任务，`Esc` 取消。
4. 任务板右上角 `+` 新增今日任务；点击圆圈完成；双击任务编辑；右键删除；同一任务线内拖动待办项排序。
5. 菜单栏选择“任务详情与统计”，可管理今日、本周、本月、闲时、历史、统计、加密备份和同步。

### Android

1. 首页顶部切换今日、明日、本周、本月和闲时；睡前选择“明日”，再点右下角 `+` 连续添加第二天任务。
2. 新建时可选择主线/支线/外传及重复方式；点击任务编辑，可打开“在指定时间提醒”并为该条待办选择时间；勾选完成，长按后在同一任务线内拖动排序。
3. “更多”中可通过“扫描 Mac 配置二维码”直接加入坚果云或 Worker 同步，也可设置 23:10 睡前规划提醒及加密恢复备份；“统计”查看历史与履约趋势。首次扫码和使用通知时分别允许相机、通知权限。
4. 长按三星桌面空白区域，进入“组件”，添加 Woo Todo 今日组件；组件内可查看、勾选任务，点击任务进入编辑。

### 坚果云自动同步（推荐跨端）

坚果云 WebDAV 不需要自建 Worker、域名或额外服务器费用，适合只想让两台设备在线自动同步的个人使用。先安装并登录坚果云官方客户端确认账号可用，再在坚果云网页的“账户信息 → 安全选项 → 第三方应用管理”创建应用密码；Woo Todo 内置 WebDAV 客户端，会直接连接坚果云完成同步。推荐先在 Mac 保存配置并点击“显示 Android 配置二维码”，再在 Android 选择“更多 → 扫描 Mac 配置二维码”。App 会预填四项配置，确认保存后生成手机独立 `deviceId` 并立即同步。二维码等同完整敏感凭据，只能在两台设备近旁展示，用完立即隐藏，不得上传或记录。完整步骤见 [坚果云自动同步与通知](docs/JIANGUOYUN_SYNC.md)。坚果云免费空间和网络可用性仍受服务商政策限制。

### 自建 Worker 同步（可选）

如果不使用坚果云，也可以自行部署 Woo Todo Worker。先注册/登录 Cloudflare 账号，在 `backend/` 用 Wrangler 创建 D1、写入两个 secrets、执行迁移并部署；无需购买域名，`workers_dev = true` 会提供 `workers.dev` 地址。完整的可执行命令、免费层额度边界和密钥安全说明见 [Cloudflare Workers + D1 免费部署指南](backend/README.md)，部署后再按 [可选在线配对同步](docs/PAIRING.md) 在 Mac 创建同步空间并用二维码加入 Android。应用未配置同步身份时不会访问 Worker；`127.0.0.1` 只表示当前设备，不能用于双机在线同步。Cloudflare 免费额度、计费政策和中国大陆网络可达性会变化，请以部署时官方 Dashboard 为准。

## 首版能力

- 时间类型：每日、每周、每月、闲时
- 任务级别：主线、支线、外传
- 一次性任务与周期重复任务
- 完成、Pass、历史与履约统计
- 每条待办的本地定时通知（macOS 与 Android）
- macOS 原生透明悬浮任务板
- Android 桌面 Widget、23:10 睡前规划提醒与任务级通知
- 坚果云 WebDAV 密文自动同步
- 可选的设备配对与端到端加密在线同步
- 加密恢复备份导入导出，可手动保存到任意文件介质
- 双端顶部标题/副标题模板与中英文星期、日期、耗时、截止天数变量
- 双端自动检查 GitHub 最新正式版，可选择更新或忽略，并支持手动检查

## 新架构

| 目录 | 说明 |
|---|---|
| `macos/` | Swift + AppKit/SwiftUI 原生客户端 |
| `android/` | Kotlin + Android Views/RemoteViews 原生客户端 |
| `backend/` | 可选 Cloudflare Workers + D1 增量同步服务 |
| `web/` | Vercel 静态产品主页 |
| `shared/` | JSON Schema、跨端契约与测试样例 |
| `docs/` | 产品规格、架构、执行计划与 ADR |

## 当前阶段

当前已发布版本为 [`v0.1.7`](https://github.com/stophemo/woo-todo/releases/tag/v0.1.7)，包含 Android 启动闪退热修复、Android App 内扫码配对、可扩展顶部模板和双端更新提醒。版本 tag 推送后由 GitHub Actions 自动生成并验证双端安装包；进度见 [执行计划](docs/EXECUTION_PLAN.md)。

详细文档：

- [产品规格](docs/PRODUCT_SPEC.md)
- [架构设计](docs/ARCHITECTURE.md)
- [执行计划](docs/EXECUTION_PLAN.md)
- [同步与安全](docs/SYNC_AND_SECURITY.md)
- [加密备份与恢复](docs/BACKUP_AND_RESTORE.md)
- [个人安装与首次使用](docs/INSTALLATION.md)
- [坚果云自动同步与通知](docs/JIANGUOYUN_SYNC.md)
- [可选在线配对同步](docs/PAIRING.md)
- [发版与签名维护](docs/RELEASING.md)

## 许可

[MIT License](LICENSE)
