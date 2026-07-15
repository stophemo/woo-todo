# 同步与安全设计

## 为什么不使用夸克网盘实时同步

夸克 SVIP 提供的是文件存储权益，不等同于稳定的应用数据 API。即使未来提供 WebDAV 或开放接口，把 SQLite 或整份 JSON 当作文件在两个设备间覆盖，也会带来并发覆盖、半写入、重复上传和冲突不可解释等问题。

因此 v1 的分工是：

- Cloudflare Workers + D1：小粒度增量同步。
- 夸克网盘：保存用户主动导出的加密 `.wootodo` 备份。

若 Cloudflare 在实际网络中不稳定，客户端通过 `SyncProvider` 接口切换到 Supabase 或自托管实现，领域层和本地数据库无需变化。

## Local-first 流程

1. 用户操作在单个本地事务中更新任务并写入 outbox。
2. UI 立即从本地数据库得到结果。
3. 同步引擎在合适时机将 outbox 加密批量上传。
4. 服务端幂等接收后分配变更序号。
5. 客户端从已确认游标之后拉取其他设备的变更。
6. 客户端验证并解密 payload，在本地事务中合并并推进游标。

上传成功但响应丢失时，同一 `op_id` 可安全重试。

## 配对

首台设备创建同步空间后生成 `vault_key` 和恢复材料。新增设备配对时：

1. 已绑定设备向服务端创建 10 分钟有效的配对会话并显示二维码。
2. 新设备扫描二维码，上传自己的 X25519 临时公钥。
3. 两端显示相同的六位核对码。
4. 旧设备确认后，用协商出的会话密钥加密传递 `vault_key` 和新设备令牌。
5. 新设备将密钥保存到系统安全存储，配对会话立即失效。

二维码不直接包含长期同步密钥。配对和恢复失败不能绕过端到端加密边界。

二维码内容为自定义深链：

`wootodo://pair?endpoint=<HTTPS URL>&pairingId=<ID>&pairingSecret=<Base64URL>&initiatorPublicKey=<Base64URL>`

生产构建只接受 HTTPS endpoint；本地开发可显式允许 `http://127.0.0.1`。深链不得写入日志或统计。

配对派生必须在两端逐字一致：

- X25519 计算 32 字节共享秘密。
- HKDF-SHA256 的 salt 为 32 字节 `pairingSecret`，info 为 `woo-todo-pairing-v1|pairingId`，输出 32 字节 session key。
- 六位核对码输入为 `woo-todo-pairing-code-v1|initiatorPublicKey|claimPublicKey`；用 session key 做 HMAC-SHA256，取摘要前 4 字节的大端无符号数模 1,000,000，并补足六位。
- vault key envelope 的 AAD 为 `woo-todo-pair-v1|pairingId|claimedDeviceId`。

固定向量位于 `shared/fixtures/crypto-vectors.json`，Swift、Kotlin 和 Node 必须共同通过。

## 密文格式

- 算法：AES-256-GCM
- nonce：每个操作随机 96 位，禁止在同一 key 下复用
- AAD：`woo-todo-sync-v1|vaultId|opId|entityId|kind|lamport|deviceId`；所有影响幂等、路由与冲突决策的外层元数据都必须被认证
- ciphertext：JSON payload 加密结果与 128 位认证标签
- 编码：Base64URL，无填充

服务端不得记录请求正文、令牌、二维码内容或解密失败后的明文诊断信息。

## 恢复与撤销

- `.wootodo` 使用 NFKC + PBKDF2-HMAC-SHA256（默认 210000 轮）和 AES-256-GCM；任务、设备令牌与 `vault_key` 只存在于认证后的密文正文。
- 导入只允许空白安装；替换设备可恢复原逻辑设备身份，新增并存设备必须使用二维码配对。
- 备份默认不上传日志和遥测，夸克网盘只用于用户手动保存加密文件。
- 设备撤销后令牌立即失效，但无法擦除该设备此前已经下载的本地副本。
- 全部设备与恢复材料同时丢失时，云端密文不可恢复。
- 服务端数据丢失时，任一仍绑定的客户端都可重新上传加密快照。

文件格式、操作步骤和口令丢失边界见 [加密备份与恢复](BACKUP_AND_RESTORE.md)。

## 运维边界

- 每个请求限制变更数量和密文总大小。
- 设备令牌按 IP 与 vault 做速率限制。
- D1 定期保存加密快照，所有活跃设备确认后再清理旧日志。
- 免费额度和暂停政策属于外部条件，部署前必须查阅当时官方文档，不在代码中假设固定数值。
