import { type Env } from "./db.ts";
import { ApiError } from "./http.ts";
import { type SyncOperationInput } from "./protocol.ts";

interface StoredOperationRow {
  op_id: string;
  entity_id: string;
  kind: string;
  lamport: number;
  ciphertext: string;
  nonce: string;
}

function sameOperationPayload(
  left: SyncOperationInput,
  right: SyncOperationInput,
): boolean {
  return left.entityId === right.entityId &&
    left.kind === right.kind &&
    left.lamport === right.lamport &&
    left.ciphertext === right.ciphertext &&
    left.nonce === right.nonce;
}

function storedOperationMatches(
  operation: SyncOperationInput,
  row: StoredOperationRow,
): boolean {
  return operation.entityId === row.entity_id &&
    operation.kind === row.kind &&
    operation.lamport === row.lamport &&
    operation.ciphertext === row.ciphertext &&
    operation.nonce === row.nonce;
}

export function opIdConflictError(opId?: string): ApiError {
  return new ApiError(
    409,
    "OP_ID_CONFLICT",
    "同一 opId 已绑定到不同的同步操作，请保留原操作并重新生成冲突操作的 ID",
    opId ? { opId } : undefined,
  );
}

export function assertPushOperationIds(
  push: readonly SyncOperationInput[],
): void {
  const seen = new Map<string, SyncOperationInput>();
  for (const operation of push) {
    const previous = seen.get(operation.opId);
    if (previous && !sameOperationPayload(previous, operation)) {
      throw opIdConflictError(operation.opId);
    }
    seen.set(operation.opId, operation);
  }
}

export async function assertStoredOperationIds(
  env: Env,
  vaultId: string,
  push: readonly SyncOperationInput[],
): Promise<void> {
  const operations = new Map(
    push.map((operation) => [operation.opId, operation] as const),
  );
  if (operations.size === 0) return;
  const placeholders = Array.from(operations, () => "?").join(", ");
  const result = await env.DB.prepare(`
    SELECT op_id, entity_id, kind, lamport, ciphertext, nonce
    FROM change_log
    WHERE vault_id = ? AND op_id IN (${placeholders})
  `).bind(vaultId, ...operations.keys()).all<StoredOperationRow>();
  for (const row of result.results ?? []) {
    const operation = operations.get(row.op_id);
    if (operation && !storedOperationMatches(operation, row)) {
      throw opIdConflictError(row.op_id);
    }
  }
}

export async function assertValidSyncCursor(
  env: Env,
  vaultId: string,
  cursor: number,
): Promise<void> {
  if (cursor === 0) return;
  const row = await env.DB.prepare(`
    SELECT
      COALESCE(MAX(server_seq), 0) AS max_cursor,
      COALESCE(MAX(CASE WHEN server_seq = ? THEN 1 ELSE 0 END), 0)
        AS cursor_exists
    FROM change_log
    WHERE vault_id = ?
  `).bind(cursor, vaultId).first<{
    max_cursor: number;
    cursor_exists: number;
  }>();
  const maxCursor = row?.max_cursor ?? 0;
  if (cursor > maxCursor) {
    throw new ApiError(
      409,
      "CURSOR_AHEAD",
      "客户端 cursor 超过此同步空间已存在的最大游标",
      { cursor, maxCursor },
    );
  }
  if (row?.cursor_exists !== 1) {
    throw new ApiError(
      409,
      "CURSOR_NOT_FOUND",
      "客户端 cursor 不属于当前同步空间",
      { cursor, maxCursor },
    );
  }
}
