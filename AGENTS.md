# woo-todo 开发约定

## 沟通与文档

- 用户沟通、项目文档、代码注释、日志和提交信息使用简体中文。
- 文件名、类型名、变量名和 API 字段继续使用英文。
- 提交信息遵循 Conventional Commits，例如 `feat(android): 增加今日桌面组件`。

## 架构边界

- `macos/`、`android/`、`backend/` 互不直接依赖。
- 三端只通过 `shared/schema/` 与 `shared/fixtures/` 约定协议。
- UI 只能读取本地仓储；网络同步不得成为用户操作的前置条件。
- macOS 不引入 Electron/WebView 运行时；Android 不引入跨端 UI 框架或前台常驻服务。
- 云端不得接触任务明文或记录认证凭证。
- `legacy/` 仅供历史参考，禁止新代码依赖。

## 质量要求

- 修改时间、重复、状态或同步逻辑时，必须增加跨周期或幂等测试。
- 修改共享协议时，同时更新 JSON Schema、fixture、Swift/Kotlin 模型和后端校验。
- 优先在目标真机验证 Widget、通知、窗口层级、穿透与耗电行为。

<!-- CODEGRAPH_START -->
## CodeGraph

在仓库根目录存在 `.codegraph/` 时，理解或定位代码应先使用 CodeGraph：

- 优先调用 `codegraph_explore`，一次获取相关符号源码和调用路径。
- Shell 环境可使用 `codegraph explore "<问题或符号>"`。
- 若不存在 `.codegraph/`，直接使用 `rg` 等工具，不要自行建立索引。
<!-- CODEGRAPH_END -->
