import assert from "node:assert/strict";
import {
  createDecipheriv,
  pbkdf2Sync,
} from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const vector = JSON.parse(await readFile(
  new URL("../fixtures/backup-vectors.json", import.meta.url),
  "utf8",
));

test("加密备份 golden vector 可跨端派生密钥并恢复正文", () => {
  assert.equal(vector.password.normalize("NFKC"), vector.passwordNormalized);
  assert.equal(vector.kdf.algorithm, "pbkdf2-hmac-sha256");
  assert.equal(vector.cipher.algorithm, "aes-256-gcm");

  const salt = Buffer.from(vector.kdf.salt, "base64url");
  const key = pbkdf2Sync(
    Buffer.from(vector.passwordNormalized, "utf8"),
    salt,
    vector.kdf.iterations,
    32,
    "sha256",
  );
  assert.equal(key.toString("base64url"), vector.derivedKey);

  const combined = Buffer.from(vector.cipher.ciphertext, "base64url");
  const encrypted = combined.subarray(0, -16);
  const tag = combined.subarray(-16);
  const decipher = createDecipheriv(
    "aes-256-gcm",
    key,
    Buffer.from(vector.cipher.nonce, "base64url"),
    { authTagLength: 16 },
  );
  decipher.setAAD(Buffer.from(vector.aadUtf8, "utf8"));
  decipher.setAuthTag(tag);
  const plaintext = Buffer.concat([decipher.update(encrypted), decipher.final()]);
  assert.equal(plaintext.toString("utf8"), vector.plaintextUtf8);

  const snapshot = JSON.parse(plaintext);
  assert.equal(snapshot.protocolVersion, 1);
  assert.equal(snapshot.exportedAt, vector.createdAt);
  assert.equal(snapshot.tasks[0].title, "提交周报");
  assert.equal(snapshot.tombstones, undefined);
  assert.equal(snapshot.syncCredentials.vaultKey.length, 43);
});

test("备份正文可选携带删除屏障且旧正文仍可读取", () => {
  const snapshot = JSON.parse(vector.tombstonePlaintextUtf8);
  assert.deepEqual(snapshot.tasks, []);
  assert.equal(snapshot.tombstones.length, 1);
  assert.equal(snapshot.tombstones[0].entityType, "tombstone");
  assert.equal(snapshot.tombstones[0].deletedAt, 1784251800000);
});
