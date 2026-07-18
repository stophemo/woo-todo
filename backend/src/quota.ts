import { hashCredential } from "./crypto.ts";
import { type D1Result, type Env } from "./db.ts";
import { ApiError } from "./http.ts";

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;
const MAX_CONFIGURED_LIMIT = 10_000;

export const VAULT_QUOTAS = Object.freeze({
  sourceCreationsPerHour: 5,
  serviceCreationsPerDay: 100,
  activeDevicesPerVault: 4,
});

interface CounterRow {
  request_count: number;
}

function configuredLimit(
  value: string | undefined,
  fallback: number,
  variableName: string,
): number {
  if (value === undefined || value.trim() === "") return fallback;
  const parsed = Number(value);
  if (
    !Number.isSafeInteger(parsed) || parsed < 1 ||
    parsed > MAX_CONFIGURED_LIMIT
  ) {
    throw new ApiError(
      500,
      "SERVER_MISCONFIGURED",
      `${variableName} 必须是 1 至 ${MAX_CONFIGURED_LIMIT} 的整数`,
    );
  }
  return parsed;
}

function requestSource(request: Request): string {
  const cloudflareAddress = request.headers.get("cf-connecting-ip")?.trim();
  if (cloudflareAddress) return cloudflareAddress.toLowerCase();

  // Wrangler 本地开发没有 Cloudflare 注入的来源地址。统一落入一个小额度桶，
  // 既允许本机和局域网调试，也不会在代理头缺失时放开无限创建。
  return "cloudflare-address-unavailable";
}

function windowStart(now: number, duration: number): number {
  return Math.floor(now / duration) * duration;
}

function counterValue(result: D1Result | undefined): number | undefined {
  const row = result?.results?.[0] as CounterRow | undefined;
  if (!row) return undefined;
  if (!Number.isSafeInteger(row.request_count)) {
    throw new ApiError(
      503,
      "QUOTA_UNAVAILABLE",
      "同步空间创建配额暂时不可用",
    );
  }
  return row.request_count;
}

function rateLimitError(
  scope: "source" | "service",
  limit: number,
  windowEndsAt: number,
  now: number,
): ApiError {
  return new ApiError(
    429,
    "VAULT_CREATE_RATE_LIMITED",
    scope === "source"
      ? "此网络创建同步空间过于频繁，请稍后重试"
      : "同步服务今日创建额度已用完，请稍后重试",
    {
      scope,
      limit,
      retryAfterSeconds: Math.max(1, Math.ceil((windowEndsAt - now) / 1000)),
    },
  );
}

export async function consumeVaultCreationQuota(
  request: Request,
  env: Env,
  now: number,
): Promise<void> {
  const sourceLimit = configuredLimit(
    env.VAULT_CREATION_SOURCE_LIMIT,
    VAULT_QUOTAS.sourceCreationsPerHour,
    "VAULT_CREATION_SOURCE_LIMIT",
  );
  const dailyLimit = configuredLimit(
    env.VAULT_CREATION_DAILY_LIMIT,
    VAULT_QUOTAS.serviceCreationsPerDay,
    "VAULT_CREATION_DAILY_LIMIT",
  );
  const sourceHash = await hashCredential(
    requestSource(request),
    "vault-creation-source",
    env.TOKEN_PEPPER,
  );
  const sourceStart = windowStart(now, HOUR_MS);
  const dailyStart = windowStart(now, DAY_MS);

  // D1 batch 在一个事务内串行执行。来源桶只有在全服务额度仍有余量时
  // 才会写入；来源超额请求也不会消耗全服务每日额度。
  const results = await env.DB.batch([
    env.DB.prepare(`
      DELETE FROM vault_creation_windows WHERE window_ends_at <= ?
    `).bind(now),
    env.DB.prepare(`
      INSERT INTO vault_creation_windows(
        scope, subject_hash, window_started_at, window_ends_at, request_count
      )
      SELECT 'source', ?, ?, ?, 1
      WHERE COALESCE((
        SELECT request_count
        FROM vault_creation_windows
        WHERE scope = 'service'
          AND subject_hash = 'all'
          AND window_started_at = ?
      ), 0) < ?
      ON CONFLICT(scope, subject_hash, window_started_at) DO UPDATE SET
        request_count = vault_creation_windows.request_count + 1
      RETURNING request_count
    `).bind(
      sourceHash,
      sourceStart,
      sourceStart + HOUR_MS,
      dailyStart,
      dailyLimit,
    ),
    env.DB.prepare(`
      INSERT INTO vault_creation_windows(
        scope, subject_hash, window_started_at, window_ends_at, request_count
      )
      SELECT 'service', 'all', ?, ?, 1
      WHERE COALESCE((
        SELECT request_count
        FROM vault_creation_windows
        WHERE scope = 'source'
          AND subject_hash = ?
          AND window_started_at = ?
      ), 0) <= ?
        AND COALESCE((
          SELECT request_count
          FROM vault_creation_windows
          WHERE scope = 'service'
            AND subject_hash = 'all'
            AND window_started_at = ?
        ), 0) < ?
      ON CONFLICT(scope, subject_hash, window_started_at) DO UPDATE SET
        request_count = vault_creation_windows.request_count + 1
      RETURNING request_count
    `).bind(
      dailyStart,
      dailyStart + DAY_MS,
      sourceHash,
      sourceStart,
      sourceLimit,
      dailyStart,
      dailyLimit,
    ),
  ]);

  const sourceCount = counterValue(results[1]);
  if (sourceCount === undefined) {
    throw rateLimitError(
      "service",
      dailyLimit,
      dailyStart + DAY_MS,
      now,
    );
  }
  if (sourceCount > sourceLimit) {
    throw rateLimitError(
      "source",
      sourceLimit,
      sourceStart + HOUR_MS,
      now,
    );
  }

  const dailyCount = counterValue(results[2]);
  if (dailyCount === undefined || dailyCount > dailyLimit) {
    throw rateLimitError(
      "service",
      dailyLimit,
      dailyStart + DAY_MS,
      now,
    );
  }
}

export async function assertVaultDeviceCapacity(
  env: Env,
  vaultId: string,
): Promise<void> {
  const row = await env.DB.prepare(`
    SELECT COUNT(*) AS active_devices
    FROM devices
    WHERE vault_id = ? AND revoked_at IS NULL
  `).bind(vaultId).first<{ active_devices: number }>();
  if ((row?.active_devices ?? 0) >= VAULT_QUOTAS.activeDevicesPerVault) {
    throw vaultDeviceLimitError();
  }
}

export function vaultDeviceLimitError(): ApiError {
  return new ApiError(
    409,
    "VAULT_DEVICE_LIMIT",
    `每个同步空间最多绑定 ${VAULT_QUOTAS.activeDevicesPerVault} 台活跃设备`,
    { limit: VAULT_QUOTAS.activeDevicesPerVault },
  );
}
