# Woo Todo Windows v0.1.28 实验版（不保证可用）

此构建仅用于开发测试，不属于 Woo Todo 正式发布通道，也不保证能够正常启动或使用。功能可能不完整，并可能存在稳定性或数据兼容风险；请勿用于唯一或重要任务数据。

## 本次更新

- 将 Windows 程序与安装包版本推进到 `v0.1.28`，与本次跨平台发布保持一致。
- 修正 `SHA256SUMS-windows-experimental.txt` 的换行格式，便于 PowerShell、`shasum` 等工具稳定读取。
- 本版没有新增 Windows 端交互功能，Windows 的可用性状态仍为“实验版（不保证可用）”。

## 下载内容

- `Woo-Todo-v0.1.28-windows-x64-experimental.zip`：Windows 10 build 19041+ / Windows 11 x64 实验包。
- `SHA256SUMS-windows-experimental.txt`：该实验包的 SHA-256 校验值。

## 升级说明

- Windows 实验版暂不提供应用内自动更新，请先退出旧程序，再下载并解压本版，用新的 `WooTodo.exe` 替换旧文件。
- 本地任务和设置保存在 `%LOCALAPPDATA%\Woo Todo`，替换可执行文件不会主动删除这些数据。
- 当前程序未签名，SmartScreen 可能提示来源未知；请先核对 SHA-256，并在升级前备份重要数据。
