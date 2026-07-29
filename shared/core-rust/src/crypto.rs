use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use subtle::ConstantTimeEq;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroize;

use crate::error::{CoreError, CoreResult};
use crate::wire::{EncryptedEnvelope, OperationKind};

pub const AES_KEY_BYTES: usize = 32;
pub const AES_NONCE_BYTES: usize = 12;
pub const AES_TAG_BYTES: usize = 16;
pub const SYNC_AAD_NAMESPACE: &str = "woo-todo-sync-v1";
pub const PAIRING_HKDF_NAMESPACE: &str = "woo-todo-pairing-v1";
pub const PAIRING_VERIFICATION_NAMESPACE: &str = "woo-todo-pairing-code-v1";
pub const PAIRING_ENVELOPE_NAMESPACE: &str = "woo-todo-pair-v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncAadMetadata {
    pub vault_id: String,
    pub operation_id: String,
    pub entity_id: String,
    pub kind: OperationKind,
    pub lamport: i64,
    pub device_id: String,
}

pub struct PairingKeyPair {
    private_key: [u8; 32],
    public_key: [u8; 32],
}

impl PairingKeyPair {
    pub fn generate() -> CoreResult<Self> {
        Self::from_private_key(random_bytes::<32>()?)
    }

    pub fn from_private_key(private_key: [u8; 32]) -> CoreResult<Self> {
        let secret = StaticSecret::from(private_key);
        let public_key = PublicKey::from(&secret).to_bytes();
        Ok(Self {
            private_key,
            public_key,
        })
    }

    pub const fn public_key(&self) -> &[u8; 32] {
        &self.public_key
    }

    pub fn public_key_base64url(&self) -> String {
        base64url_encode(&self.public_key)
    }

    pub fn shared_secret(&self, peer_public_key: &[u8]) -> CoreResult<[u8; 32]> {
        let peer = <[u8; 32]>::try_from(peer_public_key)
            .map_err(|_| CoreError::validation("X25519 公钥必须为 32 字节"))?;
        let secret = StaticSecret::from(self.private_key);
        let shared = secret.diffie_hellman(&PublicKey::from(peer)).to_bytes();
        if bool::from(shared.ct_eq(&[0_u8; 32])) {
            return Err(CoreError::new("crypto", "X25519 对端公钥不可参与密钥协商"));
        }
        Ok(shared)
    }

    pub fn session_key(
        &self,
        peer_public_key: &[u8],
        pairing_id: &str,
        pairing_secret: &[u8],
    ) -> CoreResult<[u8; AES_KEY_BYTES]> {
        if pairing_secret.len() != 32 {
            return Err(CoreError::validation("配对 secret 必须为 32 字节"));
        }
        let mut shared = self.shared_secret(peer_public_key)?;
        let hkdf = Hkdf::<Sha256>::new(Some(pairing_secret), &shared);
        let mut output = [0_u8; AES_KEY_BYTES];
        hkdf.expand(&pairing_hkdf_info(pairing_id), &mut output)
            .map_err(|_| CoreError::new("crypto", "无法派生配对 session key"))?;
        shared.zeroize();
        Ok(output)
    }

    pub fn session_key_base64url(
        &self,
        peer_public_key: &str,
        pairing_id: &str,
        pairing_secret: &str,
    ) -> CoreResult<[u8; AES_KEY_BYTES]> {
        let peer = base64url_decode(peer_public_key)?;
        let secret = zeroize::Zeroizing::new(base64url_decode(pairing_secret)?);
        self.session_key(&peer, pairing_id, &secret)
    }
}

impl Drop for PairingKeyPair {
    fn drop(&mut self) {
        self.private_key.zeroize();
    }
}

pub fn base64url_encode(data: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(data)
}

pub fn base64url_decode(source: &str) -> CoreResult<Vec<u8>> {
    if source.contains('=')
        || source.len() % 4 == 1
        || !source
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(CoreError::new("crypto", "数据不是规范的无填充 Base64URL"));
    }
    let decoded = URL_SAFE_NO_PAD
        .decode(source)
        .map_err(|_| CoreError::new("crypto", "Base64URL 解码失败"))?;
    if base64url_encode(&decoded) != source {
        return Err(CoreError::new("crypto", "数据不是规范的无填充 Base64URL"));
    }
    Ok(decoded)
}

pub fn random_bytes<const N: usize>() -> CoreResult<[u8; N]> {
    let mut bytes = [0_u8; N];
    getrandom::fill(&mut bytes)
        .map_err(|error| CoreError::new("crypto", format!("安全随机数生成失败：{error}")))?;
    Ok(bytes)
}

pub fn sync_aad_canonical(metadata: &SyncAadMetadata) -> String {
    format!(
        "{}|{}|{}|{}|{}|{}|{}",
        SYNC_AAD_NAMESPACE,
        metadata.vault_id,
        metadata.operation_id,
        metadata.entity_id,
        metadata.kind.wire_value(),
        metadata.lamport,
        metadata.device_id
    )
}

pub fn pairing_hkdf_info(pairing_id: &str) -> Vec<u8> {
    format!("{PAIRING_HKDF_NAMESPACE}|{pairing_id}").into_bytes()
}

pub fn pairing_verification_input(
    initiator_public_key: &[u8],
    claim_public_key: &[u8],
) -> CoreResult<Vec<u8>> {
    if initiator_public_key.len() != 32 || claim_public_key.len() != 32 {
        return Err(CoreError::validation("配对双方 X25519 公钥必须为 32 字节"));
    }
    Ok(format!(
        "{}|{}|{}",
        PAIRING_VERIFICATION_NAMESPACE,
        base64url_encode(initiator_public_key),
        base64url_encode(claim_public_key)
    )
    .into_bytes())
}

pub fn pairing_verification_code(
    session_key: &[u8],
    initiator_public_key: &[u8],
    claim_public_key: &[u8],
) -> CoreResult<String> {
    if session_key.len() != AES_KEY_BYTES {
        return Err(CoreError::validation("配对 session key 必须为 32 字节"));
    }
    type HmacSha256 = Hmac<Sha256>;
    let mut hmac = <HmacSha256 as Mac>::new_from_slice(session_key)
        .map_err(|_| CoreError::new("crypto", "无法初始化配对 HMAC"))?;
    hmac.update(&pairing_verification_input(
        initiator_public_key,
        claim_public_key,
    )?);
    let digest = hmac.finalize().into_bytes();
    let value = u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]);
    Ok(format!("{:06}", value % 1_000_000))
}

pub fn pairing_envelope_aad(pairing_id: &str, claimed_device_id: &str) -> Vec<u8> {
    format!("{PAIRING_ENVELOPE_NAMESPACE}|{pairing_id}|{claimed_device_id}").into_bytes()
}

pub fn seal_pairing_vault_key(
    vault_key: &[u8],
    session_key: &[u8],
    pairing_id: &str,
    claimed_device_id: &str,
    nonce: Option<&[u8]>,
) -> CoreResult<EncryptedEnvelope> {
    if vault_key.len() != AES_KEY_BYTES {
        return Err(CoreError::validation("vault key 必须为 32 字节"));
    }
    aes256_gcm_seal(
        vault_key,
        session_key,
        nonce,
        &pairing_envelope_aad(pairing_id, claimed_device_id),
    )
}

pub fn open_pairing_vault_key(
    envelope: &EncryptedEnvelope,
    session_key: &[u8],
    pairing_id: &str,
    claimed_device_id: &str,
) -> CoreResult<[u8; AES_KEY_BYTES]> {
    let mut plaintext = aes256_gcm_open(
        envelope,
        session_key,
        &pairing_envelope_aad(pairing_id, claimed_device_id),
    )?;
    let result = <[u8; AES_KEY_BYTES]>::try_from(plaintext.as_slice())
        .map_err(|_| CoreError::new("crypto", "配对 envelope 中的 vault key 长度无效"));
    plaintext.zeroize();
    result
}

pub fn aes256_gcm_seal(
    plaintext: &[u8],
    key: &[u8],
    nonce: Option<&[u8]>,
    aad: &[u8],
) -> CoreResult<EncryptedEnvelope> {
    if key.len() != AES_KEY_BYTES {
        return Err(CoreError::new("crypto", "AES-256-GCM 密钥必须为 32 字节"));
    }
    let generated;
    let nonce = if let Some(value) = nonce {
        value
    } else {
        generated = random_bytes::<AES_NONCE_BYTES>()?;
        &generated
    };
    if nonce.len() != AES_NONCE_BYTES {
        return Err(CoreError::new("crypto", "AES-GCM nonce 必须为 12 字节"));
    }
    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|_| CoreError::new("crypto", "无法初始化 AES-256-GCM"))?;
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| CoreError::new("crypto", "AES-256-GCM 加密失败"))?;
    Ok(EncryptedEnvelope {
        ciphertext: base64url_encode(&ciphertext),
        nonce: base64url_encode(nonce),
    })
}

pub fn aes256_gcm_open(
    envelope: &EncryptedEnvelope,
    key: &[u8],
    aad: &[u8],
) -> CoreResult<Vec<u8>> {
    if key.len() != AES_KEY_BYTES {
        return Err(CoreError::new("crypto", "AES-256-GCM 密钥必须为 32 字节"));
    }
    let nonce = base64url_decode(&envelope.nonce)?;
    if nonce.len() != AES_NONCE_BYTES {
        return Err(CoreError::new("crypto", "AES-GCM nonce 必须为 12 字节"));
    }
    let ciphertext = base64url_decode(&envelope.ciphertext)?;
    if ciphertext.len() < AES_TAG_BYTES {
        return Err(CoreError::new("crypto", "AES-GCM 密文缺少认证标签"));
    }
    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|_| CoreError::new("crypto", "无法初始化 AES-256-GCM"))?;
    cipher
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad,
            },
        )
        .map_err(|_| CoreError::new("authentication_failed", "密钥错误或密文已损坏"))
}
