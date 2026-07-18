import { type Env } from "./db.ts";
import { ApiError } from "./http.ts";

export const VAULT_CREATION_INVITE_HEADER = "X-Woo-Todo-Invite-Code";

const MIN_INVITE_CODE_LENGTH = 16;
const MAX_INVITE_CODE_LENGTH = 256;
const PRINTABLE_ASCII_PATTERN = /^[\x21-\x7e]+$/u;
const encoder = new TextEncoder();

function configuredInviteCode(env: Env): string {
  const value = env.VAULT_CREATION_INVITE_CODE;
  if (
    typeof value !== "string" || value.length < MIN_INVITE_CODE_LENGTH ||
    value.length > MAX_INVITE_CODE_LENGTH ||
    !PRINTABLE_ASCII_PATTERN.test(value)
  ) {
    throw new ApiError(
      500,
      "SERVER_MISCONFIGURED",
      `服务端未配置 ${MIN_INVITE_CODE_LENGTH} 至 ${MAX_INVITE_CODE_LENGTH} 字符的可打印 ASCII VAULT_CREATION_INVITE_CODE`,
    );
  }
  return value;
}

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest("SHA-256", encoder.encode(value)),
  );
}

function equalDigest(left: Uint8Array, right: Uint8Array): boolean {
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

export async function assertVaultCreationInvite(
  request: Request,
  env: Env,
): Promise<void> {
  const expected = configuredInviteCode(env);
  const provided = request.headers.get(VAULT_CREATION_INVITE_HEADER) ?? "";
  const [providedDigest, expectedDigest] = await Promise.all([
    digest(provided),
    digest(expected),
  ]);
  if (!equalDigest(providedDigest, expectedDigest)) {
    throw new ApiError(
      403,
      "INVALID_INVITE_CODE",
      "缺少有效的同步空间创建邀请码",
    );
  }
}
