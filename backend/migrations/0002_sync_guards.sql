CREATE TABLE vault_creation_windows (
  scope TEXT NOT NULL CHECK (scope IN ('source', 'service')),
  subject_hash TEXT NOT NULL,
  window_started_at INTEGER NOT NULL,
  window_ends_at INTEGER NOT NULL,
  request_count INTEGER NOT NULL CHECK (request_count >= 1),
  PRIMARY KEY (scope, subject_hash, window_started_at),
  CHECK (window_ends_at > window_started_at)
);

CREATE INDEX idx_vault_creation_window_expiry
  ON vault_creation_windows(window_ends_at);

-- 应用层会先返回可读错误；触发器负责兜住多个 Worker 实例并发写入的竞态。
CREATE TRIGGER reject_change_log_op_id_conflict
BEFORE INSERT ON change_log
WHEN EXISTS (
  SELECT 1
  FROM change_log
  WHERE vault_id = NEW.vault_id
    AND op_id = NEW.op_id
    AND NOT (
      entity_id = NEW.entity_id
      AND kind = NEW.kind
      AND lamport = NEW.lamport
      AND ciphertext = NEW.ciphertext
      AND nonce = NEW.nonce
    )
)
BEGIN
  SELECT RAISE(ABORT, 'OP_ID_CONFLICT');
END;

-- 固定为四台活跃设备，满足双机使用并为设备更换留出余量。
CREATE TRIGGER enforce_vault_active_device_limit
BEFORE INSERT ON devices
WHEN NEW.revoked_at IS NULL AND (
  SELECT COUNT(*)
  FROM devices
  WHERE vault_id = NEW.vault_id AND revoked_at IS NULL
) >= 4
BEGIN
  SELECT RAISE(ABORT, 'VAULT_DEVICE_LIMIT');
END;
