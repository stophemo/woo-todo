import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import { VAULT_CAPACITY } from "../src/capacity.ts";
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
  assert.equal(health.payload.data.version, "0.1.9");
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
        name: "Galaxy S23 Ultra",
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
