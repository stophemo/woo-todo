# 个人安装与首次使用

woo-todo 不依赖应用商店，也不要求先部署服务器。可从 [GitHub Releases](https://github.com/stophemo/woo-todo/releases) 下载双端安装包；以下文件和链接对应 `v0.1.3`。正式长期使用前仍应完成目标真机验收，并定期导出加密恢复备份。

## 1. 安装 macOS 客户端

下载 [Woo-Todo-v0.1.3-macos-arm64.zip](https://github.com/stophemo/woo-todo/releases/download/v0.1.3/Woo-Todo-v0.1.3-macos-arm64.zip)，对照 [SHA256SUMS.txt](https://github.com/stophemo/woo-todo/releases/download/v0.1.3/SHA256SUMS.txt) 校验后解压，把 `Woo Todo.app` 拖到“应用程序”。该产物只支持 Apple Silicon Mac，使用 ad-hoc 签名且没有 Apple 公证；若 Gatekeeper 阻止，进入“系统设置 → 隐私与安全性”确认本次个人启动。

需要自行构建时，要求完整 Xcode 与当前 macOS SDK/Swift 编译器匹配。仅有版本不匹配的 Command Line Tools 时不能作为 Release 构建环境：

```bash
cd macos
./scripts/package-app.sh --zip
```

自行构建的产物位于 `macos/dist/Woo Todo.app`。

首次运行后：

1. 应用只显示在菜单栏，不显示 Dock 图标；点击清单图标可选择“快速新增任务”“显示任务板”或“任务详情与统计”；
2. 默认按 `Shift + Option + 1` 从任意应用打开快速新增框；`Shift + Option + 2` 显隐任务板，`Shift + Option + 3` 切换置顶，`Shift + Option + 4` 切换穿透。四项快捷键可在“任务详情与统计 → 快捷键”自定义；
3. “始终置顶”和“毛玻璃”默认开启；菜单栏可独立开关，并可选择日常不透明度；
4. `Shift + Option + 4` 切换鼠标穿透与交互状态。开启穿透后自动使用 20% 不透明度，退出后恢复原设置；
5. 任务板右上角 `+` 新增今日任务；点击圆圈完成；双击编辑；右键删除；同一任务线内拖动待办项排序；
6. 在“任务详情与统计”管理本周、本月、闲时、历史、统计、加密备份和同步；编辑待办时可设置指定提醒时间。

## 2. 安装 Android 客户端

下载 [Woo-Todo-v0.1.3-android.apk](https://github.com/stophemo/woo-todo/releases/download/v0.1.3/Woo-Todo-v0.1.3-android.apk)，对照 [SHA256SUMS.txt](https://github.com/stophemo/woo-todo/releases/download/v0.1.3/SHA256SUMS.txt) 校验后从三星“我的文件”打开，并允许本次来源安装。连接 ADB 时也可执行：

```bash
adb install -r Woo-Todo-v0.1.3-android.apk
```

正式 APK 使用项目专用 Release 密钥签名，后续 GitHub Release 可直接覆盖升级。Debug 包与正式包签名不同，不能相互覆盖；切换前先导出加密恢复备份，再卸载旧包。

正式签名证书 SHA-256 为 `77d9b1ff936a9ea9da7ccae4360ede8f1b32b25761378826de7d812bccdba7f7`。

开发验收 APK 可从源码构建：

```bash
cd android
./gradlew testDebugUnitTest assembleDebug lintDebug
```

产物为 `android/app/build/outputs/apk/debug/app-debug.apk`。Debug APK 只适合开发期个人安装。不要清除应用数据或更换签名后直接覆盖，否则本地 SQLite、Keystore 凭据和 Widget 配置会丢失；升级前先导出加密恢复备份。

首次运行后：

1. 允许通知权限，否则 23:10 睡前规划提醒和待办定时通知不会显示；
2. 首页顶部可切换今日、明日、本周、本月和闲时；睡前选择“明日”，再点右下角 `+` 添加第二天任务；
3. 点击任务编辑，打开“在指定时间提醒”即可为该条待办设置通知时间；勾选完成，长按后在同一任务线内拖动排序；
4. “更多”中设置睡前提醒、坚果云自动同步和加密恢复备份，“统计”查看历史与履约趋势；
5. 长按三星桌面空白区域，进入“组件”，添加 Woo Todo 今日组件；组件内可查看、勾选任务，点击任务进入编辑；
6. 在系统电池设置中保持默认优化，先观察通知延迟和日耗电，不要开启前台常驻服务。

## 3. 坚果云自动同步（推荐）

不想部署 Worker 时，先安装并登录坚果云官方客户端，再按 [坚果云自动同步与通知](JIANGUOYUN_SYNC.md) 在网页安全设置中生成应用密码。推荐先在 Mac 的“任务详情与统计 → 同步 → 坚果云自动同步”填写账号与应用密码并保存；连接成功后二维码默认隐藏，需要配置手机时显式点击“显示 Android 配置二维码”。用 Android 系统扫码器扫描并选择“用 Woo Todo 打开”，确认预填配置后保存。二维码严格包含 `username`、`appPassword`、`vaultId` 和 `vaultKey`，不包含固定端点或 `deviceId`；Android 会自行生成不同于 Mac 的 `deviceId`。二维码等同完整同步凭据，只能近旁展示，用完立即隐藏，不上传 Woo Todo 服务、公开位置或日志。Woo Todo 内置 WebDAV 客户端直接连接坚果云；任务先本地保存，网络只传输加密操作对象，这条路径不要求额外服务器费用。

## 4. 加密备份与恢复

在“同步/设置”区域选择“导出加密备份”，输入并确认至少 10 个 Unicode code point 的独立口令，然后将 `.wootodo` 保存到本地归档或用户信任的网盘。恢复时只能导入空白任务库，应用会先验证文件完整性和口令，再一次性写入本地 SQLite；备份不会合并已有任务，也不能替代坚果云自动同步。

设备重装或替换前建议保留最近两到三个备份。可选的同步恢复材料只包含 Worker 身份，不包含坚果云账号、应用密码或 WebDAV 配置；它只应在原设备不再同时运行时恢复。新增并存设备请配置同一坚果云同步空间，或使用 Worker 二维码配对。完整格式、口令边界和恢复步骤见 [加密备份与恢复](BACKUP_AND_RESTORE.md)。

## 5. 自建 Worker 在线同步

明确选择自建同步服务时，再部署 Cloudflare Workers + D1。夸克网盘可保存加密文件，但不能充当在线增量同步服务。个人双端可以先使用 Cloudflare 当前免费计划，不需要购买域名；免费额度、计费和中国大陆网络可达性会变化，部署前请核对 Cloudflare Dashboard 当前政策和用量告警。

1. 注册或登录 Cloudflare 账号，确认账号可以使用 Workers 与 D1。准备 Node.js 22.18+，在仓库中安装后端依赖并登录 Wrangler：

```bash
cd backend
npm install
npx wrangler login
npx wrangler whoami
npx wrangler d1 create woo-todo
```

2. 把 `d1 create` 输出的 `database_id` 替换到 `backend/wrangler.toml` 现有 `[[d1_databases]]` 块，保持 `binding = "DB"` 和 `database_name = "woo-todo"` 不变。不要把 secrets 写进 TOML。
3. 通过交互提示写入两个 secrets，再执行远端迁移和部署：

```bash
npx wrangler secret put TOKEN_PEPPER
npx wrangler secret put VAULT_CREATION_INVITE_CODE
npx wrangler d1 migrations apply woo-todo --remote
npx wrangler deploy
```

`TOKEN_PEPPER` 使用密码管理器生成的至少 32 个字符随机值并长期保持不变；`VAULT_CREATION_INVITE_CODE` 使用 16～256 个无空格可打印 ASCII 字符，是创建同步空间的部署级门禁，不会保存在客户端，也不是两端核对的六位配对码。两个值都不要提交 Git。更完整的安全边界、额度和轮换说明见 [后端免费部署指南](../backend/README.md)。

4. `wrangler deploy` 输出的 `workers.dev` URL 就是 Worker 根地址。把实际域名替换进 `https://woo-todo-sync.example.workers.dev/health` 并确认返回 `"ok": true`，再在 Mac 的“同步”页填写根地址和邀请码创建空间，用三星系统二维码扫描器让 Android 加入并核对六位码。`127.0.0.1` 只表示当前设备，不能作为双机地址。完整步骤与排错见 [可选在线配对同步](PAIRING.md)。

## 6. 必做验收

- 坚果云配置完成后，Mac 与 Android 的新增、完成、删除和排序能在两端自动收敛；
- 暂时断网时两端仍可编辑，恢复联网后积压变化会自动发送并应用；
- 两端同时修改同一任务时，完成、Pass、删除和排序按在线同步规则收敛；
- 完成、Pass、删除和排序在重启后保持；
- 三星 Widget 在进程回收、重启、锁屏后仍能刷新；
- 睡前提醒在 Android 16 / One UI 8 的电池优化下记录实际延迟；
- macOS 快速新增、悬浮、置顶、毛玻璃、穿透和四个全局快捷键连续运行 24 小时；
- 任一端导出的恢复备份能在空白安装恢复，并确认旧设备身份不会同时活跃；
- 若启用可选在线同步，再验证不同网络下的 `/health`、二维码配对和双向增量同步。

详细矩阵见 [测试与验收](TESTING.md)。
