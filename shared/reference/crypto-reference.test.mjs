import assert from "node:assert/strict";
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  hkdfSync,
} from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const vectors = JSON.parse(await readFile(
  new URL("../fixtures/crypto-vectors.json", import.meta.url),
  "utf8",
));

function occurrenceCanonical(namespace, input) {
  return [
    namespace,
    input.seriesId.toLowerCase(),
    input.timeType,
    input.periodStart,
  ].join("|");
}

function occurrenceUuid(canonical) {
  const bytes = Buffer.from(
    createHash("sha256").update(canonical, "utf8").digest().subarray(0, 16),
  );
  // 保留摘要位，仅覆盖 UUID 的 version 与 variant 位。
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join("-");
}

function decodeBase64Url(value, label) {
  assert.equal(typeof value, "string", `${label} 必须是字符串`);
  assert.match(value, /^[A-Za-z0-9_-]*$/u, `${label} 不是无填充 Base64URL`);
  const decoded = Buffer.from(value, "base64url");
  assert.equal(decoded.toString("base64url"), value, `${label} 不是规范 Base64URL`);
  return decoded;
}

test("occurrence ID golden vectors 与字符串规范一致", () => {
  const specification = vectors.occurrenceId;
  assert.equal(specification.digest, "SHA-256");
  assert.equal(specification.digestPrefixBytes, 16);
  assert.equal(specification.uuidVersion, 5);
  assert.equal(specification.uuidVariant, "RFC-4122");

  for (const vector of specification.vectors) {
    const canonical = occurrenceCanonical(specification.namespace, vector.input);
    assert.equal(canonical, vector.canonical, `${vector.name} 的规范字符串不一致`);
    const uuid = occurrenceUuid(canonical);
    assert.equal(uuid, vector.expectedUuid, `${vector.name} 的 UUID 不一致`);
    assert.equal(uuid[14], "5", `${vector.name} 未设置 version 5`);
    assert.match(uuid[19], /^[89ab]$/u, `${vector.name} 未设置 RFC variant`);
  }
});

test("AES-256-GCM golden vector 可加密并还原中文任务正文", () => {
  const specification = vectors.aes256Gcm;
  assert.equal(vectors.encoding, "base64url-no-padding");
  assert.equal(specification.algorithm, "AES-256-GCM");
  assert.equal(specification.authenticationTagBytes, 16);

  for (const vector of specification.vectors) {
    const key = decodeBase64Url(vector.key, `${vector.name}.key`);
    const nonce = decodeBase64Url(vector.nonce, `${vector.name}.nonce`);
    const aad = decodeBase64Url(vector.aad, `${vector.name}.aad`);
    const plaintext = decodeBase64Url(vector.plaintext, `${vector.name}.plaintext`);
    const expected = decodeBase64Url(vector.ciphertext, `${vector.name}.ciphertext`);
    const expectedTag = decodeBase64Url(
      vector.authenticationTag,
      `${vector.name}.authenticationTag`,
    );

    assert.equal(key.byteLength, 32, `${vector.name} 的 key 不是 256 位`);
    assert.equal(nonce.byteLength, 12, `${vector.name} 的 nonce 不是 12 字节`);
    assert.equal(expectedTag.byteLength, 16, `${vector.name} 的 tag 不是 16 字节`);
    assert.equal(aad.toString("utf8"), vector.aadUtf8);
    assert.equal(plaintext.toString("utf8"), vector.plaintextUtf8);

    const cipher = createCipheriv("aes-256-gcm", key, nonce, { authTagLength: 16 });
    cipher.setAAD(aad);
    const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    const tag = cipher.getAuthTag();
    const combined = Buffer.concat([encrypted, tag]);
    assert.equal(combined.toString("base64url"), vector.ciphertext);
    assert.deepEqual(tag, expectedTag);
    assert.deepEqual(combined, expected);

    const encryptedBody = expected.subarray(0, -specification.authenticationTagBytes);
    const storedTag = expected.subarray(-specification.authenticationTagBytes);
    const decipher = createDecipheriv("aes-256-gcm", key, nonce, { authTagLength: 16 });
    decipher.setAAD(aad);
    decipher.setAuthTag(storedTag);
    const decrypted = Buffer.concat([decipher.update(encryptedBody), decipher.final()]);
    assert.deepEqual(decrypted, plaintext);
  }
});

test("X25519 配对、核对码和 vaultKey envelope 与跨端向量一致", () => {
  const vector = vectors.pairing;
  const initiatorPrivate = createPrivateKey({
    format: "jwk",
    key: {
      kty: "OKP",
      crv: "X25519",
      x: vector.initiatorPublicKey,
      d: vector.initiatorPrivateKey,
    },
  });
  const claimPrivate = createPrivateKey({
    format: "jwk",
    key: {
      kty: "OKP",
      crv: "X25519",
      x: vector.claimPublicKey,
      d: vector.claimPrivateKey,
    },
  });
  const initiatorPublic = createPublicKey({
    format: "jwk",
    key: { kty: "OKP", crv: "X25519", x: vector.initiatorPublicKey },
  });
  const claimPublic = createPublicKey({
    format: "jwk",
    key: { kty: "OKP", crv: "X25519", x: vector.claimPublicKey },
  });

  const initiatorShared = diffieHellman({
    privateKey: initiatorPrivate,
    publicKey: claimPublic,
  });
  const claimShared = diffieHellman({
    privateKey: claimPrivate,
    publicKey: initiatorPublic,
  });
  assert.deepEqual(initiatorShared, claimShared);
  assert.equal(initiatorShared.toString("base64url"), vector.sharedSecret);

  const sessionKey = Buffer.from(hkdfSync(
    "sha256",
    initiatorShared,
    decodeBase64Url(vector.pairingSecret, "pairing.pairingSecret"),
    Buffer.from(vector.hkdfInfoUtf8, "utf8"),
    32,
  ));
  assert.equal(sessionKey.toString("base64url"), vector.sessionKey);

  const verificationDigest = createHmac("sha256", sessionKey)
    .update(vector.verificationInputUtf8, "utf8")
    .digest();
  const verificationCode = String(
    verificationDigest.readUInt32BE(0) % 1_000_000,
  ).padStart(6, "0");
  assert.equal(verificationCode, vector.verificationCode);

  const nonce = decodeBase64Url(vector.envelopeNonce, "pairing.envelopeNonce");
  const vaultKey = decodeBase64Url(vector.vaultKey, "pairing.vaultKey");
  const cipher = createCipheriv("aes-256-gcm", sessionKey, nonce, { authTagLength: 16 });
  cipher.setAAD(Buffer.from(vector.envelopeAadUtf8, "utf8"));
  const ciphertext = Buffer.concat([
    cipher.update(vaultKey),
    cipher.final(),
    cipher.getAuthTag(),
  ]);
  assert.equal(ciphertext.toString("base64url"), vector.vaultKeyCiphertext);
});
