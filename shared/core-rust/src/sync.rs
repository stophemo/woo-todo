use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::crypto::{AES_KEY_BYTES, SyncAadMetadata, aes256_gcm_open, aes256_gcm_seal};
use crate::error::{CoreError, CoreResult};
use crate::wire::{
    EncryptedEnvelope, OperationKind, SyncPulledOperation, SyncPushOperation, WireEntity,
    decode_entity, encode_entity,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncConfiguration {
    pub vault_id: String,
    pub device_id: String,
    pub vault_key: [u8; AES_KEY_BYTES],
}

impl SyncConfiguration {
    pub fn new(
        vault_id: impl Into<String>,
        device_id: impl Into<String>,
        vault_key: &[u8],
    ) -> CoreResult<Self> {
        let vault_id = vault_id.into();
        let device_id = device_id.into();
        if vault_id.is_empty() || vault_id.chars().count() > 128 {
            return Err(CoreError::validation("vaultId 必须为 1 到 128 个字符"));
        }
        if device_id.is_empty() || device_id.chars().count() > 128 {
            return Err(CoreError::validation("deviceId 必须为 1 到 128 个字符"));
        }
        let vault_key = <[u8; AES_KEY_BYTES]>::try_from(vault_key)
            .map_err(|_| CoreError::validation("vault key 必须为 32 字节"))?;
        Ok(Self {
            vault_id,
            device_id,
            vault_key,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncState {
    pub vault_id: Option<String>,
    pub device_id: Option<String>,
    pub cursor: i64,
    pub lamport: i64,
    pub outbox_count: usize,
    pub entity_version_count: usize,
    pub applied_operation_count: usize,
    pub deferred_upsert_count: usize,
    pub deferred_deletion_count: usize,
    pub has_deferred_display_configuration: bool,
}

impl SyncState {
    pub fn has_bound_identity(&self) -> bool {
        self.vault_id.is_some() || self.device_id.is_some()
    }

    pub fn has_sync_history(&self) -> bool {
        self.cursor != 0
            || self.lamport != 0
            || self.outbox_count != 0
            || self.entity_version_count != 0
            || self.applied_operation_count != 0
            || self.deferred_upsert_count != 0
            || self.deferred_deletion_count != 0
            || self.has_deferred_display_configuration
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WebDavOperation {
    pub format: String,
    pub protocol_version: i32,
    pub vault_id: String,
    pub device_id: String,
    pub op_id: String,
    pub entity_id: String,
    pub kind: OperationKind,
    pub lamport: i64,
    pub nonce: String,
    pub ciphertext: String,
}

impl WebDavOperation {
    pub const FORMAT: &'static str = "woo-todo-webdav-operation";

    pub fn from_push(
        vault_id: impl Into<String>,
        device_id: impl Into<String>,
        operation: SyncPushOperation,
    ) -> Self {
        Self {
            format: Self::FORMAT.to_owned(),
            protocol_version: 1,
            vault_id: vault_id.into(),
            device_id: device_id.into(),
            op_id: operation.op_id,
            entity_id: operation.entity_id,
            kind: operation.kind,
            lamport: operation.lamport,
            nonce: operation.nonce,
            ciphertext: operation.ciphertext,
        }
    }

    pub fn validate(&self) -> CoreResult<()> {
        if self.format != Self::FORMAT || self.protocol_version != 1 {
            return Err(CoreError::validation("WebDAV 操作格式或协议版本无效"));
        }
        SyncPushOperation {
            op_id: self.op_id.clone(),
            entity_id: self.entity_id.clone(),
            kind: self.kind,
            lamport: self.lamport,
            ciphertext: self.ciphertext.clone(),
            nonce: self.nonce.clone(),
        }
        .validate()?;
        if self.vault_id.is_empty()
            || self.vault_id.chars().count() > 128
            || self.device_id.is_empty()
            || self.device_id.chars().count() > 128
        {
            return Err(CoreError::validation("WebDAV 空间或设备标识无效"));
        }
        Ok(())
    }

    pub fn as_pulled(&self, server_seq: i64, created_at: i64) -> SyncPulledOperation {
        SyncPulledOperation {
            server_seq,
            op_id: self.op_id.clone(),
            device_id: self.device_id.clone(),
            entity_id: self.entity_id.clone(),
            kind: self.kind,
            lamport: self.lamport,
            ciphertext: self.ciphertext.clone(),
            nonce: self.nonce.clone(),
            created_at,
        }
    }
}

pub struct OperationCodec;

impl OperationCodec {
    pub fn seal(
        entity: &WireEntity,
        configuration: &SyncConfiguration,
        operation_id: &str,
        entity_id: &str,
        kind: OperationKind,
        lamport: i64,
        nonce: Option<&[u8]>,
    ) -> CoreResult<EncryptedEnvelope> {
        let plaintext = Zeroizing::new(encode_entity(entity)?);
        let metadata = SyncAadMetadata {
            vault_id: configuration.vault_id.clone(),
            operation_id: operation_id.to_owned(),
            entity_id: entity_id.to_owned(),
            kind,
            lamport,
            device_id: configuration.device_id.clone(),
        };
        let aad = crate::crypto::sync_aad_canonical(&metadata);
        aes256_gcm_seal(&plaintext, &configuration.vault_key, nonce, aad.as_bytes())
    }

    pub fn open_push(
        operation: &SyncPushOperation,
        configuration: &SyncConfiguration,
    ) -> CoreResult<WireEntity> {
        operation.validate()?;
        Self::open(
            &EncryptedEnvelope {
                ciphertext: operation.ciphertext.clone(),
                nonce: operation.nonce.clone(),
            },
            configuration,
            &operation.op_id,
            &operation.entity_id,
            operation.kind,
            operation.lamport,
            &configuration.device_id,
        )
    }

    pub fn open_pulled(
        operation: &SyncPulledOperation,
        configuration: &SyncConfiguration,
    ) -> CoreResult<WireEntity> {
        operation.validate()?;
        Self::open(
            &EncryptedEnvelope {
                ciphertext: operation.ciphertext.clone(),
                nonce: operation.nonce.clone(),
            },
            configuration,
            &operation.op_id,
            &operation.entity_id,
            operation.kind,
            operation.lamport,
            &operation.device_id,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn open(
        envelope: &EncryptedEnvelope,
        configuration: &SyncConfiguration,
        operation_id: &str,
        entity_id: &str,
        kind: OperationKind,
        lamport: i64,
        device_id: &str,
    ) -> CoreResult<WireEntity> {
        let metadata = SyncAadMetadata {
            vault_id: configuration.vault_id.clone(),
            operation_id: operation_id.to_owned(),
            entity_id: entity_id.to_owned(),
            kind,
            lamport,
            device_id: device_id.to_owned(),
        };
        let aad = crate::crypto::sync_aad_canonical(&metadata);
        let plaintext = Zeroizing::new(aes256_gcm_open(
            envelope,
            &configuration.vault_key,
            aad.as_bytes(),
        )?);
        decode_entity(&plaintext)
    }
}
