//! Windows 作为同一网络同步主机。
//!
//! 负责创建新的局域网同步空间（vault）、承载本地同步 HTTP 服务、生成
//! `wootodo://pair` 配对链接，并处理 Android 等设备的配对确认。同步凭据
//! 仍保存在 Windows Credential Manager，服务状态文件位于
//! `%LOCALAPPDATA%\Woo Todo\local-sync\<vaultId>.json`。
//!
//! 同一网络主机模式只允许在 Windows 尚未加入任何同步空间时开启：已加入
//! 自建服务、WebDAV 或另一个局域网空间时拒绝，避免把已有同步空间拆成
//! 多套数据或出现双主机分叉。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter};
use woo_todo_core::{PairingKeyPair, base64url_encode, random_bytes, seal_pairing_vault_key};

use crate::credentials::{SyncCredentials, SyncMode};
use crate::http::WinHttpTransport;
use crate::local_server::{LocalNetworkHttpServer, LocalServerStore, SharedLocalServerStore};
use crate::worker::{DevicePlatform, PairingClaimInfo, PairingStatus, WorkerClient};

const PAIRING_POLL_INTERVAL: Duration = Duration::from_secs(2);
const PAIRING_GRACE_MILLIS: i64 = 30_000;
const DEVICE_ID_BYTES: usize = 12;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalPairingPhase {
    Open,
    Claimed,
    Confirmed,
    Expired,
    Failed,
}

impl LocalPairingPhase {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Claimed => "claimed",
            Self::Confirmed => "confirmed",
            Self::Expired => "expired",
            Self::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalPairingView {
    pub link: String,
    pub expires_at: i64,
    pub status: &'static str,
    pub claimed_device: Option<PairingClaimView>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingClaimView {
    pub name: String,
    pub platform: String,
}

impl From<&PairingClaimInfo> for PairingClaimView {
    fn from(claim: &PairingClaimInfo) -> Self {
        let platform = match claim.platform {
            DevicePlatform::Macos => "macOS".to_owned(),
            DevicePlatform::Android => "Android".to_owned(),
            DevicePlatform::Windows => "Windows".to_owned(),
        };
        Self {
            name: claim.name.clone(),
            platform,
        }
    }
}

struct ActivePairing {
    key_pair: PairingKeyPair,
    pairing_id: String,
    pairing_secret: String,
    expires_at: i64,
    state: Arc<Mutex<LocalPairingState>>,
    stop_flag: Arc<AtomicBool>,
    poll_handle: Option<JoinHandle<()>>,
}

enum LocalPairingState {
    Open,
    Claimed(PairingClaimInfo),
    Confirmed,
    Expired,
    Failed(String),
}

impl LocalPairingState {
    fn phase(&self) -> LocalPairingPhase {
        match self {
            Self::Open => LocalPairingPhase::Open,
            Self::Claimed(_) => LocalPairingPhase::Claimed,
            Self::Confirmed => LocalPairingPhase::Confirmed,
            Self::Expired => LocalPairingPhase::Expired,
            Self::Failed(_) => LocalPairingPhase::Failed,
        }
    }
}

pub struct LocalSyncHost {
    server: LocalNetworkHttpServer,
    credentials: SyncCredentials,
    state_path: PathBuf,
    pairing: Mutex<Option<ActivePairing>>,
}

impl LocalSyncHost {
    /// 创建并启动局域网同步主机。
    ///
    /// `credentials` 必须是新生成的 `LocalNetwork` 身份（vault 为空或
    /// Windows 已属于另一个局域网空间时返回错误）；`state_path` 指向
    /// `local-sync/<vaultId>.json` 状态文件。
    pub fn start(credentials: SyncCredentials, state_path: PathBuf) -> Result<Self, String> {
        credentials.validate()?;
        if credentials.mode() != SyncMode::LocalNetwork {
            return Err("局域网同步主机需要同一网络同步身份".to_owned());
        }
        if let Some(parent) = state_path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("无法创建局域网同步状态目录：{error}"))?;
        }
        let store: SharedLocalServerStore = Arc::new(Mutex::new(
            LocalServerStore::new(&state_path, &credentials)
                .map_err(|error| format!("无法初始化局域网同步状态：{error}"))?,
        ));
        let mut server = LocalNetworkHttpServer::bind_default(store)
            .map_err(|error| format!("无法启动局域网同步服务：{error}"))?;
        server
            .start()
            .map_err(|error| format!("无法启动局域网同步服务：{error}"))?;
        Ok(Self {
            server,
            credentials,
            state_path,
            pairing: Mutex::new(None),
        })
    }

    pub fn endpoint(&self) -> &str {
        self.server.endpoint()
    }

    pub fn vault_id(&self) -> &str {
        self.credentials.vault_id()
    }

    /// 中止启动：停止服务并删除新建的状态文件（仅用于绑定失败回滚）。
    pub fn abort(mut self) {
        let _ = self.server.stop();
        if self.state_path.exists() {
            let _ = std::fs::remove_file(&self.state_path);
        }
    }

    pub fn stop(&mut self) {
        self.cancel_pairing();
        let _ = self.server.stop();
    }

    /// 当前配对会话的对外视图。
    pub fn pairing_view(&self) -> Option<LocalPairingView> {
        let pairing = self.pairing.lock().ok()?;
        let active = pairing.as_ref()?;
        let state = active.state.lock().ok()?;
        Some(LocalPairingView {
            link: pairing_link(
                self.server.endpoint(),
                &active.pairing_id,
                &active.pairing_secret,
                &active.key_pair.public_key_base64url(),
                self.credentials.vault_id(),
            ),
            expires_at: active.expires_at,
            status: state.phase().name(),
            claimed_device: match &*state {
                LocalPairingState::Claimed(claim) => Some(PairingClaimView::from(claim)),
                _ => None,
            },
        })
    }

    /// 生成新的配对链接并开始轮询设备认领。同一时刻只保留一个配对会话。
    pub fn create_pairing(&self, app: &AppHandle) -> Result<LocalPairingView, String> {
        self.cancel_pairing();
        let key_pair = PairingKeyPair::generate().map_err(|error| error.to_string())?;
        let client = WorkerClient::new(&self.credentials, WinHttpTransport)
            .map_err(|error| error.to_string())?;
        let created = client
            .create_pairing(&key_pair.public_key_base64url())
            .map_err(|error| format!("无法创建配对会话：{error}"))?;
        if created.initiator_public_key != key_pair.public_key_base64url() {
            return Err("配对会话响应与本地密钥不一致".to_owned());
        }
        let expires_at = created.expires_at;
        let state = Arc::new(Mutex::new(LocalPairingState::Open));
        let stop_flag = Arc::new(AtomicBool::new(false));
        let poll_handle = start_pairing_polling(
            app.clone(),
            self.credentials.clone(),
            created.pairing_id.clone(),
            expires_at,
            Arc::clone(&state),
            Arc::clone(&stop_flag),
        );
        let active = ActivePairing {
            key_pair,
            pairing_id: created.pairing_id,
            pairing_secret: created.pairing_secret,
            expires_at,
            state,
            stop_flag,
            poll_handle: Some(poll_handle),
        };
        *self
            .pairing
            .lock()
            .map_err(|_| "配对会话状态不可用".to_owned())? = Some(active);
        self.pairing_view()
            .ok_or_else(|| "配对会话状态不可用".to_owned())
    }

    /// 确认或忽略当前配对请求。`accept = true` 时用会话密钥封装同步密钥
    /// 并提交确认，Android 随后才能取得 vault key。
    pub fn respond_pairing(
        &self,
        app: &AppHandle,
        accept: bool,
    ) -> Result<LocalPairingView, String> {
        let pairing = self
            .pairing
            .lock()
            .map_err(|_| "配对会话状态不可用".to_owned())?;
        let Some(active) = pairing.as_ref() else {
            return Err("当前没有等待处理的配对请求".to_owned());
        };
        let claim = {
            let state = active
                .state
                .lock()
                .map_err(|_| "配对会话状态不可用".to_owned())?;
            match &*state {
                LocalPairingState::Claimed(claim) => claim.clone(),
                LocalPairingState::Confirmed => return Err("该设备已经加入同步空间".to_owned()),
                LocalPairingState::Expired => {
                    return Err("配对请求已过期，请重新生成链接".to_owned())
                }
                LocalPairingState::Failed(message) => {
                    return Err(format!("配对会话已失效：{message}"))
                }
                LocalPairingState::Open => return Err("还没有设备请求加入".to_owned()),
            }
        };
        if !accept {
            active.stop_flag.store(true, Ordering::Release);
            *active
                .state
                .lock()
                .map_err(|_| "配对会话状态不可用".to_owned())? = LocalPairingState::Expired;
            drop(pairing);
            let _ = app.emit("local-pairing://settled", ());
            return self
                .pairing_view()
                .ok_or_else(|| "配对会话状态不可用".to_owned());
        }
        let secret = zeroize::Zeroizing::new(
            String::from_utf8(
                woo_todo_core::base64url_decode(&active.pairing_secret)
                    .map_err(|error| error.to_string())?,
            )
            .map_err(|_| "配对 secret 无法解码".to_owned())?,
        );
        let session_key = active
            .key_pair
            .session_key_base64url(&claim.public_key, &active.pairing_id, secret.as_str())
            .map_err(|error| error.to_string())?;
        let vault_key = zeroize::Zeroizing::new(
            woo_todo_core::base64url_decode(self.credentials.vault_key())
                .map_err(|error| error.to_string())?,
        );
        let envelope = seal_pairing_vault_key(
            vault_key.as_slice(),
            &session_key,
            &active.pairing_id,
            &claim.device_id,
            None,
        )
        .map_err(|error| error.to_string())?;
        let client = WorkerClient::new(&self.credentials, WinHttpTransport)
            .map_err(|error| error.to_string())?;
        client
            .confirm_pairing(&active.pairing_id, &claim.device_id, envelope)
            .map_err(|error| format!("确认配对失败：{error}"))?;
        active.stop_flag.store(true, Ordering::Release);
        *active
            .state
            .lock()
            .map_err(|_| "配对会话状态不可用".to_owned())? = LocalPairingState::Confirmed;
        drop(pairing);
        let _ = app.emit("local-pairing://settled", ());
        self.pairing_view()
            .ok_or_else(|| "配对会话状态不可用".to_owned())
    }

    fn cancel_pairing(&self) {
        let Some(mut active) = self
            .pairing
            .lock()
            .ok()
            .and_then(|mut value| value.take())
        else {
            return;
        };
        active.stop_flag.store(true, Ordering::Release);
        if let Some(handle) = active.poll_handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for LocalSyncHost {
    fn drop(&mut self) {
        self.stop();
    }
}

fn start_pairing_polling(
    app: AppHandle,
    credentials: SyncCredentials,
    pairing_id: String,
    expires_at: i64,
    state: Arc<Mutex<LocalPairingState>>,
    stop_flag: Arc<AtomicBool>,
) -> JoinHandle<()> {
    thread::Builder::new()
        .name("woo-todo-local-pairing".to_owned())
        .spawn(move || {
            let client = match WorkerClient::new(&credentials, WinHttpTransport) {
                Ok(client) => client,
                Err(_) => {
                    if let Ok(mut value) = state.lock() {
                        *value = LocalPairingState::Failed("无法访问本地同步服务".to_owned());
                    }
                    let _ = app.emit("local-pairing://settled", ());
                    return;
                }
            };
            while !stop_flag.load(Ordering::Acquire) {
                match client.pairing_status(&pairing_id) {
                    Ok(status) => match status.status {
                        PairingStatus::Open => {}
                        PairingStatus::Claimed => {
                            if let Some(claim) = status.claim
                                && let Ok(mut value) = state.lock()
                            {
                                *value = LocalPairingState::Claimed(claim);
                                let _ = app.emit("local-pairing://request", ());
                            }
                        }
                        PairingStatus::Confirmed => {
                            if let Ok(mut value) = state.lock() {
                                *value = LocalPairingState::Confirmed;
                            }
                            stop_flag.store(true, Ordering::Release);
                            let _ = app.emit("local-pairing://settled", ());
                        }
                        PairingStatus::Expired | PairingStatus::Canceled => {
                            if let Ok(mut value) = state.lock() {
                                *value = LocalPairingState::Expired;
                            }
                            stop_flag.store(true, Ordering::Release);
                            let _ = app.emit("local-pairing://settled", ());
                        }
                    },
                    Err(error) => {
                        if let Ok(mut value) = state.lock() {
                            *value = LocalPairingState::Failed(error);
                        }
                        stop_flag.store(true, Ordering::Release);
                        let _ = app.emit("local-pairing://settled", ());
                    }
                }
                if stop_flag.load(Ordering::Acquire) {
                    break;
                }
                let now = chrono::Utc::now().timestamp_millis();
                if now >= expires_at.saturating_add(PAIRING_GRACE_MILLIS) {
                    if let Ok(mut value) = state.lock() {
                        *value = LocalPairingState::Expired;
                    }
                    stop_flag.store(true, Ordering::Release);
                    let _ = app.emit("local-pairing://settled", ());
                    break;
                }
                thread::sleep(PAIRING_POLL_INTERVAL);
            }
        })
        .expect("无法启动配对轮询线程")
}

fn pairing_link(
    endpoint: &str,
    pairing_id: &str,
    pairing_secret: &str,
    initiator_public_key: &str,
    vault_id: &str,
) -> String {
    let encoded = |value: &str| {
        url::form_urlencoded::byte_serialize(value.as_bytes()).collect::<String>()
    };
    format!(
        "wootodo://pair?endpoint={}&pairingId={}&pairingSecret={}&initiatorPublicKey={}&vaultId={}",
        encoded(endpoint),
        encoded(pairing_id),
        encoded(pairing_secret),
        encoded(initiator_public_key),
        encoded(vault_id),
    )
}

/// 为新建的局域网同步空间生成 `LocalNetwork` 身份（vault id 格式与
/// macOS 保持一致：`vault-` + 9 字节 Base64URL）。
pub fn generate_local_network_credentials(
    endpoint: String,
) -> Result<SyncCredentials, String> {
    let random_vault = base64url_encode(&random_bytes::<9>().map_err(|error| error.to_string())?);
    let device_id = format!(
        "device-{}",
        base64url_encode(&random_bytes::<DEVICE_ID_BYTES>().map_err(|error| error.to_string())?)
    );
    let device_token = base64url_encode(&random_bytes::<32>().map_err(|error| error.to_string())?);
    let vault_key = base64url_encode(&random_bytes::<32>().map_err(|error| error.to_string())?);
    let credentials = SyncCredentials::LocalNetwork {
        endpoint,
        vault_id: format!("vault-{random_vault}"),
        device_id,
        device_token,
        vault_key,
    };
    credentials.validate()?;
    Ok(credentials)
}

/// 局域网同步状态文件路径：`<数据目录>/local-sync/<vaultId>.json`。
pub fn local_state_path(data_directory: &Path, vault_id: &str) -> PathBuf {
    data_directory
        .join("local-sync")
        .join(format!("{vault_id}.json"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::worker::PairingLink;

    #[test]
    fn generated_credentials_match_local_network_identity_rules() {
        let credentials = generate_local_network_credentials("http://192.168.1.5:48473".to_owned())
            .expect("凭据应能生成");
        credentials.validate().expect("凭据应通过校验");
        assert_eq!(credentials.mode(), SyncMode::LocalNetwork);
        let vault_id = credentials.vault_id();
        assert!(vault_id.starts_with("vault-"));
        assert!(vault_id.len() <= 64);
        let device_id = credentials.device_id();
        assert!(device_id.starts_with("device-"));
        assert!(device_id.len() >= 8);
        // 每次生成必须产生不同的身份
        let second = generate_local_network_credentials("http://192.168.1.5:48473".to_owned())
            .expect("凭据应能生成");
        assert_ne!(credentials.vault_id(), second.vault_id());
        assert_ne!(credentials.device_id(), second.device_id());
        assert_ne!(credentials.device_token(), second.device_token());
        assert_ne!(credentials.vault_key(), second.vault_key());
    }

    #[test]
    fn generated_pairing_link_round_trips_through_parser() {
        let secret = base64url_encode(&[7; 32]);
        let public_key = base64url_encode(&[9; 32]);
        let link = pairing_link(
            "http://192.168.1.5:48473",
            "pair-abc123",
            &secret,
            &public_key,
            "vault-XXXXYYYYZZZZ",
        );
        let parsed = PairingLink::parse(&link).expect("Windows 生成的链接应能被 Windows 加入方解析");
        assert_eq!(parsed.endpoint, "http://192.168.1.5:48473");
        assert_eq!(parsed.pairing_id, "pair-abc123");
        assert_eq!(parsed.vault_id.as_deref(), Some("vault-XXXXYYYYZZZZ"));
        assert_eq!(parsed.initiator_public_key, public_key);
    }
}
