export type CredentialPurpose =
  | "device-token"
  | "pairing-secret"
  | "pairing-code"
  | "join-secret"
  | "vault-creation-source"
  | "pairing-source";

const encoder = new TextEncoder();

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}

export function randomSecret(byteLength = 32): string {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return bytesToBase64Url(bytes);
}

export async function hashCredential(
  secret: string,
  purpose: CredentialPurpose,
  pepper: string,
): Promise<string> {
  const signature = await hmacBytes(
    encoder.encode(`${purpose}\u0000${secret}`),
    pepper,
  );
  return Array.from(
    signature,
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}

async function hmacBytes(input: BufferSource, pepper: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(pepper),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, input));
}

/** 六位码使用拒绝采样，避免取模偏差。 */
export function randomShortCode(): string {
  const maximum = 1_000_000;
  const ceiling = Math.floor(0x1_0000_0000 / maximum) * maximum;
  const value = new Uint32Array(1);
  do {
    crypto.getRandomValues(value);
  } while (value[0] >= ceiling);
  return String(value[0] % maximum).padStart(6, "0");
}

/** 短码模式下服务端只保存 hash；resolve 用同一算法重建 pairing secret。 */
export async function deriveShortPairingSecret(
  pairingId: string,
  code: string,
  pepper: string,
): Promise<string> {
  const signature = await hmacBytes(
    encoder.encode(`short-pairing\u0000${pairingId}\u0000${code}`),
    pepper,
  );
  return bytesToBase64Url(signature);
}
