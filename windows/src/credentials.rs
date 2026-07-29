use std::fmt;
#[cfg(test)]
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use url::Url;

#[cfg(windows)]
const DEFAULT_TARGET: &str = "WooTodo/Sync/v1";
const MAXIMUM_CREDENTIAL_BYTES: usize = 2_560;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncMode {
    Worker,
    LocalNetwork,
    WebDav,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "camelCase", deny_unknown_fields)]
pub enum SyncCredentials {
    Worker {
        endpoint: String,
        vault_id: String,
        device_id: String,
        device_token: String,
        vault_key: String,
    },
    LocalNetwork {
        endpoint: String,
        vault_id: String,
        device_id: String,
        device_token: String,
        vault_key: String,
    },
    WebDav {
        username: String,
        app_password: String,
        vault_id: String,
        device_id: String,
        vault_key: String,
    },
}

impl fmt::Debug for SyncCredentials {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut output = formatter.debug_struct("SyncCredentials");
        output.field("mode", &self.mode());
        if let Some(endpoint) = self.endpoint() {
            output.field("endpoint", &endpoint);
        }
        if matches!(self, Self::WebDav { .. }) {
            output.field("username", &"<已隐藏>");
        }
        output
            .field("vault_id", &"<已隐藏>")
            .field("device_id", &"<已隐藏>")
            .field("secrets", &"<已隐藏>")
            .finish()
    }
}

impl SyncCredentials {
    pub fn mode(&self) -> SyncMode {
        match self {
            Self::Worker { .. } => SyncMode::Worker,
            Self::LocalNetwork { .. } => SyncMode::LocalNetwork,
            Self::WebDav { .. } => SyncMode::WebDav,
        }
    }

    pub fn vault_id(&self) -> &str {
        match self {
            Self::Worker { vault_id, .. }
            | Self::LocalNetwork { vault_id, .. }
            | Self::WebDav { vault_id, .. } => vault_id,
        }
    }

    pub fn device_id(&self) -> &str {
        match self {
            Self::Worker { device_id, .. }
            | Self::LocalNetwork { device_id, .. }
            | Self::WebDav { device_id, .. } => device_id,
        }
    }

    pub fn vault_key(&self) -> &str {
        match self {
            Self::Worker { vault_key, .. }
            | Self::LocalNetwork { vault_key, .. }
            | Self::WebDav { vault_key, .. } => vault_key,
        }
    }

    pub fn endpoint(&self) -> Option<&str> {
        match self {
            Self::Worker { endpoint, .. } | Self::LocalNetwork { endpoint, .. } => Some(endpoint),
            Self::WebDav { .. } => None,
        }
    }

    pub fn device_token(&self) -> Option<&str> {
        match self {
            Self::Worker { device_token, .. } | Self::LocalNetwork { device_token, .. } => {
                Some(device_token)
            }
            Self::WebDav { .. } => None,
        }
    }

    pub fn reuse_empty_secrets(mut self, saved: Option<&Self>) -> Result<Self, String> {
        match (&mut self, saved) {
            (
                Self::Worker {
                    vault_id,
                    device_id,
                    device_token,
                    vault_key,
                    ..
                },
                Some(Self::Worker {
                    vault_id: saved_vault_id,
                    device_id: saved_device_id,
                    device_token: saved_device_token,
                    vault_key: saved_vault_key,
                    ..
                }),
            )
            | (
                Self::LocalNetwork {
                    vault_id,
                    device_id,
                    device_token,
                    vault_key,
                    ..
                },
                Some(Self::LocalNetwork {
                    vault_id: saved_vault_id,
                    device_id: saved_device_id,
                    device_token: saved_device_token,
                    vault_key: saved_vault_key,
                    ..
                }),
            ) => {
                if device_token.is_empty()
                    && vault_id == saved_vault_id
                    && device_id == saved_device_id
                {
                    device_token.clone_from(saved_device_token);
                }
                if vault_key.is_empty() && vault_id == saved_vault_id {
                    vault_key.clone_from(saved_vault_key);
                }
            }
            (
                Self::WebDav {
                    username,
                    app_password,
                    vault_id,
                    vault_key,
                    ..
                },
                Some(Self::WebDav {
                    username: saved_username,
                    app_password: saved_app_password,
                    vault_id: saved_vault_id,
                    vault_key: saved_vault_key,
                    ..
                }),
            ) => {
                if app_password.is_empty() && username == saved_username {
                    app_password.clone_from(saved_app_password);
                }
                if vault_key.is_empty() && vault_id == saved_vault_id {
                    vault_key.clone_from(saved_vault_key);
                }
            }
            _ => {}
        }
        self.validate()?;
        Ok(self)
    }

    pub fn with_endpoint(&self, endpoint: String) -> Result<Self, String> {
        let updated = match self {
            Self::Worker {
                vault_id,
                device_id,
                device_token,
                vault_key,
                ..
            } => Self::Worker {
                endpoint,
                vault_id: vault_id.clone(),
                device_id: device_id.clone(),
                device_token: device_token.clone(),
                vault_key: vault_key.clone(),
            },
            Self::LocalNetwork {
                vault_id,
                device_id,
                device_token,
                vault_key,
                ..
            } => Self::LocalNetwork {
                endpoint,
                vault_id: vault_id.clone(),
                device_id: device_id.clone(),
                device_token: device_token.clone(),
                vault_key: vault_key.clone(),
            },
            Self::WebDav { .. } => return Err("坚果云凭据没有可修改的同步端点".to_owned()),
        };
        updated.validate()?;
        Ok(updated)
    }

    pub fn webdav_login(&self) -> Option<(&str, &str)> {
        match self {
            Self::WebDav {
                username,
                app_password,
                ..
            } => Some((username, app_password)),
            _ => None,
        }
    }

    pub fn webdav_setup_link(&self) -> Result<String, String> {
        let Self::WebDav {
            username,
            app_password,
            vault_id,
            vault_key,
            ..
        } = self
        else {
            return Err("只有坚果云同步身份可以生成配置二维码".to_owned());
        };
        self.validate()?;
        let mut link =
            Url::parse("wootodo://webdav").map_err(|_| "无法构造坚果云配置链接".to_owned())?;
        link.query_pairs_mut()
            .append_pair("v", "1")
            .append_pair("username", username)
            .append_pair("appPassword", app_password)
            .append_pair("vaultId", vault_id)
            .append_pair("vaultKey", vault_key);
        Ok(link.to_string())
    }

    pub fn validate(&self) -> Result<(), String> {
        if !valid_vault_id(self.vault_id())
            || !valid_identifier(self.device_id())
            || !valid_base64url_32(self.vault_key())
        {
            return Err("同步身份字段无效".to_owned());
        }
        match self {
            Self::Worker {
                endpoint,
                device_token,
                ..
            } => {
                if !valid_endpoint_text(endpoint, true) || !valid_base64url_32(device_token) {
                    return Err("Worker 同步凭据无效".to_owned());
                }
            }
            Self::LocalNetwork {
                endpoint,
                device_token,
                ..
            } => {
                if !valid_endpoint_text(endpoint, false) || !valid_base64url_32(device_token) {
                    return Err("同一网络同步凭据无效".to_owned());
                }
            }
            Self::WebDav {
                username,
                app_password,
                ..
            } => {
                if username.is_empty()
                    || username.chars().count() > 320
                    || username
                        .chars()
                        .any(|value| value.is_whitespace() || value.is_control())
                    || app_password.is_empty()
                    || app_password.chars().count() > 256
                    || app_password.chars().any(char::is_control)
                {
                    return Err("坚果云同步凭据无效".to_owned());
                }
            }
        }
        Ok(())
    }

    fn encode(&self) -> Result<Vec<u8>, String> {
        self.validate()?;
        let value =
            serde_json::to_vec(self).map_err(|error| format!("无法编码同步凭据：{error}"))?;
        if value.len() > MAXIMUM_CREDENTIAL_BYTES {
            return Err("同步凭据超过 Windows 安全存储上限".to_owned());
        }
        Ok(value)
    }

    fn decode(value: &[u8]) -> Result<Self, String> {
        if value.is_empty() || value.len() > MAXIMUM_CREDENTIAL_BYTES {
            return Err("Windows 安全存储中的同步凭据长度无效".to_owned());
        }
        let decoded: Self = serde_json::from_slice(value)
            .map_err(|_| "Windows 安全存储中的同步凭据格式无效".to_owned())?;
        decoded.validate()?;
        Ok(decoded)
    }
}

pub trait SyncCredentialStore: Send + Sync {
    fn save(&self, credentials: &SyncCredentials) -> Result<(), String>;
    fn load(&self) -> Result<Option<SyncCredentials>, String>;
    fn delete(&self) -> Result<(), String>;
}

#[cfg(test)]
#[derive(Default)]
pub struct MemoryCredentialStore {
    value: Mutex<Option<Vec<u8>>>,
}

#[cfg(test)]
impl SyncCredentialStore for MemoryCredentialStore {
    fn save(&self, credentials: &SyncCredentials) -> Result<(), String> {
        *self.value.lock().map_err(|_| "同步凭据锁已损坏")? = Some(credentials.encode()?);
        Ok(())
    }

    fn load(&self) -> Result<Option<SyncCredentials>, String> {
        self.value
            .lock()
            .map_err(|_| "同步凭据锁已损坏".to_owned())?
            .as_deref()
            .map(SyncCredentials::decode)
            .transpose()
    }

    fn delete(&self) -> Result<(), String> {
        *self.value.lock().map_err(|_| "同步凭据锁已损坏")? = None;
        Ok(())
    }
}

#[cfg(windows)]
pub struct WindowsCredentialStore {
    target: String,
}

#[cfg(windows)]
impl Default for WindowsCredentialStore {
    fn default() -> Self {
        Self::new(DEFAULT_TARGET)
    }
}

#[cfg(windows)]
impl WindowsCredentialStore {
    pub fn new(target: impl Into<String>) -> Self {
        Self {
            target: target.into(),
        }
    }
}

#[cfg(windows)]
impl SyncCredentialStore for WindowsCredentialStore {
    fn save(&self, credentials: &SyncCredentials) -> Result<(), String> {
        use windows_sys::Win32::Security::Credentials::{
            CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC, CREDENTIALW, CredWriteW,
        };

        let mut blob = credentials.encode()?;
        let mut target = wide(&self.target);
        let mut username = wide("Woo Todo 同步身份");
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: target.as_mut_ptr(),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            UserName: username.as_mut_ptr(),
            ..Default::default()
        };
        let result = unsafe { CredWriteW(&credential, 0) };
        blob.fill(0);
        if result == 0 {
            return Err(last_error("无法保存 Windows 同步凭据"));
        }
        Ok(())
    }

    fn load(&self) -> Result<Option<SyncCredentials>, String> {
        use std::ptr::null_mut;
        use windows_sys::Win32::Foundation::{ERROR_NOT_FOUND, GetLastError};
        use windows_sys::Win32::Security::Credentials::{
            CRED_TYPE_GENERIC, CREDENTIALW, CredFree, CredReadW,
        };

        struct CredentialGuard(*mut CREDENTIALW);
        impl Drop for CredentialGuard {
            fn drop(&mut self) {
                if !self.0.is_null() {
                    unsafe { CredFree(self.0.cast()) };
                }
            }
        }

        let target = wide(&self.target);
        let mut raw: *mut CREDENTIALW = null_mut();
        if unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut raw) } == 0 {
            let error = unsafe { GetLastError() };
            if error == ERROR_NOT_FOUND {
                return Ok(None);
            }
            return Err(format!("无法读取 Windows 同步凭据（错误 {error}）"));
        }
        let guard = CredentialGuard(raw);
        let credential = unsafe { &*guard.0 };
        if credential.CredentialBlob.is_null() {
            return Err("Windows 安全存储返回空同步凭据".to_owned());
        }
        let length = credential.CredentialBlobSize as usize;
        if length == 0 || length > MAXIMUM_CREDENTIAL_BYTES {
            return Err("Windows 安全存储返回的同步凭据长度无效".to_owned());
        }
        let mut bytes =
            unsafe { std::slice::from_raw_parts(credential.CredentialBlob, length).to_vec() };
        let decoded = SyncCredentials::decode(&bytes);
        bytes.fill(0);
        decoded.map(Some)
    }

    fn delete(&self) -> Result<(), String> {
        use windows_sys::Win32::Foundation::{ERROR_NOT_FOUND, GetLastError};
        use windows_sys::Win32::Security::Credentials::{CRED_TYPE_GENERIC, CredDeleteW};

        let target = wide(&self.target);
        if unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) } == 0 {
            let error = unsafe { GetLastError() };
            if error != ERROR_NOT_FOUND {
                return Err(format!("无法删除 Windows 同步凭据（错误 {error}）"));
            }
        }
        Ok(())
    }
}

fn valid_identifier(value: &str) -> bool {
    (8..=128).contains(&value.len())
        && value.bytes().enumerate().all(|(index, value)| {
            value.is_ascii_alphanumeric()
                || (index > 0 && matches!(value, b'.' | b'_' | b':' | b'-'))
        })
}

fn valid_vault_id(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value.bytes().enumerate().all(|(index, value)| {
            value.is_ascii_alphanumeric() || (index > 0 && matches!(value, b'.' | b'_' | b'-'))
        })
}

fn valid_base64url_32(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || matches!(value, b'-' | b'_'))
}

fn valid_endpoint_text(value: &str, require_https: bool) -> bool {
    let expected = if require_https { "https://" } else { "http://" };
    value.starts_with(expected)
        && value.len() > expected.len()
        && !value.chars().any(char::is_control)
        && !value.contains([' ', '\\', '@', '#', '?'])
}

#[cfg(windows)]
fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

#[cfg(windows)]
fn last_error(action: &str) -> String {
    use windows_sys::Win32::Foundation::GetLastError;
    format!("{action}（错误 {}）", unsafe { GetLastError() })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(value: char) -> String {
        std::iter::repeat_n(value, 43).collect()
    }

    fn worker() -> SyncCredentials {
        SyncCredentials::Worker {
            endpoint: "https://sync.example.com".to_owned(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            device_token: key('a'),
            vault_key: key('b'),
        }
    }

    #[test]
    fn credentials_round_trip_without_exposing_secrets_in_settings() {
        let store = MemoryCredentialStore::default();
        let credentials = worker();
        store.save(&credentials).unwrap();
        assert_eq!(store.load().unwrap(), Some(credentials));
        store.delete().unwrap();
        assert_eq!(store.load().unwrap(), None);
    }

    #[test]
    fn credential_json_is_strict_and_modes_are_mutually_exclusive() {
        let value = worker().encode().unwrap();
        assert_eq!(
            SyncCredentials::decode(&value).unwrap().mode(),
            SyncMode::Worker
        );
        let mut object: serde_json::Value = serde_json::from_slice(&value).unwrap();
        object["appPassword"] = serde_json::Value::String("secret".to_owned());
        assert!(SyncCredentials::decode(&serde_json::to_vec(&object).unwrap()).is_err());
    }

    #[test]
    fn malformed_identifiers_keys_and_endpoints_are_rejected() {
        let invalid = SyncCredentials::Worker {
            endpoint: "http://sync.example.com".to_owned(),
            vault_id: "vault-windows".to_owned(),
            device_id: "bad/id".to_owned(),
            device_token: "short".to_owned(),
            vault_key: key('b'),
        };
        assert!(invalid.validate().is_err());

        let invalid_webdav = SyncCredentials::WebDav {
            username: "user name".to_owned(),
            app_password: "secret".to_owned(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            vault_key: key('b'),
        };
        assert!(invalid_webdav.validate().is_err());
    }

    #[test]
    fn empty_secrets_reuse_only_saved_credentials_from_the_same_mode() {
        let saved_worker = worker();
        let worker_draft = SyncCredentials::Worker {
            endpoint: "https://new-sync.example.com".to_owned(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            device_token: String::new(),
            vault_key: String::new(),
        };
        let resolved = worker_draft
            .reuse_empty_secrets(Some(&saved_worker))
            .unwrap();
        assert_eq!(resolved.device_token(), saved_worker.device_token());
        assert_eq!(resolved.vault_key(), saved_worker.vault_key());

        let webdav_draft = SyncCredentials::WebDav {
            username: "windows@example.com".to_owned(),
            app_password: String::new(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            vault_key: String::new(),
        };
        assert!(
            webdav_draft
                .reuse_empty_secrets(Some(&saved_worker))
                .is_err()
        );

        let changed_device = SyncCredentials::Worker {
            endpoint: "https://sync.example.com".to_owned(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-2".to_owned(),
            device_token: String::new(),
            vault_key: String::new(),
        };
        assert!(
            changed_device
                .reuse_empty_secrets(Some(&saved_worker))
                .is_err()
        );

        let changed_vault = SyncCredentials::Worker {
            endpoint: "https://sync.example.com".to_owned(),
            vault_id: "vault-new".to_owned(),
            device_id: "device-windows-1".to_owned(),
            device_token: String::new(),
            vault_key: String::new(),
        };
        assert!(
            changed_vault
                .reuse_empty_secrets(Some(&saved_worker))
                .is_err()
        );
    }

    #[test]
    fn entered_secrets_override_saved_values_and_webdav_blanks_reuse_them() {
        let saved_webdav = SyncCredentials::WebDav {
            username: "windows@example.com".to_owned(),
            app_password: "saved application password".to_owned(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            vault_key: key('b'),
        };
        let reused = SyncCredentials::WebDav {
            username: "windows@example.com".to_owned(),
            app_password: String::new(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            vault_key: String::new(),
        }
        .reuse_empty_secrets(Some(&saved_webdav))
        .unwrap();
        assert_eq!(
            reused.webdav_login(),
            Some(("windows@example.com", "saved application password"))
        );
        assert_eq!(reused.vault_key(), saved_webdav.vault_key());

        let changed_username = SyncCredentials::WebDav {
            username: "updated@example.com".to_owned(),
            app_password: String::new(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            vault_key: String::new(),
        };
        assert!(
            changed_username
                .reuse_empty_secrets(Some(&saved_webdav))
                .is_err()
        );

        let entered_token = key('x');
        let entered_key = key('y');
        let overridden = SyncCredentials::Worker {
            endpoint: "https://sync.example.com".to_owned(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            device_token: entered_token.clone(),
            vault_key: entered_key.clone(),
        }
        .reuse_empty_secrets(Some(&worker()))
        .unwrap();
        assert_eq!(overridden.device_token(), Some(entered_token.as_str()));
        assert_eq!(overridden.vault_key(), entered_key);
    }

    #[test]
    fn webdav_setup_link_matches_android_contract_and_debug_is_redacted() {
        let vault_key = key('z');
        let credentials = SyncCredentials::WebDav {
            username: "user+windows@example.com".to_owned(),
            app_password: "application password / private".to_owned(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            vault_key: vault_key.clone(),
        };
        let link = Url::parse(&credentials.webdav_setup_link().unwrap()).unwrap();
        assert_eq!(link.scheme(), "wootodo");
        assert_eq!(link.host_str(), Some("webdav"));
        let parameters = link
            .query_pairs()
            .into_owned()
            .collect::<std::collections::BTreeMap<_, _>>();
        assert_eq!(parameters.len(), 5);
        assert_eq!(parameters.get("v").map(String::as_str), Some("1"));
        assert_eq!(
            parameters.get("username").map(String::as_str),
            Some("user+windows@example.com")
        );
        assert_eq!(
            parameters.get("appPassword").map(String::as_str),
            Some("application password / private")
        );
        assert_eq!(
            parameters.get("vaultId").map(String::as_str),
            Some("vault-windows")
        );
        assert_eq!(
            parameters.get("vaultKey").map(String::as_str),
            Some(vault_key.as_str())
        );
        assert!(!parameters.contains_key("deviceId"));

        let debug = format!("{credentials:?}");
        for secret in [
            "user+windows@example.com",
            "application password / private",
            "vault-windows",
            "device-windows-1",
            vault_key.as_str(),
        ] {
            assert!(!debug.contains(secret));
        }
    }
}
