# Woo Todo Rust 共享核心

这里保存三端共用的领域与本地仓储语义，不包含任何平台 UI 或通知权限代码。

当前能力包括：

- 任务校验与日、周、月、闲时周期计算
- 确定性重复实例 ID 与幂等跨周期结算
- 履约统计
- SQLite 仓储、事务与 tombstone 约束
- 稳定任务通知计划
- 面向 Swift、Kotlin/JNI 等跨语言调用方的窄 C ABI/JSON 边界

## 本地验证

```bash
cargo fmt --manifest-path shared/core-rust/Cargo.toml --check
cargo test --manifest-path shared/core-rust/Cargo.toml --locked --all-targets
cargo clippy --manifest-path shared/core-rust/Cargo.toml --locked --all-targets -- -D warnings
```

构建动态库：

```bash
cargo build --manifest-path shared/core-rust/Cargo.toml --release --locked
```

C 调用约定见 [`include/woo_todo_core.h`](include/woo_todo_core.h)。所有请求和响应都是 UTF-8 JSON；返回字符串必须由 `woo_todo_string_free` 释放。JSON 使用 `camelCase`，响应固定为：

```json
{"ok":true,"value":{}}
```

或：

```json
{"ok":false,"error":{"code":"validation","message":"..."}}
```

成功响应中的 `value` 可以合法为 `null`，调用方不能把它误判为缺少字段。

## 接入状态

- Windows：`windows` Rust crate 直接依赖共享核心，以 Rust 类型在同一进程内调用，不经过 C ABI 或动态库复制。
- macOS、Android：采用能力切片的渐进迁移；现有原生 UI、通知调度、同步与安全存储不重写。切换每项领域能力前，先用跨端 fixture 验证与现有实现等价。
