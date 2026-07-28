DROP TRIGGER IF EXISTS reject_change_log_op_id_conflict;
DROP TRIGGER IF EXISTS require_change_log_vault_usage;
DROP TRIGGER IF EXISTS enforce_change_log_vault_capacity;
DROP TRIGGER IF EXISTS track_change_log_insert;
DROP TRIGGER IF EXISTS track_change_log_delete;

CREATE TABLE change_log_reopen (
  server_seq INTEGER PRIMARY KEY AUTOINCREMENT,
  vault_id TEXT NOT NULL,
  op_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (
    kind IN ('upsert', 'delete', 'complete', 'pass', 'reopen', 'reorder')
  ),
  lamport INTEGER NOT NULL CHECK (lamport >= 1),
  ciphertext TEXT NOT NULL,
  nonce TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE RESTRICT,
  UNIQUE (vault_id, op_id)
);

INSERT INTO change_log_reopen(
  server_seq, vault_id, op_id, device_id, entity_id, kind,
  lamport, ciphertext, nonce, created_at
)
SELECT
  server_seq, vault_id, op_id, device_id, entity_id, kind,
  lamport, ciphertext, nonce, created_at
FROM change_log;

DROP TABLE change_log;
ALTER TABLE change_log_reopen RENAME TO change_log;
CREATE INDEX idx_change_log_pull ON change_log(vault_id, server_seq);

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

CREATE TRIGGER require_change_log_vault_usage
BEFORE INSERT ON change_log
WHEN NOT EXISTS (
  SELECT 1 FROM change_log
  WHERE vault_id = NEW.vault_id AND op_id = NEW.op_id
)
AND NOT EXISTS (
  SELECT 1 FROM vault_usage WHERE vault_id = NEW.vault_id
)
BEGIN
  SELECT RAISE(ABORT, 'VAULT_USAGE_MISSING');
END;

CREATE TRIGGER enforce_change_log_vault_capacity
BEFORE INSERT ON change_log
WHEN NOT EXISTS (
  SELECT 1 FROM change_log
  WHERE vault_id = NEW.vault_id AND op_id = NEW.op_id
)
AND EXISTS (
  SELECT 1
  FROM vault_usage
  WHERE vault_id = NEW.vault_id
    AND (
      operation_count >= 100000
      OR ciphertext_bytes
        + CAST((length(NEW.ciphertext) * 6) / 8 AS INTEGER) > 33554432
    )
)
BEGIN
  SELECT RAISE(ABORT, 'VAULT_CAPACITY_REACHED');
END;

CREATE TRIGGER track_change_log_insert
AFTER INSERT ON change_log
BEGIN
  UPDATE vault_usage
  SET operation_count = operation_count + 1,
      ciphertext_bytes = ciphertext_bytes
        + CAST((length(NEW.ciphertext) * 6) / 8 AS INTEGER)
  WHERE vault_id = NEW.vault_id;
END;

CREATE TRIGGER track_change_log_delete
AFTER DELETE ON change_log
BEGIN
  UPDATE vault_usage
  SET operation_count = operation_count - 1,
      ciphertext_bytes = ciphertext_bytes
        - CAST((length(OLD.ciphertext) * 6) / 8 AS INTEGER)
  WHERE vault_id = OLD.vault_id;
END;
