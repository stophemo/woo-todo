# 测试与验收矩阵

## 自动化层级

| 层级 | 覆盖内容 |
|---|---|
| 共享 golden tests | 周期边界、确定性实例 ID、同步/备份 AES-GCM 格式 |
| 领域单元测试 | 日/周/月/闲时、重复、完成、Pass、统计、排序 |
| 本地仓储测试 | SQLite 往返、迁移、事务结算、历史不可改写 |
| 后端测试 | vault、配对、鉴权、幂等同步、分页、撤销 |
| 客户端同步测试 | 加密、API 错误、outbox、cursor、失败重试 |
| 配置与更新测试 | 双端二维码 URI、严格 Release 解析、版本比较、检查节流与重复提醒 |
| Android instrumentation | 真实 SQLite 绑定、tombstone、幂等、事务回滚、cursor 与备份恢复 |
| 平台测试 | NSPanel、全局快捷键、App Widget、通知、重启 |

## Android 验证执行位置

- 开发机默认不启动 Android 模拟器，避免模拟器持续占用 CPU 与内存。
- 开发机只运行 JVM 单元测试、构建和 Lint；不执行 `connectedDebugAndroidTest`。
- SQLite instrumentation 统一交由 GitHub Actions 的托管 Pixel 6 / API 35 模拟器运行。
- Widget、通知、后台回收、重启和耗电结论仍以 Galaxy S23 Ultra 真机验收为准。

## 时间边界

- 北京时间 23:59 到次日 00:00
- 周日到周一
- 月末到月初，包括二月
- App 关闭数日后再次打开
- 设备时区改变但同步空间仍固定 `Asia/Shanghai`
- 重复任务追赶多个遗漏周期且不产生重复实例

## 同步场景

- 一端断网新增，恢复网络后由坚果云或 Worker 上传
- 两端分别断网新增不同任务，恢复网络后通过在线同步拉取并合并
- 两端修改同一任务，按 `(lamport, deviceId)` 确定结果
- 上传成功但响应丢失，`opId` 重试不重复
- 拉取一页后本地落地失败，不推进 cursor
- 删除 tombstone 阻止旧设备复活数据
- completed/Pass 两种到达顺序收敛，截止瞬间按左闭右开规则判定
- 已结算快照不会被较大 Lamport 的 pending 操作改写
- 设备撤销后令牌不能继续同步
- 服务端清空后由客户端加密快照重建
- Mac 坚果云二维码由 Android App 内扫码后完整预填，取消不落盘，确认后生成独立 `deviceId` 并立即同步
- Android 未连接时点击“配对”可直接选择扫码、粘贴链接或手动坚果云配置，不出现纯说明弹窗；粘贴链接允许首尾空白并继续执行严格格式校验
- Android 启动读取安全存储期间显示加载态且配对按钮不可用；同签名覆盖升级后凭据可从重建的仓储实例继续读取，不短暂误报未配对
- 应用密码包含空格、`+`、`/`、`&`、`=` 时，Mac `URLComponents` 输出仍可由 Android 严格解析
- 扫到网页、普通文本、缺字段、重复字段或错误版本时拒绝配置

## 更新检查场景

- GitHub 正式版高于当前版本时只显示菜单入口，不自动弹窗；等于或低于当前版本时隐藏入口，手动检查显示“已是最新”
- 草稿、预发布、非三段式 tag、错误仓库 URL 和错误 APK 路径均拒绝
- 自动检查成功后 24 小时内不重复请求；发现的可用版本在菜单中持久保留，重启后仍可点击，安装到对应版本后自动清除
- 手动检查始终返回结果；发现新版本时刷新菜单入口，点击入口才打开 GitHub 下载页
- DNS、超时或 HTTP 失败不影响本地任务，并在 15 分钟后允许再次自动检查
- Android Activity 销毁会取消底层 OkHttp Call；macOS 终止时取消 URLSession 任务
- Android 同包名、同签名覆盖升级保留 SQLite、Keystore 与同步凭据；卸载、清除数据或更换签名才进入重新配置流程

## 备份场景

- Swift、Kotlin 与 Node 使用同一 PBKDF2/AES-GCM golden vector
- NFKC 后相同口令跨端解密，错误口令与篡改密文均失败
- 未配对设备导出/恢复纯任务快照
- 已配对设备恢复任务和同步凭据后可继续拉取
- 非空任务库、已有凭据、未知字段、重复 ID 和超量文件拒绝导入
- Pass 的原始 `settledAt` 与 `updatedAt` 不同时仍精确往返

## Android 平台矩阵

| 环境 | 目标 |
|---|---|
| GitHub Actions 托管 Pixel 6 / API 35 | 真实 SQLite 绑定、tombstone、幂等、cursor、事务回滚与备份恢复 |
| Galaxy S23 Ultra / Android 16 / One UI 8 | Widget、应用内扫码、相机拒权、后台回收、通知延迟、重启恢复、耗电 |

托管模拟器的 instrumentation 通过结果不能替代 One UI Widget 验收。三星专项需要检查组件缩放、列表刷新、系统电池优化和 24 小时耗电。

## macOS 平台矩阵

- M4 / Tahoe 26.5.2：主验收环境
- 多桌面空间、全屏 App、外接显示器
- 置顶、毛玻璃、穿透的任意开关组合
- 穿透状态下全局快捷键与菜单栏均可恢复交互
- 睡眠、唤醒、网络切换和连续运行 24 小时

## 性能预算

- macOS Release：RSS 目标不超过 60MB、硬上限 100MB，30 分钟平均 CPU 不超过 0.3%。
- Android：无前台服务；典型使用额外耗电目标不超过 0.5%/天。
- Widget 本地操作反馈不超过 1 秒。
- 典型个人使用同步流量不超过 1MB/天。

性能结论必须来自 Release 构建与目标真机；模拟器、Debug 构建和单次 Activity Monitor 截图只能用于诊断。
