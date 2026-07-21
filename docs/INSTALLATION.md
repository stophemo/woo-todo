# 个人安装与首次使用

woo-todo 不依赖应用商店，也不要求先部署服务器。可从 [GitHub Releases](https://github.com/stophemo/woo-todo/releases) 下载双端安装包；以下文件和链接对应 `v0.1.2`。正式长期使用前仍应完成目标真机验收，并定期导出加密恢复备份。

## 1. 安装 macOS 客户端

下载 [Woo-Todo-v0.1.2-macos-arm64.zip](https://github.com/stophemo/woo-todo/releases/download/v0.1.2/Woo-Todo-v0.1.2-macos-arm64.zip)，对照 [SHA256SUMS.txt](https://github.com/stophemo/woo-todo/releases/download/v0.1.2/SHA256SUMS.txt) 校验后解压，把 `Woo Todo.app` 拖到“应用程序”。该产物只支持 Apple Silicon Mac，使用 ad-hoc 签名且没有 Apple 公证；若 Gatekeeper 阻止，进入“系统设置 → 隐私与安全性”确认本次个人启动。

需要自行构建时，要求完整 Xcode 与当前 macOS SDK/Swift 编译器匹配。仅有版本不匹配的 Command Line Tools 时不能作为 Release 构建环境：

```bash
cd macos
./scripts/package-app.sh --zip
```

自行构建的产物位于 `macos/dist/Woo Todo.app`。

首次运行后：

1. 应用只显示在菜单栏，不显示 Dock 图标；点击清单图标可选择“快速新增任务”“显示任务板”或“任务详情与统计”；
2. 默认按 `Shift + Option + N` 从任意应用打开快速新增框；`Shift + Option + L` 显隐任务板，`Shift + Option + T` 切换置顶，`Control + Option + Space` 切换穿透。四项快捷键可在“任务详情与统计 → 快捷键”自定义；
3. “始终置顶”和“毛玻璃”默认开启；菜单栏可独立开关，并可选择日常不透明度；
4. `Control + Option + Space` 切换鼠标穿透与交互状态。开启穿透后自动使用 20% 不透明度，退出后恢复原设置；
5. 任务板右上角 `+` 新增今日任务；点击圆圈完成；双击编辑；右键删除；同一任务线内拖动待办项排序；
6. 在“任务详情与统计”管理本周、本月、闲时、历史、统计、离线接力、恢复备份和同步；编辑待办时可设置指定提醒时间。

## 2. 安装 Android 客户端

下载 [Woo-Todo-v0.1.2-android.apk](https://github.com/stophemo/woo-todo/releases/download/v0.1.2/Woo-Todo-v0.1.2-android.apk)，对照 [SHA256SUMS.txt](https://github.com/stophemo/woo-todo/releases/download/v0.1.2/SHA256SUMS.txt) 校验后从三星“我的文件”打开，并允许本次来源安装。连接 ADB 时也可执行：

```bash
adb install -r Woo-Todo-v0.1.2-android.apk
```

正式 APK 使用项目专用 Release 密钥签名，后续 GitHub Release 可直接覆盖升级。Debug 包与正式包签名不同，不能相互覆盖；切换前先导出 `.wootodo`，再卸载旧包。

正式签名证书 SHA-256 为 `77d9b1ff936a9ea9da7ccae4360ede8f1b32b25761378826de7d812bccdba7f7`。

开发验收 APK 可从源码构建：

```bash
cd android
./gradlew testDebugUnitTest assembleDebug lintDebug
```

产物为 `android/app/build/outputs/apk/debug/app-debug.apk`。Debug APK 只适合开发期个人安装。不要清除应用数据或更换签名后直接覆盖，否则本地 SQLite、Keystore 凭据和 Widget 配置会丢失；升级前先导出 `.wootodo`。

首次运行后：

1. 允许通知权限，否则 23:10 睡前规划提醒和待办定时通知不会显示；
2. 首页顶部可切换今日、明日、本周、本月和闲时；睡前选择“明日”，再点右下角 `+` 添加第二天任务；
3. 点击任务编辑，打开“在指定时间提醒”即可为该条待办设置通知时间；勾选完成，长按后在同一任务线内拖动排序；
4. “更多”中设置睡前提醒、坚果云自动同步、导入/导出离线接力包和恢复备份，“统计”查看历史与履约趋势；
5. 长按三星桌面空白区域，进入“组件”，添加 Woo Todo 今日组件；组件内可查看、勾选任务，点击任务进入编辑；
6. 在系统电池设置中保持默认优化，先观察通知延迟和日耗电，不要开启前台常驻服务。

## 3. 坚果云自动同步（推荐）

不想部署 Worker 时，按 [坚果云自动同步与通知](JIANGUOYUN_SYNC.md) 使用坚果云应用密码、相同同步空间名和同步密钥配置两端。任务先本地保存，网络只传输加密操作对象；这条路径不要求额外服务器费用。

## 4. 离线跨端接力

安装完成后无需配置账号、服务地址或配对。两端全部操作先写各自本地 SQLite；需要把手机任务交给 Mac 时：

1. Android 打开“更多 → 导出离线接力包”，输入并确认至少 10 个字符的独立口令；
2. 选择“系统分享”或保存文件，通过 U 盘、局域网文件传输等方式把 `.wootodo` 交给 Mac；
3. Mac 打开“任务详情与统计 → 同步 → 离线接力与加密备份”，输入同一口令并选择“合并离线接力包”；
4. 从 Mac 接力回 Android 时，在 Mac 导出接力包，再在 Android 选择“导入离线接力包”。

接力合并不会清空已有任务，也不会复制同步身份；同一文件可以安全重复导入。它是用户主动触发的文件传递，不是后台实时同步。完整冲突规则、加密格式以及“接力包”和“恢复备份”的区别见 [加密备份、离线接力与恢复](BACKUP_AND_RESTORE.md)。

## 5. 自建 Worker 在线同步

明确选择自建同步服务时，再部署 Cloudflare Workers + D1。夸克网盘可保存加密文件，但不能充当在线增量同步服务。

```bash
cd backend
npm install
npx wrangler login
npx wrangler d1 create woo-todo
```

把返回的 D1 `database_id` 写入 `backend/wrangler.toml`，然后执行：

```bash
npx wrangler secret put TOKEN_PEPPER
npx wrangler secret put VAULT_CREATION_INVITE_CODE
npx wrangler d1 migrations apply woo-todo --remote
npx wrangler deploy
```

`TOKEN_PEPPER` 使用密码管理器生成的至少 32 字节随机值。`VAULT_CREATION_INVITE_CODE` 是创建第一个同步空间时使用的一次性部署者口令，不会保存在客户端，也不是两端核对的六位配对码。

部署后在 Mac 的“同步”页填写 Worker HTTPS 根地址并创建空间，再用三星系统二维码扫描器加入 Android。`127.0.0.1` 只表示当前设备，不能作为双机地址。完整步骤与排错见 [可选在线配对同步](PAIRING.md)。

## 6. 必做验收

- 手机保持无公网，规划明日任务并导出接力包；Mac 合并后能展示对应日期任务；
- Mac 反向导出接力包，Android 合并后能看到实际变化，重复导入不产生重复任务；
- 两端同时修改同一任务时，完成、Pass、删除和排序按文档规则收敛；
- 完成、Pass、删除和排序在重启后保持；
- 三星 Widget 在进程回收、重启、锁屏后仍能刷新；
- 睡前提醒在 Android 16 / One UI 8 的电池优化下记录实际延迟；
- macOS 快速新增、悬浮、置顶、毛玻璃、穿透和四个全局快捷键连续运行 24 小时；
- 任一端导出的恢复备份能在空白安装恢复，并确认旧设备身份不会同时活跃；
- 若启用可选在线同步，再验证不同网络下的 `/health`、二维码配对和双向增量同步。

详细矩阵见 [测试与验收](TESTING.md)。
