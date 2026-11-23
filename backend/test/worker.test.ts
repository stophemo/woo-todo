import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import { VAULT_CAPACITY } from "../src/capacity.ts";
import { hashCredential } from "../src/crypto.ts";
import worker from "../src/index.ts";
import { VAULT_CREATION_INVITE_HEADER } from "../src/vault-creation-auth.ts";

const migrationsDirectory = new URL("../migrations/", import.meta.url);
const migrationNames = readdirSync(migrationsDirectory)
  .filter((name) => /^\d+_.+\.sql$/u.test(name))
  .sort();

class MemoryStatement {
  readonly database: DatabaseSync;
  readonly sql: string;
  readonly values: unknown[];

  constructor(database: DatabaseSync, sql: string, values: unknown[] = []) {
    this.database = database;
    this.sql = sql;
    this.values = values;
  }

  bind(...values: unknown[]): MemoryStatement {
    return new MemoryStatement(this.database, this.sql, values);
  }

  async first<T>(): Promise<T | null> {
    const row = this.database.prepare(this.sql).get(...this.values);
    return (row as T | undefined) ?? null;
  }

  async all<T>(): Promise<
    { success: true; results: T[]; meta: { changes: number } }
  > {
    const rows = this.database.prepare(this.sql).all(...this.values) as T[];
    return { success: true, results: rows, meta: { changes: 0 } };
  }

  async run(): Promise<
    { success: true; results: []; meta: { changes: number } }
  > {
    const result = this.database.prepare(this.sql).run(...this.values);
    return {
      success: true,
      results: [],
      meta: { changes: Number(result.changes) },
    };
  }

  executeForBatch(): {
    success: true;
    results: Record<string, unknown>[];
    meta: { changes: number };
  } {
    if (
      /^\s*(SELECT|WITH|PRAGMA)\b/iu.test(this.sql) ||
      /\bRETURNING\b/iu.test(this.sql)
    ) {
      const rows = this.database.prepare(this.sql).all(
        ...this.values,
      ) as Record<string, unknown>[];
      return { success: true, results: rows, meta: { changes: 0 } };
    }
    const result = this.database.prepare(this.sql).run(...this.values);
    return {
      success: true,
      results: [],
      meta: { changes: Number(result.changes) },
    };
  }
}

const TEST_INVITE_CODE = "test-vault-invite-code-1234567890";

interface TestEnv {
  DB: MemoryD1;
  TOKEN_PEPPER: string;
  VAULT_CREATION_INVITE_CODE?: string;
  APP_ENV: string;
  VAULT_CREATION_SOURCE_LIMIT?: string;
  VAULT_CREATION_DAILY_LIMIT?: string;
}

class MemoryD1 {
  readonly database = new DatabaseSync(":memory:");

  constructor(throughMigration = migrationNames.at(-1)) {
    for (const migrationName of migrationNames) {
      if (throughMigration && migrationName > throughMigration) break;
      this.applyMigration(migrationName);
    }
  }

  applyMigration(migrationName: string): void {
    const migration = readFileSync(
      new URL(migrationName, migrationsDirectory),
      "utf8",
    );
    this.database.exec(migration);
  }

  prepare(sql: string): MemoryStatement {
    return new MemoryStatement(this.database, sql);
  }

  async batch(
    statements: MemoryStatement[],
  ): Promise<ReturnType<MemoryStatement["executeForBatch"]>[]> {
    this.database.exec("BEGIN IMMEDIATE");
    try {
      const results = statements.map((statement) =>
        statement.executeForBatch()
      );
      this.database.exec("COMMIT");
      return results;
    } catch (error) {
      this.database.exec("ROLLBACK");
      throw error;
    }
  }

  close(): void {
    this.database.close();
  }
}

function encodedBytes(length: number, fill: number): string {
  return Buffer.alloc(length, fill).toString("base64url");
}

async function callApi(
  env: TestEnv,
  method: string,
  path: string,
  body?: unknown,
  token?: string,
  sourceAddress = "203.0.113.10",
  inviteCode: string | null | undefined = env.VAULT_CREATION_INVITE_CODE,
): Promise<{ status: number; payload: any }> {
  const headers = new Headers();
  if (body !== undefined) headers.set("content-type", "application/json");
  if (token) headers.set("authorization", `Bearer ${token}`);
  if (inviteCode !== null && inviteCode !== undefined) {
    headers.set(VAULT_CREATION_INVITE_HEADER, inviteCode);
  }
  headers.set("cf-connecting-ip", sourceAddress);
  const request = new Request(`https://sync.example.test${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const response = await worker.fetch(request, env as never);
  return { status: response.status, payload: await response.json() };
}

interface TestVault {
  token: string;
  deviceId: string;
  vaultId: string;
}

async function createVaultForTest(
  env: TestEnv,
  name = "Mac",
  platform: "macos" | "android" | "windows" = "macos",
  sourceAddress = "203.0.113.10",
): Promise<TestVault> {
  const created = await callApi(
    env,
    "POST",
    "/v1/vaults",
    { device: { name, platform } },
    undefined,
    sourceAddress,
  );
  assert.equal(created.status, 201);
  return {
    token: created.payload.data.device.token as string,
    deviceId: created.payload.data.device.id as string,
    vaultId: created.payload.data.vaultId as string,
  };
}

async function pairViaDisplayedCode(
  env: TestEnv,
  existingToken: string,
  fill: number,
  device: { name: string; platform: "macos" | "android" | "windows" },
  sourceAddress = "203.0.113.10",
): Promise<{ pairingId: string; deviceId: string; deviceToken: string }> {
  const codeResult = await callApi(
    env,
    "POST",
    "/v1/pairings/code",
    { publicKey: encodedBytes(32, fill) },
    existingToken,
    sourceAddress,
  );
  assert.equal(codeResult.status, 201);
  const resolved = await callApi(
    env,
    "POST",
    "/v1/pairings/resolve",
    { code: codeResult.payload.data.shortCode },
    undefined,
    sourceAddress,
  );
  assert.equal(resolved.status, 200);
  const pairingId = resolved.payload.data.pairingId as string;
  const pairingSecret = resolved.payload.data.pairingSecret as string;
  const deviceToken = encodedBytes(32, fill + 1);
  const claimed = await callApi(
    env,
    "POST",
    `/v1/pairings/${pairingId}/claim`,
    {
      pairingSecret,
      deviceToken,
      device: { ...device, publicKey: encodedBytes(32, fill + 2) },
    },
    undefined,
    sourceAddress,
  );
  assert.equal(claimed.status, 202);
  const confirmed = await callApi(
    env,
    "POST",
    `/v1/pairings/${pairingId}/confirm`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, fill + 3),
        nonce: encodedBytes(12, fill + 4),
      },
    },
    existingToken,
    sourceAddress,
  );
  assert.equal(confirmed.status, 200);
  const result = await callApi(
    env,
    "POST",
    `/v1/pairings/${pairingId}/result`,
    { pairingSecret, deviceToken },
    undefined,
    sourceAddress,
  );
  assert.equal(result.status, 200);
  return {
    pairingId,
    deviceId: result.payload.data.deviceId as string,
    deviceToken,
  };
}

async function createJoinRequestForTest(
  env: TestEnv,
  fill: number,
  device: { name: string; platform: "macos" | "android" | "windows" },
  sourceAddress = "203.0.113.10",
): Promise<{
  joinRequestId: string;
  joinSecret: string;
  shortCode: string;
  deviceId: string;
  joinToken: string;
}> {
  const joinToken = encodedBytes(32, fill);
  const join = await callApi(
    env,
    "POST",
    "/v1/pairings/join",
    {
      publicKey: encodedBytes(32, fill + 1),
      deviceToken: joinToken,
      device,
    },
    undefined,
    sourceAddress,
  );
  assert.equal(join.status, 201);
  return {
    joinRequestId: join.payload.data.joinRequestId as string,
    joinSecret: join.payload.data.joinSecret as string,
    shortCode: join.payload.data.shortCode as string,
    deviceId: join.payload.data.deviceId as string,
    joinToken,
  };
}

test("Windows 平台迁移保留既有设备、日志、游标与快照", (context) => {
  const db = new MemoryD1("0004_reopen_operation.sql");
  context.after(() => db.close());
  db.database.exec(`
    INSERT INTO vaults(id, created_at) VALUES ('vault-existing', 100);
    INSERT INTO devices(
      id, vault_id, token_hash, name, platform, public_key,
      created_by_device_id, created_at, last_seen_at, revoked_at
    ) VALUES (
      'device-mac', 'vault-existing', 'token-mac', 'Mac', 'macos',
      'public-mac', NULL, 101, 102, NULL
    );
    INSERT INTO devices(
      id, vault_id, token_hash, name, platform, public_key,
      created_by_device_id, created_at, last_seen_at, revoked_at
    ) VALUES (
      'device-android', 'vault-existing', 'token-android', 'Android', 'android',
      'public-android', 'device-mac', 103, 104, NULL
    );
    INSERT INTO pairing_sessions(
      id, vault_id, initiator_device_id, secret_hash, initiator_public_key,
      status, created_at, expires_at
    ) VALUES (
      'pair-existing', 'vault-existing', 'device-mac', 'pair-secret',
      'pair-public', 'OPEN', 105, 999
    );
    INSERT INTO change_log(
      vault_id, op_id, device_id, entity_id, kind, lamport,
      ciphertext, nonce, created_at
    ) VALUES (
      'vault-existing', 'op-existing', 'device-mac', 'task-existing',
      'reopen', 7, 'aaaa', 'bbbb', 106
    );
    INSERT INTO device_cursors(device_id, vault_id, cursor, updated_at)
    VALUES ('device-android', 'vault-existing', 1, 107);
    INSERT INTO encrypted_snapshots(
      id, vault_id, cursor, ciphertext, nonce, created_by_device_id, created_at
    ) VALUES (
      'snapshot-existing', 'vault-existing', 1, 'cccc', 'dddd',
      'device-mac', 108
    );
  `);
  const usageBefore = db.database.prepare(`
    SELECT operation_count, ciphertext_bytes
    FROM vault_usage WHERE vault_id = 'vault-existing'
  `).get() as { operation_count: number; ciphertext_bytes: number };

  db.applyMigration("0005_windows_platform.sql");

  const linkedDevice = db.database.prepare(`
    SELECT platform, created_by_device_id
    FROM devices WHERE id = 'device-android'
  `).get() as { platform: string; created_by_device_id: string };
  assert.equal(linkedDevice.platform, "android");
  assert.equal(linkedDevice.created_by_device_id, "device-mac");
  assert.equal(
    db.database.prepare("SELECT COUNT(*) AS count FROM pairing_sessions")
      .get().count,
    1,
  );
  assert.equal(
    db.database.prepare("SELECT kind FROM change_log").get().kind,
    "reopen",
  );
  assert.equal(
    db.database.prepare("SELECT cursor FROM device_cursors").get().cursor,
    1,
  );
  assert.equal(
    db.database.prepare("SELECT id FROM encrypted_snapshots").get().id,
    "snapshot-existing",
  );
  assert.deepEqual(
    db.database.prepare(`
      SELECT operation_count, ciphertext_bytes
      FROM vault_usage WHERE vault_id = 'vault-existing'
    `).get(),
    usageBefore,
  );
  assert.deepEqual(db.database.prepare("PRAGMA foreign_key_check").all(), []);

  db.database.prepare(`
    INSERT INTO devices(
      id, vault_id, token_hash, name, platform, created_at
    ) VALUES (?, ?, ?, ?, ?, ?)
  `).run(
    "device-windows",
    "vault-existing",
    "token-windows",
    "Windows",
    "windows",
    109,
  );
  assert.equal(
    db.database.prepare("SELECT platform FROM devices WHERE id = ?")
      .get("device-windows").platform,
    "windows",
  );
});

test("创建同步空间必须提供部署者邀请码且非法请求不消耗额度", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const body = {
    device: { name: "邀请码测试 Mac", platform: "macos" },
  };
  const env: TestEnv = {
    DB: db,
    TOKEN_PEPPER: "邀请码测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };

  const missing = await callApi(
    env,
    "POST",
    "/v1/vaults",
    body,
    undefined,
    "203.0.113.20",
    null,
  );
  assert.equal(missing.status, 403);
  assert.equal(missing.payload.error.code, "INVALID_INVITE_CODE");

  const wrongCode = "wrong-vault-invite-code-1234567890";
  const invalid = await callApi(
    env,
    "POST",
    "/v1/vaults",
    body,
    undefined,
    "203.0.113.20",
    wrongCode,
  );
  assert.equal(invalid.status, 403);
  assert.equal(invalid.payload.error.code, "INVALID_INVITE_CODE");
  assert.equal(JSON.stringify(invalid.payload).includes(wrongCode), false);

  const countersBeforeSuccess = db.database.prepare(`
    SELECT COUNT(*) AS count FROM vault_creation_windows
  `).get() as { count: number };
  assert.equal(countersBeforeSuccess.count, 0);

  const created = await callApi(env, "POST", "/v1/vaults", body);
  assert.equal(created.status, 201);
  const countersAfterSuccess = db.database.prepare(`
    SELECT COUNT(*) AS count FROM vault_creation_windows
  `).get() as { count: number };
  assert.equal(countersAfterSuccess.count, 2);

  const unconfiguredDb = new MemoryD1();
  context.after(() => unconfiguredDb.close());
  const unconfigured = await callApi(
    {
      DB: unconfiguredDb,
      TOKEN_PEPPER: env.TOKEN_PEPPER,
      APP_ENV: "test",
    },
    "POST",
    "/v1/vaults",
    body,
  );
  assert.equal(unconfigured.status, 500);
  assert.equal(unconfigured.payload.error.code, "SERVER_MISCONFIGURED");
});

test("vault、配对、密文同步、幂等与撤销形成完整闭环", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env = {
    DB: db,
    TOKEN_PEPPER: "集成测试专用且长度超过三十二字符的随机pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };

  const health = await callApi(env, "GET", "/health");
  assert.equal(health.status, 200);
  assert.equal(health.payload.data.version, "0.2.0");
  assert.equal(health.payload.data.database, "ok");

  const created = await callApi(env, "POST", "/v1/vaults", {
    device: { name: "MacBook Air", platform: "macos" },
  });
  assert.equal(created.status, 201);
  assert.equal(created.payload.ok, true);
  const macToken = created.payload.data.device.token as string;
  const macDeviceId = created.payload.data.device.id as string;
  const vaultId = created.payload.data.vaultId as string;

  const pairing = await callApi(env, "POST", "/v1/pairings", {
    publicKey: encodedBytes(32, 1),
  }, macToken);
  assert.equal(pairing.status, 201);
  const pairingId = pairing.payload.data.pairingId as string;
  const pairingSecret = pairing.payload.data.pairingSecret as string;
  const androidToken = encodedBytes(32, 2);

  const claimed = await callApi(
    env,
    "POST",
    `/v1/pairings/${pairingId}/claim`,
    {
      pairingSecret,
      deviceToken: androidToken,
      device: {
        name: "Android 测试设备",
        platform: "android",
        publicKey: encodedBytes(32, 3),
      },
    },
  );
  assert.equal(claimed.status, 202);

  const confirmed = await callApi(
    env,
    "POST",
    `/v1/pairings/${pairingId}/confirm`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, 4),
        nonce: encodedBytes(12, 5),
      },
    },
    macToken,
  );
  assert.equal(confirmed.status, 200);

  const result = await callApi(
    env,
    "POST",
    `/v1/pairings/${pairingId}/result`,
    {
      pairingSecret,
      deviceToken: androidToken,
    },
  );
  assert.equal(result.status, 200);
  assert.equal(result.payload.data.vaultId, vaultId);
  assert.equal(
    result.payload.data.vaultKeyEnvelope.ciphertext,
    encodedBytes(48, 4),
  );

  const operation = {
    opId: "op-integration-1",
    entityId: "task-integration-1",
    kind: "upsert",
    lamport: 1,
    ciphertext: encodedBytes(32, 6),
    nonce: encodedBytes(12, 7),
  };
  const firstSync = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [operation],
  }, macToken);
  assert.equal(firstSync.status, 200);
  assert.equal(firstSync.payload.data.push.inserted, 1);
  assert.equal(firstSync.payload.data.pull[0].ciphertext, operation.ciphertext);

  const replay = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [operation],
  }, androidToken);
  assert.equal(replay.status, 200);
  assert.equal(replay.payload.data.push.inserted, 0);
  assert.equal(replay.payload.data.push.duplicates, 1);
  assert.equal(replay.payload.data.pull.length, 1);

  const conflictingReplay = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [{ ...operation, ciphertext: encodedBytes(32, 8) }],
  }, androidToken);
  assert.equal(conflictingReplay.status, 409);
  assert.equal(conflictingReplay.payload.error.code, "OP_ID_CONFLICT");
  assert.equal(
    conflictingReplay.payload.error.details.opId,
    operation.opId,
  );

  const conflictingBatch = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [
      { ...operation, opId: "op-conflicting-batch" },
      {
        ...operation,
        opId: "op-conflicting-batch",
        lamport: 2,
      },
    ],
  }, macToken);
  assert.equal(conflictingBatch.status, 409);
  assert.equal(conflictingBatch.payload.error.code, "OP_ID_CONFLICT");
  const conflictingRows = db.database.prepare(`
    SELECT COUNT(*) AS count FROM change_log WHERE op_id = ?
  `).get("op-conflicting-batch") as { count: number };
  assert.equal(conflictingRows.count, 0);

  const cursorAhead = await callApi(env, "POST", "/v1/sync", {
    cursor: 999,
    push: [],
  }, macToken);
  assert.equal(cursorAhead.status, 409);
  assert.equal(cursorAhead.payload.error.code, "CURSOR_AHEAD");
  assert.equal(cursorAhead.payload.error.details.cursor, 999);
  assert.equal(cursorAhead.payload.error.details.maxCursor, 1);

  const unchanged = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [],
  }, macToken);
  assert.equal(unchanged.status, 200);
  assert.equal(unchanged.payload.data.pull.length, 1);
  assert.equal(unchanged.payload.data.pull[0].ciphertext, operation.ciphertext);
  assert.throws(
    () =>
      db.database.prepare(`
        INSERT OR IGNORE INTO change_log(
          vault_id, op_id, device_id, entity_id, kind,
          lamport, ciphertext, nonce, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        vaultId,
        operation.opId,
        macDeviceId,
        operation.entityId,
        operation.kind,
        operation.lamport,
        encodedBytes(32, 9),
        operation.nonce,
        Date.now(),
      ),
    /OP_ID_CONFLICT/u,
  );

  const androidDeviceId = result.payload.data.deviceId as string;
  const revoked = await callApi(
    env,
    "POST",
    `/v1/devices/${androidDeviceId}/revoke`,
    {},
    macToken,
  );
  assert.equal(revoked.status, 200);

  const denied = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [],
  }, androidToken);
  assert.equal(denied.status, 403);
  assert.equal(denied.payload.error.code, "DEVICE_REVOKED");
});

test("非零 cursor 必须是当前同步空间真实存在的服务端序号", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env = {
    DB: db,
    TOKEN_PEPPER: "游标空洞测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const create = async (name: string, sourceAddress: string) => {
    const response = await callApi(
      env,
      "POST",
      "/v1/vaults",
      { device: { name, platform: "macos" } },
      undefined,
      sourceAddress,
    );
    assert.equal(response.status, 201);
    return response.payload.data.device.token as string;
  };
  const vaultAToken = await create("空间 A", "203.0.113.31");
  const vaultBToken = await create("空间 B", "203.0.113.32");
  const operation = (opId: string, fill: number) => ({
    opId,
    entityId: `task-${opId}`,
    kind: "upsert",
    lamport: fill,
    ciphertext: encodedBytes(16, fill),
    nonce: encodedBytes(12, fill + 1),
  });

  const vaultAFirst = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [operation("vault-a-first", 1)],
  }, vaultAToken);
  assert.equal(vaultAFirst.status, 200);
  assert.equal(vaultAFirst.payload.data.cursor, 1);

  const vaultBMiddle = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [operation("vault-b-middle", 3)],
  }, vaultBToken);
  assert.equal(vaultBMiddle.status, 200);
  assert.equal(vaultBMiddle.payload.data.pull[0].serverSeq, 2);

  const vaultALast = await callApi(env, "POST", "/v1/sync", {
    cursor: 1,
    push: [operation("vault-a-last", 5)],
  }, vaultAToken);
  assert.equal(vaultALast.status, 200);
  assert.equal(vaultALast.payload.data.cursor, 3);

  const foreignHole = await callApi(env, "POST", "/v1/sync", {
    cursor: 2,
    push: [],
  }, vaultAToken);
  assert.equal(foreignHole.status, 409);
  assert.equal(foreignHole.payload.error.code, "CURSOR_NOT_FOUND");
  assert.deepEqual(foreignHole.payload.error.details, {
    cursor: 2,
    maxCursor: 3,
  });

  const validLatest = await callApi(env, "POST", "/v1/sync", {
    cursor: 3,
    push: [],
  }, vaultAToken);
  assert.equal(validLatest.status, 200);
  assert.equal(validLatest.payload.data.pull.length, 0);
  assert.equal(validLatest.payload.data.cursor, 3);
});

test("创建同步空间同时受来源小时额度和服务每日额度保护", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env = {
    DB: db,
    TOKEN_PEPPER: "创建额度测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
    VAULT_CREATION_SOURCE_LIMIT: "2",
    VAULT_CREATION_DAILY_LIMIT: "3",
  };
  const body = {
    device: { name: "测试 Mac", platform: "macos" },
  };

  assert.equal(
    (await callApi(env, "POST", "/v1/vaults", body, undefined, "203.0.113.1"))
      .status,
    201,
  );
  assert.equal(
    (await callApi(env, "POST", "/v1/vaults", body, undefined, "203.0.113.1"))
      .status,
    201,
  );
  const sourceLimited = await callApi(
    env,
    "POST",
    "/v1/vaults",
    body,
    undefined,
    "203.0.113.1",
  );
  assert.equal(sourceLimited.status, 429);
  assert.equal(sourceLimited.payload.error.code, "VAULT_CREATE_RATE_LIMITED");
  assert.equal(sourceLimited.payload.error.details.scope, "source");
  assert.equal(sourceLimited.payload.error.details.limit, 2);
  assert.ok(sourceLimited.payload.error.details.retryAfterSeconds > 0);

  const thirdAllowed = await callApi(
    env,
    "POST",
    "/v1/vaults",
    body,
    undefined,
    "203.0.113.2",
  );
  assert.equal(thirdAllowed.status, 201);
  const serviceLimited = await callApi(
    env,
    "POST",
    "/v1/vaults",
    body,
    undefined,
    "203.0.113.3",
  );
  assert.equal(serviceLimited.status, 429);
  assert.equal(serviceLimited.payload.error.code, "VAULT_CREATE_RATE_LIMITED");
  assert.equal(serviceLimited.payload.error.details.scope, "service");
  assert.equal(serviceLimited.payload.error.details.limit, 3);

  const vaultCount = db.database.prepare(`
    SELECT COUNT(*) AS count FROM vaults
  `).get() as { count: number };
  assert.equal(vaultCount.count, 3);
  const storedSources = db.database.prepare(`
    SELECT subject_hash FROM vault_creation_windows WHERE scope = 'source'
  `).all() as Array<{ subject_hash: string }>;
  assert.equal(storedSources.length, 2);
  assert.ok(storedSources.every((row) => /^[a-f0-9]{64}$/u.test(row.subject_hash)));
  assert.ok(storedSources.every((row) => !row.subject_hash.includes("203.0.113")));
  const serviceCounter = db.database.prepare(`
    SELECT request_count
    FROM vault_creation_windows
    WHERE scope = 'service' AND subject_hash = 'all'
  `).get() as { request_count: number };
  assert.equal(serviceCounter.request_count, 3);
});

test("同步空间最多允许四台活跃设备且撤销后可继续配对", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env = {
    DB: db,
    TOKEN_PEPPER: "设备额度测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const created = await callApi(env, "POST", "/v1/vaults", {
    device: { name: "MacBook Air", platform: "macos" },
  });
  assert.equal(created.status, 201);
  const vaultId = created.payload.data.vaultId as string;
  const macToken = created.payload.data.device.token as string;
  const macDeviceId = created.payload.data.device.id as string;
  const insertDevice = db.database.prepare(`
    INSERT INTO devices(
      id, vault_id, token_hash, name, platform, public_key,
      created_by_device_id, created_at, last_seen_at, revoked_at
    ) VALUES (?, ?, ?, ?, 'android', NULL, ?, ?, NULL, NULL)
  `);
  for (let index = 1; index <= 3; index += 1) {
    insertDevice.run(
      `seed-device-${index}`,
      vaultId,
      `seed-token-hash-${index}`,
      `测试设备 ${index}`,
      macDeviceId,
      Date.now(),
    );
  }
  assert.throws(
    () =>
      insertDevice.run(
        "seed-device-over-limit",
        vaultId,
        "seed-token-hash-over-limit",
        "超额设备",
        macDeviceId,
        Date.now(),
      ),
    /VAULT_DEVICE_LIMIT/u,
  );

  const pairing = await callApi(env, "POST", "/v1/pairings", {
    publicKey: encodedBytes(32, 11),
  }, macToken);
  assert.equal(pairing.status, 201);
  const pairingId = pairing.payload.data.pairingId as string;
  const pairingSecret = pairing.payload.data.pairingSecret as string;
  const androidToken = encodedBytes(32, 12);
  const claimBody = {
    pairingSecret,
    deviceToken: androidToken,
    device: {
      name: "替换设备",
      platform: "android",
      publicKey: encodedBytes(32, 13),
    },
  };
  const blockedClaim = await callApi(
    env,
    "POST",
    `/v1/pairings/${pairingId}/claim`,
    claimBody,
  );
  assert.equal(blockedClaim.status, 409);
  assert.equal(blockedClaim.payload.error.code, "VAULT_DEVICE_LIMIT");
  assert.equal(blockedClaim.payload.error.details.limit, 4);

  const revoked = await callApi(
    env,
    "POST",
    "/v1/devices/seed-device-3/revoke",
    {},
    macToken,
  );
  assert.equal(revoked.status, 200);
  const claimed = await callApi(
    env,
    "POST",
    `/v1/pairings/${pairingId}/claim`,
    claimBody,
  );
  assert.equal(claimed.status, 202);
  const confirmed = await callApi(
    env,
    "POST",
    `/v1/pairings/${pairingId}/confirm`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, 14),
        nonce: encodedBytes(12, 15),
      },
    },
    macToken,
  );
  assert.equal(confirmed.status, 200);
});

test("容量迁移会回填既有日志并在插入删除时增量维护账本", async (context) => {
  const db = new MemoryD1("0002_sync_guards.sql");
  context.after(() => db.close());
  const vaultId = "vault-before-capacity-migration";
  const deviceId = "device-before-capacity-migration";
  db.database.prepare(`
    INSERT INTO vaults(id, recovery_ciphertext, recovery_nonce, created_at)
    VALUES (?, NULL, NULL, ?)
  `).run(vaultId, Date.now());
  db.database.prepare(`
    INSERT INTO devices(
      id, vault_id, token_hash, name, platform, public_key,
      created_by_device_id, created_at, last_seen_at, revoked_at
    ) VALUES (?, ?, ?, '迁移测试设备', 'macos', NULL, NULL, ?, NULL, NULL)
  `).run(deviceId, vaultId, "migration-token-hash", Date.now());
  db.database.prepare(`
    INSERT INTO change_log(
      vault_id, op_id, device_id, entity_id, kind,
      lamport, ciphertext, nonce, created_at
    ) VALUES (?, 'op-before-migration', ?, 'task-before-migration',
      'upsert', 1, ?, ?, ?)
  `).run(
    vaultId,
    deviceId,
    encodedBytes(17, 21),
    encodedBytes(12, 22),
    Date.now(),
  );

  db.applyMigration("0003_vault_capacity.sql");
  const backfilled = db.database.prepare(`
    SELECT operation_count, ciphertext_bytes
    FROM vault_usage WHERE vault_id = ?
  `).get(vaultId) as { operation_count: number; ciphertext_bytes: number };
  assert.deepEqual({ ...backfilled }, {
    operation_count: 1,
    ciphertext_bytes: 17,
  });

  db.database.prepare(`
    INSERT INTO change_log(
      vault_id, op_id, device_id, entity_id, kind,
      lamport, ciphertext, nonce, created_at
    ) VALUES (?, 'op-after-migration', ?, 'task-after-migration',
      'upsert', 2, ?, ?, ?)
  `).run(
    vaultId,
    deviceId,
    encodedBytes(23, 23),
    encodedBytes(12, 24),
    Date.now(),
  );
  const incremented = db.database.prepare(`
    SELECT operation_count, ciphertext_bytes
    FROM vault_usage WHERE vault_id = ?
  `).get(vaultId) as { operation_count: number; ciphertext_bytes: number };
  assert.deepEqual({ ...incremented }, {
    operation_count: 2,
    ciphertext_bytes: 40,
  });

  db.database.prepare(`
    DELETE FROM change_log WHERE vault_id = ? AND op_id = 'op-before-migration'
  `).run(vaultId);
  const decremented = db.database.prepare(`
    SELECT operation_count, ciphertext_bytes
    FROM vault_usage WHERE vault_id = ?
  `).get(vaultId) as { operation_count: number; ciphertext_bytes: number };
  assert.deepEqual({ ...decremented }, {
    operation_count: 1,
    ciphertext_bytes: 23,
  });
});

test("同步空间条数和密文字节容量在并发及整批事务中不可越界", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env = {
    DB: db,
    TOKEN_PEPPER: "容量测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const created = await callApi(env, "POST", "/v1/vaults", {
    device: { name: "容量测试 Mac", platform: "macos" },
  });
  assert.equal(created.status, 201);
  const vaultId = created.payload.data.vaultId as string;
  const token = created.payload.data.device.token as string;
  const operation = (opId: string, fill: number) => ({
    opId,
    entityId: `task-${opId}`,
    kind: "upsert",
    lamport: fill,
    ciphertext: encodedBytes(16, fill),
    nonce: encodedBytes(12, fill + 1),
  });

  const initial = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [operation("capacity-initial", 31)],
  }, token);
  assert.equal(initial.status, 200);
  db.database.prepare(`
    UPDATE vault_usage
    SET operation_count = ?, ciphertext_bytes = 16
    WHERE vault_id = ?
  `).run(VAULT_CAPACITY.operations - 1, vaultId);

  const countBatch = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [
      operation("capacity-count-a", 33),
      operation("capacity-count-b", 35),
    ],
  }, token);
  assert.equal(countBatch.status, 507);
  assert.equal(countBatch.payload.error.code, "VAULT_CAPACITY_REACHED");
  assert.deepEqual(countBatch.payload.error.details, {
    maxOperations: VAULT_CAPACITY.operations,
    maxCiphertextBytes: VAULT_CAPACITY.ciphertextBytes,
  });
  const countBatchRows = db.database.prepare(`
    SELECT COUNT(*) AS count
    FROM change_log
    WHERE op_id IN ('capacity-count-a', 'capacity-count-b')
  `).get() as { count: number };
  assert.equal(countBatchRows.count, 0);
  const countAfterRollback = db.database.prepare(`
    SELECT operation_count FROM vault_usage WHERE vault_id = ?
  `).get(vaultId) as { operation_count: number };
  assert.equal(
    countAfterRollback.operation_count,
    VAULT_CAPACITY.operations - 1,
  );

  const countCandidates = [
    operation("capacity-count-a", 33),
    operation("capacity-count-b", 35),
  ];
  const concurrentCountResults = await Promise.all(
    countCandidates.map((candidate) =>
      callApi(env, "POST", "/v1/sync", {
        cursor: 0,
        push: [candidate],
      }, token)
    ),
  );
  assert.deepEqual(
    concurrentCountResults.map((result) => result.status).sort(),
    [200, 507],
  );
  const acceptedCountOperation = countCandidates[
    concurrentCountResults.findIndex((result) => result.status === 200)
  ];
  const duplicateAtCapacity = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [acceptedCountOperation],
  }, token);
  assert.equal(duplicateAtCapacity.status, 200);
  assert.equal(duplicateAtCapacity.payload.data.push.duplicates, 1);
  const overCountCapacity = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [operation("capacity-count-c", 36)],
  }, token);
  assert.equal(overCountCapacity.status, 507);
  assert.equal(overCountCapacity.payload.error.code, "VAULT_CAPACITY_REACHED");

  db.database.prepare(`
    UPDATE vault_usage
    SET operation_count = 2, ciphertext_bytes = ?
    WHERE vault_id = ?
  `).run(VAULT_CAPACITY.ciphertextBytes - 16, vaultId);
  const byteBatch = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [
      operation("capacity-bytes-a", 37),
      operation("capacity-bytes-b", 39),
    ],
  }, token);
  assert.equal(byteBatch.status, 507);
  assert.equal(byteBatch.payload.error.code, "VAULT_CAPACITY_REACHED");
  const byteBatchRows = db.database.prepare(`
    SELECT COUNT(*) AS count
    FROM change_log
    WHERE op_id IN ('capacity-bytes-a', 'capacity-bytes-b')
  `).get() as { count: number };
  assert.equal(byteBatchRows.count, 0);
  const bytesAfterRollback = db.database.prepare(`
    SELECT operation_count, ciphertext_bytes
    FROM vault_usage WHERE vault_id = ?
  `).get(vaultId) as { operation_count: number; ciphertext_bytes: number };
  assert.deepEqual({ ...bytesAfterRollback }, {
    operation_count: 2,
    ciphertext_bytes: VAULT_CAPACITY.ciphertextBytes - 16,
  });

  const fillsByteCapacity = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [operation("capacity-bytes-a", 37)],
  }, token);
  assert.equal(fillsByteCapacity.status, 200);
  const overByteCapacity = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [operation("capacity-bytes-b", 39)],
  }, token);
  assert.equal(overByteCapacity.status, 507);
  assert.equal(overByteCapacity.payload.error.code, "VAULT_CAPACITY_REACHED");

  db.database.prepare(`DELETE FROM vault_usage WHERE vault_id = ?`).run(vaultId);
  const unhealthy = await callApi(env, "GET", "/health");
  assert.equal(unhealthy.status, 503);
  assert.equal(unhealthy.payload.error.code, "DATABASE_UNAVAILABLE");
  const missingUsage = await callApi(env, "POST", "/v1/sync", {
    cursor: 0,
    push: [operation("capacity-missing-usage", 41)],
  }, token);
  assert.equal(missingUsage.status, 503);
  assert.equal(missingUsage.payload.error.code, "VAULT_USAGE_UNAVAILABLE");
});

test("短码配对可让新设备加入并一次性消费", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env = {
    DB: db,
    TOKEN_PEPPER: "短码测试专用且长度超过三十二字符的随机pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const created = await callApi(env, "POST", "/v1/vaults", {
    device: { name: "Mac", platform: "macos" },
  });
  const macToken = created.payload.data.device.token as string;

  const codeResult = await callApi(env, "POST", "/v1/pairings/code", {
    publicKey: encodedBytes(32, 11),
  }, macToken);
  assert.equal(codeResult.status, 201);
  const shortCode = codeResult.payload.data.shortCode as string;
  assert.match(shortCode, /^\d{6}$/);

  const resolved = await callApi(env, "POST", "/v1/pairings/resolve", {
    code: shortCode,
  });
  assert.equal(resolved.status, 200);
  assert.equal(resolved.payload.data.pairingId, codeResult.payload.data.pairingId);
  assert.equal(resolved.payload.data.vaultId, created.payload.data.vaultId);
  assert.equal(
    resolved.payload.data.pairingSecret,
    codeResult.payload.data.pairingSecret,
  );

  const androidToken = encodedBytes(32, 12);
  const claimed = await callApi(
    env,
    "POST",
    `/v1/pairings/${resolved.payload.data.pairingId}/claim`,
    {
      pairingSecret: resolved.payload.data.pairingSecret,
      deviceToken: androidToken,
      device: {
        name: "Pixel",
        platform: "android",
        publicKey: encodedBytes(32, 13),
      },
    },
  );
  assert.equal(claimed.status, 202);

  const confirmed = await callApi(
    env,
    "POST",
    `/v1/pairings/${resolved.payload.data.pairingId}/confirm`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, 14),
        nonce: encodedBytes(12, 15),
      },
    },
    macToken,
  );
  assert.equal(confirmed.status, 200);

  const result = await callApi(
    env,
    "POST",
    `/v1/pairings/${resolved.payload.data.pairingId}/result`,
    {
      pairingSecret: resolved.payload.data.pairingSecret,
      deviceToken: androidToken,
    },
  );
  assert.equal(result.status, 200);
  assert.equal(result.payload.data.status, "confirmed");
  assert.equal(result.payload.data.vaultId, created.payload.data.vaultId);

  const replay = await callApi(env, "POST", "/v1/pairings/resolve", {
    code: shortCode,
  });
  assert.equal(replay.status, 404);
  const devices = await callApi(env, "GET", "/v1/devices", undefined, macToken);
  assert.equal(devices.payload.data.devices.length, 2);
});

test("新设备显示码等待已有设备批准后可双向加入", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env = {
    DB: db,
    TOKEN_PEPPER: "反向配对测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const created = await callApi(env, "POST", "/v1/vaults", {
    device: { name: "Mac", platform: "macos" },
  });
  const macToken = created.payload.data.device.token as string;
  const newToken = encodedBytes(32, 21);
  const join = await callApi(env, "POST", "/v1/pairings/join", {
    publicKey: encodedBytes(32, 22),
    deviceToken: newToken,
    device: { name: "Pixel", platform: "android" },
  });
  assert.equal(join.status, 201);
  const { shortCode, joinSecret, joinRequestId, deviceId } = join.payload.data;
  assert.match(shortCode, /^\d{6}$/);

  const resolved = await callApi(
    env,
    "POST",
    "/v1/pairings/join/resolve",
    { code: shortCode, publicKey: encodedBytes(32, 23) },
    macToken,
  );
  assert.equal(resolved.status, 200);
  assert.equal(resolved.payload.data.deviceId, deviceId);
  assert.equal(resolved.payload.data.device.name, "Pixel");

  const pending = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${joinRequestId}/result`,
    { joinSecret },
  );
  assert.equal(pending.status, 202);
  assert.equal(pending.payload.data.status, "resolved");
  assert.equal(pending.payload.data.approverPublicKey, encodedBytes(32, 23));

  const approved = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${joinRequestId}/approve`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, 24),
        nonce: encodedBytes(12, 25),
      },
    },
    macToken,
  );
  assert.equal(approved.status, 200);
  assert.equal(approved.payload.data.vaultId, created.payload.data.vaultId);

  const result = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${joinRequestId}/result`,
    { joinSecret },
  );
  assert.equal(result.status, 200);
  assert.equal(result.payload.data.status, "approved");
  assert.equal(result.payload.data.vaultId, created.payload.data.vaultId);
  assert.equal(result.payload.data.deviceId, deviceId);

  const replay = await callApi(env, "POST", "/v1/pairings/join/resolve", {
    code: shortCode,
    publicKey: encodedBytes(32, 26),
  }, macToken);
  assert.equal(replay.status, 404);

  const devices = await callApi(env, "GET", "/v1/devices", undefined, macToken);
  assert.deepEqual(
    devices.payload.data.devices.map((device: { name: string }) => device.name),
    ["Mac", "Pixel"],
  );
});

test("中继 epoch 在撤销设备后旋转并可更新 relay URL", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env = {
    DB: db,
    TOKEN_PEPPER: "中继测试专用且长度超过三十二字符的随机pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const created = await callApi(env, "POST", "/v1/vaults", {
    device: { name: "Mac", platform: "macos" },
  });
  const macToken = created.payload.data.device.token as string;
  const initial = await callApi(env, "GET", "/v1/relay", undefined, macToken);
  assert.equal(initial.status, 200);
  assert.equal(initial.payload.data.relayUrl, "https://ntfy.sh");
  assert.ok(initial.payload.data.epoch.length >= 32);

  const updated = await callApi(env, "PUT", "/v1/relay", {
    relayUrl: "https://ntfy.example.test",
  }, macToken);
  assert.equal(updated.status, 200);
  assert.equal(updated.payload.data.relayUrl, "https://ntfy.example.test");

  const androidToken = encodedBytes(32, 31);
  const pairing = await callApi(env, "POST", "/v1/pairings", {
    publicKey: encodedBytes(32, 32),
  }, macToken);
  const claimed = await callApi(
    env,
    "POST",
    `/v1/pairings/${pairing.payload.data.pairingId}/claim`,
    {
      pairingSecret: pairing.payload.data.pairingSecret,
      deviceToken: androidToken,
      device: {
        name: "Pixel",
        platform: "android",
        publicKey: encodedBytes(32, 33),
      },
    },
  );
  const androidDeviceId = claimed.payload.data.deviceId as string;
  await callApi(
    env,
    "POST",
    `/v1/pairings/${pairing.payload.data.pairingId}/confirm`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, 34),
        nonce: encodedBytes(12, 35),
      },
    },
    macToken,
  );
  const beforeRevoke = await callApi(env, "GET", "/v1/relay", undefined, macToken);
  const revoked = await callApi(
    env,
    "POST",
    `/v1/devices/${androidDeviceId}/revoke`,
    undefined,
    macToken,
  );
  assert.equal(revoked.status, 200);
  const afterRevoke = await callApi(env, "GET", "/v1/relay", undefined, macToken);
  assert.notEqual(afterRevoke.payload.data.epoch, beforeRevoke.payload.data.epoch);
  assert.equal(afterRevoke.payload.data.relayUrl, "https://ntfy.example.test");
});

test("join 请求支持 OPEN/RESOLVED 取消且批准后取消幂等", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env: TestEnv = {
    DB: db,
    TOKEN_PEPPER: "join取消测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const mac = await createVaultForTest(env);

  const opened = await createJoinRequestForTest(env, 101, {
    name: "Pixel OPEN",
    platform: "android",
  });
  const wrongSecret = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${opened.joinRequestId}/cancel`,
    { joinSecret: encodedBytes(32, 199) },
  );
  assert.equal(wrongSecret.status, 404);
  assert.equal(wrongSecret.payload.error.code, "PAIRING_NOT_FOUND");

  const canceledOpen = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${opened.joinRequestId}/cancel`,
    { joinSecret: opened.joinSecret },
  );
  assert.equal(canceledOpen.status, 200);
  assert.equal(canceledOpen.payload.data.status, "canceled");
  assert.deepEqual(
    {
      ...db.database.prepare(`
        SELECT status, short_code_hash FROM pairing_join_requests WHERE id = ?
      `).get(opened.joinRequestId),
    },
    { status: "CANCELED", short_code_hash: null },
  );
  const canceledAgain = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${opened.joinRequestId}/cancel`,
    { joinSecret: opened.joinSecret },
  );
  assert.equal(canceledAgain.status, 200);
  assert.equal(canceledAgain.payload.data.status, "canceled");
  const openResult = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${opened.joinRequestId}/result`,
    { joinSecret: opened.joinSecret },
  );
  assert.equal(openResult.status, 409);
  assert.equal(openResult.payload.error.code, "PAIRING_CANCELED");

  const resolvedRequest = await createJoinRequestForTest(env, 111, {
    name: "Pixel RESOLVED",
    platform: "android",
  });
  const resolved = await callApi(
    env,
    "POST",
    "/v1/pairings/join/resolve",
    {
      code: resolvedRequest.shortCode,
      publicKey: encodedBytes(32, 113),
    },
    mac.token,
  );
  assert.equal(resolved.status, 200);
  const canceledResolved = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${resolvedRequest.joinRequestId}/cancel`,
    { joinSecret: resolvedRequest.joinSecret },
  );
  assert.equal(canceledResolved.status, 200);
  assert.equal(canceledResolved.payload.data.status, "canceled");
  const resolvedResult = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${resolvedRequest.joinRequestId}/result`,
    { joinSecret: resolvedRequest.joinSecret },
  );
  assert.equal(resolvedResult.status, 409);
  assert.equal(resolvedResult.payload.error.code, "PAIRING_CANCELED");

  const approvedRequest = await createJoinRequestForTest(env, 121, {
    name: "Pixel APPROVED",
    platform: "android",
  });
  const resolvedApproved = await callApi(
    env,
    "POST",
    "/v1/pairings/join/resolve",
    {
      code: approvedRequest.shortCode,
      publicKey: encodedBytes(32, 123),
    },
    mac.token,
  );
  assert.equal(resolvedApproved.status, 200);
  const envelope = {
    ciphertext: encodedBytes(48, 124),
    nonce: encodedBytes(12, 125),
  };
  const approved = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${approvedRequest.joinRequestId}/approve`,
    { vaultKeyEnvelope: envelope },
    mac.token,
  );
  assert.equal(approved.status, 200);
  const canceledApproved = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${approvedRequest.joinRequestId}/cancel`,
    { joinSecret: approvedRequest.joinSecret },
  );
  assert.equal(canceledApproved.status, 200);
  assert.equal(canceledApproved.payload.data.status, "approved");
  const approvedResult = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${approvedRequest.joinRequestId}/result`,
    { joinSecret: approvedRequest.joinSecret },
  );
  assert.equal(approvedResult.status, 200);
  assert.equal(approvedResult.payload.data.status, "approved");
  assert.deepEqual(approvedResult.payload.data.vaultKeyEnvelope, envelope);
});

test("当前设备撤销使令牌失效并旋转 relay epoch，旧路由仍拒绝自我撤销", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const pepper = "退出空间测试专用且长度超过三十二字符的pepper-1234567890";
  const env: TestEnv = {
    DB: db,
    TOKEN_PEPPER: pepper,
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const mac = await createVaultForTest(env);

  const phoneDeviceId = "device-phone-seeded";
  const phoneToken = encodedBytes(32, 201);
  const phoneTokenHash = await hashCredential(phoneToken, "device-token", pepper);
  db.database.prepare(`
    INSERT INTO devices(
      id, vault_id, token_hash, name, platform, public_key,
      created_by_device_id, created_at, last_seen_at, revoked_at
    ) VALUES (?, ?, ?, 'Pixel', 'android', NULL, ?, ?, ?, NULL)
  `).run(
    phoneDeviceId,
    mac.vaultId,
    phoneTokenHash,
    mac.deviceId,
    Date.now(),
    Date.now(),
  );

  const before = await callApi(env, "GET", "/v1/relay", undefined, phoneToken);
  assert.equal(before.status, 200);
  const epochBefore = before.payload.data.epoch as string;

  const selfRevoke = await callApi(
    env,
    "POST",
    `/v1/devices/${phoneDeviceId}/revoke`,
    {},
    phoneToken,
  );
  assert.equal(selfRevoke.status, 409);
  assert.equal(selfRevoke.payload.error.code, "CANNOT_REVOKE_SELF");

  const revoked = await callApi(
    env,
    "POST",
    "/v1/devices/current/revoke",
    undefined,
    mac.token,
  );
  assert.equal(revoked.status, 200);
  assert.equal(revoked.payload.data.deviceId, mac.deviceId);

  const deniedRoutes: Array<[string, string, unknown]> = [
    ["GET", "/v1/devices", undefined],
    ["POST", "/v1/devices/current/revoke", undefined],
    ["POST", "/v1/sync", { cursor: 0, push: [] }],
  ];
  for (const [method, path, body] of deniedRoutes) {
    const denied = await callApi(env, method, path, body, mac.token);
    assert.equal(denied.status, 403, `${method} ${path}`);
    assert.equal(denied.payload.error.code, "DEVICE_REVOKED");
  }

  const after = await callApi(env, "GET", "/v1/relay", undefined, phoneToken);
  assert.equal(after.status, 200);
  assert.notEqual(after.payload.data.epoch, epochBefore);
  assert.ok((after.payload.data.epoch as string).length >= 32);
});

test("三台设备可通过显示码与输入码两种路径加入同一同步空间", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env: TestEnv = {
    DB: db,
    TOKEN_PEPPER: "三设备配对测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const mac = await createVaultForTest(env);
  const phone1 = await pairViaDisplayedCode(env, mac.token, 301, {
    name: "Pixel 1",
    platform: "android",
  });

  const phone2Join = await createJoinRequestForTest(env, 311, {
    name: "Pixel 2",
    platform: "android",
  });
  const resolved = await callApi(
    env,
    "POST",
    "/v1/pairings/join/resolve",
    {
      code: phone2Join.shortCode,
      publicKey: encodedBytes(32, 313),
    },
    mac.token,
  );
  assert.equal(resolved.status, 200);
  const approved = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${phone2Join.joinRequestId}/approve`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, 314),
        nonce: encodedBytes(12, 315),
      },
    },
    mac.token,
  );
  assert.equal(approved.status, 200);
  const phone2Result = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${phone2Join.joinRequestId}/result`,
    { joinSecret: phone2Join.joinSecret },
  );
  assert.equal(phone2Result.status, 200);
  assert.equal(phone2Result.payload.data.vaultId, mac.vaultId);
  assert.equal(phone2Result.payload.data.deviceId, phone2Join.deviceId);

  const lists = await Promise.all([
    callApi(env, "GET", "/v1/devices", undefined, mac.token),
    callApi(env, "GET", "/v1/devices", undefined, phone1.deviceToken),
    callApi(env, "GET", "/v1/devices", undefined, phone2Join.joinToken),
  ]);
  for (const list of lists) {
    assert.equal(list.status, 200);
    assert.equal(list.payload.data.devices.length, 3);
  }
  assert.deepEqual(
    lists[0].payload.data.devices
      .map((device: { name: string; platform: string }) =>
        `${device.name}:${device.platform}`
      )
      .sort(),
    ["Mac:macos", "Pixel 1:android", "Pixel 2:android"],
  );
  assert.deepEqual(
    lists.map((list) =>
      list.payload.data.devices.find(
        (device: { isCurrent: boolean }) => device.isCurrent,
      )?.id
    ),
    [mac.deviceId, phone1.deviceId, phone2Join.deviceId],
  );

  const phone2Sync = await callApi(
    env,
    "POST",
    "/v1/sync",
    { cursor: 0, push: [] },
    phone2Join.joinToken,
  );
  assert.equal(phone2Sync.status, 200);
  assert.equal(phone2Sync.payload.data.pull.length, 0);
});

test("join 批准幂等重试，超过四台设备时返回 VAULT_DEVICE_LIMIT", async (context) => {
  const idempotentDb = new MemoryD1();
  context.after(() => idempotentDb.close());
  const idempotentEnv: TestEnv = {
    DB: idempotentDb,
    TOKEN_PEPPER: "批准幂等测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const mac = await createVaultForTest(idempotentEnv);
  const join = await createJoinRequestForTest(idempotentEnv, 401, {
    name: "Pixel 幂等",
    platform: "android",
  });
  const resolved = await callApi(
    idempotentEnv,
    "POST",
    "/v1/pairings/join/resolve",
    {
      code: join.shortCode,
      publicKey: encodedBytes(32, 403),
    },
    mac.token,
  );
  assert.equal(resolved.status, 200);
  const firstEnvelope = {
    ciphertext: encodedBytes(48, 404),
    nonce: encodedBytes(12, 405),
  };
  const approved = await callApi(
    idempotentEnv,
    "POST",
    `/v1/pairings/join/${join.joinRequestId}/approve`,
    { vaultKeyEnvelope: firstEnvelope },
    mac.token,
  );
  assert.equal(approved.status, 200);
  assert.equal(approved.payload.data.deviceId, join.deviceId);

  const retried = await callApi(
    idempotentEnv,
    "POST",
    `/v1/pairings/join/${join.joinRequestId}/approve`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, 406),
        nonce: encodedBytes(12, 407),
      },
    },
    mac.token,
  );
  assert.equal(retried.status, 200);
  assert.equal(retried.payload.data.status, "approved");
  assert.equal(retried.payload.data.deviceId, join.deviceId);

  const result = await callApi(
    idempotentEnv,
    "POST",
    `/v1/pairings/join/${join.joinRequestId}/result`,
    { joinSecret: join.joinSecret },
  );
  assert.equal(result.status, 200);
  assert.deepEqual(result.payload.data.vaultKeyEnvelope, firstEnvelope);
  const devices = await callApi(
    idempotentEnv,
    "GET",
    "/v1/devices",
    undefined,
    mac.token,
  );
  assert.equal(devices.payload.data.devices.length, 2);

  const limitDb = new MemoryD1();
  context.after(() => limitDb.close());
  const limitEnv: TestEnv = {
    DB: limitDb,
    TOKEN_PEPPER: "设备上限测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const limitMac = await createVaultForTest(limitEnv, "Mac 限额");
  const insertDevice = limitDb.database.prepare(`
    INSERT INTO devices(
      id, vault_id, token_hash, name, platform, public_key,
      created_by_device_id, created_at, last_seen_at, revoked_at
    ) VALUES (?, ?, ?, ?, 'android', NULL, ?, ?, NULL, NULL)
  `);
  for (let index = 1; index <= 3; index += 1) {
    insertDevice.run(
      `limit-device-${index}`,
      limitMac.vaultId,
      `limit-token-hash-${index}`,
      `限额设备 ${index}`,
      limitMac.deviceId,
      Date.now(),
    );
  }
  const limitJoin = await createJoinRequestForTest(limitEnv, 411, {
    name: "第五台设备",
    platform: "android",
  });
  const limitResolved = await callApi(
    limitEnv,
    "POST",
    "/v1/pairings/join/resolve",
    {
      code: limitJoin.shortCode,
      publicKey: encodedBytes(32, 413),
    },
    limitMac.token,
  );
  assert.equal(limitResolved.status, 200);
  const limited = await callApi(
    limitEnv,
    "POST",
    `/v1/pairings/join/${limitJoin.joinRequestId}/approve`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, 414),
        nonce: encodedBytes(12, 415),
      },
    },
    limitMac.token,
  );
  assert.equal(limited.status, 409);
  assert.equal(limited.payload.error.code, "VAULT_DEVICE_LIMIT");
  assert.equal(limited.payload.error.details.limit, 4);
  const limitRow = limitDb.database.prepare(`
    SELECT status FROM pairing_join_requests WHERE id = ?
  `).get(limitJoin.joinRequestId) as { status: string };
  assert.equal(limitRow.status, "RESOLVED");
  const limitDevice = limitDb.database.prepare(`
    SELECT 1 AS found FROM devices WHERE id = ?
  `).get(limitJoin.deviceId);
  assert.equal(limitDevice, undefined);
});

test("配对码与 join 请求 5 分钟过期后按现有实现返回 404 或 410", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env: TestEnv = {
    DB: db,
    TOKEN_PEPPER: "配对过期测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const mac = await createVaultForTest(env);
  const expiredAt = Date.now() - 1;

  const codeResult = await callApi(
    env,
    "POST",
    "/v1/pairings/code",
    { publicKey: encodedBytes(32, 501) },
    mac.token,
  );
  assert.equal(codeResult.status, 201);
  db.database.prepare(`
    UPDATE pairing_sessions SET expires_at = ? WHERE id = ?
  `).run(expiredAt, codeResult.payload.data.pairingId);
  const expiredResolve = await callApi(env, "POST", "/v1/pairings/resolve", {
    code: codeResult.payload.data.shortCode,
  });
  assert.equal(expiredResolve.status, 404);
  assert.equal(expiredResolve.payload.error.code, "PAIRING_NOT_FOUND");

  const openJoin = await createJoinRequestForTest(env, 511, {
    name: "过期 OPEN",
    platform: "android",
  });
  db.database.prepare(`
    UPDATE pairing_join_requests SET expires_at = ? WHERE id = ?
  `).run(expiredAt, openJoin.joinRequestId);
  const expiredJoinResolve = await callApi(
    env,
    "POST",
    "/v1/pairings/join/resolve",
    {
      code: openJoin.shortCode,
      publicKey: encodedBytes(32, 513),
    },
    mac.token,
  );
  assert.equal(expiredJoinResolve.status, 404);
  assert.equal(expiredJoinResolve.payload.error.code, "PAIRING_NOT_FOUND");
  const expiredJoinResult = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${openJoin.joinRequestId}/result`,
    { joinSecret: openJoin.joinSecret },
  );
  assert.equal(expiredJoinResult.status, 410);
  assert.equal(expiredJoinResult.payload.error.code, "PAIRING_EXPIRED");
  const openRow = db.database.prepare(`
    SELECT status FROM pairing_join_requests WHERE id = ?
  `).get(openJoin.joinRequestId) as { status: string };
  assert.equal(openRow.status, "EXPIRED");

  const resolvedJoin = await createJoinRequestForTest(env, 521, {
    name: "过期 RESOLVED",
    platform: "android",
  });
  const resolved = await callApi(
    env,
    "POST",
    "/v1/pairings/join/resolve",
    {
      code: resolvedJoin.shortCode,
      publicKey: encodedBytes(32, 523),
    },
    mac.token,
  );
  assert.equal(resolved.status, 200);
  db.database.prepare(`
    UPDATE pairing_join_requests SET expires_at = ? WHERE id = ?
  `).run(expiredAt, resolvedJoin.joinRequestId);
  const expiredApprove = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${resolvedJoin.joinRequestId}/approve`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, 524),
        nonce: encodedBytes(12, 525),
      },
    },
    mac.token,
  );
  assert.equal(expiredApprove.status, 410);
  assert.equal(expiredApprove.payload.error.code, "PAIRING_EXPIRED");
  const resolvedRow = db.database.prepare(`
    SELECT status FROM pairing_join_requests WHERE id = ?
  `).get(resolvedJoin.joinRequestId) as { status: string };
  assert.equal(resolvedRow.status, "EXPIRED");
  const resultAfterExpiry = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${resolvedJoin.joinRequestId}/result`,
    { joinSecret: resolvedJoin.joinSecret },
  );
  assert.equal(resultAfterExpiry.status, 410);
  assert.equal(resultAfterExpiry.payload.error.code, "PAIRING_EXPIRED");
});

test("配对码、解析与 join 接口按既有窗口限次", async (context) => {
  const codeDb = new MemoryD1();
  context.after(() => codeDb.close());
  const codeEnv: TestEnv = {
    DB: codeDb,
    TOKEN_PEPPER: "配对码限次测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const codeMac = await createVaultForTest(codeEnv);
  for (let index = 0; index < 3; index += 1) {
    const activeCode = await callApi(
      codeEnv,
      "POST",
      "/v1/pairings/code",
      { publicKey: encodedBytes(32, 601 + index) },
      codeMac.token,
    );
    assert.equal(activeCode.status, 201);
  }
  const codeLimited = await callApi(
    codeEnv,
    "POST",
    "/v1/pairings/code",
    { publicKey: encodedBytes(32, 604) },
    codeMac.token,
  );
  assert.equal(codeLimited.status, 429);
  assert.equal(codeLimited.payload.error.code, "PAIRING_CODE_LIMIT");

  const resolveDb = new MemoryD1();
  context.after(() => resolveDb.close());
  const resolveEnv: TestEnv = {
    DB: resolveDb,
    TOKEN_PEPPER: "解析限次测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  let resolveLimited: { status: number; payload: any } | undefined;
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const response = await callApi(resolveEnv, "POST", "/v1/pairings/resolve", {
      code: String(attempt).padStart(6, "0"),
    });
    if (response.status === 429) {
      resolveLimited = response;
      break;
    }
    assert.equal(response.status, 404);
  }
  assert.ok(resolveLimited);
  assert.equal(resolveLimited.payload.error.code, "PAIRING_RATE_LIMITED");
  assert.equal(resolveLimited.payload.error.details.scope, "resolve_source");

  const joinDb = new MemoryD1();
  context.after(() => joinDb.close());
  const joinEnv: TestEnv = {
    DB: joinDb,
    TOKEN_PEPPER: "join限次测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  let joinLimited: { status: number; payload: any } | undefined;
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const response = await callApi(joinEnv, "POST", "/v1/pairings/join", {
      publicKey: encodedBytes(32, 610 + attempt),
      deviceToken: encodedBytes(32, 630 + attempt),
      device: { name: `限次设备 ${attempt}`, platform: "android" },
    });
    if (response.status === 429) {
      joinLimited = response;
      break;
    }
    assert.equal(response.status, 201);
  }
  assert.ok(joinLimited);
  assert.equal(joinLimited.payload.error.code, "PAIRING_RATE_LIMITED");
  assert.equal(joinLimited.payload.error.details.scope, "join_source");
});

test("Windows 平台可通过新设备显示码加入同步空间", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env: TestEnv = {
    DB: db,
    TOKEN_PEPPER: "Windows配对测试专用且长度超过三十二字符的pepper-1234567890",
    VAULT_CREATION_INVITE_CODE: TEST_INVITE_CODE,
    APP_ENV: "test",
  };
  const mac = await createVaultForTest(env);
  const joinToken = encodedBytes(32, 701);
  const join = await callApi(env, "POST", "/v1/pairings/join", {
    publicKey: encodedBytes(32, 702),
    deviceToken: joinToken,
    device: { name: "Windows 工作站", platform: "windows" },
  });
  assert.equal(join.status, 201);
  const joinRequestId = join.payload.data.joinRequestId as string;
  const resolved = await callApi(
    env,
    "POST",
    "/v1/pairings/join/resolve",
    {
      code: join.payload.data.shortCode,
      publicKey: encodedBytes(32, 703),
    },
    mac.token,
  );
  assert.equal(resolved.status, 200);
  assert.deepEqual(resolved.payload.data.device, {
    name: "Windows 工作站",
    platform: "windows",
  });
  const approved = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${joinRequestId}/approve`,
    {
      vaultKeyEnvelope: {
        ciphertext: encodedBytes(48, 704),
        nonce: encodedBytes(12, 705),
      },
    },
    mac.token,
  );
  assert.equal(approved.status, 200);
  const result = await callApi(
    env,
    "POST",
    `/v1/pairings/join/${joinRequestId}/result`,
    { joinSecret: join.payload.data.joinSecret },
  );
  assert.equal(result.status, 200);
  assert.equal(result.payload.data.deviceId, join.payload.data.deviceId);

  const sync = await callApi(
    env,
    "POST",
    "/v1/sync",
    { cursor: 0, push: [] },
    joinToken,
  );
  assert.equal(sync.status, 200);
  const devices = await callApi(env, "GET", "/v1/devices", undefined, mac.token);
  const windowsDevice = devices.payload.data.devices.find(
    (device: { id: string }) => device.id === join.payload.data.deviceId,
  );
  assert.equal(windowsDevice?.name, "Windows 工作站");
  assert.equal(windowsDevice?.platform, "windows");
});
