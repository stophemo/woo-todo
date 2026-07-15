export const LIMITS = Object.freeze({
  requestBytes: 256 * 1024,
  pushOperations: 50,
  pullOperations: 100,
  ciphertextBytes: 32 * 1024,
  recoveryCiphertextBytes: 64 * 1024,
  pairingEnvelopeBytes: 4 * 1024,
  identifierCharacters: 128,
  deviceNameCharacters: 80,
  pairingLifetimeMs: 10 * 60 * 1000,
});

const PLATFORMS = ["macos", "android"] as const;
const OPERATION_KINDS = [
  "upsert",
  "delete",
  "complete",
  "pass",
  "reorder",
] as const;

const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;
const IDENTIFIER_PATTERN = /^[A-Za-z0-9._:-]+$/;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f]/;

export type Platform = (typeof PLATFORMS)[number];
export type OperationKind = (typeof OPERATION_KINDS)[number];
export type PairingStatus =
  | "OPEN"
  | "CLAIMED"
  | "CONFIRMED"
  | "EXPIRED"
  | "CANCELED";

export interface EncryptedEnvelope {
  ciphertext: string;
  nonce: string;
}

export interface DeviceRegistration {
  name: string;
  platform: Platform;
  publicKey?: string;
}

export interface CreateVaultRequest {
  device: DeviceRegistration;
  recoveryEnvelope?: EncryptedEnvelope;
}

export interface PairingClaimRequest {
  pairingSecret: string;
  deviceToken: string;
  device: DeviceRegistration & { publicKey: string };
}

export interface SyncOperationInput {
  opId: string;
  entityId: string;
  kind: OperationKind;
  lamport: number;
  ciphertext: string;
  nonce: string;
}

export interface SyncRequestInput {
  cursor: number;
  ack: number;
  pullLimit: number;
  push: SyncOperationInput[];
}

export interface SequencedOperation {
  serverSeq: number;
}

export class ProtocolValidationError extends Error {
  readonly field: string;

  constructor(field: string, message: string) {
    super(message);
    this.name = "ProtocolValidationError";
    this.field = field;
  }
}

function fail(field: string, message: string): never {
  throw new ProtocolValidationError(field, message);
}

function record(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    fail(field, "必须是 JSON 对象");
  }
  return value as Record<string, unknown>;
}

function exactKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
  field: string,
): void {
  const allowedKeys = new Set(allowed);
  const unknown = Object.keys(value).filter((key) => !allowedKeys.has(key));
  if (unknown.length > 0) {
    fail(field, `包含未知字段：${unknown.sort().join(", ")}`);
  }
}

function text(value: unknown, field: string): string {
  if (typeof value !== "string") {
    fail(field, "必须是字符串");
  }
  return value;
}

function safeInteger(value: unknown, field: string, minimum: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum) {
    fail(field, `必须是大于等于 ${minimum} 的安全整数`);
  }
  return value as number;
}

function decodedBase64UrlBytes(value: string): number | null {
  if (!BASE64URL_PATTERN.test(value) || value.length % 4 === 1) {
    return null;
  }
  return Math.floor((value.length * 6) / 8);
}

export function isBase64UrlBytes(
  value: unknown,
  expectedBytes: number,
): value is string {
  return typeof value === "string" &&
    decodedBase64UrlBytes(value) === expectedBytes;
}

export function validateOpaqueSecret(value: unknown, field: string): string {
  if (!isBase64UrlBytes(value, 32)) {
    fail(field, "必须是 32 字节的无填充 Base64URL 字符串");
  }
  return value;
}

export function validateIdentifier(value: unknown, field: string): string {
  const parsed = text(value, field);
  if (
    parsed.length < 1 ||
    parsed.length > LIMITS.identifierCharacters ||
    !IDENTIFIER_PATTERN.test(parsed)
  ) {
    fail(
      field,
      `只能包含安全标识字符，且长度不得超过 ${LIMITS.identifierCharacters}`,
    );
  }
  return parsed;
}

function encryptedEnvelope(
  value: unknown,
  field: string,
  maximumBytes: number,
  requireExactKeys = true,
): EncryptedEnvelope {
  const parsed = record(value, field);
  if (requireExactKeys) {
    exactKeys(parsed, ["ciphertext", "nonce"], field);
  }
  const ciphertext = text(parsed.ciphertext, `${field}.ciphertext`);
  const ciphertextBytes = decodedBase64UrlBytes(ciphertext);
  if (
    ciphertextBytes === null || ciphertextBytes < 16 ||
    ciphertextBytes > maximumBytes
  ) {
    fail(
      `${field}.ciphertext`,
      `必须是 16 至 ${maximumBytes} 字节的无填充 Base64URL 密文`,
    );
  }
  if (!isBase64UrlBytes(parsed.nonce, 12)) {
    fail(`${field}.nonce`, "必须是 12 字节的 AES-GCM nonce");
  }
  return { ciphertext, nonce: parsed.nonce };
}

function deviceRegistration(value: unknown, field: string): DeviceRegistration {
  const parsed = record(value, field);
  exactKeys(parsed, ["name", "platform", "publicKey"], field);
  const name = text(parsed.name, `${field}.name`).trim();
  if (
    name.length < 1 ||
    name.length > LIMITS.deviceNameCharacters ||
    CONTROL_CHARACTER_PATTERN.test(name)
  ) {
    fail(
      `${field}.name`,
      `长度必须为 1 至 ${LIMITS.deviceNameCharacters}，且不得包含控制字符`,
    );
  }
  if (
    typeof parsed.platform !== "string" ||
    !PLATFORMS.includes(parsed.platform as Platform)
  ) {
    fail(`${field}.platform`, "仅支持 macos 或 android");
  }

  let publicKey: string | undefined;
  if (parsed.publicKey !== undefined) {
    if (!isBase64UrlBytes(parsed.publicKey, 32)) {
      fail(`${field}.publicKey`, "必须是 32 字节的 X25519 公钥");
    }
    publicKey = parsed.publicKey;
  }
  return { name, platform: parsed.platform as Platform, publicKey };
}

export function parseCreateVaultRequest(value: unknown): CreateVaultRequest {
  const parsed = record(value, "body");
  exactKeys(parsed, ["device", "recoveryEnvelope"], "body");
  const device = deviceRegistration(parsed.device, "device");
  const recoveryEnvelope = parsed.recoveryEnvelope === undefined
    ? undefined
    : encryptedEnvelope(
      parsed.recoveryEnvelope,
      "recoveryEnvelope",
      LIMITS.recoveryCiphertextBytes,
    );
  return { device, recoveryEnvelope };
}

export function parseCreatePairingRequest(
  value: unknown,
): { publicKey: string } {
  const parsed = record(value, "body");
  exactKeys(parsed, ["publicKey"], "body");
  if (!isBase64UrlBytes(parsed.publicKey, 32)) {
    fail("publicKey", "必须是 32 字节的临时 X25519 公钥");
  }
  return { publicKey: parsed.publicKey };
}

export function parsePairingClaimRequest(value: unknown): PairingClaimRequest {
  const parsed = record(value, "body");
  exactKeys(parsed, ["pairingSecret", "deviceToken", "device"], "body");
  const pairingSecret = validateOpaqueSecret(
    parsed.pairingSecret,
    "pairingSecret",
  );
  const deviceToken = validateOpaqueSecret(parsed.deviceToken, "deviceToken");
  const device = deviceRegistration(parsed.device, "device");
  if (!device.publicKey) {
    fail("device.publicKey", "认领配对时必须提供临时 X25519 公钥");
  }
  return {
    pairingSecret,
    deviceToken,
    device: device as DeviceRegistration & { publicKey: string },
  };
}

export function parsePairingConfirmRequest(
  value: unknown,
): { vaultKeyEnvelope: EncryptedEnvelope } {
  const parsed = record(value, "body");
  exactKeys(parsed, ["vaultKeyEnvelope"], "body");
  return {
    vaultKeyEnvelope: encryptedEnvelope(
      parsed.vaultKeyEnvelope,
      "vaultKeyEnvelope",
      LIMITS.pairingEnvelopeBytes,
    ),
  };
}

export function parsePairingResultRequest(value: unknown): {
  pairingSecret: string;
  deviceToken: string;
} {
  const parsed = record(value, "body");
  exactKeys(parsed, ["pairingSecret", "deviceToken"], "body");
  return {
    pairingSecret: validateOpaqueSecret(parsed.pairingSecret, "pairingSecret"),
    deviceToken: validateOpaqueSecret(parsed.deviceToken, "deviceToken"),
  };
}

function syncOperation(value: unknown, index: number): SyncOperationInput {
  const field = `push[${index}]`;
  const parsed = record(value, field);
  exactKeys(
    parsed,
    ["opId", "entityId", "kind", "lamport", "ciphertext", "nonce"],
    field,
  );
  const kind = text(parsed.kind, `${field}.kind`);
  if (!OPERATION_KINDS.includes(kind as OperationKind)) {
    fail(`${field}.kind`, "是不支持的操作类型");
  }
  const envelope = encryptedEnvelope(
    parsed,
    field,
    LIMITS.ciphertextBytes,
    false,
  );
  return {
    opId: validateIdentifier(parsed.opId, `${field}.opId`),
    entityId: validateIdentifier(parsed.entityId, `${field}.entityId`),
    kind: kind as OperationKind,
    lamport: safeInteger(parsed.lamport, `${field}.lamport`, 1),
    ciphertext: envelope.ciphertext,
    nonce: envelope.nonce,
  };
}

export function parseSyncRequest(value: unknown): SyncRequestInput {
  const parsed = record(value, "body");
  exactKeys(parsed, ["cursor", "ack", "pullLimit", "push"], "body");
  const cursor = safeInteger(parsed.cursor, "cursor", 0);
  const ack = parsed.ack === undefined
    ? cursor
    : safeInteger(parsed.ack, "ack", 0);
  if (ack > cursor) {
    fail("ack", "不得大于 cursor");
  }

  const pullLimit = parsed.pullLimit === undefined
    ? LIMITS.pullOperations
    : safeInteger(parsed.pullLimit, "pullLimit", 1);
  if (pullLimit > LIMITS.pullOperations) {
    fail("pullLimit", `不得超过 ${LIMITS.pullOperations}`);
  }

  const rawPush = parsed.push === undefined ? [] : parsed.push;
  if (!Array.isArray(rawPush)) {
    fail("push", "必须是数组");
  }
  if (rawPush.length > LIMITS.pushOperations) {
    fail("push", `单批不得超过 ${LIMITS.pushOperations} 条操作`);
  }

  return {
    cursor,
    ack,
    pullLimit,
    push: rawPush.map(syncOperation),
  };
}

export function effectivePairingStatus(
  status: PairingStatus,
  expiresAt: number,
  now: number,
): PairingStatus {
  if (status !== "CANCELED" && status !== "EXPIRED" && now >= expiresAt) {
    return "EXPIRED";
  }
  return status;
}

export function paginateOperations<T extends SequencedOperation>(
  rows: readonly T[],
  limit: number,
  currentCursor: number,
): { operations: T[]; cursor: number; hasMore: boolean } {
  const hasMore = rows.length > limit;
  const operations = rows.slice(0, limit);
  const cursor = operations.length === 0
    ? currentCursor
    : operations[operations.length - 1].serverSeq;
  return { operations, cursor, hasMore };
}
