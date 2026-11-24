import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";

const QUEST_LINE_PATTERN = /^[a-z0-9][a-z0-9_-]{0,31}$/u;

const files = [
  "shared/schema/task.schema.json",
  "shared/schema/sync.schema.json",
  "shared/schema/webdav-operation.schema.json",
  "shared/schema/webdav-setup-link.schema.json",
  "shared/schema/webdav-pairing.schema.json",
  "shared/schema/backup.schema.json",
  "shared/schema/backup-plaintext.schema.json",
  "shared/fixtures/period-cases.json",
  "shared/fixtures/sync-request.json",
  "shared/fixtures/webdav-operation.json",
  "shared/fixtures/webdav-setup-link.json",
  "shared/fixtures/webdav-pairing-offer.json",
  "shared/fixtures/webdav-pairing-claim.json",
  "shared/fixtures/webdav-pairing-join.json",
  "shared/fixtures/webdav-pairing-resolve.json",
  "shared/fixtures/webdav-pairing-approval.json",
  "shared/fixtures/webdav-pairing-approval-path-a.json",
  "shared/fixtures/crypto-vectors.json",
  "shared/fixtures/task-payloads.json",
  "shared/fixtures/task-validation-cases.json",
  "shared/fixtures/backup-vectors.json",
];

const documents = new Map();

for (const file of files) {
  const source = await readFile(new URL(`../${file}`, import.meta.url), "utf8");
  documents.set(file, JSON.parse(source));
}

const periodCases = documents.get("shared/fixtures/period-cases.json");
if (periodCases.timezone !== "Asia/Shanghai" || periodCases.cases.length < 4) {
  throw new Error("周期契约样例缺少默认时区或边界用例");
}

const dateFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: periodCases.timezone,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

for (const testCase of periodCases.cases) {
  const instant = new Date(testCase.instant);
  const parts = Object.fromEntries(
    dateFormatter.formatToParts(instant)
      .filter(({ type }) => type !== "literal")
      .map(({ type, value }) => [type, value]),
  );
  const localDate = new Date(Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
  ));
  const dayKey = `${parts.year}-${parts.month}-${parts.day}`;
  const monthKey = `${parts.year}-${parts.month}`;
  const weekKey = isoWeekKey(localDate);

  if (
    dayKey !== testCase.expectedDayKey
    || monthKey !== testCase.expectedMonthKey
    || weekKey !== testCase.expectedWeekKey
  ) {
    throw new Error(`周期样例不一致：${testCase.name}`);
  }
}

const syncRequest = documents.get("shared/fixtures/sync-request.json");
if (!Number.isSafeInteger(syncRequest.cursor) || !Array.isArray(syncRequest.push)) {
  throw new Error("同步请求样例结构不完整");
}

const webDavOperation = documents.get("shared/fixtures/webdav-operation.json");
if (
  webDavOperation.format !== "woo-todo-webdav-operation"
  || webDavOperation.protocolVersion !== 1
  || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/u.test(webDavOperation.vaultId)
  || !/^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/u.test(webDavOperation.deviceId)
  || !/^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/u.test(webDavOperation.opId)
  || !/^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/u.test(webDavOperation.entityId)
  || !Number.isSafeInteger(webDavOperation.lamport)
  || webDavOperation.lamport < 1
) {
  throw new Error("WebDAV 操作对象元数据无效");
}

const webDavSetupLink = documents.get("shared/fixtures/webdav-setup-link.json");
const setupKeys = Object.keys(webDavSetupLink).sort().join(",");
if (
  setupKeys !== "appPassword,endpoint,username,v,vaultId,vaultKey"
  || webDavSetupLink.v !== "2"
  || !isValidWebDavEndpoint(webDavSetupLink.endpoint)
  || typeof webDavSetupLink.username !== "string"
  || webDavSetupLink.username.length < 1
  || webDavSetupLink.username.length > 320
  || /[\s\u0000-\u001f\u007f-\u009f]/u.test(webDavSetupLink.username)
  || typeof webDavSetupLink.appPassword !== "string"
  || webDavSetupLink.appPassword.length < 1
  || webDavSetupLink.appPassword.length > 256
  || /[\u0000-\u001f\u007f-\u009f]/u.test(webDavSetupLink.appPassword)
  || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/u.test(webDavSetupLink.vaultId)
  || !/^[A-Za-z0-9_-]{43}$/u.test(webDavSetupLink.vaultKey)
  || Object.hasOwn(webDavSetupLink, "deviceId")
) {
  throw new Error("第三方 WebDAV 配置深链 fixture 无效");
}
if (Buffer.from(webDavOperation.nonce, "base64url").byteLength !== 12) {
  throw new Error("WebDAV 操作对象 nonce 不是 12 字节");
}
if (Buffer.from(webDavOperation.ciphertext, "base64url").byteLength < 16) {
  throw new Error("WebDAV 操作对象密文缺少认证标签");
}

const webDavPairingSchema = documents.get("shared/schema/webdav-pairing.schema.json");
const pairingKinds = ["offer", "claim", "join", "resolve", "approval"];
if (
  webDavPairingSchema.$schema !== "https://json-schema.org/draft/2020-12/schema"
  || webDavPairingSchema.properties?.format?.const !== "woo-todo-webdav-pairing"
  || webDavPairingSchema.properties?.protocolVersion?.const !== 1
  || webDavPairingSchema.properties?.kind?.enum?.join(",") !== pairingKinds.join(",")
  || !Array.isArray(webDavPairingSchema.oneOf)
  || webDavPairingSchema.oneOf.length !== pairingKinds.length
  || pairingKinds.some((kind) => (
    webDavPairingSchema.$defs?.[`${kind}File`]?.properties?.kind?.const !== kind
    || webDavPairingSchema.$defs[`${kind}File`].additionalProperties !== false
  ))
) {
  throw new Error("WebDAV 配对 JSON Schema 未按 kind 严格约束字段");
}

const webDavPairingFixtures = {
  offer: documents.get("shared/fixtures/webdav-pairing-offer.json"),
  claim: documents.get("shared/fixtures/webdav-pairing-claim.json"),
  join: documents.get("shared/fixtures/webdav-pairing-join.json"),
  resolve: documents.get("shared/fixtures/webdav-pairing-resolve.json"),
  approvalPathA: documents.get("shared/fixtures/webdav-pairing-approval-path-a.json"),
  approvalPathB: documents.get("shared/fixtures/webdav-pairing-approval.json"),
};
for (const [name, fixture] of Object.entries(webDavPairingFixtures)) {
  validateWebDavPairingFile(
    name === "approvalPathA" || name === "approvalPathB" ? "approval" : name,
    fixture,
  );
}
if (
  webDavPairingFixtures.offer.pairingId !== webDavPairingFixtures.claim.pairingId
  || webDavPairingFixtures.offer.pairingId !== webDavPairingFixtures.approvalPathA.pairingId
  || webDavPairingFixtures.approvalPathA.deviceId !== webDavPairingFixtures.claim.deviceId
  || webDavPairingFixtures.approvalPathA.vaultId !== webDavPairingFixtures.offer.vaultId
  || webDavPairingFixtures.approvalPathA.initiatorPublicKey !== webDavPairingFixtures.offer.publicKey
  || Object.hasOwn(webDavPairingFixtures.approvalPathA, "approverPublicKey")
) {
  throw new Error("WebDAV 配对 Path A fixture 未构成一致的 offer→claim→approval 示例");
}
if (
  webDavPairingFixtures.join.pairingId !== webDavPairingFixtures.resolve.pairingId
  || webDavPairingFixtures.join.pairingId !== webDavPairingFixtures.approvalPathB.pairingId
  || webDavPairingFixtures.approvalPathB.deviceId !== webDavPairingFixtures.join.deviceId
  || webDavPairingFixtures.approvalPathB.initiatorPublicKey !== webDavPairingFixtures.join.publicKey
  || webDavPairingFixtures.approvalPathB.approverPublicKey !== webDavPairingFixtures.resolve.approverPublicKey
) {
  throw new Error("WebDAV 配对 Path B fixture 未构成一致的 join→resolve→approval 示例");
}

const opIds = new Set(syncRequest.push.map((operation) => operation.opId));
if (opIds.size !== syncRequest.push.length) {
  throw new Error("同步请求样例包含重复 opId");
}

for (const operation of syncRequest.push) {
  if (Buffer.from(operation.nonce, "base64url").byteLength !== 12) {
    throw new Error(`同步操作 ${operation.opId} 的 nonce 不是 12 字节`);
  }
  if (Buffer.from(operation.ciphertext, "base64url").byteLength < 16) {
    throw new Error(`同步操作 ${operation.opId} 的密文长度不足`);
  }
}

const taskPayloads = documents.get("shared/fixtures/task-payloads.json");
if (
  !Array.isArray(taskPayloads)
  || taskPayloads.filter(({ entityType }) => entityType === "displayConfiguration").length !== 1
) {
  throw new Error("任务正文 fixture 必须包含且仅包含一条显示配置");
}
for (const payload of taskPayloads) {
  validateTaskPayload(payload);
  if (payload.entityType !== "task") continue;
  if (!payload.title.trim() || payload.timezone !== "Asia/Shanghai") {
    throw new Error(`任务 payload ${payload.id} 的标题或时区无效`);
  }
  if ((payload.state === "pending") !== (payload.settledAt === null)) {
    throw new Error(`任务 payload ${payload.id} 的状态与结算时间不一致`);
  }
  if (payload.timeType === "someday" && (payload.periodStart !== null || payload.recurrence !== "once")) {
    throw new Error(`闲时任务 payload ${payload.id} 不能有周期或重复规则`);
  }
  if (payload.recurrence === "repeat" && payload.id !== payload.seriesId) {
    const expectedId = deterministicOccurrenceId(
      payload.seriesId,
      payload.timeType,
      payload.periodStart,
    );
    if (payload.id !== expectedId) {
      throw new Error(`重复任务 payload ${payload.id} 不是确定性实例 ID`);
    }
  }
}

const taskValidationCases = documents.get(
  "shared/fixtures/task-validation-cases.json",
);
if (
  !Array.isArray(taskValidationCases.valid)
  || !Array.isArray(taskValidationCases.invalid)
  || taskValidationCases.valid.length < 4
  || taskValidationCases.invalid.length < 10
) {
  throw new Error("Wire v1 任务校验 fixture 不完整");
}
for (const testCase of taskValidationCases.valid) {
  validateTaskPayload(testCase.payload);
}
for (const testCase of taskValidationCases.invalid) {
  let rejected = false;
  try {
    validateTaskPayload(testCase.payload);
  } catch {
    rejected = true;
  }
  if (!rejected) {
    throw new Error(`无效任务 fixture 未被拒绝：${testCase.name}`);
  }
}

const backup = documents.get("shared/fixtures/backup-vectors.json");
if (
  backup.format !== "woo-todo-backup"
  || backup.version !== 1
  || backup.password.normalize("NFKC") !== backup.passwordNormalized
  || Buffer.from(backup.kdf.salt, "base64url").byteLength !== 16
  || Buffer.from(backup.cipher.nonce, "base64url").byteLength !== 12
  || Buffer.from(backup.cipher.ciphertext, "base64url").byteLength < 16
) {
  throw new Error("加密备份向量结构或二进制长度无效");
}
const legacyBackupSnapshot = JSON.parse(backup.plaintextUtf8);
if (legacyBackupSnapshot.tombstones !== undefined) {
  throw new Error("旧备份向量不应强制携带 tombstones");
}
const tombstoneBackupSnapshot = JSON.parse(backup.tombstonePlaintextUtf8);
if (
  !Array.isArray(tombstoneBackupSnapshot.tombstones)
  || tombstoneBackupSnapshot.tombstones.length !== 1
) {
  throw new Error("备份删除屏障 fixture 不完整");
}
validateTaskPayload(tombstoneBackupSnapshot.tombstones[0]);

console.log(`契约基础校验通过：${files.length} 个文件`);

function isValidWebDavEndpoint(value) {
  if (typeof value !== "string" || value.length > 2048) return false;
  try {
    const endpoint = new URL(value);
    return endpoint.protocol === "https:"
      && endpoint.hostname.length > 0
      && endpoint.username === ""
      && endpoint.password === ""
      && endpoint.search === ""
      && endpoint.hash === "";
  } catch {
    return false;
  }
}

function validateWebDavPairingFile(kind, document) {
  const pairingIdPattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/u;
  const vaultIdPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/u;
  const deviceIdPattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/u;
  const deviceNamePattern = /^[^\u0000-\u001f\u007f-\u009f]+$/u;
  const commonFields = ["format", "protocolVersion", "kind", "pairingId", "createdAt", "expiresAt"];
  const specificFields = {
    offer: ["code", "publicKey", "pairingSecret", "vaultId", "deviceName", "platform"],
    claim: ["publicKey", "deviceId", "deviceName", "platform"],
    join: ["code", "publicKey", "deviceId", "deviceName", "platform"],
    resolve: ["approverPublicKey", "approverDeviceId", "approverName"],
    approval: ["deviceId", "vaultId", "vaultKeyEnvelope", "initiatorPublicKey"],
  }[kind];
  const optionalFields = kind === "approval" ? ["approverPublicKey"] : [];
  const requiredFields = [...commonFields, ...(specificFields ?? [])];
  const allowedFields = [...requiredFields, ...optionalFields];
  const actualFields = Object.keys(document);
  if (
    !Array.isArray(specificFields)
    || requiredFields.some((field) => !actualFields.includes(field))
    || actualFields.some((field) => !allowedFields.includes(field))
    || document.format !== "woo-todo-webdav-pairing"
    || document.protocolVersion !== 1
    || document.kind !== kind
    || !pairingIdPattern.test(document.pairingId)
    || !isBoundedInteger(document.createdAt, Number.MAX_SAFE_INTEGER)
    || !isBoundedInteger(document.expiresAt, Number.MAX_SAFE_INTEGER)
    || document.expiresAt <= document.createdAt
  ) {
    throw new Error(`WebDAV 配对 ${kind} 文件公共字段无效`);
  }
  if (document.code !== undefined && !/^[0-9]{6}$/u.test(document.code)) {
    throw new Error(`WebDAV 配对 ${kind} 文件六位码无效`);
  }
  for (const field of ["publicKey", "pairingSecret", "initiatorPublicKey", "approverPublicKey"]) {
    if (document[field] === undefined) continue;
    if (
      !/^[A-Za-z0-9_-]{43}$/u.test(document[field])
      || Buffer.from(document[field], "base64url").byteLength !== 32
    ) {
      throw new Error(`WebDAV 配对 ${kind} 文件 ${field} 不是 32 字节`);
    }
  }
  if (document.vaultId !== undefined && !vaultIdPattern.test(document.vaultId)) {
    throw new Error(`WebDAV 配对 ${kind} 文件 vaultId 无效`);
  }
  for (const field of ["deviceId", "approverDeviceId"]) {
    if (document[field] !== undefined && !deviceIdPattern.test(document[field])) {
      throw new Error(`WebDAV 配对 ${kind} 文件 ${field} 无效`);
    }
  }
  for (const field of ["deviceName", "approverName"]) {
    if (document[field] === undefined) continue;
    if (
      codePointLength(document[field]) < 1
      || codePointLength(document[field]) > 64
      || !deviceNamePattern.test(document[field])
    ) {
      throw new Error(`WebDAV 配对 ${kind} 文件 ${field} 无效`);
    }
  }
  if (document.platform !== undefined && !["macos", "android", "windows"].includes(document.platform)) {
    throw new Error(`WebDAV 配对 ${kind} 文件平台无效`);
  }
  if (document.vaultKeyEnvelope !== undefined) {
    const envelope = document.vaultKeyEnvelope;
    if (
      Object.keys(envelope).sort().join(",") !== "ciphertext,nonce"
      || !/^[A-Za-z0-9_-]{64}$/u.test(envelope.ciphertext)
      || Buffer.from(envelope.ciphertext, "base64url").byteLength !== 48
      || !/^[A-Za-z0-9_-]{16}$/u.test(envelope.nonce)
      || Buffer.from(envelope.nonce, "base64url").byteLength !== 12
    ) {
      throw new Error(`WebDAV 配对 ${kind} 文件 vaultKey 密文无效`);
    }
  }
}

function isoWeekKey(date) {
  const value = new Date(date);
  const weekday = value.getUTCDay() || 7;
  value.setUTCDate(value.getUTCDate() + 4 - weekday);
  const isoYear = value.getUTCFullYear();
  const yearStart = new Date(Date.UTC(isoYear, 0, 1));
  const week = Math.ceil((((value - yearStart) / 86_400_000) + 1) / 7);
  return `${isoYear}-W${String(week).padStart(2, "0")}`;
}

function deterministicOccurrenceId(seriesId, timeType, periodStart) {
  const canonical = [
    "woo-todo-occurrence-v1",
    seriesId.toLowerCase(),
    timeType,
    periodStart,
  ].join("|");
  const bytes = Buffer.from(createHash("sha256").update(canonical).digest().subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join("-");
}

function validateQuestLines(questLines) {
  if (questLines === undefined) return;
  if (!Array.isArray(questLines) || questLines.length === 0 || questLines.length > 8) {
    throw new Error("任务分类定义数量无效");
  }
  const ids = new Set();
  const orders = new Set();
  for (const line of questLines) {
    const keys = Object.keys(line ?? {});
    if (
      keys.length !== 3
      || !keys.includes("id")
      || !keys.includes("name")
      || !keys.includes("order")
    ) {
      throw new Error("任务分类定义字段无效");
    }
    if (typeof line.id !== "string" || !QUEST_LINE_PATTERN.test(line.id) || ids.has(line.id)) {
      throw new Error("任务分类标识无效或重复");
    }
    ids.add(line.id);
    if (
      typeof line.name !== "string"
      || line.name.trim().length === 0
      || codePointLength(line.name) > 12
      || /[\r\n\u000B\u000C\u0085\u2028\u2029]/u.test(line.name)
    ) {
      throw new Error("任务分类名称无效");
    }
    if (!Number.isInteger(line.order) || line.order < 0 || line.order > 63 || orders.has(line.order)) {
      throw new Error("任务分类优先级无效或重复");
    }
    orders.add(line.order);
  }
}

function validateTaskPayload(payload) {
  const maximumSafeInteger = Number.MAX_SAFE_INTEGER;
  const identifierPattern = /^[A-Za-z0-9._:-]+$/;
  if (payload?.protocolVersion !== 1) {
    throw new Error("任务 payload 协议版本无效");
  }
  if (payload.entityType === "tombstone") {
    if (
      typeof payload.id !== "string"
      || codePointLength(payload.id) < 8
      || codePointLength(payload.id) > 128
      || !identifierPattern.test(payload.id)
      || !isBoundedInteger(payload.deletedAt, maximumSafeInteger)
    ) {
      throw new Error("tombstone payload 无效");
    }
    return;
  }
  if (payload.entityType === "displayConfiguration") {
    const allowedKeys = new Set([
      "protocolVersion", "entityType", "id", "headerTemplate",
      "subtitleTemplate", "startDate", "deadlineDate", "questLines",
    ]);
    const requiredKeys = [
      "protocolVersion", "entityType", "id", "headerTemplate",
      "subtitleTemplate", "startDate", "deadlineDate",
    ];
    const actualKeys = Object.keys(payload);
    if (
      requiredKeys.some((key) => !actualKeys.includes(key))
      || actualKeys.some((key) => !allowedKeys.has(key))
      || payload.id !== "display.today.configuration"
      || typeof payload.headerTemplate !== "string"
      || codePointLength(payload.headerTemplate) > 80
      || /[\r\n\u000B\u000C\u0085\u2028\u2029]/u.test(payload.headerTemplate)
      || typeof payload.subtitleTemplate !== "string"
      || codePointLength(payload.subtitleTemplate) > 160
      || /[\r\n\u000B\u000C\u0085\u2028\u2029]/u.test(payload.subtitleTemplate)
      || typeof payload.startDate !== "string"
      || typeof payload.deadlineDate !== "string"
    ) {
      throw new Error("显示配置 payload 无效");
    }
    parseDateKey(payload.startDate);
    parseDateKey(payload.deadlineDate);
    validateQuestLines(payload.questLines);
    return;
  }
  if (payload.entityType !== "task") {
    throw new Error("任务 payload 实体类型无效");
  }
  if (payload.timezone !== "Asia/Shanghai") {
    throw new Error("任务 payload 必须使用固定时区");
  }
  if (
    typeof payload.id !== "string"
    || codePointLength(payload.id) < 8
    || codePointLength(payload.id) > 128
    || !identifierPattern.test(payload.id)
    || typeof payload.seriesId !== "string"
    || codePointLength(payload.seriesId) < 8
    || codePointLength(payload.seriesId) > 128
    || !identifierPattern.test(payload.seriesId)
    || typeof payload.title !== "string"
    || codePointLength(payload.title) < 1
    || codePointLength(payload.title) > 120
  ) {
    throw new Error("任务 ID、seriesId 或标题长度无效");
  }
  if (typeof payload.questLine !== "string" || !QUEST_LINE_PATTERN.test(payload.questLine)) {
    throw new Error("任务分类标识无效");
  }
  if (!isBoundedInteger(payload.sortOrder, 2_147_483_647)) {
    throw new Error("任务排序值越界");
  }
  for (const field of ["createdAt", "updatedAt"]) {
    if (!isBoundedInteger(payload[field], maximumSafeInteger)) {
      throw new Error(`任务 ${field} 越界`);
    }
  }
  if (
    payload.settledAt !== null
    && !isBoundedInteger(payload.settledAt, maximumSafeInteger)
  ) {
    throw new Error("任务 settledAt 越界");
  }
  if (
    payload.reminderTime !== undefined
    && payload.reminderTime !== null
    && !/^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/u.test(payload.reminderTime)
  ) {
    throw new Error("任务 reminderTime 格式无效");
  }
  if (payload.deadlineDate !== undefined && payload.deadlineDate !== null) {
    parseDateKey(payload.deadlineDate);
  }
  if (payload.timeType === "someday") {
    if (
      payload.periodStart !== null
      || payload.recurrence !== "once"
      || (payload.reminderTime ?? null) !== null
    ) {
      throw new Error("闲时任务不能携带周期、重复规则或提醒时间");
    }
  } else {
    const date = parseDateKey(payload.periodStart);
    if (payload.timeType === "week" && date.getUTCDay() !== 1) {
      throw new Error("周任务必须从周一开始");
    }
    if (payload.timeType === "month" && date.getUTCDate() !== 1) {
      throw new Error("月任务必须从一日开始");
    }
  }
  if ((payload.state === "pending") !== (payload.settledAt === null)) {
    throw new Error("任务状态与结算时间不一致");
  }
}

function isBoundedInteger(value, maximum) {
  return Number.isSafeInteger(value) && value >= 0 && value <= maximum;
}

function codePointLength(value) {
  return [...value].length;
}

function parseDateKey(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value ?? "");
  if (!match) throw new Error("周期起点格式无效");
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (year < 1 || year > 9_999) throw new Error("周期年份无效");
  const date = new Date(0);
  date.setUTCHours(0, 0, 0, 0);
  date.setUTCFullYear(year, month - 1, day);
  if (
    date.getUTCFullYear() !== year
    || date.getUTCMonth() !== month - 1
    || date.getUTCDate() !== day
  ) {
    throw new Error("周期起点不是合法公历日期");
  }
  return date;
}
