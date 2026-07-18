# 跨端协议

`shared/` 不包含任何客户端运行时代码。Swift、Kotlin 与 TypeScript 各自实现协议，并共同消费这里的 Schema 和 golden vectors。

## 内容

- `schema/task.schema.json`：解密后的任务或 tombstone 正文。
- `schema/sync.schema.json`：`POST /v1/sync` 的裸 `data` 请求/响应结构。
- `schema/backup.schema.json`：`.wootodo` 加密文件外层格式。
- `schema/backup-plaintext.schema.json`：备份解密后的任务、可选 tombstone 删除屏障与恢复凭据。
- `fixtures/period-cases.json`：`Asia/Shanghai` 跨日、周、月边界。
- `fixtures/task-payloads.json`：任务正文和历史状态样例。
- `fixtures/task-validation-cases.json`：Wire v1 时区、数值上限与周期起点的跨端正反例。
- `fixtures/sync-request.json`：增量同步请求样例。
- `fixtures/crypto-vectors.json`：确定性 ID、同步 AES-GCM、X25519/HKDF 配对向量。
- `fixtures/backup-vectors.json`：PBKDF2、备份 AAD 与 AES-GCM 跨端向量。
- `reference/`：只用于验证向量的 Node 零依赖参考测试。

## 兼容规则

- 所有时间戳均为 Unix epoch 毫秒。
- 周期起点使用 `YYYY-MM-DD`，周任务的日期必须是周一，月任务必须是每月 1 日。
- 二进制字段使用无填充 Base64URL。
- 新增必填字段或改变加密/AAD 属于破坏性协议变更，必须提升 `protocolVersion`。
- 备份口令先做 Unicode NFKC 规范化，再以 UTF-8 字节执行 PBKDF2-HMAC-SHA256。
- 服务端 HTTP 成功外层 `ok/data/requestId` 不在 `sync.schema.json` 中；客户端仍必须验证该 envelope。

## 本地校验

```bash
npm run validate:contracts
npm run test:crypto
```
