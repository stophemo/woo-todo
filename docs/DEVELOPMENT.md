# 开发指南

## 环境要求

- macOS 15 或更高版本
- 完整 Xcode，Swift 工具链与 macOS SDK 版本必须匹配
- Android SDK 36、Android Build Tools 35、JDK 17
- Node.js 24、npm 11

目标真机为 macOS Tahoe 26.5.2 / Apple M4 和 Android 16 / Samsung One UI 8.0。较低系统版本只用于兼容性测试，不代表完成三星专项验收。

## 共享契约

```bash
npm run validate:contracts
npm run test:crypto
```

修改协议时必须同时更新：

- `shared/schema/`
- `shared/fixtures/`
- Swift 模型和测试
- Kotlin 模型和测试
- 后端请求校验

## 后端

```bash
cd backend
npm install
npm test
npm run typecheck
```

本地 D1：

```bash
npx wrangler d1 migrations apply woo-todo --local
npx wrangler dev
```

部署前需要创建 D1、替换 `wrangler.toml` 中的占位 ID，并通过 `wrangler secret put TOKEN_PEPPER` 设置至少 32 字符的随机 pepper。不要把令牌、密钥或 `.dev.vars` 提交到 Git。

## Android

```bash
cd android
./gradlew testDebugUnitTest
./gradlew assembleDebug
./gradlew assembleDebugAndroidTest
```

Debug APK 位于 `android/app/build/outputs/apk/debug/app-debug.apk`。项目不要求 Android Studio，但使用模拟器或真机时需要可用的 ADB 环境。

真实 SQLite instrumentation 测试由 GitHub Actions 的 API 35 托管模拟器运行；本机开发默认只跑 JVM 测试和 APK 编译，避免长时间占用图形模拟器。三星 Widget、后台回收、通知和耗电仍必须在 Galaxy S23 Ultra 真机验收。

## macOS

```bash
cd macos
swift test
swift run woo-todo-mac
```

仅安装 Command Line Tools 时，如果 Swift 编译器与系统 SDK 补丁版本不一致，标准命令会拒绝构建。应优先安装并通过 `xcode-select` 选择匹配的完整 Xcode，不应在发布流程中绕过版本检查。

个人安装包脚本位于 `macos/scripts/`。它使用 Release 产物组装 `.app` 并进行 ad-hoc 签名，不等同于 Developer ID 公证。

## 全仓 CI

GitHub Actions 分成契约/后端、macOS、Android JVM/构建和 Android SQLite instrumentation 四个独立任务。任何一端失败都不会隐藏其他端的诊断结果；CI 不部署服务，也不读取生产秘密。
