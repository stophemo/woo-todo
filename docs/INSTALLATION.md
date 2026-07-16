# 个人安装与首次使用

woo-todo 不依赖应用商店。`v0.1.0` 起可从 GitHub Releases 下载双端安装包；正式长期使用前仍应完成目标真机验收并定期导出加密备份。

## 1. 先部署同步服务

不需要同步时可跳过此步，两端仍可完全离线使用。

```bash
cd backend
npm install
npx wrangler login
npx wrangler d1 create woo-todo
```

把命令返回的 D1 `database_id` 写入 `backend/wrangler.toml`，然后执行：

```bash
npx wrangler secret put TOKEN_PEPPER
npx wrangler d1 migrations apply woo-todo --remote
npx wrangler deploy
```

`TOKEN_PEPPER` 使用密码管理器生成的至少 32 字节随机值。部署完成后记录 Worker 的 HTTPS 根地址，并访问 `/health` 确认 D1 可用。Cloudflare 免费额度和中国大陆网络连通性会变化，部署当天仍需查看官方说明并分别用家庭、公司和移动网络验证。

## 2. 安装 macOS 客户端

从 GitHub Releases 下载 `Woo-Todo-v0.1.0-macos-arm64.zip`，校验 `SHA256SUMS.txt` 后解压，把 `Woo Todo.app` 拖到“应用程序”。该产物只支持 Apple Silicon Mac，使用 ad-hoc 签名且没有 Apple 公证；若 Gatekeeper 阻止，进入“系统设置 → 隐私与安全性”确认本次个人启动。

需要自行构建时，要求完整 Xcode 与当前 macOS SDK/Swift 编译器匹配。仅有版本不匹配的 Command Line Tools 时不能作为 Release 构建环境：

```bash
cd macos
./scripts/package-app.sh --zip
```

自行构建的产物位于 `macos/dist/Woo Todo.app`。

首次运行后：

1. 在菜单栏打开“任务详情与统计…”；
2. 进入“同步”，填写 Worker HTTPS 根地址并创建同步空间；
3. 保存一份 `.wootodo` 加密备份；
4. `Control + Option + Space` 可随时恢复或切换悬浮面板交互。

## 3. 安装 Android 客户端

从 GitHub Releases 下载 `Woo-Todo-v0.1.0-android.apk`，校验 `SHA256SUMS.txt` 后从三星“我的文件”打开并允许本次来源安装。连接 ADB 时也可执行：

```bash
adb install -r Woo-Todo-v0.1.0-android.apk
```

正式 APK 使用项目专用 Release 密钥签名，后续 GitHub Release 可直接覆盖升级。Debug 包与正式包签名不同，不能相互覆盖；切换前先导出 `.wootodo`，再卸载旧包。

正式签名证书 SHA-256 为 `77d9b1ff936a9ea9da7ccae4360ede8f1b32b25761378826de7d812bccdba7f7`。

开发验收 APK 可从源码构建：

```bash
cd android
./gradlew testDebugUnitTest assembleDebug lintDebug
```

产物为 `android/app/build/outputs/apk/debug/app-debug.apk`。连接 ADB 后可执行：

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Debug APK 使用本机调试签名，只适合开发期个人安装。不要清除应用数据或更换签名后直接覆盖，否则本地 SQLite、Keystore 凭据和 Widget 配置会丢失；升级前先导出 `.wootodo`。

首次运行后：

1. 允许通知权限，否则 23:10 睡前提醒不会显示；
2. 扫描 Mac 同步页生成的二维码并核对六位码；
3. 长按三星桌面空白区域，进入“组件”，添加 Woo Todo 今日组件；
4. 在系统电池设置中保持默认优化，先观察通知延迟和日耗电，不要开启前台常驻服务。

## 4. 必做验收

- 手机离线规划明日任务，Mac 恢复网络后能拉取并展示；
- Mac 与手机同时离线修改不同任务，恢复网络后均不丢失；
- 完成、Pass、删除和排序在重启后保持；
- 三星 Widget 在进程回收、重启、锁屏后仍能刷新；
- 睡前提醒在 Android 16 / One UI 8 的电池优化下记录实际延迟；
- macOS 悬浮、置顶、毛玻璃、穿透和全局快捷键连续运行 24 小时；
- 任一端导出的 `.wootodo` 能在空白安装恢复，并确认旧设备身份不会同时活跃。

详细矩阵见 [测试与验收](TESTING.md)，备份说明见 [加密备份与恢复](BACKUP_AND_RESTORE.md)。
