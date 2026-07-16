# 发版与签名维护

GitHub Actions 在推送 `v*` tag 后构建并发布双端安装包。只有 Android 需要长期私钥；macOS 首版使用 ad-hoc 签名，不依赖证书私钥。

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

1. 更新 `android/app/build.gradle.kts` 中的 `versionCode` 和 `versionName`。
2. 更新 `macos/Resources/Info.plist` 中的显示版本和构建号默认值。
3. 新增 `docs/releases/vX.Y.Z.md`，内容中的产物名称与 tag 保持一致。
4. 在 `main` 完成测试并等待持续集成通过。
5. 创建并推送 annotated tag：`git tag -a vX.Y.Z -m "release: 发布 vX.Y.Z"`，然后执行 `git push origin vX.Y.Z`。
6. 等待“正式发布”工作流完成，下载两个安装包与 `SHA256SUMS.txt` 做最终校验。

Release workflow 会拒绝 tag 与双端源码版本不一致的发布。Android 会运行 Release 单测、Lint、签名构建和独立验签；macOS 会在 Apple Silicon Runner 运行全量 Swift 测试、组装 `.app`、ad-hoc 签名并压缩。

## 后端部署边界

客户端 Release 不会自动部署 Cloudflare Workers + D1。同步服务需要单独配置真实 `database_id`、`TOKEN_PEPPER`、远端迁移和网络验收，部署步骤见 `backend/README.md`。
