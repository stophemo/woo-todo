PRAGMA foreign_keys = ON;

CREATE TABLE vaults (
  id TEXT PRIMARY KEY,
  recovery_ciphertext TEXT,
  recovery_nonce TEXT,
  created_at INTEGER NOT NULL,
  CHECK (
    (recovery_ciphertext IS NULL AND recovery_nonce IS NULL)
    OR (recovery_ciphertext IS NOT NULL AND recovery_nonce IS NOT NULL)
  )
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('macos', 'android')),
  public_key TEXT,
  created_by_device_id TEXT,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  revoked_at INTEGER,
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY (created_by_device_id) REFERENCES devices(id) ON DELETE SET NULL
);

CREATE INDEX idx_devices_vault ON devices(vault_id, created_at);
CREATE INDEX idx_devices_active ON devices(vault_id, revoked_at);

CREATE TABLE pairing_sessions (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  initiator_device_id TEXT NOT NULL,
  secret_hash TEXT NOT NULL UNIQUE,
  initiator_public_key TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('OPEN', 'CLAIMED', 'CONFIRMED', 'EXPIRED', 'CANCELED')),
  claimed_device_id TEXT,
  claimed_device_name TEXT,
  claimed_platform TEXT CHECK (claimed_platform IS NULL OR claimed_platform IN ('macos', 'android')),
  claimed_public_key TEXT,
  claimed_token_hash TEXT UNIQUE,
  confirmed_ciphertext TEXT,
  confirmed_nonce TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  claimed_at INTEGER,
  confirmed_at INTEGER,
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY (initiator_device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE INDEX idx_pairing_initiator ON pairing_sessions(initiator_device_id, created_at);
CREATE INDEX idx_pairing_expiry ON pairing_sessions(status, expires_at);

CREATE TABLE change_log (
  server_seq INTEGER PRIMARY KEY AUTOINCREMENT,
  vault_id TEXT NOT NULL,
  op_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (
    kind IN ('upsert', 'delete', 'complete', 'pass', 'reorder')
  ),
  lamport INTEGER NOT NULL CHECK (lamport >= 1),
  ciphertext TEXT NOT NULL,
  nonce TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE RESTRICT,
  UNIQUE (vault_id, op_id)
);

CREATE INDEX idx_change_log_pull ON change_log(vault_id, server_seq);

CREATE TABLE device_cursors (
  device_id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  cursor INTEGER NOT NULL DEFAULT 0 CHECK (cursor >= 0),
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE
);

CREATE INDEX idx_device_cursors_vault ON device_cursors(vault_id, cursor);

CREATE TABLE encrypted_snapshots (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  cursor INTEGER NOT NULL CHECK (cursor >= 0),
  ciphertext TEXT NOT NULL,
  nonce TEXT NOT NULL,
  created_by_device_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY (created_by_device_id) REFERENCES devices(id) ON DELETE RESTRICT
);

CREATE INDEX idx_snapshots_vault_cursor ON encrypted_snapshots(vault_id, cursor DESC);
