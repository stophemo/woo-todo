<p align="center">
  <img src="web/assets/app-icon.svg" width="72" alt="无我待办图标">
</p>

# 无我待办（Woo Todo）

> 今晚规划，明早开干。

Woo Todo 是一个为个人日常规划设计的跨端待办应用，支持 **macOS** 和 **Android**。它坚持本地优先：任务先写入设备上的 SQLite，不登录 Woo Todo 账号也能完整使用；需要跨端时，再按自己的信任边界选择同步方式。

[产品主页](https://woo-todo.vercel.app/) · [下载最新版](https://github.com/stophemo/woo-todo/releases) · [安装与首次使用](docs/INSTALLATION.md) · [问题反馈](https://github.com/stophemo/woo-todo/issues)

当前正式版：[`v0.1.9`](https://github.com/stophemo/woo-todo/releases/tag/v0.1.9)

## 适合什么场景

| 设备 | 主要体验 |
| --- | --- |
| macOS | 菜单栏常驻、可置顶/毛玻璃/鼠标穿透的悬浮任务板；支持快速新增和全局快捷键。 |
| Android | 今日、明日、周/月与闲时任务；睡前规划提醒、任务级提醒和三星桌面 Widget。 |
| 两端一起用 | 推荐使用坚果云 WebDAV 自动同步；也可以自建 Cloudflare Worker + D1 做端到端加密同步。 |

任务支持一次性与周期重复、主线/支线/外传、完成/Pass、历史和履约统计。顶部标题和副标题可使用模板变量，包含中文或英文星期、日期、耗时和截止天数；详细变量表见[产品规格](docs/PRODUCT_SPEC.md)。

## 下载与安装

以下是当前正式版的直接下载入口，校验值在同一 Release 中的 `SHA256SUMS.txt`。

| 平台 | 安装包 | 说明 |
| --- | --- | --- |
| macOS 15+、Apple Silicon | [Woo-Todo-v0.1.9-macos-arm64.zip](https://github.com/stophemo/woo-todo/releases/download/v0.1.9/Woo-Todo-v0.1.9-macos-arm64.zip) | 解压后将 `Woo Todo.app` 拖入“应用程序”。当前使用 ad-hoc 签名，未经过 Apple 公证；首次打开若被拦截，请在“系统设置 → 隐私与安全性”允许。 |
| Android 13+ | [Woo-Todo-v0.1.9-android.apk](https://github.com/stophemo/woo-todo/releases/download/v0.1.9/Woo-Todo-v0.1.9-android.apk) | 从系统文件管理器打开并允许本次来源安装；正式包使用项目长期 Release 签名。 |
| 完整性校验 | [SHA256SUMS.txt](https://github.com/stophemo/woo-todo/releases/download/v0.1.9/SHA256SUMS.txt) | 下载后可用 `shasum -a 256 <文件>` 对照。 |

macOS 客户端只显示在菜单栏，不显示 Dock 图标。Android 正式包可直接覆盖升级：保留任务、同步身份和配对状态，**普通版本更新不需要重新配对**。请不要先卸载、清除应用数据，或用不同签名的 Debug 包覆盖正式包；这些操作可能删除本地数据库/Keystore，只有在更换设备、清除数据或主动更换同步空间时才需要重新配对。

## 第一次使用

### macOS

1. 启动后点击菜单栏 Woo Todo 图标：选择“任务详情与统计…”打开任务和统计主窗口，选择独立的“设置…”管理显示、快捷键、同步等选项。
2. 在主窗口左侧，“任务与统计”用于今日、本周、本月、闲时、历史和统计；“设置”用于显示、快捷键和同步。
3. 任务板右上角 `+` 可新增任务；点击圆圈完成，双击编辑，右键删除，同一任务线内可拖动排序。

### Android

1. 首次打开后按系统提示授予通知权限；首页可切换今日、明日、本周、本月和闲时。
2. 点击右下角 `+` 新建任务；编辑任务时可设置重复规则和指定时间提醒。
3. 在“更多”中管理显示设置、提醒、备份和同步；三星设备可从桌面“组件”添加今日 Widget。

## 连接两端

不需要同步时可以跳过配对，两端仍可独立使用。需要同步时，先在 Mac 的“设置 → 同步”完成一端配置，再在 Android 首页未连接状态点击“配对”；Android 会先让你选择连接方式，不会把说明强行弹成阻塞对话框。

### 方式一：坚果云 WebDAV（推荐，不用自建服务器）

1. 在坚果云网页“账户信息 → 安全选项 → 第三方应用管理”创建应用密码，不要把网页登录密码填入 Woo Todo。
2. Mac 在“设置 → 同步 → 坚果云自动同步”填写账号和应用密码，点击保存连接，再选择“显示 Android 配置二维码”。
3. Android 点击“配对 → 扫描二维码配对”，扫描 Mac 二维码并确认预填内容；手机会生成独立设备 ID，保存后自动首次同步。
4. 没有相机或不方便扫码时，Android 选择“手动填写坚果云配置”，填写账号邮箱、应用密码、同步空间名和同步密钥；这些值必须与 Mac 完全一致。

### 方式二：自建 Worker 在线配对

1. 按[后端部署指南](backend/README.md)部署 Cloudflare Worker + D1，并确认两端都能访问 HTTPS 根地址。
2. Mac 在“设置 → 同步”页填写 Worker 根地址和创建邀请码，创建同步空间后点击“生成配对二维码”。
3. Android 点击“配对 → 扫描二维码配对”，扫描后逐位核对两端显示的六位码，再回 Mac 确认绑定。
4. 没有相机时，使用 Mac 的“复制配对链接（备用）”，通过私密渠道发送到自己的手机，在 Android 选择“配对 → 粘贴配对链接”；配对链接约 10 分钟有效。

两种方式的二维码/链接都可能包含完整同步凭据或一次性 secret，只应在两台设备旁使用，确认后立即隐藏或清理剪贴板，不要发到群聊、截图、公开仓库或日志。完整排错和撤销设备流程见[可选在线配对同步](docs/PAIRING.md)与[坚果云自动同步](docs/JIANGUOYUN_SYNC.md)。

## 更新方式

- 双端会低频检查 GitHub 最新正式 Release；检查失败不会影响本地任务。
- 发现新版本时只在菜单中留下“有新版本可用”：macOS 在菜单栏菜单，Android 在“更多”菜单。不会自动弹窗、抢占焦点、下载或安装，用户可以继续使用并自行决定何时更新。
- 菜单中的版本入口会打开 GitHub Release 下载页；“检查更新”始终保留，用户也可以随时手动检查。
- 安装到对应版本后，提示会自动消失。若 Release 页面暂时不可达，可稍后从[发布页](https://github.com/stophemo/woo-todo/releases)手动下载。

## 数据与隐私

- **任务默认只在本地**：不要求 Woo Todo 账号，应用启动和编辑不依赖网络；本地数据存储在设备 SQLite。
- **坚果云同步**：Woo Todo 直接使用 WebDAV，上传的是 AES-256-GCM 加密的增量对象，不上传 SQLite 整库或任务明文。配置二维码包含坚果云应用密码和同步密钥，应按完整凭据保护。
- **Worker 同步**：vault key 由客户端生成，Worker/D1 只保存密文和同步所需元数据，服务端不能读取任务正文。自建服务的域名、密钥和额度由部署者负责。
- **加密备份**：`.wootodo` 使用 AES-256-GCM 加密，恢复口令无法找回；备份可保存到用户信任的本地或云端位置。默认不把同步身份放入备份，替换丢失设备时才按文档谨慎恢复。
- **离线可用**：断网时两端仍可编辑，网络恢复后再发送积压变更。撤销设备会阻止后续同步，但不会远程删除该设备已经下载的本地数据。

## 技术边界

- `macos/` 是 Swift + AppKit/SwiftUI 原生客户端；`android/` 是 Kotlin + Android Views/RemoteViews 原生客户端；不引入 Electron、Flutter、WebView 运行时或 Android 前台常驻服务。
- `backend/` 是可选的 Cloudflare Workers + D1 服务；`shared/` 保存 JSON Schema、fixture 和跨端契约。三端通过 `shared/` 约定协议，不直接依赖彼此实现。
- 当前发布目标为 macOS Apple Silicon 和 Android 13+；暂不提供 iOS、Windows 或 Web 任务客户端。

## 开发

开发环境和真机验收要求见[开发指南](docs/DEVELOPMENT.md)。常用检查命令：

```bash
npm install
npm run validate:contracts
npm run test:crypto
npm run test:backend
cd android && ./gradlew testDebugUnitTest assembleDebug lintDebug
cd ../macos && swift build
```

修改共享协议时，需要同步更新 `shared/schema/`、`shared/fixtures/`、Swift/Kotlin 模型和后端校验；完整测试矩阵见[测试与验收](docs/TESTING.md)。发版和签名维护见[发版指南](docs/RELEASING.md)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [个人安装与首次使用](docs/INSTALLATION.md) | 安装、权限、备份和首次验收 |
| [产品规格](docs/PRODUCT_SPEC.md) | 任务规则、显示变量、通知和更新行为 |
| [坚果云自动同步](docs/JIANGUOYUN_SYNC.md) | 不自建服务器的跨端同步 |
| [可选在线配对同步](docs/PAIRING.md) | Worker 配对、六位核对码和撤销设备 |
| [同步与安全](docs/SYNC_AND_SECURITY.md) | 加密、凭据和服务端边界 |
| [加密备份与恢复](docs/BACKUP_AND_RESTORE.md) | `.wootodo` 格式与恢复限制 |
| [开发指南](docs/DEVELOPMENT.md) | 工具链、构建和真机测试 |
| [后端部署指南](backend/README.md) | Cloudflare Workers + D1 自托管 |
| [发版指南](docs/RELEASING.md) | CI、签名和 Release 流程 |

## 许可

[MIT License](LICENSE)
