import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import worker from "../src/index.ts";

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
    if (/^\s*(SELECT|WITH|PRAGMA)\b/iu.test(this.sql)) {
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

class MemoryD1 {
  readonly database = new DatabaseSync(":memory:");

  constructor() {
    const migration = readFileSync(
      new URL("../migrations/0001_initial.sql", import.meta.url),
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
  env: { DB: MemoryD1; TOKEN_PEPPER: string; APP_ENV: string },
  method: string,
  path: string,
  body?: unknown,
  token?: string,
): Promise<{ status: number; payload: any }> {
  const headers = new Headers();
  if (body !== undefined) headers.set("content-type", "application/json");
  if (token) headers.set("authorization", `Bearer ${token}`);
  const request = new Request(`https://sync.example.test${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const response = await worker.fetch(request, env as never);
  return { status: response.status, payload: await response.json() };
}

test("vault、配对、密文同步、幂等与撤销形成完整闭环", async (context) => {
  const db = new MemoryD1();
  context.after(() => db.close());
  const env = {
    DB: db,
    TOKEN_PEPPER: "集成测试专用且长度超过三十二字符的随机pepper-1234567890",
    APP_ENV: "test",
  };

  const health = await callApi(env, "GET", "/health");
  assert.equal(health.status, 200);
  assert.equal(health.payload.data.database, "ok");

  const created = await callApi(env, "POST", "/v1/vaults", {
    device: { name: "MacBook Air", platform: "macos" },
  });
  assert.equal(created.status, 201);
  assert.equal(created.payload.ok, true);
  const macToken = created.payload.data.device.token as string;
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
