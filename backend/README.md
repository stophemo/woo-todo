# woo-todo 同步后端

这是一个运行在 Cloudflare Workers + D1 上的 local-first 增量同步服务。macOS 与 Android 客户端始终先写各自的本地 SQLite；服务端只负责保存客户端产生的 AES-256-GCM 密文、分配递增游标和转发变更，不读取任务正文。

## 安全边界

- 每台设备持有独立的 32 字节随机 Bearer 令牌。服务端使用 `TOKEN_PEPPER` 做 HMAC-SHA-256 后再写入 D1，令牌明文只在创建或配对客户端本地存在。
- vault 密钥由客户端产生。配对双方使用 X25519 建立会话，服务端仅暂存旧设备提交的加密密钥包。
- 整个配对流程（认领、确认、领取结果）严格限制在 10 分钟内。6 位人工核对码属于客户端交互层，不能替代 32 字节配对密钥。
- HTTP 仍必须使用 Cloudflare 提供的 HTTPS。应用层密文不替代 TLS。
- 任意已绑定设备都可撤销同 vault 的其他设备；撤销会阻止后续 API 访问，但无法远程删除目标设备已经下载的数据。
- 创建 vault 必须提供部署者配置的邀请码。邀请码只通过专用 Header 传输并与 Worker secret 比较，不进入 JSON、日志或 D1；它只控制新空间创建，不是传统账号，也不参与已有设备同步和配对。
- 通过邀请码后，创建请求会按 Cloudflare 提供的来源 IP 做 HMAC 后进入固定时间窗计数，D1 不保存 IP 明文。默认每个来源每小时最多创建 5 个、整个服务每天最多创建 100 个；全服务额度已满时不会创建新的来源计数桶。
- 每个 vault 最多保留 4 台未撤销设备，足够 macOS + Android 双机配对，并为设备更换留出余量；达到上限时先撤销不用的旧设备。
- 每个 vault 最多保存 100000 条操作、合计 32 MiB 解码后密文。D1 用持久用量账本和触发器原子维护额度，不会在每次同步时全表求和。

## 本地准备

当前实现不要求安装测试依赖；Node.js 22.18 及以上可直接运行内建测试。Wrangler 和 TypeScript 仅在开发或部署 Worker 时需要。

```bash
cd backend
node --test test/*.test.ts
npm install
cp .dev.vars.example .dev.vars
npx wrangler d1 migrations apply woo-todo --local
npx wrangler dev
```

编辑本地 `.dev.vars`，把示例的 `TOKEN_PEPPER` 和 `VAULT_CREATION_INVITE_CODE` 换成符合下述格式的开发值；该文件已被 `.gitignore` 排除。生产部署请按下面的个人免费部署流程操作。

## 面向个人的 Cloudflare 免费部署

这是一条自托管的可选路径，坚果云用户不需要执行本节。它不需要购买域名：仓库的 `workers_dev = true` 会使用 Cloudflare 提供的 `workers.dev` 地址。Cloudflare 账号、Workers/D1 免费计划的额度、计费规则和中国大陆网络可达性都由 Cloudflare 决定，可能随时间或地区变化；部署前请在 Cloudflare Dashboard 核对当前计划、用量和告警设置。项目按个人双端低频负载设计，但是否落在免费计划范围内以部署账号的实时用量为准，项目不承诺永久零费用或免费额度。

### 1. 准备账号和工具

1. 注册或登录 Cloudflare 账号，并确认账号可以使用 Workers 和 D1。无需创建自定义域名；首次使用 `workers.dev` 时按 Wrangler 或 Dashboard 提示启用账号的 Workers 子域名。
2. 安装 Node.js 22.18 或更高版本，进入仓库后安装部署依赖：

```bash
cd backend
npm install
```

3. 登录并确认 Wrangler 使用的是目标 Cloudflare 账号：

```bash
npx wrangler login
npx wrangler whoami
```

`wrangler login` 会打开浏览器完成授权；不要把授权令牌写入仓库、日志或截图。

### 2. 创建并绑定 D1

在 `backend/` 目录执行：

```bash
npx wrangler d1 create woo-todo
```

命令输出一个 D1 `database_id`。只把这个 UUID 替换到 `backend/wrangler.toml` 现有 `[[d1_databases]]` 块的 `database_id`，保持 `binding = "DB"`、`database_name = "woo-todo"` 和 `migrations_dir = "migrations"` 不变。`database_id` 不是任务数据或密钥，但不要把下方 secrets 填进该文件。

### 3. 配置 Worker secrets

两个 secrets 必须通过交互式命令写入 Cloudflare，不要放入 `wrangler.toml`、`.dev.vars`、Git 或客户端：

```bash
npx wrangler secret put TOKEN_PEPPER
npx wrangler secret put VAULT_CREATION_INVITE_CODE
```

在每条命令的交互提示中粘贴密码管理器生成的值。也可以先在本机用 `openssl rand -hex 32` 生成 `TOKEN_PEPPER`，用 `openssl rand -hex 24` 生成邀请码，再手动粘贴；不要把值作为命令行参数。`TOKEN_PEPPER` 至少 32 个字符且应保持长期不变；更换它会使所有已有设备令牌无法认证，除非恢复原值，否则必须创建新的同步空间。`VAULT_CREATION_INVITE_CODE` 必须是 16 至 256 个无空格可打印 ASCII 字符，是部署级可复用的“创建空间”门禁，不是传统账号或六位配对码；轮换邀请码不会影响已有 vault。

`APP_ENV = "production"`、`VAULT_CREATION_SOURCE_LIMIT = "5"` 和 `VAULT_CREATION_DAILY_LIMIT = "100"` 已在 `wrangler.toml` 的公开 `[vars]` 中，无需另行创建 secret。后两个值可按自托管规模调整，但必须是 1 至 10000 的整数。计数通过 D1 原子 `UPSERT` 完成，因此同一 D1 绑定下的多个 Worker 实例共享额度。该机制能限制数据库写入成本，但无法阻止分布式来源耗尽每日额度所造成的临时拒绝服务；正式公开运营时仍应叠加 Cloudflare WAF 或边缘 Rate Limiting。

### 4. 迁移并部署

先在本地完成轻量检查（可选但建议），再把迁移应用到刚创建的远端 D1：

```bash
npm test
npm run typecheck
npx wrangler d1 migrations apply woo-todo --remote
npx wrangler deploy
```

迁移必须在 `wrangler.toml` 写入真实 `database_id` 后执行。不要用 `--local` 代替 `--remote`，也不要跳过仓库中的迁移文件。`wrangler deploy` 成功后会打印 Worker URL，通常形如 `https://woo-todo-sync.<你的 workers 子域>.workers.dev`；如果命令提示选择或创建 `workers.dev` 子域名，按 Cloudflare 提示完成一次启用。自定义域名不是本项目必需项。

### 5. 验证并连接双端

把部署输出的根地址（不要附加 `/v1`）保存到密码管理器或私密笔记，并先检查健康接口：

```bash
curl -fsS 'https://woo-todo-sync.example.workers.dev/health'
```

把示例地址替换为部署命令输出的实际 URL；响应应包含 `"ok": true`。随后按 [macOS 与 Android 可选在线配对同步](../docs/PAIRING.md) 操作：在 Mac 的“同步”页填写 Worker 根地址和 `VAULT_CREATION_INVITE_CODE`，创建同步空间；再生成二维码，让 Android 用系统二维码扫描器加入，逐位核对六位码后确认。邀请码只随创建请求发送，客户端不会保存；二维码和配对 secret 只通过自己的私密渠道传递。

### 免费层和数据边界

- Cloudflare 免费计划的 Workers 请求、D1 存储/读写、日志和网络政策不是本项目能保证的固定额度；以部署时 Cloudflare Dashboard 的当前定价和用量页为准，设置用量告警，避免误升级或产生超额费用。
- 项目自身还限制每个 vault 最多 4 台未撤销设备、100000 条操作和 32 MiB 解码后密文，并限制创建频率；这些是应用保护阈值，不等于 Cloudflare 免费额度。
- Worker 和 D1 永远只接收 AES-256-GCM 密文及必要元数据。`TOKEN_PEPPER` 与创建邀请码只存 Cloudflare Secret；任务标题、备份口令、设备令牌明文和 `vault_key` 不得写入服务端日志、环境变量或文件。
- 关闭或删除 Worker 不会删除客户端本地 SQLite；但服务端不可达期间会积压 outbox，重新部署同一 D1 和 secrets 后才能继续同步。

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
| `POST /v1/vaults` | 创建邀请码 | 创建 vault 与首台设备 |
| `POST /v1/pairings` | 是 | 生成 10 分钟配对会话 |
| `POST /v1/pairings/:id/claim` | 否 | 新设备认领会话 |
| `GET /v1/pairings/:id` | 是 | 发起设备查看认领状态 |
| `POST /v1/pairings/:id/confirm` | 是 | 发起设备确认并提交 vault 密钥密文 |
| `POST /v1/pairings/:id/result` | 否 | 新设备领取确认结果 |
| `POST /v1/sync` | 是 | 原子 push、ack 与 pull |
| `GET /v1/devices` | 是 | 查看同 vault 设备 |
| `POST /v1/devices/:id/revoke` | 是 | 撤销另一台设备 |

### 创建 vault

请求必须通过专用 Header 携带部署者提供的邀请码；不要把它放入 JSON 或 URL：

```http
X-Woo-Todo-Invite-Code: <部署者提供的邀请码>
Content-Type: application/json
```

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

D1 `batch()` 在同一事务内完成所有密文写入、设备 ack 更新和增量查询。`(vault_id, op_id)` 唯一约束保证相同内容重试幂等；若同一 `opId` 被用于不同的 `entityId`、操作类型、Lamport、密文或 nonce，服务端返回 `409 OP_ID_CONFLICT`，数据库触发器负责兜住多个 Worker 并发写入的竞态并回滚整批请求。响应中的 `inserted` 与 `duplicates` 可用于诊断。

`vault_usage` 持久记录每个 vault 的操作数和解码后密文字节数。新增、删除日志时由 D1 触发器增量更新；同一批 push 中任何一条越界都会回滚整批并返回 `507 VAULT_CAPACITY_REACHED`。相同内容的幂等重放不重复计费，在容量已满时仍可正常重试和 pull。迁移 `0003_vault_capacity.sql` 会对既有数据执行一次性回填，之后正常请求不扫描整张 `change_log`。

`server_seq` 是整个 D1 共享的自增序号，因此不同 vault 之间可能形成空洞。`cursor = 0` 始终表示从头同步；非零 cursor 必须对应当前 vault 真实存在的 `server_seq`，若只属于其他 vault 或不存在则返回 `409 CURSOR_NOT_FOUND`。超过当前 vault 最大值的 cursor 返回 `409 CURSOR_AHEAD`。这两项校验可防止错误客户端永久跳过尚未拉取的远端变更。pull 会比 `pullLimit` 多查询一条来计算 `hasMore`，客户端仅在成功落地返回操作后保存新 `cursor`。

服务端不执行任务冲突合并；tombstone 终态、已结算状态、completed/Pass 领域优先级与 `(lamport, deviceId)` LWW 由客户端在解密后确定。

## 固定限制

- 单个 JSON 请求：256 KiB
- 每次 push：最多 50 条
- 每次 pull：最多 100 条
- 单条操作密文：最多 32 KiB
- AES-GCM nonce：固定 12 字节
- 设备名：最多 80 个字符
- 配对认领与确认：创建后 10 分钟内完成
- 创建同步空间：必须携带有效的 `X-Woo-Todo-Invite-Code`
- 创建同步空间：默认每个来源每小时 5 个、整个服务每天 100 个
- 每个同步空间：最多 4 台未撤销设备
- 每个同步空间：最多 100000 条密文操作、32 MiB 解码后密文

请求与密文格式限制同时存在于协议纯逻辑和 Worker 入口；创建、设备及容量额度由 Worker 与 D1 约束。若未来调整 Wire 协议，必须同步升级客户端模型并补充迁移测试。

## 已知限制与容量演进

- 当前服务端无法验证 AES-GCM 密文是否能被客户端解密，pull 又严格按游标顺序交付，尚无经设备共同确认的隔离或跳过协议。因此，一条由错误密钥产生或存储损坏的密文可能阻止客户端继续推进 cursor。本版保持失败即不 ack，不能由服务端擅自跳过或删除。
- 当前没有对外开放历史压缩 API。容量接近上限时，后续版本应先由客户端生成端到端加密 snapshot，再由所有未撤销设备确认 snapshot cursor，服务端才能删除此前日志；`track_change_log_delete` 会同步归还容量。同时必须持久保存 vault 的 server-seq 高水位，并将游标校验改为同时考虑 snapshot cursor，避免日志全部压缩后把合法 cursor 误判为超前。不能只依据单台设备的 ack 清理，否则离线设备可能永久丢失变更。
- 在压缩协议完成前，自托管实例如确需更大容量，应通过新的 D1 migration 同步调整容量触发器和服务端错误详情，或导出密文后迁移到独立数据库；不要直接修改 `vault_usage` 绕过限制。条数与密文字节额度不包含 SQLite 索引和元数据开销，因此不是 D1 实际磁盘占用的承诺。
