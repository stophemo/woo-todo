import { ApiError } from "./http.ts";

export const VAULT_CAPACITY = Object.freeze({
  operations: 100_000,
  ciphertextBytes: 32 * 1024 * 1024,
});

export function vaultCapacityReachedError(): ApiError {
  return new ApiError(
    507,
    "VAULT_CAPACITY_REACHED",
    "同步空间的密文历史容量已满，需要压缩历史记录或迁移存储后再同步",
    {
      maxOperations: VAULT_CAPACITY.operations,
      maxCiphertextBytes: VAULT_CAPACITY.ciphertextBytes,
    },
  );
}
