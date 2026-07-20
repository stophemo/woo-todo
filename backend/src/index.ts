import { hashCredential, randomSecret } from "./crypto.ts";
import { vaultCapacityReachedError } from "./capacity.ts";
import {
  type AuthenticatedDevice,
  authenticateDevice,
  changedRows,
  type D1Result,
  type Env,
  hasDatabaseSignal,
  requireTokenPepper,
} from "./db.ts";
import { ApiError, errorResponse, jsonResponse, readJsonBody } from "./http.ts";
import {
  effectivePairingStatus,
  LIMITS,
  paginateOperations,
  type PairingStatus,
  parseCreatePairingRequest,
  parseCreateVaultRequest,
  parsePairingClaimRequest,
  parsePairingConfirmRequest,
  parsePairingResultRequest,
  parseSyncRequest,
  ProtocolValidationError,
  validateIdentifier,
} from "./protocol.ts";
import {
  assertVaultDeviceCapacity,
  consumeVaultCreationQuota,
  vaultDeviceLimitError,
} from "./quota.ts";
import {
  assertPushOperationIds,
  assertStoredOperationIds,
  assertValidSyncCursor,
  opIdConflictError,
} from "./sync-guards.ts";
import { assertVaultCreationInvite } from "./vault-creation-auth.ts";

const SERVICE_VERSION = "0.1.2";

interface PairingRow {
  id: string;
  vault_id: string;
  initiator_device_id: string;
  secret_hash: string;
  initiator_public_key: string;
  status: PairingStatus;
  claimed_device_id: string | null;
  claimed_device_name: string | null;
  claimed_platform: "macos" | "android" | null;
  claimed_public_key: string | null;
  claimed_token_hash: string | null;
  confirmed_ciphertext: string | null;
  confirmed_nonce: string | null;
  created_at: number;
  expires_at: number;
  claimed_at: number | null;
  confirmed_at: number | null;
}

interface ChangeRow {
  server_seq: number;
  op_id: string;
  device_id: string;
  entity_id: string;
  kind: string;
  lamport: number;
  ciphertext: string;
  nonce: string;
  created_at: number;
}

interface DeviceListRow {
  id: string;
  name: string;
  platform: "macos" | "android";
  public_key: string | null;
  created_at: number;
  last_seen_at: number | null;
  revoked_at: number | null;
}

function parseProtocol<T>(parser: (value: unknown) => T, value: unknown): T {
  try {
    return parser(value);
  } catch (error) {
    if (error instanceof ProtocolValidationError) {
      throw new ApiError(400, "VALIDATION_ERROR", error.message, {
        field: error.field,
      });
    }
    throw error;
  }
}

function statusName(status: PairingStatus): string {
  return status.toLowerCase();
}

async function markPairingExpired(
  env: Env,
  pairingId: string,
  now: number,
): Promise<void> {
  await env.DB.prepare(`
    UPDATE pairing_sessions
    SET status = 'EXPIRED'
    WHERE id = ?
      AND status IN ('OPEN', 'CLAIMED', 'CONFIRMED')
      AND expires_at <= ?
  `).bind(pairingId, now).run();
}

async function loadInitiatedPairing(
  env: Env,
  device: AuthenticatedDevice,
  pairingId: string,
): Promise<PairingRow> {
  const row = await env.DB.prepare(`
    SELECT *
    FROM pairing_sessions
    WHERE id = ? AND vault_id = ? AND initiator_device_id = ?
    LIMIT 1
  `).bind(pairingId, device.vaultId, device.id).first<PairingRow>();
  if (!row) {
    throw new ApiError(404, "PAIRING_NOT_FOUND", "配对会话不存在");
  }
  return row;
}

async function handleHealth(env: Env, requestId: string): Promise<Response> {
  const result = await env.DB.prepare(`
    SELECT COUNT(*) AS required_objects
    FROM sqlite_master
    WHERE (type = 'table' AND name IN (
         'vaults', 'vault_creation_windows', 'vault_usage'
       ))
       OR (type = 'trigger' AND name IN (
         'reject_change_log_op_id_conflict',
         'enforce_vault_active_device_limit',
         'initialize_vault_usage',
         'require_change_log_vault_usage',
         'enforce_change_log_vault_capacity',
         'track_change_log_insert',
         'track_change_log_delete'
       ))
  `).first<{ required_objects: number }>();
  if (result?.required_objects !== 10) {
    throw new ApiError(503, "DATABASE_UNAVAILABLE", "D1 健康检查未通过");
  }
  const missingUsage = await env.DB.prepare(`
    SELECT 1 AS missing_usage
    FROM vaults v
    LEFT JOIN vault_usage u ON u.vault_id = v.id
    WHERE u.vault_id IS NULL
    LIMIT 1
  `).first<{ missing_usage: 1 }>();
  if (missingUsage) {
    throw new ApiError(503, "DATABASE_UNAVAILABLE", "D1 健康检查未通过");
  }
  return jsonResponse({
    service: "woo-todo-sync",
    version: SERVICE_VERSION,
    status: "ok",
    database: "ok",
    serverTime: Date.now(),
  }, requestId);
}

async function handleCreateVault(
  request: Request,
  env: Env,
  requestId: string,
): Promise<Response> {
  await assertVaultCreationInvite(request, env);
  const input = parseProtocol(
    parseCreateVaultRequest,
    await readJsonBody(request),
  );
  const now = Date.now();
  const pepper = requireTokenPepper(env);
  await consumeVaultCreationQuota(request, env, now);
  const vaultId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const deviceToken = randomSecret();
  const tokenHash = await hashCredential(
    deviceToken,
    "device-token",
    pepper,
  );

  await env.DB.batch([
    env.DB.prepare(`
      INSERT INTO vaults(id, recovery_ciphertext, recovery_nonce, created_at)
      VALUES (?, ?, ?, ?)
    `).bind(
      vaultId,
      input.recoveryEnvelope?.ciphertext ?? null,
      input.recoveryEnvelope?.nonce ?? null,
      now,
    ),
    env.DB.prepare(`
      INSERT INTO devices(
        id, vault_id, token_hash, name, platform, public_key,
        created_by_device_id, created_at, last_seen_at, revoked_at
      ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, NULL)
    `).bind(
      deviceId,
      vaultId,
      tokenHash,
      input.device.name,
      input.device.platform,
      input.device.publicKey ?? null,
      now,
      now,
    ),
    env.DB.prepare(`
      INSERT INTO device_cursors(device_id, vault_id, cursor, updated_at)
      VALUES (?, ?, 0, ?)
    `).bind(deviceId, vaultId, now),
  ]);

  return jsonResponse(
    {
      vaultId,
      device: {
        id: deviceId,
        name: input.device.name,
        platform: input.device.platform,
        token: deviceToken,
      },
      serverTime: now,
    },
    requestId,
    201,
  );
}

async function handleCreatePairing(
  request: Request,
  env: Env,
  requestId: string,
  device: AuthenticatedDevice,
): Promise<Response> {
  const input = parseProtocol(
    parseCreatePairingRequest,
    await readJsonBody(request),
  );
  const now = Date.now();
  const expiresAt = now + LIMITS.pairingLifetimeMs;
  const pairingId = crypto.randomUUID();
  const pairingSecret = randomSecret();
  const secretHash = await hashCredential(
    pairingSecret,
    "pairing-secret",
    requireTokenPepper(env),
  );

  await env.DB.prepare(`
    INSERT INTO pairing_sessions(
      id, vault_id, initiator_device_id, secret_hash, initiator_public_key,
      status, created_at, expires_at
    ) VALUES (?, ?, ?, ?, ?, 'OPEN', ?, ?)
  `).bind(
    pairingId,
    device.vaultId,
    device.id,
    secretHash,
    input.publicKey,
    now,
    expiresAt,
  ).run();

  return jsonResponse(
    {
      pairingId,
      pairingSecret,
      initiatorPublicKey: input.publicKey,
      expiresAt,
      serverTime: now,
    },
    requestId,
    201,
  );
}

async function handleClaimPairing(
  request: Request,
  env: Env,
  requestId: string,
  pairingId: string,
): Promise<Response> {
  const input = parseProtocol(
    parsePairingClaimRequest,
    await readJsonBody(request),
  );
  const pepper = requireTokenPepper(env);
  const [secretHash, tokenHash] = await Promise.all([
    hashCredential(input.pairingSecret, "pairing-secret", pepper),
    hashCredential(input.deviceToken, "device-token", pepper),
  ]);
  const row = await env.DB.prepare(`
    SELECT * FROM pairing_sessions WHERE id = ? AND secret_hash = ? LIMIT 1
  `).bind(pairingId, secretHash).first<PairingRow>();
  if (!row) {
    throw new ApiError(404, "PAIRING_NOT_FOUND", "配对会话或配对密钥无效");
  }

  const now = Date.now();
  const effectiveStatus = effectivePairingStatus(
    row.status,
    row.expires_at,
    now,
  );
  if (effectiveStatus === "EXPIRED") {
    await markPairingExpired(env, pairingId, now);
    throw new ApiError(410, "PAIRING_EXPIRED", "配对会话已过期");
  }
  if (row.status === "CLAIMED" && row.claimed_token_hash === tokenHash) {
    return jsonResponse(
      {
        pairingId,
        status: "claimed",
        deviceId: row.claimed_device_id,
        expiresAt: row.expires_at,
      },
      requestId,
      202,
    );
  }
  if (row.status !== "OPEN") {
    throw new ApiError(409, "PAIRING_NOT_OPEN", "配对会话已被认领或结束");
  }
  await assertVaultDeviceCapacity(env, row.vault_id);

  const credentialInUse = await env.DB.prepare(`
    SELECT 1 AS found FROM devices WHERE token_hash = ?
    UNION ALL
    SELECT 1 AS found FROM pairing_sessions WHERE claimed_token_hash = ?
    LIMIT 1
  `).bind(tokenHash, tokenHash).first<{ found: number }>();
  if (credentialInUse) {
    throw new ApiError(
      409,
      "DEVICE_TOKEN_IN_USE",
      "新设备令牌已被使用，请重新生成",
    );
  }

  const claimedDeviceId = crypto.randomUUID();
  const result = await env.DB.prepare(`
    UPDATE OR IGNORE pairing_sessions
    SET status = 'CLAIMED',
        claimed_device_id = ?,
        claimed_device_name = ?,
        claimed_platform = ?,
        claimed_public_key = ?,
        claimed_token_hash = ?,
        claimed_at = ?
    WHERE id = ? AND secret_hash = ? AND status = 'OPEN' AND expires_at > ?
  `).bind(
    claimedDeviceId,
    input.device.name,
    input.device.platform,
    input.device.publicKey,
    tokenHash,
    now,
    pairingId,
    secretHash,
    now,
  ).run();
  if (changedRows(result) !== 1) {
    throw new ApiError(409, "PAIRING_CLAIM_RACE", "配对会话刚刚被其他设备认领");
  }

  return jsonResponse(
    {
      pairingId,
      status: "claimed",
      deviceId: claimedDeviceId,
      expiresAt: row.expires_at,
    },
    requestId,
    202,
  );
}

async function handlePairingStatus(
  env: Env,
  requestId: string,
  device: AuthenticatedDevice,
  pairingId: string,
): Promise<Response> {
  const row = await loadInitiatedPairing(env, device, pairingId);
  const now = Date.now();
  const status = effectivePairingStatus(row.status, row.expires_at, now);
  if (status === "EXPIRED" && row.status !== "EXPIRED") {
    await markPairingExpired(env, pairingId, now);
  }
  return jsonResponse({
    pairingId,
    status: statusName(status),
    expiresAt: row.expires_at,
    claim: row.claimed_device_id
      ? {
        deviceId: row.claimed_device_id,
        name: row.claimed_device_name,
        platform: row.claimed_platform,
        publicKey: row.claimed_public_key,
        claimedAt: row.claimed_at,
      }
      : null,
  }, requestId);
}

async function handleConfirmPairing(
  request: Request,
  env: Env,
  requestId: string,
  device: AuthenticatedDevice,
  pairingId: string,
): Promise<Response> {
  const input = parseProtocol(
    parsePairingConfirmRequest,
    await readJsonBody(request),
  );
  const row = await loadInitiatedPairing(env, device, pairingId);
  const now = Date.now();
  const effectiveStatus = effectivePairingStatus(
    row.status,
    row.expires_at,
    now,
  );
  if (effectiveStatus === "EXPIRED") {
    await markPairingExpired(env, pairingId, now);
    throw new ApiError(410, "PAIRING_EXPIRED", "配对会话已过期");
  }
  if (row.status === "CONFIRMED") {
    return jsonResponse({
      pairingId,
      status: "confirmed",
      deviceId: row.claimed_device_id,
    }, requestId);
  }
  if (row.status !== "CLAIMED") {
    throw new ApiError(409, "PAIRING_NOT_CLAIMED", "尚无新设备认领此配对会话");
  }
  await assertVaultDeviceCapacity(env, row.vault_id);

  let results: D1Result[];
  try {
    results = await env.DB.batch([
      env.DB.prepare(`
        INSERT OR IGNORE INTO devices(
          id, vault_id, token_hash, name, platform, public_key,
          created_by_device_id, created_at, last_seen_at, revoked_at
        )
        SELECT
          claimed_device_id, vault_id, claimed_token_hash, claimed_device_name,
          claimed_platform, claimed_public_key, ?, ?, NULL, NULL
        FROM pairing_sessions
        WHERE id = ? AND status = 'CLAIMED' AND expires_at > ?
      `).bind(device.id, now, pairingId, now),
      env.DB.prepare(`
        INSERT OR IGNORE INTO device_cursors(device_id, vault_id, cursor, updated_at)
        SELECT p.claimed_device_id, p.vault_id, 0, ?
        FROM pairing_sessions p
        INNER JOIN devices d
          ON d.id = p.claimed_device_id AND d.token_hash = p.claimed_token_hash
        WHERE p.id = ?
      `).bind(now, pairingId),
      env.DB.prepare(`
        UPDATE pairing_sessions
        SET status = 'CONFIRMED', confirmed_ciphertext = ?, confirmed_nonce = ?, confirmed_at = ?
        WHERE id = ?
          AND initiator_device_id = ?
          AND status = 'CLAIMED'
          AND expires_at > ?
          AND EXISTS (
            SELECT 1 FROM devices d
            WHERE d.id = pairing_sessions.claimed_device_id
              AND d.token_hash = pairing_sessions.claimed_token_hash
          )
      `).bind(
        input.vaultKeyEnvelope.ciphertext,
        input.vaultKeyEnvelope.nonce,
        now,
        pairingId,
        device.id,
        now,
      ),
      env.DB.prepare(`
        SELECT status, claimed_device_id
        FROM pairing_sessions
        WHERE id = ?
      `).bind(pairingId),
    ]);
  } catch (error) {
    if (hasDatabaseSignal(error, "VAULT_DEVICE_LIMIT")) {
      throw vaultDeviceLimitError();
    }
    throw error;
  }
  const finalResult = results[3] as D1Result<{
    status: PairingStatus;
    claimed_device_id: string | null;
  }>;
  const finalRow = finalResult.results?.[0];
  if (finalRow?.status !== "CONFIRMED") {
    throw new ApiError(
      409,
      "PAIRING_CONFIRM_FAILED",
      "无法创建设备，可能是设备令牌冲突或配对状态已改变",
    );
  }

  return jsonResponse({
    pairingId,
    status: "confirmed",
    deviceId: finalRow.claimed_device_id,
  }, requestId);
}

async function handlePairingResult(
  request: Request,
  env: Env,
  requestId: string,
  pairingId: string,
): Promise<Response> {
  const input = parseProtocol(
    parsePairingResultRequest,
    await readJsonBody(request),
  );
  const pepper = requireTokenPepper(env);
  const [secretHash, tokenHash] = await Promise.all([
    hashCredential(input.pairingSecret, "pairing-secret", pepper),
    hashCredential(input.deviceToken, "device-token", pepper),
  ]);
  const row = await env.DB.prepare(`
    SELECT *
    FROM pairing_sessions
    WHERE id = ? AND secret_hash = ? AND claimed_token_hash = ?
    LIMIT 1
  `).bind(pairingId, secretHash, tokenHash).first<PairingRow>();
  if (!row) {
    throw new ApiError(404, "PAIRING_NOT_FOUND", "配对会话或新设备凭据无效");
  }

  const now = Date.now();
  const status = effectivePairingStatus(row.status, row.expires_at, now);
  if (status === "EXPIRED") {
    await markPairingExpired(env, pairingId, now);
    throw new ApiError(410, "PAIRING_EXPIRED", "配对会话已过期");
  }
  if (status === "CLAIMED") {
    return jsonResponse(
      {
        pairingId,
        status: "claimed",
        expiresAt: row.expires_at,
      },
      requestId,
      202,
    );
  }
  if (
    status !== "CONFIRMED" || !row.confirmed_ciphertext || !row.confirmed_nonce
  ) {
    throw new ApiError(409, "PAIRING_NOT_CONFIRMED", "配对尚未确认或已取消");
  }

  return jsonResponse({
    pairingId,
    status: "confirmed",
    vaultId: row.vault_id,
    deviceId: row.claimed_device_id,
    initiatorPublicKey: row.initiator_public_key,
    vaultKeyEnvelope: {
      ciphertext: row.confirmed_ciphertext,
      nonce: row.confirmed_nonce,
    },
    expiresAt: row.expires_at,
  }, requestId);
}

async function handleSync(
  request: Request,
  env: Env,
  requestId: string,
  device: AuthenticatedDevice,
): Promise<Response> {
  const input = parseProtocol(parseSyncRequest, await readJsonBody(request));
  assertPushOperationIds(input.push);
  await assertValidSyncCursor(env, device.vaultId, input.cursor);
  await assertStoredOperationIds(env, device.vaultId, input.push);
  const now = Date.now();
  const statements = input.push.map((operation) =>
    env.DB.prepare(`
    INSERT OR IGNORE INTO change_log(
      vault_id, op_id, device_id, entity_id, kind,
      lamport, ciphertext, nonce, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).bind(
        device.vaultId,
        operation.opId,
        device.id,
        operation.entityId,
        operation.kind,
        operation.lamport,
        operation.ciphertext,
        operation.nonce,
        now,
      )
  );
  statements.push(
    env.DB.prepare(`
      INSERT INTO device_cursors(device_id, vault_id, cursor, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(device_id) DO UPDATE SET
        cursor = MAX(device_cursors.cursor, excluded.cursor),
        updated_at = excluded.updated_at
    `).bind(device.id, device.vaultId, input.ack, now),
    env.DB.prepare(`
      UPDATE devices SET last_seen_at = ? WHERE id = ? AND revoked_at IS NULL
    `).bind(now, device.id),
    env.DB.prepare(`
      SELECT
        server_seq, op_id, device_id, entity_id, kind,
        lamport, ciphertext, nonce, created_at
      FROM change_log
      WHERE vault_id = ? AND server_seq > ?
      ORDER BY server_seq ASC
      LIMIT ?
    `).bind(device.vaultId, input.cursor, input.pullLimit + 1),
  );

  let results: D1Result[];
  try {
    results = await env.DB.batch(statements);
  } catch (error) {
    if (hasDatabaseSignal(error, "OP_ID_CONFLICT")) {
      throw opIdConflictError();
    }
    if (hasDatabaseSignal(error, "VAULT_CAPACITY_REACHED")) {
      throw vaultCapacityReachedError();
    }
    if (hasDatabaseSignal(error, "VAULT_USAGE_MISSING")) {
      throw new ApiError(
        503,
        "VAULT_USAGE_UNAVAILABLE",
        "同步空间容量账本缺失，请联系服务维护者修复迁移",
      );
    }
    throw error;
  }
  const inserted = results
    .slice(0, input.push.length)
    .reduce((total, result) => total + changedRows(result), 0);
  const pullResult = results[input.push.length + 2] as unknown as D1Result<
    ChangeRow
  >;
  const rows = (pullResult.results ?? []).map((row) => ({
    serverSeq: row.server_seq,
    opId: row.op_id,
    deviceId: row.device_id,
    entityId: row.entity_id,
    kind: row.kind,
    lamport: row.lamport,
    ciphertext: row.ciphertext,
    nonce: row.nonce,
    createdAt: row.created_at,
  }));
  const page = paginateOperations(rows, input.pullLimit, input.cursor);

  return jsonResponse({
    push: {
      received: input.push.length,
      inserted,
      duplicates: input.push.length - inserted,
    },
    pull: page.operations,
    cursor: page.cursor,
    hasMore: page.hasMore,
    serverTime: now,
  }, requestId);
}

async function handleListDevices(
  env: Env,
  requestId: string,
  device: AuthenticatedDevice,
): Promise<Response> {
  const result = await env.DB.prepare(`
    SELECT id, name, platform, public_key, created_at, last_seen_at, revoked_at
    FROM devices
    WHERE vault_id = ?
    ORDER BY created_at ASC
  `).bind(device.vaultId).all<DeviceListRow>();
  return jsonResponse({
    devices: (result.results ?? []).map((row) => ({
      id: row.id,
      name: row.name,
      platform: row.platform,
      publicKey: row.public_key,
      createdAt: row.created_at,
      lastSeenAt: row.last_seen_at,
      revokedAt: row.revoked_at,
      isCurrent: row.id === device.id,
    })),
  }, requestId);
}

async function handleRevokeDevice(
  env: Env,
  requestId: string,
  device: AuthenticatedDevice,
  rawTargetId: string,
): Promise<Response> {
  let targetId: string;
  try {
    targetId = validateIdentifier(rawTargetId, "deviceId");
  } catch (error) {
    if (error instanceof ProtocolValidationError) {
      throw new ApiError(400, "VALIDATION_ERROR", error.message, {
        field: error.field,
      });
    }
    throw error;
  }
  if (targetId === device.id) {
    throw new ApiError(409, "CANNOT_REVOKE_SELF", "当前设备不能撤销自身");
  }

  const target = await env.DB.prepare(`
    SELECT id, revoked_at FROM devices WHERE id = ? AND vault_id = ? LIMIT 1
  `).bind(targetId, device.vaultId).first<
    { id: string; revoked_at: number | null }
  >();
  if (!target) {
    throw new ApiError(404, "DEVICE_NOT_FOUND", "目标设备不存在");
  }
  if (target.revoked_at !== null) {
    return jsonResponse(
      { deviceId: targetId, revokedAt: target.revoked_at },
      requestId,
    );
  }

  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare(`
      UPDATE devices SET revoked_at = ?
      WHERE id = ? AND vault_id = ? AND revoked_at IS NULL
    `).bind(now, targetId, device.vaultId),
    env.DB.prepare(`
      UPDATE pairing_sessions SET status = 'CANCELED'
      WHERE initiator_device_id = ? AND status IN ('OPEN', 'CLAIMED')
    `).bind(targetId),
  ]);
  return jsonResponse({ deviceId: targetId, revokedAt: now }, requestId);
}

function methodNotAllowed(): never {
  throw new ApiError(405, "METHOD_NOT_ALLOWED", "此资源不支持当前 HTTP 方法");
}

async function route(
  request: Request,
  env: Env,
  requestId: string,
): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname.length > 1 && url.pathname.endsWith("/")
    ? url.pathname.slice(0, -1)
    : url.pathname;

  if (path === "/health") {
    if (request.method !== "GET") methodNotAllowed();
    return handleHealth(env, requestId);
  }
  if (path === "/v1/vaults") {
    if (request.method !== "POST") methodNotAllowed();
    return handleCreateVault(request, env, requestId);
  }
  if (path === "/v1/pairings") {
    if (request.method !== "POST") methodNotAllowed();
    const device = await authenticateDevice(request, env);
    return handleCreatePairing(request, env, requestId, device);
  }
  if (path === "/v1/sync") {
    if (request.method !== "POST") methodNotAllowed();
    const device = await authenticateDevice(request, env);
    return handleSync(request, env, requestId, device);
  }
  if (path === "/v1/devices") {
    if (request.method !== "GET") methodNotAllowed();
    const device = await authenticateDevice(request, env);
    return handleListDevices(env, requestId, device);
  }

  const pairingAction = /^\/v1\/pairings\/([^/]+)\/(claim|confirm|result)$/u
    .exec(path);
  if (pairingAction) {
    const pairingId = pairingAction[1];
    const action = pairingAction[2];
    if (request.method !== "POST") methodNotAllowed();
    if (action === "claim") {
      return handleClaimPairing(request, env, requestId, pairingId);
    }
    if (action === "result") {
      return handlePairingResult(request, env, requestId, pairingId);
    }
    const device = await authenticateDevice(request, env);
    return handleConfirmPairing(request, env, requestId, device, pairingId);
  }

  const pairingStatus = /^\/v1\/pairings\/([^/]+)$/u.exec(path);
  if (pairingStatus) {
    if (request.method !== "GET") methodNotAllowed();
    const device = await authenticateDevice(request, env);
    return handlePairingStatus(env, requestId, device, pairingStatus[1]);
  }

  const deviceRevoke = /^\/v1\/devices\/([^/]+)\/revoke$/u.exec(path);
  if (deviceRevoke) {
    if (request.method !== "POST") methodNotAllowed();
    const device = await authenticateDevice(request, env);
    return handleRevokeDevice(env, requestId, device, deviceRevoke[1]);
  }

  throw new ApiError(404, "NOT_FOUND", "请求的资源不存在");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const requestId = request.headers.get("cf-ray") ?? crypto.randomUUID();
    try {
      return await route(request, env, requestId);
    } catch (error) {
      if (error instanceof ApiError) {
        return errorResponse(error, requestId);
      }
      console.error("同步服务处理请求时发生未预期错误", {
        requestId,
        method: request.method,
        path: new URL(request.url).pathname,
        error: error instanceof Error ? error.message : String(error),
      });
      return errorResponse(
        new ApiError(500, "INTERNAL_ERROR", "服务端发生未预期错误"),
        requestId,
      );
    }
  },
};
