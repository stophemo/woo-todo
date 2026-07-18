CREATE TABLE vault_usage (
  vault_id TEXT PRIMARY KEY,
  operation_count INTEGER NOT NULL DEFAULT 0 CHECK (operation_count >= 0),
  ciphertext_bytes INTEGER NOT NULL DEFAULT 0 CHECK (ciphertext_bytes >= 0),
  FOREIGN KEY (vault_id) REFERENCES vaults(id) ON DELETE CASCADE
);

-- 迁移时只扫描一次既有日志；后续写入和删除均由触发器增量维护。
INSERT INTO vault_usage(vault_id, operation_count, ciphertext_bytes)
SELECT
  v.id,
  COUNT(c.server_seq),
  COALESCE(SUM(CAST((length(c.ciphertext) * 6) / 8 AS INTEGER)), 0)
FROM vaults v
LEFT JOIN change_log c ON c.vault_id = v.id
GROUP BY v.id;

CREATE TRIGGER initialize_vault_usage
AFTER INSERT ON vaults
BEGIN
  INSERT INTO vault_usage(vault_id, operation_count, ciphertext_bytes)
  VALUES (NEW.id, 0, 0);
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

-- 100000 条操作与 32 MiB 解码后密文为固定上限。SQLite 写事务和触发器
-- 保证多个 Worker 实例并发 push 时也不会越过边界。
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
