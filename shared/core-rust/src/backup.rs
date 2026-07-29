use std::collections::HashSet;

use pbkdf2::pbkdf2_hmac;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use unicode_normalization::UnicodeNormalization;
use zeroize::{Zeroize, Zeroizing};

use crate::crypto::{
    AES_KEY_BYTES, AES_NONCE_BYTES, AES_TAG_BYTES, aes256_gcm_open, aes256_gcm_seal,
    base64url_decode, base64url_encode, random_bytes,
};
use crate::error::{CoreError, CoreResult};
use crate::model::MAXIMUM_JSON_INTEGER;
use crate::wire::{EncryptedEnvelope, WireTaskPayload, WireTombstonePayload, canonical_json};

pub const BACKUP_FORMAT: &str = "woo-todo-backup";
pub const BACKUP_PROTOCOL_VERSION: i32 = 1;
pub const BACKUP_KDF_ALGORITHM: &str = "pbkdf2-hmac-sha256";
pub const BACKUP_CIPHER_ALGORITHM: &str = "aes-256-gcm";
pub const BACKUP_AAD_NAMESPACE: &str = "woo-todo-backup-v1";
pub const BACKUP_DEFAULT_ITERATIONS: u32 = 210_000;
pub const BACKUP_MINIMUM_ITERATIONS: u32 = 100_000;
pub const BACKUP_MAXIMUM_ITERATIONS: u32 = 2_000_000;
pub const BACKUP_SALT_BYTES: usize = 16;
pub const BACKUP_MAXIMUM_ENTITY_COUNT: usize = 50_000;
pub const BACKUP_MAXIMUM_CIPHERTEXT_BYTES: usize = 32 * 1024 * 1024;
pub const BACKUP_MAXIMUM_FILE_BYTES: usize = 45 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BackupKdfParameters {
    pub algorithm: String,
    pub iterations: u32,
    pub salt: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BackupCipherPayload {
    pub algorithm: String,
    pub nonce: String,
    pub ciphertext: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EncryptedBackupFile {
    pub format: String,
    pub version: i32,
    pub created_at: i64,
    pub kdf: BackupKdfParameters,
    pub cipher: BackupCipherPayload,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BackupSyncCredentials {
    pub endpoint: String,
    pub vault_id: String,
    pub device_id: String,
    pub device_token: String,
    pub vault_key: String,
}

impl BackupSyncCredentials {
    pub fn validate(&self) -> CoreResult<()> {
        if self.endpoint.is_empty()
            || self.endpoint.chars().count() > 2048
            || url::Url::parse(&self.endpoint).is_err()
            || !(1..=128).contains(&self.vault_id.chars().count())
            || !(1..=128).contains(&self.device_id.chars().count())
        {
            return Err(CoreError::validation("备份同步身份字段无效"));
        }
        let token = Zeroizing::new(base64url_decode(&self.device_token)?);
        let key = Zeroizing::new(base64url_decode(&self.vault_key)?);
        if token.len() != 32 || key.len() != AES_KEY_BYTES {
            return Err(CoreError::validation("备份设备令牌或 vault key 长度无效"));
        }
        Ok(())
    }

    pub fn decoded_vault_key(&self) -> CoreResult<[u8; AES_KEY_BYTES]> {
        self.validate()?;
        let decoded = Zeroizing::new(base64url_decode(&self.vault_key)?);
        <[u8; AES_KEY_BYTES]>::try_from(decoded.as_slice())
            .map_err(|_| CoreError::validation("vault key 必须为 32 字节"))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BackupSnapshot {
    pub exported_at: i64,
    pub protocol_version: i32,
    pub sync_credentials: Option<BackupSyncCredentials>,
    pub tasks: Vec<WireTaskPayload>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tombstones: Vec<WireTombstonePayload>,
}

impl BackupSnapshot {
    pub fn validate(&self) -> CoreResult<()> {
        if self.protocol_version != BACKUP_PROTOCOL_VERSION {
            return Err(CoreError::validation("不支持的备份正文协议版本"));
        }
        if !(0..=MAXIMUM_JSON_INTEGER).contains(&self.exported_at) {
            return Err(CoreError::validation(
                "exportedAt 超出 JSON safe integer 范围",
            ));
        }
        if self.tasks.len() + self.tombstones.len() > BACKUP_MAXIMUM_ENTITY_COUNT {
            return Err(CoreError::validation("备份任务与删除记录总数超过 50000"));
        }
        let mut identifiers = HashSet::with_capacity(self.tasks.len() + self.tombstones.len());
        for task in &self.tasks {
            task.validate()?;
            if !identifiers.insert(task.id.to_lowercase()) {
                return Err(CoreError::validation("备份包含重复任务 ID"));
            }
        }
        for tombstone in &self.tombstones {
            tombstone.validate()?;
            if !identifiers.insert(tombstone.id.to_lowercase()) {
                return Err(CoreError::validation("备份包含重复任务或删除 ID"));
            }
        }
        if let Some(credentials) = &self.sync_credentials {
            credentials.validate()?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupSealOptions {
    pub iterations: u32,
    pub salt: Option<[u8; BACKUP_SALT_BYTES]>,
    pub nonce: Option<[u8; AES_NONCE_BYTES]>,
}

impl Default for BackupSealOptions {
    fn default() -> Self {
        Self {
            iterations: BACKUP_DEFAULT_ITERATIONS,
            salt: None,
            nonce: None,
        }
    }
}

pub fn normalize_backup_passphrase(passphrase: &str) -> CoreResult<String> {
    let normalized: String = passphrase.nfkc().collect();
    if !(10..=256).contains(&normalized.chars().count()) {
        return Err(CoreError::validation(
            "备份口令规范化后须为 10 到 256 个字符",
        ));
    }
    Ok(normalized)
}

pub fn derive_backup_key(
    passphrase: &str,
    salt: &[u8],
    iterations: u32,
) -> CoreResult<[u8; AES_KEY_BYTES]> {
    if salt.len() != BACKUP_SALT_BYTES {
        return Err(CoreError::validation("备份 KDF salt 必须为 16 字节"));
    }
    if !(BACKUP_MINIMUM_ITERATIONS..=BACKUP_MAXIMUM_ITERATIONS).contains(&iterations) {
        return Err(CoreError::validation("备份 KDF iterations 超出允许范围"));
    }
    let mut password = Zeroizing::new(normalize_backup_passphrase(passphrase)?.into_bytes());
    let mut key = [0_u8; AES_KEY_BYTES];
    pbkdf2_hmac::<Sha256>(&password, salt, iterations, &mut key);
    password.zeroize();
    Ok(key)
}

pub fn backup_aad_canonical(created_at: i64, kdf: &BackupKdfParameters) -> String {
    format!(
        "{}|{}|{}|{}|{}|{}",
        BACKUP_AAD_NAMESPACE,
        created_at,
        kdf.algorithm,
        kdf.iterations,
        kdf.salt,
        BACKUP_CIPHER_ALGORITHM
    )
}

pub fn seal_backup(
    snapshot: &BackupSnapshot,
    passphrase: &str,
    options: BackupSealOptions,
) -> CoreResult<Vec<u8>> {
    snapshot.validate()?;
    if !(BACKUP_MINIMUM_ITERATIONS..=BACKUP_MAXIMUM_ITERATIONS).contains(&options.iterations) {
        return Err(CoreError::validation("备份 KDF iterations 超出允许范围"));
    }
    let salt = match options.salt {
        Some(value) => value,
        None => random_bytes::<BACKUP_SALT_BYTES>()?,
    };
    let nonce = match options.nonce {
        Some(value) => value,
        None => random_bytes::<AES_NONCE_BYTES>()?,
    };
    let kdf = BackupKdfParameters {
        algorithm: BACKUP_KDF_ALGORITHM.to_owned(),
        iterations: options.iterations,
        salt: base64url_encode(&salt),
    };
    let plaintext = Zeroizing::new(canonical_json(snapshot)?);
    if plaintext.len() > BACKUP_MAXIMUM_CIPHERTEXT_BYTES - AES_TAG_BYTES {
        return Err(CoreError::validation("备份正文超过安全大小限制"));
    }
    let mut key = derive_backup_key(passphrase, &salt, options.iterations)?;
    let envelope = aes256_gcm_seal(
        &plaintext,
        &key,
        Some(&nonce),
        backup_aad_canonical(snapshot.exported_at, &kdf).as_bytes(),
    );
    key.zeroize();
    let envelope = envelope?;
    let encoded = canonical_json(&EncryptedBackupFile {
        format: BACKUP_FORMAT.to_owned(),
        version: BACKUP_PROTOCOL_VERSION,
        created_at: snapshot.exported_at,
        kdf,
        cipher: BackupCipherPayload {
            algorithm: BACKUP_CIPHER_ALGORITHM.to_owned(),
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
        },
    })?;
    if encoded.len() > BACKUP_MAXIMUM_FILE_BYTES {
        return Err(CoreError::validation("备份文件超过安全大小限制"));
    }
    Ok(encoded)
}

pub fn open_backup(data: &[u8], passphrase: &str) -> CoreResult<BackupSnapshot> {
    if data.len() > BACKUP_MAXIMUM_FILE_BYTES {
        return Err(CoreError::validation("备份文件超过安全大小限制"));
    }
    let file: EncryptedBackupFile = serde_json::from_slice(data)?;
    validate_backup_file(&file)?;
    let salt = Zeroizing::new(base64url_decode(&file.kdf.salt)?);
    let mut key = derive_backup_key(passphrase, &salt, file.kdf.iterations)?;
    let plaintext = aes256_gcm_open(
        &EncryptedEnvelope {
            ciphertext: file.cipher.ciphertext.clone(),
            nonce: file.cipher.nonce.clone(),
        },
        &key,
        backup_aad_canonical(file.created_at, &file.kdf).as_bytes(),
    );
    key.zeroize();
    let plaintext = Zeroizing::new(plaintext?);
    if plaintext.len() > BACKUP_MAXIMUM_CIPHERTEXT_BYTES {
        return Err(CoreError::validation("备份正文超过安全大小限制"));
    }
    let snapshot: BackupSnapshot = serde_json::from_slice(&plaintext)?;
    snapshot.validate()?;
    if snapshot.exported_at != file.created_at {
        return Err(CoreError::validation("备份外层与正文导出时间不一致"));
    }
    Ok(snapshot)
}

fn validate_backup_file(file: &EncryptedBackupFile) -> CoreResult<()> {
    if file.format != BACKUP_FORMAT || file.version != BACKUP_PROTOCOL_VERSION {
        return Err(CoreError::validation("备份格式或协议版本无效"));
    }
    if !(0..=MAXIMUM_JSON_INTEGER).contains(&file.created_at) {
        return Err(CoreError::validation(
            "createdAt 超出 JSON safe integer 范围",
        ));
    }
    if file.kdf.algorithm != BACKUP_KDF_ALGORITHM
        || !(BACKUP_MINIMUM_ITERATIONS..=BACKUP_MAXIMUM_ITERATIONS).contains(&file.kdf.iterations)
        || base64url_decode(&file.kdf.salt)?.len() != BACKUP_SALT_BYTES
    {
        return Err(CoreError::validation("备份 KDF 参数无效"));
    }
    if file.cipher.algorithm != BACKUP_CIPHER_ALGORITHM
        || base64url_decode(&file.cipher.nonce)?.len() != AES_NONCE_BYTES
    {
        return Err(CoreError::validation("备份 cipher 参数无效"));
    }
    let ciphertext = base64url_decode(&file.cipher.ciphertext)?;
    if ciphertext.len() < AES_TAG_BYTES || ciphertext.len() > BACKUP_MAXIMUM_CIPHERTEXT_BYTES {
        return Err(CoreError::validation("备份密文长度无效"));
    }
    Ok(())
}
