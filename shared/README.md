# 跨端协议

`shared/` 不包含任何客户端运行时代码。Swift、Kotlin 与 TypeScript 各自实现协议，并共同消费这里的 Schema 和 golden vectors。

## 内容

- `schema/task.schema.json`：解密后的任务或 tombstone 正文。
- `schema/sync.schema.json`：`POST /v1/sync` 的裸 `data` 请求/响应结构。
- `schema/webdav-operation.schema.json`：第三方 WebDAV 中每个不可变密文操作对象的格式。
- `schema/webdav-setup-link.schema.json`：桌面端到 Android 的 WebDAV 配置深链参数；只在两台设备近旁传递，不经过同步服务。
- `schema/webdav-pairing.schema.json`：第三方 WebDAV `v1/pairing/` 下 offer、claim、join、resolve、approval 五类配对文件的严格结构；只含临时公钥、设备信息、vaultId 与 vaultKey 密文。
- `schema/webdav-device.schema.json`：第三方 WebDAV `v1/<vaultId>/devices/<deviceId>.json` 设备心跳信封；只含 format、protocolVersion、deviceId、nonce 与 ciphertext，其余设备元数据由客户端在密文内约定。
- `schema/backup.schema.json`：`.wootodo` 加密文件外层格式。
- `schema/backup-plaintext.schema.json`：备份解密后的任务、可选 tombstone 删除屏障与自建服务恢复凭据；不包含 WebDAV 凭据。
- `fixtures/period-cases.json`：`Asia/Shanghai` 跨日、周、月边界。
- `fixtures/task-payloads.json`：任务正文和历史状态样例。
- `fixtures/task-validation-cases.json`：Wire v1 时区、数值上限与周期起点的跨端正反例。
- `fixtures/sync-request.json`：增量同步请求样例。
- `fixtures/webdav-operation.json`：WebDAV 操作对象样例。
- `fixtures/webdav-setup-link.json`：WebDAV 配置深链的脱敏字段向量，不包含真实账号、应用密码或密钥。
- `fixtures/webdav-pairing-*.json`：Path A（offer→claim→approval）与 Path B（join→resolve→approval）的完整配对样例；Path A 的 approval 为 `webdav-pairing-approval-path-a.json`（无 `approverPublicKey`），Path B 的 approval 为 `webdav-pairing-approval.json`（带 `approverPublicKey`），公钥与密文均为测试占位值。
- `fixtures/webdav-device.json`：WebDAV 设备心跳信封样例，nonce 与 ciphertext 为符合长度的测试占位值。
- `fixtures/crypto-vectors.json`：确定性 ID、同步 AES-GCM、X25519/HKDF 配对向量。
- `fixtures/backup-vectors.json`：PBKDF2、备份 AAD 与 AES-GCM 跨端向量。
- `reference/`：只用于验证向量的 Node 零依赖参考测试。

## 兼容规则

- 所有时间戳均为 Unix epoch 毫秒。
- 周期起点使用 `YYYY-MM-DD`，周任务的日期必须是周一，月任务必须是每月 1 日。
- 二进制字段使用无填充 Base64URL。
- 新增必填字段或改变加密/AAD 属于破坏性协议变更，必须提升 `protocolVersion`。
- WebDAV 对象按 `v1/<vaultId>/ops/<opId 前两位>/<opId>.json` 寻址；对象只创建一次，重复上传必须写入相同字节。
- WebDAV 的 `vaultId`、`deviceId`、`opId` 与 `entityId` 必须以 ASCII 字母或数字开头，防止路径组件被解释为 `.` 或 `..`。
- WebDAV 配对文件位于 `v1/pairing/`，文件名分别为 `offer-<code>-<pairingId>.json`、`claim-<pairingId>.json`、`join-<code>-<pairingId>.json`、`resolve-<pairingId>.json`、`approval-<pairingId>.json`；五类文件字段严格匹配 `kind`，未知字段拒绝。
- 配对文件只含 32 字节 X25519 公钥、设备信息、`vaultId` 与 `vaultKeyEnvelope`；六位码只用于定位文件，六位核对码必须两端人工比对；TTL 为 5 分钟。
- `vaultKeyEnvelope.ciphertext` 为 32 字节 vaultKey 加 16 字节 AES-GCM 标签（48 字节），`nonce` 为 12 字节，均使用无填充 Base64URL。
- 备份口令先做 Unicode NFKC 规范化，再以 UTF-8 字节执行 PBKDF2-HMAC-SHA256。
- 服务端 HTTP 成功外层 `ok/data/requestId` 不在 `sync.schema.json` 中；客户端仍必须验证该 envelope。

## 本地校验

```bash
npm run validate:contracts
npm run test:crypto
```
