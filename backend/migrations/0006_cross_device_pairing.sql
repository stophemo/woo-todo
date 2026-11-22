-- 跨设备配对：短码、反向加入请求、中继 epoch 与限流窗口。
-- 只做 additive 变更，不改动既有 change_log/cursor/容量语义。

ALTER TABLE pairing_sessions ADD COLUMN short_code_hash TEXT;

CREATE UNIQUE INDEX idx_pairing_short_code
  ON pairing_sessions(short_code_hash)
  WHERE short_code_hash IS NOT NULL;

ALTER TABLE vaults ADD COLUMN relay_epoch TEXT NOT NULL DEFAULT '';
ALTER TABLE vaults ADD COLUMN relay_url TEXT NOT NULL DEFAULT 'https://ntfy.sh';

UPDATE vaults
SET relay_epoch = lower(hex(randomblob(32)))
WHERE relay_epoch = '';

CREATE TABLE pairing_join_requests (
  id TEXT PRIMARY KEY,
  short_code_hash TEXT UNIQUE,
  join_secret_hash TEXT NOT NULL UNIQUE,
  join_public_key TEXT NOT NULL,
  device_id TEXT NOT NULL UNIQUE,
  device_name TEXT NOT NULL,
  device_platform TEXT NOT NULL CHECK (device_platform IN ('macos', 'android', 'windows')),
  device_token_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL CHECK (status IN ('OPEN', 'RESOLVED', 'APPROVED', 'EXPIRED', 'CANCELED')),
  approver_device_id TEXT,
  approver_public_key TEXT,
  vault_id TEXT,
  confirmed_ciphertext TEXT,
  confirmed_nonce TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  resolved_at INTEGER,
  approved_at INTEGER,
  CHECK (
    (confirmed_ciphertext IS NULL AND confirmed_nonce IS NULL)
    OR (confirmed_ciphertext IS NOT NULL AND confirmed_nonce IS NOT NULL)
  ),
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE,
  FOREIGN KEY (approver_device_id) REFERENCES devices(id) ON DELETE SET NULL
);

CREATE INDEX idx_join_expiry
  ON pairing_join_requests(status, expires_at);

CREATE INDEX idx_join_vault
  ON pairing_join_requests(vault_id, created_at);

CREATE TABLE pairing_rate_windows (
  scope TEXT NOT NULL CHECK (scope IN (
    'resolve_source', 'resolve_service', 'join_source', 'join_service',
    'join_device', 'code_device'
  )),
  subject_hash TEXT NOT NULL,
  window_started_at INTEGER NOT NULL,
  window_ends_at INTEGER NOT NULL,
  request_count INTEGER NOT NULL CHECK (request_count >= 1),
  PRIMARY KEY (scope, subject_hash, window_started_at),
  CHECK (window_ends_at > window_started_at)
);

CREATE INDEX idx_pairing_rate_expiry
  ON pairing_rate_windows(window_ends_at);
