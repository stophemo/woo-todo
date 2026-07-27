# 发版与签名维护

GitHub Actions 在推送规范的 `vMAJOR.MINOR.PATCH` tag 后构建并发布 Android APK、macOS ZIP 和 Windows 免安装 ZIP；其他 `v*` 标签会在构建前被拒绝。只有 Android 需要长期私钥；macOS 使用 ad-hoc 签名，Windows 原生程序暂不签名。

## Android 签名

首版证书 SHA-256：

```text
77d9b1ff936a9ea9da7ccae4360ede8f1b32b25761378826de7d812bccdba7f7
```

维护者本机的密钥默认保存在 `$HOME/Library/Application Support/Woo Todo/signing/android-release.p12`，密码保存在 macOS Keychain 的 `io.github.stophemo.woo-todo.android-signing` 服务项。仓库 Actions 需要以下 Secrets：

- `ANDROID_RELEASE_KEYSTORE_BASE64`
- `ANDROID_RELEASE_STORE_PASSWORD`
- `ANDROID_RELEASE_KEY_ALIAS`
- `ANDROID_RELEASE_KEY_PASSWORD`

GitHub Secrets 不能下载还原。必须把本机 keystore 和密码分别备份到两个可信位置；丢失任意一项后，都不能使用同一 `applicationId` 覆盖升级既有安装。

## 发布步骤

1. 更新根目录、后端、Android、macOS 和 `windows/Cargo.toml` 的版本号，并重新生成 `windows/Cargo.lock`；Android `versionCode` 与 macOS 构建号必须递增。
2. 同步更新 `macos/scripts/package-app.sh` 的本地默认版本与构建号。
3. 新增 `docs/releases/vX.Y.Z.md`，内容中的产物名称与 tag 保持一致；正文直接从版本说明开始，不重复写一级标题，GitHub Release 标题由工作流生成。
4. 在 `main` 完成测试并等待持续集成通过。
5. 创建并推送 annotated tag：`git tag -a vX.Y.Z -m "release: 发布 vX.Y.Z"`，然后执行 `git push origin vX.Y.Z`。
6. 等待“正式发布”工作流完成，下载三个发布文件与 `SHA256SUMS.txt` 做最终校验。
7. 产物确认存在后再更新 `web/` 的版本、日期与下载链接，并验证 Vercel 生产页面。

Release workflow 会拒绝 tag 与各端源码版本不一致的发布。Android 会运行 Release 单测、Lint、签名构建和独立验签；macOS 会在 Apple Silicon Runner 运行 Swift 测试并组装 `.app` ZIP；Windows 会运行 Rust 格式、测试和 Clippy，构建固定的 MSVC x64 目标，再对最终 ZIP 执行真实 Win32 烟测，覆盖 AMD64 PE、启动、原生窗口、单实例、协议激活、快速新增、完成/取消完成、透明度与穿透独立变化、托盘退出及重启持久化。通过烟测的同一份 ZIP 才会进入 GitHub Release，不在测试后重新打包；烟测诊断、截图、事件日志和隔离数据会在成功或失败时保留 7 天。

## 后端部署边界

客户端 Release 不会自动部署 Cloudflare Workers + D1。同步服务需要单独配置真实 `database_id`、`TOKEN_PEPPER`、远端迁移和网络验收，部署步骤见 `backend/README.md`。
