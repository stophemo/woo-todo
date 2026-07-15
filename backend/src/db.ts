import { hashCredential } from "./crypto.ts";
import { ApiError } from "./http.ts";
import { isBase64UrlBytes } from "./protocol.ts";

export type D1Value = string | number | null | ArrayBuffer | Uint8Array;

export interface D1Result<T = Record<string, unknown>> {
  results?: T[];
  success: boolean;
  error?: string;
  meta?: {
    changes?: number;
    [key: string]: unknown;
  };
}

export interface D1PreparedStatement {
  bind(...values: D1Value[]): D1PreparedStatement;
  first<T = Record<string, unknown>>(columnName?: string): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<D1Result<T>>;
  run<T = Record<string, unknown>>(): Promise<D1Result<T>>;
}

export interface D1Database {
  prepare(query: string): D1PreparedStatement;
  batch(statements: D1PreparedStatement[]): Promise<D1Result[]>;
}

export interface Env {
  DB: D1Database;
  TOKEN_PEPPER: string;
  APP_ENV?: string;
}

export interface AuthenticatedDevice {
  id: string;
  vaultId: string;
  name: string;
  platform: "macos" | "android";
  createdAt: number;
}

interface DeviceAuthRow {
  id: string;
  vault_id: string;
  name: string;
  platform: "macos" | "android";
  created_at: number;
  revoked_at: number | null;
}

export function requireTokenPepper(env: Env): string {
  if (typeof env.TOKEN_PEPPER !== "string" || env.TOKEN_PEPPER.length < 32) {
    throw new ApiError(
      500,
      "SERVER_MISCONFIGURED",
      "服务端未配置至少 32 字符的 TOKEN_PEPPER",
    );
  }
  return env.TOKEN_PEPPER;
}

export async function authenticateDevice(
  request: Request,
  env: Env,
): Promise<AuthenticatedDevice> {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([A-Za-z0-9_-]+)$/u.exec(authorization);
  if (!match || !isBase64UrlBytes(match[1], 32)) {
    throw new ApiError(401, "AUTH_REQUIRED", "缺少有效的 Bearer 设备令牌");
  }

  const tokenHash = await hashCredential(
    match[1],
    "device-token",
    requireTokenPepper(env),
  );
  const row = await env.DB.prepare(`
    SELECT id, vault_id, name, platform, created_at, revoked_at
    FROM devices
    WHERE token_hash = ?
    LIMIT 1
  `).bind(tokenHash).first<DeviceAuthRow>();

  if (!row) {
    throw new ApiError(401, "INVALID_DEVICE_TOKEN", "设备令牌无效");
  }
  if (row.revoked_at !== null) {
    throw new ApiError(403, "DEVICE_REVOKED", "此设备已被撤销");
  }
  return {
    id: row.id,
    vaultId: row.vault_id,
    name: row.name,
    platform: row.platform,
    createdAt: row.created_at,
  };
}

export function changedRows(result: D1Result | undefined): number {
  return result?.meta?.changes ?? 0;
}
