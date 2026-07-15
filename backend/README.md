# woo-todo 同步后端

这是一个运行在 Cloudflare Workers + D1 上的 local-first 增量同步服务。macOS 与 Android 客户端始终先写各自的本地 SQLite；服务端只负责保存客户端产生的 AES-256-GCM 密文、分配递增游标和转发变更，不读取任务正文。

## 安全边界

- 每台设备持有独立的 32 字节随机 Bearer 令牌。服务端使用 `TOKEN_PEPPER` 做 HMAC-SHA-256 后再写入 D1，令牌明文只在创建或配对客户端本地存在。
- vault 密钥由客户端产生。配对双方使用 X25519 建立会话，服务端仅暂存旧设备提交的加密密钥包。
- 整个配对流程（认领、确认、领取结果）严格限制在 10 分钟内。6 位人工核对码属于客户端交互层，不能替代 32 字节配对密钥。
- HTTP 仍必须使用 Cloudflare 提供的 HTTPS。应用层密文不替代 TLS。
- 任意已绑定设备都可撤销同 vault 的其他设备；撤销会阻止后续 API 访问，但无法远程删除目标设备已经下载的数据。

## 本地准备

当前实现不要求安装测试依赖；Node.js 22.18 及以上可直接运行内建测试。Wrangler 和 TypeScript 仅在开发或部署 Worker 时需要。

```bash
cd backend
node --test test/*.test.ts
npm install
npx wrangler d1 create woo-todo
```

将 D1 命令输出的数据库 ID 写入 `wrangler.toml`，然后配置凭据散列密钥并执行迁移：

```bash
npx wrangler secret put TOKEN_PEPPER
npx wrangler d1 migrations apply woo-todo --local
npx wrangler d1 migrations apply woo-todo --remote
npx wrangler dev
```

`TOKEN_PEPPER` 应是密码管理器生成的至少 32 字节随机值，不得写入 Git。Cloudflare 与 D1 的 2026 年免费额度、备份政策及中国大陆网络可达性，需要在正式部署前按官方文档重新核验。

## 统一响应

成功响应：

```json
{
  "ok": true,
  "data": {},
  "requestId": "请求追踪 ID"
}
```

失败响应：

```json
{
  "ok": false,
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "错误说明",
    "details": { "field": "push[0].nonce" }
  },
  "requestId": "请求追踪 ID"
}
```

除健康检查、创建 vault、认领配对和领取配对结果外，其余接口均要求：

```http
Authorization: Bearer <32字节无填充Base64URL设备令牌>
Content-Type: application/json
```

## API

| 方法与路径 | 鉴权 | 用途 |
|---|---:|---|
| `GET /health` | 否 | Worker 与 D1 健康检查 |
| `POST /v1/vaults` | 否 | 创建 vault 与首台设备 |
| `POST /v1/pairings` | 是 | 生成 10 分钟配对会话 |
| `POST /v1/pairings/:id/claim` | 否 | 新设备认领会话 |
| `GET /v1/pairings/:id` | 是 | 发起设备查看认领状态 |
| `POST /v1/pairings/:id/confirm` | 是 | 发起设备确认并提交 vault 密钥密文 |
| `POST /v1/pairings/:id/result` | 否 | 新设备领取确认结果 |
| `POST /v1/sync` | 是 | 原子 push、ack 与 pull |
| `GET /v1/devices` | 是 | 查看同 vault 设备 |
| `POST /v1/devices/:id/revoke` | 是 | 撤销另一台设备 |

### 创建 vault

```json
{
  "device": {
    "name": "我的 MacBook Air",
    "platform": "macos",
    "publicKey": "32字节X25519公钥的Base64URL"
  },
  "recoveryEnvelope": {
    "ciphertext": "客户端生成的AES-GCM密文",
    "nonce": "12字节nonce的Base64URL"
  }
}
```

响应中的 `device.token` 只返回一次，客户端必须立即保存到 macOS Keychain 或 Android Keystore 包裹的本地存储。

### 配对顺序

1. 旧设备调用 `POST /v1/pairings`，提交本次配对的临时 X25519 公钥；将返回的 `pairingId`、`pairingSecret`、公钥和服务地址编码为二维码。
2. 新设备生成自己的临时 X25519 密钥与 32 字节 `deviceToken`，调用 `claim`。服务端只保存设备令牌散列。
3. 旧设备轮询配对状态，向用户展示设备名与公钥指纹；用户确认后，客户端使用共享密钥加密 `vault_key` 并调用 `confirm`。
4. 新设备携带原 `pairingSecret` 与自己已保存的 `deviceToken` 调用 `result`。成功后该令牌即可用于正常 Bearer 鉴权。

### 增量同步

```json
{
  "cursor": 18,
  "ack": 18,
  "pullLimit": 100,
  "push": [
    {
      "opId": "设备生成且全局稳定的幂等ID",
      "entityId": "任务ID",
      "kind": "upsert",
      "lamport": 42,
      "ciphertext": "任务正文及字段时钟的AES-GCM密文",
      "nonce": "12字节nonce的Base64URL"
    }
  ]
}
```

D1 `batch()` 在同一事务内完成所有 `INSERT OR IGNORE`、设备 ack 更新和增量查询。`(vault_id, op_id)` 唯一约束保证重试幂等；响应中的 `inserted` 与 `duplicates` 可用于诊断。pull 会比 `pullLimit` 多查询一条来计算 `hasMore`，客户端仅在成功落地返回操作后保存新 `cursor`。

服务端不执行任务冲突合并；tombstone 终态、已结算状态、completed/Pass 领域优先级与 `(lamport, deviceId)` LWW 由客户端在解密后确定。

## 固定限制

- 单个 JSON 请求：256 KiB
- 每次 push：最多 50 条
- 每次 pull：最多 100 条
- 单条操作密文：最多 32 KiB
- AES-GCM nonce：固定 12 字节
- 设备名：最多 80 个字符
- 配对认领与确认：创建后 10 分钟内完成

这些限制同时存在于协议纯逻辑和 Worker 入口。若未来调整，必须同步升级客户端协议版本并补充迁移测试。
