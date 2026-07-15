import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";

const files = [
  "shared/schema/task.schema.json",
  "shared/schema/sync.schema.json",
  "shared/schema/backup.schema.json",
  "shared/schema/backup-plaintext.schema.json",
  "shared/fixtures/period-cases.json",
  "shared/fixtures/sync-request.json",
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
for (const payload of taskPayloads) {
  validateTaskPayload(payload);
  if (payload.entityType === "tombstone") continue;
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

console.log(`契约基础校验通过：${files.length} 个文件`);

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

function validateTaskPayload(payload) {
  const maximumSafeInteger = Number.MAX_SAFE_INTEGER;
  if (payload?.protocolVersion !== 1) {
    throw new Error("任务 payload 协议版本无效");
  }
  if (payload.entityType === "tombstone") {
    if (
      typeof payload.id !== "string"
      || codePointLength(payload.id) < 8
      || codePointLength(payload.id) > 128
      || !isBoundedInteger(payload.deletedAt, maximumSafeInteger)
    ) {
      throw new Error("tombstone payload 无效");
    }
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
    || typeof payload.seriesId !== "string"
    || codePointLength(payload.seriesId) < 8
    || codePointLength(payload.seriesId) > 128
    || typeof payload.title !== "string"
    || codePointLength(payload.title) < 1
    || codePointLength(payload.title) > 120
  ) {
    throw new Error("任务 ID、seriesId 或标题长度无效");
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
  if (payload.timeType === "someday") {
    if (payload.periodStart !== null || payload.recurrence !== "once") {
      throw new Error("闲时任务不能携带周期或重复规则");
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
