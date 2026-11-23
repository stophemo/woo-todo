import assert from "node:assert/strict";
import test from "node:test";

import { hashCredential } from "../src/crypto.ts";
import {
  effectivePairingStatus,
  isBase64UrlBytes,
  LIMITS,
  paginateOperations,
  parseCreateJoinRequest,
  parseCreateVaultRequest,
  parseJoinSecretRequest,
  parsePairingClaimRequest,
  parseRelayUpdateRequest,
  parseResolveJoinRequest,
  parseShortCodeRequest,
  parseSyncRequest,
  ProtocolValidationError,
} from "../src/protocol.ts";

function encodedBytes(length: number, fill = 7): string {
  return Buffer.alloc(length, fill).toString("base64url");
}

function validOperation(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    opId: "op_01",
    entityId: "task_01",
    kind: "upsert",
    lamport: 1,
    ciphertext: encodedBytes(32),
    nonce: encodedBytes(12),
    ...overrides,
  };
}

test("仅接受精确 32 字节的无填充 Base64URL 密钥", () => {
  assert.equal(isBase64UrlBytes(encodedBytes(32), 32), true);
  assert.equal(isBase64UrlBytes(encodedBytes(31), 32), false);
  assert.equal(isBase64UrlBytes("包含非URL字符+", 32), false);
});

test("创建 vault 时会清理设备名并保留密文恢复包", () => {
  const result = parseCreateVaultRequest({
    device: { name: "  我的 Mac  ", platform: "macos" },
    recoveryEnvelope: {
      ciphertext: encodedBytes(48),
      nonce: encodedBytes(12),
    },
  });
  assert.equal(result.device.name, "我的 Mac");
  assert.equal(result.device.platform, "macos");
  assert.equal(result.recoveryEnvelope?.ciphertext, encodedBytes(48));
});

test("Windows 客户端可创建同步空间", () => {
  const result = parseCreateVaultRequest({
    device: { name: "Windows 工作站", platform: "windows" },
  });
  assert.equal(result.device.platform, "windows");
});

test("认领配对必须携带 32 字节令牌和 X25519 公钥", () => {
  const input = parsePairingClaimRequest({
    pairingSecret: encodedBytes(32, 1),
    deviceToken: encodedBytes(32, 2),
    device: {
      name: "Android 测试设备",
      platform: "android",
      publicKey: encodedBytes(32, 3),
    },
  });
  assert.equal(input.device.platform, "android");

  assert.throws(
    () =>
      parsePairingClaimRequest({
        pairingSecret: encodedBytes(32),
        deviceToken: encodedBytes(32),
        device: { name: "手机", platform: "android" },
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError &&
      error.field === "device.publicKey",
  );
});

test("同步请求使用 cursor 作为默认 ack，并校验密文操作", () => {
  const input = parseSyncRequest({
    cursor: 9,
    push: [validOperation()],
  });
  assert.equal(input.cursor, 9);
  assert.equal(input.ack, 9);
  assert.equal(input.pullLimit, LIMITS.pullOperations);
  assert.equal(input.push[0].kind, "upsert");

  const reopen = parseSyncRequest({
    cursor: 9,
    push: [validOperation({ kind: "reopen" })],
  });
  assert.equal(reopen.push[0].kind, "reopen");

  assert.throws(
    () => parseSyncRequest({ cursor: 0, push: [], vaultId: "不应由正文传入" }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "body",
  );
  assert.throws(
    () =>
      parseSyncRequest({
        cursor: 0,
        push: [validOperation({ deviceId: "伪造设备" })],
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError &&
      error.field === "push[0]",
  );
});

test("拒绝 ack 超前、nonce 长度错误和超量批次", () => {
  assert.throws(
    () => parseSyncRequest({ cursor: 2, ack: 3 }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "ack",
  );
  assert.throws(
    () =>
      parseSyncRequest({
        cursor: 0,
        push: [validOperation({ kind: "rule_upsert" })],
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError &&
      error.field === "push[0].kind",
  );
  assert.throws(
    () =>
      parseSyncRequest({
        cursor: 0,
        push: [validOperation({ nonce: encodedBytes(16) })],
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError &&
      error.field === "push[0].nonce",
  );
  assert.throws(
    () =>
      parseSyncRequest({
        cursor: 0,
        push: [validOperation({
          ciphertext: encodedBytes(LIMITS.ciphertextBytes + 1),
        })],
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError &&
      error.field === "push[0].ciphertext",
  );
  assert.throws(
    () =>
      parseSyncRequest({
        cursor: 0,
        push: Array.from({ length: LIMITS.pushOperations + 1 }, () =>
          validOperation()),
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "push",
  );
});

test("分页多取一条用于判断 hasMore，空页不推进 cursor", () => {
  const page = paginateOperations(
    [{ serverSeq: 8 }, { serverSeq: 9 }, { serverSeq: 10 }],
    2,
    7,
  );
  assert.deepEqual(page, {
    operations: [{ serverSeq: 8 }, { serverSeq: 9 }],
    cursor: 9,
    hasMore: true,
  });
  assert.deepEqual(paginateOperations([], 2, 9), {
    operations: [],
    cursor: 9,
    hasMore: false,
  });
});

test("配对会话在到达十分钟截止点时立即过期", () => {
  const expiresAt = 100_000;
  assert.equal(
    effectivePairingStatus("OPEN", expiresAt, expiresAt - 1),
    "OPEN",
  );
  assert.equal(
    effectivePairingStatus("CLAIMED", expiresAt, expiresAt),
    "EXPIRED",
  );
  assert.equal(
    effectivePairingStatus("CANCELED", expiresAt, expiresAt + 1),
    "CANCELED",
  );
});

test("不同用途的凭据散列彼此隔离且结果稳定", async () => {
  const secret = encodedBytes(32);
  const pepper = "这是一个长度足够且仅用于单元测试的服务端pepper值-123456";
  const deviceHash = await hashCredential(secret, "device-token", pepper);
  assert.equal(
    deviceHash,
    await hashCredential(secret, "device-token", pepper),
  );
  assert.notEqual(
    deviceHash,
    await hashCredential(secret, "pairing-secret", pepper),
  );
  assert.match(deviceHash, /^[a-f0-9]{64}$/u);
});

test("join 创建请求校验公钥、设备令牌、平台与未知字段", () => {
  const input = parseCreateJoinRequest({
    publicKey: encodedBytes(32, 1),
    deviceToken: encodedBytes(32, 2),
    device: { name: "  Windows 工作站  ", platform: "windows" },
  });
  assert.equal(input.publicKey, encodedBytes(32, 1));
  assert.equal(input.deviceToken, encodedBytes(32, 2));
  assert.equal(input.device.name, "Windows 工作站");
  assert.equal(input.device.platform, "windows");
  assert.equal(input.device.publicKey, undefined);

  const withDevicePublicKey = parseCreateJoinRequest({
    publicKey: encodedBytes(32, 3),
    deviceToken: encodedBytes(32, 4),
    device: {
      name: "Pixel",
      platform: "android",
      publicKey: encodedBytes(32, 3),
    },
  });
  assert.equal(withDevicePublicKey.device.publicKey, encodedBytes(32, 3));

  assert.throws(
    () =>
      parseCreateJoinRequest({
        deviceToken: encodedBytes(32),
        device: { name: "Pixel", platform: "android" },
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "publicKey",
  );
  assert.throws(
    () =>
      parseCreateJoinRequest({
        publicKey: encodedBytes(31),
        deviceToken: encodedBytes(32),
        device: { name: "Pixel", platform: "android" },
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "publicKey",
  );
  assert.throws(
    () =>
      parseCreateJoinRequest({
        publicKey: encodedBytes(32),
        deviceToken: encodedBytes(31),
        device: { name: "Pixel", platform: "android" },
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "deviceToken",
  );
  assert.throws(
    () =>
      parseCreateJoinRequest({
        publicKey: encodedBytes(32),
        deviceToken: encodedBytes(32),
        device: { name: "Pixel", platform: "linux" },
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError &&
      error.field === "device.platform",
  );
  assert.throws(
    () =>
      parseCreateJoinRequest({
        publicKey: encodedBytes(32),
        deviceToken: encodedBytes(32),
        device: { name: "Pixel", platform: "android" },
        deviceId: "不应由新设备指定",
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "body",
  );
});

test("join 解析、取消与短码请求拒绝非法输入", () => {
  const resolved = parseResolveJoinRequest({
    code: "012345",
    publicKey: encodedBytes(32, 5),
  });
  assert.equal(resolved.code, "012345");
  assert.equal(resolved.publicKey, encodedBytes(32, 5));

  for (const code of ["12345", "1234567", "12a456"]) {
    assert.throws(
      () =>
        parseResolveJoinRequest({
          code,
          publicKey: encodedBytes(32),
        }),
      (error: unknown) =>
        error instanceof ProtocolValidationError && error.field === "code",
    );
  }
  assert.throws(
    () => parseResolveJoinRequest({ code: "012345", publicKey: encodedBytes(31) }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "publicKey",
  );
  assert.throws(
    () =>
      parseResolveJoinRequest({
        code: "012345",
        publicKey: encodedBytes(32),
        joinRequestId: "不应由解析方指定",
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "body",
  );

  const cancel = parseJoinSecretRequest({ joinSecret: encodedBytes(32, 6) });
  assert.equal(cancel.joinSecret, encodedBytes(32, 6));
  assert.throws(
    () => parseJoinSecretRequest({ joinSecret: encodedBytes(31) }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "joinSecret",
  );
  assert.throws(
    () =>
      parseJoinSecretRequest({
        joinSecret: encodedBytes(32),
        deviceToken: encodedBytes(32),
      }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "body",
  );

  const shortCode = parseShortCodeRequest({ code: "654321" });
  assert.equal(shortCode.code, "654321");
  assert.throws(
    () => parseShortCodeRequest({ code: "65432a" }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "code",
  );
  assert.throws(
    () => parseShortCodeRequest({ code: "654321", publicKey: encodedBytes(32) }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "body",
  );
});

test("relay 更新仅接受合法 HTTPS 地址并去掉尾斜杠", () => {
  assert.deepEqual(
    parseRelayUpdateRequest({ relayUrl: "https://ntfy.example.test/" }),
    { relayUrl: "https://ntfy.example.test" },
  );
  assert.deepEqual(
    parseRelayUpdateRequest({ relayUrl: "  https://ntfy.example.test/custom/  " }),
    { relayUrl: "https://ntfy.example.test/custom" },
  );
  for (const relayUrl of ["http://ntfy.example.test", "https://", "not a url"]) {
    assert.throws(
      () => parseRelayUpdateRequest({ relayUrl }),
      (error: unknown) =>
        error instanceof ProtocolValidationError && error.field === "relayUrl",
      relayUrl,
    );
  }
  assert.throws(
    () => parseRelayUpdateRequest({ relayUrl: 42 }),
    (error: unknown) =>
      error instanceof ProtocolValidationError && error.field === "relayUrl",
  );
});
