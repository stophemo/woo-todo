-- SQLite 无法直接扩展 CHECK 约束。先复制完整关系图，再按子表到父表的
-- 顺序替换，避免触发级联删除；vault_usage 计数在迁移期间保持不变。
CREATE TABLE devices_windows (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('macos', 'android', 'windows')),
  public_key TEXT,
  created_by_device_id TEXT,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  revoked_at INTEGER,
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY (created_by_device_id) REFERENCES devices_windows(id) ON DELETE SET NULL
);

INSERT INTO devices_windows(
  id, vault_id, token_hash, name, platform, public_key,
  created_by_device_id, created_at, last_seen_at, revoked_at
)
SELECT
  id, vault_id, token_hash, name, platform, public_key,
  NULL, created_at, last_seen_at, revoked_at
FROM devices;

UPDATE devices_windows
SET created_by_device_id = (
  SELECT source.created_by_device_id
  FROM devices AS source
  WHERE source.id = devices_windows.id
);

CREATE TABLE pairing_sessions_windows (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  initiator_device_id TEXT NOT NULL,
  secret_hash TEXT NOT NULL UNIQUE,
  initiator_public_key TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('OPEN', 'CLAIMED', 'CONFIRMED', 'EXPIRED', 'CANCELED')),
  claimed_device_id TEXT,
  claimed_device_name TEXT,
  claimed_platform TEXT CHECK (claimed_platform IS NULL OR claimed_platform IN ('macos', 'android', 'windows')),
  claimed_public_key TEXT,
  claimed_token_hash TEXT UNIQUE,
  confirmed_ciphertext TEXT,
  confirmed_nonce TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  claimed_at INTEGER,
  confirmed_at INTEGER,
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY (initiator_device_id) REFERENCES devices_windows(id) ON DELETE CASCADE
);

INSERT INTO pairing_sessions_windows SELECT * FROM pairing_sessions;

CREATE TABLE change_log_windows (
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
  FOREIGN KEY (device_id) REFERENCES devices_windows(id) ON DELETE RESTRICT,
  UNIQUE (vault_id, op_id)
);

INSERT INTO change_log_windows SELECT * FROM change_log;

CREATE TABLE device_cursors_windows (
  device_id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  cursor INTEGER NOT NULL DEFAULT 0 CHECK (cursor >= 0),
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (device_id) REFERENCES devices_windows(id) ON DELETE CASCADE,
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE
);

INSERT INTO device_cursors_windows SELECT * FROM device_cursors;

CREATE TABLE encrypted_snapshots_windows (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  cursor INTEGER NOT NULL CHECK (cursor >= 0),
  ciphertext TEXT NOT NULL,
  nonce TEXT NOT NULL,
  created_by_device_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY (created_by_device_id) REFERENCES devices_windows(id) ON DELETE RESTRICT
);

INSERT INTO encrypted_snapshots_windows SELECT * FROM encrypted_snapshots;

DROP TRIGGER IF EXISTS reject_change_log_op_id_conflict;
DROP TRIGGER IF EXISTS require_change_log_vault_usage;
DROP TRIGGER IF EXISTS enforce_change_log_vault_capacity;
DROP TRIGGER IF EXISTS track_change_log_insert;
DROP TRIGGER IF EXISTS track_change_log_delete;

DROP TABLE pairing_sessions;
DROP TABLE change_log;
DROP TABLE device_cursors;
DROP TABLE encrypted_snapshots;
DROP TABLE devices;

ALTER TABLE devices_windows RENAME TO devices;
ALTER TABLE pairing_sessions_windows RENAME TO pairing_sessions;
ALTER TABLE change_log_windows RENAME TO change_log;
ALTER TABLE device_cursors_windows RENAME TO device_cursors;
ALTER TABLE encrypted_snapshots_windows RENAME TO encrypted_snapshots;

CREATE INDEX idx_devices_vault ON devices(vault_id, created_at);
CREATE INDEX idx_devices_active ON devices(vault_id, revoked_at);
CREATE INDEX idx_pairing_initiator ON pairing_sessions(initiator_device_id, created_at);
CREATE INDEX idx_pairing_expiry ON pairing_sessions(status, expires_at);
CREATE INDEX idx_change_log_pull ON change_log(vault_id, server_seq);
CREATE INDEX idx_device_cursors_vault ON device_cursors(vault_id, cursor);
CREATE INDEX idx_snapshots_vault_cursor ON encrypted_snapshots(vault_id, cursor DESC);

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
