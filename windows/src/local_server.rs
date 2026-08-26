use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt::Write as _;
#[cfg(unix)]
use std::fs::File;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use woo_todo_core::{
    EncryptedEnvelope, MAXIMUM_CIPHERTEXT_BYTES, SyncData, SyncPulledOperation, SyncPushOperation,
    SyncPushSummary, SyncRequest, base64url_decode, base64url_encode, random_bytes,
};

use crate::credentials::{SyncCredentials, SyncMode};
use crate::worker::{DeviceInfo, DevicePlatform};

pub const DEFAULT_LOCAL_SYNC_PORT: u16 = 48_473;
pub const PAIRING_LIFETIME_MILLIS: i64 = 10 * 60 * 1_000;
pub const MAXIMUM_HEADER_BYTES: usize = 32 * 1_024;
pub const MAXIMUM_BODY_BYTES: usize = 3 * 1_024 * 1_024;

const STATE_VERSION: u32 = 1;
const MAXIMUM_REQUEST_BYTES: usize = MAXIMUM_HEADER_BYTES + 4 + MAXIMUM_BODY_BYTES;
const MAXIMUM_DEVICE_NAME_CHARACTERS: usize = 80;
const MAXIMUM_DEVICES: usize = 64;
const MAXIMUM_ACTIVE_PAIRINGS: usize = 32;
const MAXIMUM_PUSH_OPERATIONS: usize = 50;
const MAXIMUM_PULL_OPERATIONS: usize = 100;
const MAXIMUM_STATE_BYTES: u64 = 128 * 1_024 * 1_024;
const MAXIMUM_CONFIRMED_OPERATIONS: usize = 16_384;
const MAXIMUM_WIRE_TIMESTAMP: i64 = 9_007_199_254_740_991;
const MAXIMUM_PATH_BYTES: usize = 2_048;
const MAXIMUM_HEADERS: usize = 100;
const MAXIMUM_CLIENTS: usize = 16;
const CONNECTION_LIFETIME: Duration = Duration::from_secs(8);
const SOCKET_POLL_INTERVAL: Duration = Duration::from_millis(200);
const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(20);

type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;
pub type SharedLocalServerStore = Arc<Mutex<LocalServerStore>>;

#[derive(Debug)]
pub enum LocalServerError {
    InvalidBootstrapIdentity,
    IdentityMismatch,
    CorruptedState,
    Persistence(String),
    CannotResolveEndpoint,
    ListenerFailed(String),
}

impl std::fmt::Display for LocalServerError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidBootstrapIdentity => formatter.write_str("局域网同步身份无效"),
            Self::IdentityMismatch => formatter.write_str("局域网主机数据与当前同步身份不一致"),
            Self::CorruptedState => formatter.write_str("局域网同步主机数据已损坏"),
            Self::Persistence(message) => write!(formatter, "无法保存局域网同步状态：{message}"),
            Self::CannotResolveEndpoint => {
                formatter.write_str("无法获取其他设备可访问的 Windows 局域网地址")
            }
            Self::ListenerFailed(message) => {
                write!(formatter, "局域网同步服务启动失败：{message}")
            }
        }
    }
}

impl std::error::Error for LocalServerError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalHttpRequest {
    pub method: String,
    pub path: String,
    pub headers: BTreeMap<String, String>,
    pub body: Vec<u8>,
}

impl LocalHttpRequest {
    #[cfg(test)]
    pub fn new(method: impl Into<String>, path: impl Into<String>, body: Vec<u8>) -> Self {
        Self {
            method: method.into().to_ascii_uppercase(),
            path: path.into(),
            headers: BTreeMap::new(),
            body,
        }
    }

    #[cfg(test)]
    pub fn with_header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers
            .insert(name.into().to_ascii_lowercase(), value.into());
        self
    }

    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(String::as_str)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalHttpResponse {
    pub status: u16,
    pub headers: BTreeMap<String, String>,
    pub body: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PairingStatus {
    Open,
    Claimed,
    Confirmed,
    Expired,
    Canceled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreatePairingRequest {
    pub public_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreatePairingData {
    pub pairing_id: String,
    pub pairing_secret: String,
    pub initiator_public_key: String,
    pub expires_at: i64,
    pub server_time: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingDeviceRegistration {
    pub name: String,
    pub platform: DevicePlatform,
    pub public_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingClaimRequest {
    pub pairing_secret: String,
    pub device_token: String,
    pub device: PairingDeviceRegistration,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingClaimData {
    pub pairing_id: String,
    pub status: PairingStatus,
    pub device_id: String,
    pub expires_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingClaimInfo {
    pub device_id: String,
    pub name: String,
    pub platform: DevicePlatform,
    pub public_key: String,
    pub claimed_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingStatusData {
    pub pairing_id: String,
    pub status: PairingStatus,
    pub expires_at: i64,
    pub claim: Option<PairingClaimInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingConfirmRequest {
    pub vault_key_envelope: EncryptedEnvelope,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingConfirmData {
    pub pairing_id: String,
    pub status: PairingStatus,
    pub device_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingResultRequest {
    pub pairing_secret: String,
    pub device_token: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingResultData {
    pub pairing_id: String,
    pub status: PairingStatus,
    pub vault_id: Option<String>,
    pub device_id: Option<String>,
    pub initiator_public_key: Option<String>,
    pub vault_key_envelope: Option<EncryptedEnvelope>,
    pub expires_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedState {
    version: u32,
    vault_id: String,
    next_server_sequence: i64,
    devices: Vec<StoredDevice>,
    operations: Vec<SyncPulledOperation>,
    /// 已被所有设备确认（ack）并从 operations 裁剪的操作 id，用于重复
    /// push 去重；`#[serde(default)]` 兼容旧格式状态文件，不提升版本号。
    #[serde(default)]
    confirmed_op_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredDevice {
    id: String,
    name: String,
    platform: DevicePlatform,
    public_key: Option<String>,
    token_hash: String,
    created_at: i64,
    last_seen_at: Option<i64>,
    revoked_at: Option<i64>,
    /// 该设备已确认应用到的服务端序号（ack 驱动的清理水位）。
    /// `#[serde(default)]` 兼容旧格式状态文件。
    #[serde(default)]
    ack_cursor: i64,
}

impl StoredDevice {
    fn info(&self, current_device_id: &str) -> DeviceInfo {
        DeviceInfo {
            id: self.id.clone(),
            name: self.name.clone(),
            platform: self.platform,
            public_key: self.public_key.clone(),
            created_at: self.created_at,
            last_seen_at: self.last_seen_at,
            revoked_at: self.revoked_at,
            is_current: self.id == current_device_id,
        }
    }
}

#[derive(Debug, Clone)]
struct PairingSession {
    secret_hash: String,
    initiator_device_id: String,
    initiator_public_key: String,
    expires_at: i64,
    claimed_device: Option<ClaimedDevice>,
    confirmed_envelope: Option<EncryptedEnvelope>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ClaimedDevice {
    id: String,
    name: String,
    platform: DevicePlatform,
    public_key: String,
    token_hash: String,
    claimed_at: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SuccessEnvelope<T> {
    ok: bool,
    data: T,
    request_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FailureEnvelope {
    ok: bool,
    error: FailurePayload,
    request_id: String,
}

#[derive(Serialize)]
struct FailurePayload {
    code: String,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    details: Option<Value>,
}

#[derive(Debug)]
struct ServiceFailure {
    status: u16,
    code: &'static str,
    message: String,
    details: Option<Value>,
}

impl ServiceFailure {
    fn new(status: u16, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
            details: None,
        }
    }

    fn with_details(mut self, details: Value) -> Self {
        self.details = Some(details);
        self
    }

    fn validation(field: &str, message: impl Into<String>) -> Self {
        Self::new(400, "VALIDATION_ERROR", message).with_details(json!({ "field": field }))
    }

    fn internal() -> Self {
        Self::new(500, "INTERNAL_ERROR", "局域网同步服务发生未预期错误")
    }
}

#[derive(Serialize)]
struct HealthData {
    version: u32,
    service: &'static str,
}

#[derive(Serialize)]
struct DeviceListData {
    devices: Vec<DeviceInfo>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RevokeDeviceData {
    device_id: String,
    revoked_at: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EmptyObject {}

pub struct LocalServerStore {
    state_path: PathBuf,
    clock: Clock,
    state: PersistedState,
    pairings: HashMap<String, PairingSession>,
}

impl LocalServerStore {
    pub fn new(
        state_path: impl Into<PathBuf>,
        bootstrap_credentials: &SyncCredentials,
    ) -> Result<Self, LocalServerError> {
        let host_name = std::env::var("COMPUTERNAME")
            .ok()
            .and_then(|value| normalize_device_name(&value))
            .unwrap_or_else(|| "Windows".to_owned());
        Self::new_with_clock(
            state_path,
            bootstrap_credentials,
            host_name,
            system_time_millis,
        )
    }

    pub fn new_with_clock<F>(
        state_path: impl Into<PathBuf>,
        bootstrap_credentials: &SyncCredentials,
        host_name: impl Into<String>,
        clock: F,
    ) -> Result<Self, LocalServerError>
    where
        F: Fn() -> i64 + Send + Sync + 'static,
    {
        bootstrap_credentials
            .validate()
            .map_err(|_| LocalServerError::InvalidBootstrapIdentity)?;
        if bootstrap_credentials.mode() != SyncMode::LocalNetwork {
            return Err(LocalServerError::InvalidBootstrapIdentity);
        }
        let host_name = normalize_device_name(&host_name.into())
            .ok_or(LocalServerError::InvalidBootstrapIdentity)?;
        let clock: Clock = Arc::new(clock);
        let timestamp = clock();
        if !valid_timestamp(timestamp) {
            return Err(LocalServerError::InvalidBootstrapIdentity);
        }
        let state_path = state_path.into();
        let token = bootstrap_credentials
            .device_token()
            .ok_or(LocalServerError::InvalidBootstrapIdentity)?;
        let token_hash = credential_hash(token);

        let state = if state_path.exists() {
            let metadata =
                fs::metadata(&state_path).map_err(|_| LocalServerError::CorruptedState)?;
            if !metadata.is_file() || metadata.len() > MAXIMUM_STATE_BYTES {
                return Err(LocalServerError::CorruptedState);
            }
            let source = fs::read(&state_path).map_err(|_| LocalServerError::CorruptedState)?;
            let loaded: PersistedState =
                serde_json::from_slice(&source).map_err(|_| LocalServerError::CorruptedState)?;
            validate_persisted_state(&loaded)?;
            let identity_matches = loaded.vault_id == bootstrap_credentials.vault_id()
                && loaded.devices.iter().any(|device| {
                    device.id == bootstrap_credentials.device_id()
                        && constant_time_equal(&device.token_hash, &token_hash)
                        && device.revoked_at.is_none()
                });
            if !identity_matches {
                return Err(LocalServerError::IdentityMismatch);
            }
            loaded
        } else {
            let initial = PersistedState {
                version: STATE_VERSION,
                vault_id: bootstrap_credentials.vault_id().to_owned(),
                next_server_sequence: 1,
                devices: vec![StoredDevice {
                    id: bootstrap_credentials.device_id().to_owned(),
                    name: host_name,
                    platform: DevicePlatform::Windows,
                    public_key: None,
                    token_hash,
                    created_at: timestamp,
                    last_seen_at: Some(timestamp),
                    revoked_at: None,
                    ack_cursor: 0,
                }],
                operations: Vec::new(),
                confirmed_op_ids: Vec::new(),
            };
            persist_atomically(&state_path, &initial)?;
            initial
        };

        Ok(Self {
            state_path,
            clock,
            state,
            pairings: HashMap::new(),
        })
    }

    #[allow(dead_code)] // 供同步运行时统计本机最高水位时使用
    pub fn highest_lamport(&self) -> i64 {
        self.state
            .operations
            .iter()
            .map(|operation| operation.lamport)
            .max()
            .unwrap_or(0)
    }

    pub fn handle(&mut self, request: LocalHttpRequest) -> LocalHttpResponse {
        let request_id = request_identifier();
        if request.body.len() > MAXIMUM_BODY_BYTES {
            return failure_response(
                ServiceFailure::new(413, "PAYLOAD_TOO_LARGE", "请求体超过局域网同步上限"),
                request_id,
            );
        }
        match self.route(&request, &request_id) {
            Ok(response) => response,
            Err(failure) => failure_response(failure, request_id),
        }
    }

    fn route(
        &mut self,
        request: &LocalHttpRequest,
        request_id: &str,
    ) -> Result<LocalHttpResponse, ServiceFailure> {
        let components = route_components(&request.path)?;
        match components.as_slice() {
            ["health"] => {
                require_method(request, "GET")?;
                require_empty_body(request)?;
                success_response(
                    200,
                    HealthData {
                        version: 1,
                        service: "woo-todo-local-sync",
                    },
                    request_id,
                )
            }
            ["v1", "pairings"] => {
                require_method(request, "POST")?;
                require_json_body(request)?;
                let initiator = self.authenticate(request)?;
                self.create_pairing(request, &initiator, request_id)
            }
            ["v1", "sync"] => {
                require_method(request, "POST")?;
                require_json_body(request)?;
                let device = self.authenticate(request)?;
                self.synchronize(request, &device, request_id)
            }
            ["v1", "devices"] => {
                require_method(request, "GET")?;
                require_empty_body(request)?;
                let device = self.authenticate(request)?;
                self.list_devices(&device, request_id)
            }
            ["v1", "pairings", pairing_id] => {
                require_method(request, "GET")?;
                require_empty_body(request)?;
                let initiator = self.authenticate(request)?;
                self.pairing_status(pairing_id, &initiator, request_id)
            }
            ["v1", "pairings", pairing_id, "claim"] => {
                require_method(request, "POST")?;
                require_json_body(request)?;
                self.claim_pairing(request, pairing_id, request_id)
            }
            ["v1", "pairings", pairing_id, "confirm"] => {
                require_method(request, "POST")?;
                require_json_body(request)?;
                let initiator = self.authenticate(request)?;
                self.confirm_pairing(request, pairing_id, &initiator, request_id)
            }
            ["v1", "pairings", pairing_id, "result"] => {
                require_method(request, "POST")?;
                require_json_body(request)?;
                self.pairing_result(request, pairing_id, request_id)
            }
            ["v1", "devices", device_id, "revoke"] => {
                require_method(request, "POST")?;
                require_optional_empty_json(request)?;
                let current_device = self.authenticate(request)?;
                self.revoke_device(device_id, &current_device, request_id)
            }
            _ => Err(ServiceFailure::new(404, "NOT_FOUND", "请求的资源不存在")),
        }
    }

    fn create_pairing(
        &mut self,
        request: &LocalHttpRequest,
        initiator: &StoredDevice,
        request_id: &str,
    ) -> Result<LocalHttpResponse, ServiceFailure> {
        let input: CreatePairingRequest = decode_json(&request.body)?;
        if !valid_32_byte_base64url(&input.public_key) {
            return Err(ServiceFailure::validation(
                "publicKey",
                "临时公钥必须是 32 字节 Base64URL",
            ));
        }
        let timestamp = self.now()?;
        self.expire_pairings(timestamp);
        if self.pairings.len() >= MAXIMUM_ACTIVE_PAIRINGS {
            return Err(ServiceFailure::new(
                429,
                "PAIRING_LIMIT_REACHED",
                "同时进行的配对会话过多",
            ));
        }
        let pairing_id = self.unique_identifier("pair")?;
        let secret =
            base64url_encode(&random_bytes::<32>().map_err(|_| ServiceFailure::internal())?);
        let expires_at = timestamp
            .checked_add(PAIRING_LIFETIME_MILLIS)
            .filter(|value| valid_timestamp(*value))
            .ok_or_else(ServiceFailure::internal)?;
        self.pairings.insert(
            pairing_id.clone(),
            PairingSession {
                secret_hash: credential_hash(&secret),
                initiator_device_id: initiator.id.clone(),
                initiator_public_key: input.public_key.clone(),
                expires_at,
                claimed_device: None,
                confirmed_envelope: None,
            },
        );
        success_response(
            201,
            CreatePairingData {
                pairing_id,
                pairing_secret: secret,
                initiator_public_key: input.public_key,
                expires_at,
                server_time: timestamp,
            },
            request_id,
        )
    }

    fn pairing_status(
        &mut self,
        pairing_id: &str,
        initiator: &StoredDevice,
        request_id: &str,
    ) -> Result<LocalHttpResponse, ServiceFailure> {
        let session = self.active_pairing(pairing_id)?;
        if session.initiator_device_id != initiator.id {
            return Err(pairing_not_found());
        }
        let status = if session.confirmed_envelope.is_some() {
            PairingStatus::Confirmed
        } else if session.claimed_device.is_some() {
            PairingStatus::Claimed
        } else {
            PairingStatus::Open
        };
        let claim = session
            .claimed_device
            .as_ref()
            .map(|claimed| PairingClaimInfo {
                device_id: claimed.id.clone(),
                name: claimed.name.clone(),
                platform: claimed.platform,
                public_key: claimed.public_key.clone(),
                claimed_at: claimed.claimed_at,
            });
        success_response(
            200,
            PairingStatusData {
                pairing_id: pairing_id.to_owned(),
                status,
                expires_at: session.expires_at,
                claim,
            },
            request_id,
        )
    }

    fn claim_pairing(
        &mut self,
        request: &LocalHttpRequest,
        pairing_id: &str,
        request_id: &str,
    ) -> Result<LocalHttpResponse, ServiceFailure> {
        let input: PairingClaimRequest = decode_json(&request.body)?;
        let mut session = self.active_pairing(pairing_id)?;
        if !constant_time_matches(&input.pairing_secret, &session.secret_hash) {
            return Err(pairing_not_found());
        }
        if !valid_32_byte_base64url(&input.device_token) {
            return Err(ServiceFailure::validation(
                "deviceToken",
                "设备令牌必须是 32 字节 Base64URL",
            ));
        }
        if !valid_32_byte_base64url(&input.device.public_key) {
            return Err(ServiceFailure::validation(
                "device.publicKey",
                "临时公钥必须是 32 字节 Base64URL",
            ));
        }
        let name = normalize_device_name(&input.device.name)
            .ok_or_else(|| ServiceFailure::validation("device.name", "设备名称长度或字符无效"))?;
        let token_hash = credential_hash(&input.device_token);

        if let Some(claimed) = &session.claimed_device {
            if constant_time_equal(&claimed.token_hash, &token_hash)
                && claimed.public_key == input.device.public_key
                && claimed.name == name
                && claimed.platform == input.device.platform
            {
                return success_response(
                    202,
                    PairingClaimData {
                        pairing_id: pairing_id.to_owned(),
                        status: PairingStatus::Claimed,
                        device_id: claimed.id.clone(),
                        expires_at: session.expires_at,
                    },
                    request_id,
                );
            }
            return Err(ServiceFailure::new(
                409,
                "PAIRING_ALREADY_CLAIMED",
                "配对会话已被其他设备认领",
            ));
        }

        let reserved_devices = self
            .pairings
            .values()
            .filter(|pairing| pairing.claimed_device.is_some())
            .count();
        if self.state.devices.len() + reserved_devices >= MAXIMUM_DEVICES {
            return Err(ServiceFailure::new(
                409,
                "DEVICE_LIMIT_REACHED",
                "同步空间的设备数量已达上限",
            ));
        }
        let token_in_use = self
            .state
            .devices
            .iter()
            .any(|device| constant_time_equal(&device.token_hash, &token_hash))
            || self.pairings.values().any(|pairing| {
                pairing
                    .claimed_device
                    .as_ref()
                    .is_some_and(|device| constant_time_equal(&device.token_hash, &token_hash))
            });
        if token_in_use {
            return Err(ServiceFailure::new(
                409,
                "DEVICE_TOKEN_IN_USE",
                "新设备令牌已被使用，请重新生成",
            ));
        }

        let claimed = ClaimedDevice {
            id: self.unique_identifier("device")?,
            name,
            platform: input.device.platform,
            public_key: input.device.public_key,
            token_hash,
            claimed_at: self.now()?,
        };
        let response_device_id = claimed.id.clone();
        session.claimed_device = Some(claimed);
        self.pairings.insert(pairing_id.to_owned(), session.clone());
        success_response(
            202,
            PairingClaimData {
                pairing_id: pairing_id.to_owned(),
                status: PairingStatus::Claimed,
                device_id: response_device_id,
                expires_at: session.expires_at,
            },
            request_id,
        )
    }

    fn confirm_pairing(
        &mut self,
        request: &LocalHttpRequest,
        pairing_id: &str,
        initiator: &StoredDevice,
        request_id: &str,
    ) -> Result<LocalHttpResponse, ServiceFailure> {
        let input: PairingConfirmRequest = decode_json(&request.body)?;
        if !valid_envelope(&input.vault_key_envelope) {
            return Err(ServiceFailure::validation(
                "vaultKeyEnvelope",
                "同步密钥密文格式无效",
            ));
        }
        let mut session = self.active_pairing(pairing_id)?;
        if session.initiator_device_id != initiator.id {
            return Err(pairing_not_found());
        }
        let claimed = session.claimed_device.clone().ok_or_else(|| {
            ServiceFailure::new(409, "PAIRING_NOT_CLAIMED", "尚无设备认领此配对会话")
        })?;

        if let Some(existing) = &session.confirmed_envelope {
            if existing != &input.vault_key_envelope {
                return Err(ServiceFailure::new(
                    409,
                    "PAIRING_ALREADY_CONFIRMED",
                    "配对会话已使用其他密文确认",
                ));
            }
        } else {
            if let Some(existing) = self
                .state
                .devices
                .iter()
                .find(|device| device.id == claimed.id)
            {
                if !constant_time_equal(&existing.token_hash, &claimed.token_hash)
                    || existing.revoked_at.is_some()
                {
                    return Err(ServiceFailure::new(
                        409,
                        "PAIRING_CONFIRM_FAILED",
                        "配对设备身份发生冲突",
                    ));
                }
            } else {
                let mut updated = self.state.clone();
                updated.devices.push(StoredDevice {
                    id: claimed.id.clone(),
                    name: claimed.name.clone(),
                    platform: claimed.platform,
                    public_key: Some(claimed.public_key.clone()),
                    token_hash: claimed.token_hash.clone(),
                    created_at: claimed.claimed_at,
                    last_seen_at: None,
                    revoked_at: None,
                    ack_cursor: 0,
                });
                self.persist(&updated)?;
                self.state = updated;
            }
            session.confirmed_envelope = Some(input.vault_key_envelope);
            self.pairings.insert(pairing_id.to_owned(), session.clone());
        }

        success_response(
            200,
            PairingConfirmData {
                pairing_id: pairing_id.to_owned(),
                status: PairingStatus::Confirmed,
                device_id: claimed.id,
            },
            request_id,
        )
    }

    fn pairing_result(
        &mut self,
        request: &LocalHttpRequest,
        pairing_id: &str,
        request_id: &str,
    ) -> Result<LocalHttpResponse, ServiceFailure> {
        let input: PairingResultRequest = decode_json(&request.body)?;
        let session = self.active_pairing(pairing_id)?;
        let claimed = session
            .claimed_device
            .as_ref()
            .filter(|claimed| {
                constant_time_matches(&input.pairing_secret, &session.secret_hash)
                    && constant_time_matches(&input.device_token, &claimed.token_hash)
            })
            .ok_or_else(pairing_not_found)?;

        if let Some(envelope) = &session.confirmed_envelope {
            let active_device = self.state.devices.iter().any(|device| {
                device.id == claimed.id
                    && device.revoked_at.is_none()
                    && constant_time_equal(&device.token_hash, &claimed.token_hash)
            });
            if !active_device {
                return Err(pairing_not_found());
            }
            success_response(
                200,
                PairingResultData {
                    pairing_id: pairing_id.to_owned(),
                    status: PairingStatus::Confirmed,
                    vault_id: Some(self.state.vault_id.clone()),
                    device_id: Some(claimed.id.clone()),
                    initiator_public_key: Some(session.initiator_public_key.clone()),
                    vault_key_envelope: Some(envelope.clone()),
                    expires_at: session.expires_at,
                },
                request_id,
            )
        } else {
            success_response(
                202,
                PairingResultData {
                    pairing_id: pairing_id.to_owned(),
                    status: PairingStatus::Claimed,
                    vault_id: None,
                    device_id: None,
                    initiator_public_key: None,
                    vault_key_envelope: None,
                    expires_at: session.expires_at,
                },
                request_id,
            )
        }
    }

    fn synchronize(
        &mut self,
        request: &LocalHttpRequest,
        device: &StoredDevice,
        request_id: &str,
    ) -> Result<LocalHttpResponse, ServiceFailure> {
        let input: SyncRequest = decode_json(&request.body)?;
        input
            .validate()
            .map_err(|_| ServiceFailure::validation("sync", "同步操作字段或批次大小无效"))?;
        if input.ack.is_some_and(|ack| ack > input.cursor) {
            return Err(ServiceFailure::validation("ack", "ack 不得大于 cursor"));
        }
        let pull_limit = input.pull_limit.unwrap_or(MAXIMUM_PULL_OPERATIONS);
        if input.push.len() > MAXIMUM_PUSH_OPERATIONS
            || !(1..=MAXIMUM_PULL_OPERATIONS).contains(&pull_limit)
        {
            return Err(ServiceFailure::validation(
                "sync",
                "同步游标、分页或批次大小无效",
            ));
        }
        // 最新序号来自 next_server_sequence：即使 operations 已被确认裁剪，
        // 客户端的历史游标仍然有效；只有服务端状态真正重置（序号从头开始）
        // 时才返回 CURSOR_AHEAD。
        let maximum_cursor = self.state.next_server_sequence.saturating_sub(1);
        if input.cursor > maximum_cursor {
            return Err(
                ServiceFailure::new(409, "CURSOR_AHEAD", "客户端游标超过服务端最新序号")
                    .with_details(json!({
                        "cursor": input.cursor,
                        "maxCursor": maximum_cursor,
                    })),
            );
        }
        self.validate_push(&input.push)?;

        let timestamp = self.now()?;
        let mut updated = self.state.clone();
        let mut inserted = 0_usize;
        for operation in &input.push {
            if updated
                .operations
                .iter()
                .any(|stored| stored.op_id == operation.op_id)
                || updated
                    .confirmed_op_ids
                    .iter()
                    .any(|id| id == &operation.op_id)
            {
                continue;
            }
            let sequenced = SyncPulledOperation {
                server_seq: updated.next_server_sequence,
                op_id: operation.op_id.clone(),
                device_id: device.id.clone(),
                entity_id: operation.entity_id.clone(),
                kind: operation.kind,
                lamport: operation.lamport,
                ciphertext: operation.ciphertext.clone(),
                nonce: operation.nonce.clone(),
                created_at: timestamp,
            };
            updated.next_server_sequence = updated
                .next_server_sequence
                .checked_add(1)
                .filter(|value| *value <= MAXIMUM_WIRE_TIMESTAMP)
                .ok_or_else(ServiceFailure::internal)?;
            updated.operations.push(sequenced);
            inserted += 1;
        }
        if let Some(stored_device) = updated
            .devices
            .iter_mut()
            .find(|stored| stored.id == device.id)
        {
            stored_device.last_seen_at = Some(timestamp);
            // 有效 ack（已由请求校验保证非负且 <= cursor）推进该设备水位。
            if let Some(ack) = input.ack {
                stored_device.ack_cursor = stored_device.ack_cursor.max(ack);
            }
        }
        // ack 驱动的操作日志清理：只裁剪所有未撤销设备都已确认的序号，
        // 避免低水位设备拉取时缺失；被裁剪 opId 记入 confirmed_op_ids，
        // 供后续重复 push 去重（上限 16384，超出丢弃最旧的）。
        let threshold = updated
            .devices
            .iter()
            .filter(|device| device.revoked_at.is_none())
            .map(|device| device.ack_cursor)
            .min()
            .unwrap_or(0);
        if threshold > 0 {
            let split = updated
                .operations
                .iter()
                .position(|operation| operation.server_seq > threshold);
            let confirmed = match split {
                Some(index) => updated.operations.drain(..index).collect::<Vec<_>>(),
                None => std::mem::take(&mut updated.operations),
            };
            for operation in confirmed {
                if !updated.confirmed_op_ids.contains(&operation.op_id) {
                    updated.confirmed_op_ids.push(operation.op_id);
                }
            }
            if updated.confirmed_op_ids.len() > MAXIMUM_CONFIRMED_OPERATIONS {
                let overflow = updated.confirmed_op_ids.len() - MAXIMUM_CONFIRMED_OPERATIONS;
                updated.confirmed_op_ids.drain(..overflow);
            }
        }
        self.persist(&updated)?;
        self.state = updated;

        let candidates: Vec<_> = self
            .state
            .operations
            .iter()
            .filter(|operation| operation.server_seq > input.cursor)
            .collect();
        let page: Vec<_> = candidates
            .iter()
            .take(pull_limit)
            .map(|operation| (*operation).clone())
            .collect();
        let cursor = page
            .last()
            .map_or(input.cursor, |operation| operation.server_seq);
        success_response(
            200,
            SyncData {
                push: SyncPushSummary {
                    received: input.push.len(),
                    inserted,
                    duplicates: input.push.len() - inserted,
                },
                pull: page,
                cursor,
                has_more: candidates.len() > pull_limit,
                server_time: timestamp,
            },
            request_id,
        )
    }

    fn list_devices(
        &self,
        current_device: &StoredDevice,
        request_id: &str,
    ) -> Result<LocalHttpResponse, ServiceFailure> {
        success_response(
            200,
            DeviceListData {
                devices: self
                    .state
                    .devices
                    .iter()
                    .map(|device| device.info(&current_device.id))
                    .collect(),
            },
            request_id,
        )
    }

    fn revoke_device(
        &mut self,
        device_id: &str,
        current_device: &StoredDevice,
        request_id: &str,
    ) -> Result<LocalHttpResponse, ServiceFailure> {
        if !valid_identifier(device_id) {
            return Err(ServiceFailure::new(
                404,
                "DEVICE_NOT_FOUND",
                "目标设备不存在",
            ));
        }
        if device_id == current_device.id {
            return Err(ServiceFailure::new(
                409,
                "CANNOT_REVOKE_SELF",
                "当前设备不能撤销自身",
            ));
        }
        let index = self
            .state
            .devices
            .iter()
            .position(|device| device.id == device_id)
            .ok_or_else(|| ServiceFailure::new(404, "DEVICE_NOT_FOUND", "目标设备不存在"))?;
        let revoked_at = if let Some(existing) = self.state.devices[index].revoked_at {
            existing
        } else {
            let timestamp = self.now()?;
            let mut updated = self.state.clone();
            updated.devices[index].revoked_at = Some(timestamp);
            self.persist(&updated)?;
            self.state = updated;
            timestamp
        };
        self.pairings.retain(|_, pairing| {
            pairing.initiator_device_id != device_id
                && pairing
                    .claimed_device
                    .as_ref()
                    .is_none_or(|claimed| claimed.id != device_id)
        });
        success_response(
            200,
            RevokeDeviceData {
                device_id: device_id.to_owned(),
                revoked_at,
            },
            request_id,
        )
    }

    fn authenticate(&self, request: &LocalHttpRequest) -> Result<StoredDevice, ServiceFailure> {
        let authorization = request.header("authorization").ok_or_else(unauthorized)?;
        let token = authorization
            .strip_prefix("Bearer ")
            .filter(|value| {
                !value.is_empty() && !value.bytes().any(|byte| byte.is_ascii_whitespace())
            })
            .ok_or_else(unauthorized)?;
        if !valid_32_byte_base64url(token) {
            return Err(unauthorized());
        }
        let token_hash = credential_hash(token);
        self.state
            .devices
            .iter()
            .find(|device| {
                device.revoked_at.is_none() && constant_time_equal(&device.token_hash, &token_hash)
            })
            .cloned()
            .ok_or_else(unauthorized)
    }

    fn validate_push(&self, operations: &[SyncPushOperation]) -> Result<(), ServiceFailure> {
        let mut current_batch: HashMap<&str, &SyncPushOperation> = HashMap::new();
        for operation in operations {
            if !valid_identifier(&operation.op_id)
                || !valid_identifier(&operation.entity_id)
                || operation.validate().is_err()
            {
                return Err(ServiceFailure::validation(
                    "push",
                    "同步操作字段或密文格式无效",
                ));
            }
            if let Some(previous) = current_batch.insert(&operation.op_id, operation)
                && previous != operation
            {
                return Err(operation_conflict(&operation.op_id));
            }
            if let Some(stored) = self
                .state
                .operations
                .iter()
                .find(|stored| stored.op_id == operation.op_id)
                && !operation_matches(stored, operation)
            {
                return Err(operation_conflict(&operation.op_id));
            }
        }
        Ok(())
    }

    fn active_pairing(&mut self, pairing_id: &str) -> Result<PairingSession, ServiceFailure> {
        if !valid_identifier(pairing_id) {
            return Err(pairing_not_found());
        }
        let session = self
            .pairings
            .get(pairing_id)
            .cloned()
            .ok_or_else(pairing_not_found)?;
        let timestamp = self.now()?;
        if session.expires_at <= timestamp {
            self.pairings.remove(pairing_id);
            return Err(ServiceFailure::new(
                410,
                "PAIRING_EXPIRED",
                "配对会话已过期",
            ));
        }
        Ok(session)
    }

    fn expire_pairings(&mut self, timestamp: i64) {
        self.pairings
            .retain(|_, pairing| pairing.expires_at > timestamp);
    }

    fn unique_identifier(&self, prefix: &str) -> Result<String, ServiceFailure> {
        for _ in 0..8 {
            let random = random_bytes::<16>().map_err(|_| ServiceFailure::internal())?;
            let identifier = hex_identifier(prefix, &random);
            let device_collision = self
                .state
                .devices
                .iter()
                .any(|device| device.id == identifier);
            if !device_collision && !self.pairings.contains_key(&identifier) {
                return Ok(identifier);
            }
        }
        Err(ServiceFailure::internal())
    }

    fn now(&self) -> Result<i64, ServiceFailure> {
        let value = (self.clock)();
        valid_timestamp(value)
            .then_some(value)
            .ok_or_else(ServiceFailure::internal)
    }

    fn persist(&self, updated: &PersistedState) -> Result<(), ServiceFailure> {
        validate_persisted_state(updated).map_err(|_| ServiceFailure::internal())?;
        persist_atomically(&self.state_path, updated).map_err(|_| ServiceFailure::internal())
    }
}

fn route_components(path: &str) -> Result<Vec<&str>, ServiceFailure> {
    if path.is_empty()
        || path.len() > MAXIMUM_PATH_BYTES
        || !path.starts_with('/')
        || path.contains('?')
        || path.contains('#')
        || path
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte == b' ')
        || path.contains("//")
    {
        return Err(ServiceFailure::new(400, "INVALID_PATH", "请求路径无效"));
    }
    let normalized = if path.len() > 1 {
        path.strip_suffix('/').unwrap_or(path)
    } else {
        path
    };
    Ok(normalized
        .split('/')
        .skip(1)
        .filter(|component| !component.is_empty())
        .collect())
}

fn require_method(request: &LocalHttpRequest, expected: &str) -> Result<(), ServiceFailure> {
    if request.method == expected {
        Ok(())
    } else {
        Err(ServiceFailure::new(
            405,
            "METHOD_NOT_ALLOWED",
            "此资源不支持当前 HTTP 方法",
        ))
    }
}

fn require_empty_body(request: &LocalHttpRequest) -> Result<(), ServiceFailure> {
    if request.body.is_empty() {
        Ok(())
    } else {
        Err(ServiceFailure::validation("body", "此请求不得包含请求体"))
    }
}

fn require_json_body(request: &LocalHttpRequest) -> Result<(), ServiceFailure> {
    if request.body.is_empty() {
        return Err(ServiceFailure::validation("body", "请求体必须是 JSON 对象"));
    }
    require_json_content_type(request)
}

fn require_optional_empty_json(request: &LocalHttpRequest) -> Result<(), ServiceFailure> {
    if request.body.is_empty() {
        return Ok(());
    }
    require_json_content_type(request)?;
    let _: EmptyObject = decode_json(&request.body)?;
    Ok(())
}

fn require_json_content_type(request: &LocalHttpRequest) -> Result<(), ServiceFailure> {
    let valid = request.header("content-type").is_some_and(|value| {
        let mut parts = value.split(';');
        let media_type = parts.next().unwrap_or_default().trim();
        media_type.eq_ignore_ascii_case("application/json")
            && parts.all(|parameter| parameter.trim().eq_ignore_ascii_case("charset=utf-8"))
    });
    if valid {
        Ok(())
    } else {
        Err(ServiceFailure::new(
            415,
            "UNSUPPORTED_MEDIA_TYPE",
            "请求体必须使用 application/json",
        ))
    }
}

fn decode_json<T: DeserializeOwned>(body: &[u8]) -> Result<T, ServiceFailure> {
    serde_json::from_slice(body)
        .map_err(|_| ServiceFailure::validation("body", "请求 JSON 或字段格式无效"))
}

fn success_response<T: Serialize>(
    status: u16,
    data: T,
    request_id: &str,
) -> Result<LocalHttpResponse, ServiceFailure> {
    let body = serde_json::to_vec(&SuccessEnvelope {
        ok: true,
        data,
        request_id: request_id.to_owned(),
    })
    .map_err(|_| ServiceFailure::internal())?;
    Ok(json_response(status, request_id, body))
}

fn failure_response(failure: ServiceFailure, request_id: String) -> LocalHttpResponse {
    let body = serde_json::to_vec(&FailureEnvelope {
        ok: false,
        error: FailurePayload {
            code: failure.code.to_owned(),
            message: failure.message,
            details: failure.details,
        },
        request_id: request_id.clone(),
    })
    .unwrap_or_else(|_| {
        b"{\"ok\":false,\"error\":{\"code\":\"INTERNAL_ERROR\",\"message\":\"internal error\"}}"
            .to_vec()
    });
    json_response(failure.status, &request_id, body)
}

fn json_response(status: u16, request_id: &str, body: Vec<u8>) -> LocalHttpResponse {
    LocalHttpResponse {
        status,
        headers: BTreeMap::from([
            ("Content-Type".to_owned(), "application/json".to_owned()),
            ("Cache-Control".to_owned(), "no-store".to_owned()),
            ("X-Request-Id".to_owned(), request_id.to_owned()),
        ]),
        body,
    }
}

fn unauthorized() -> ServiceFailure {
    ServiceFailure::new(401, "UNAUTHORIZED", "设备认证凭据无效、缺失或已撤销")
}

fn pairing_not_found() -> ServiceFailure {
    ServiceFailure::new(404, "PAIRING_NOT_FOUND", "配对会话或一次性凭据无效")
}

fn operation_conflict(operation_id: &str) -> ServiceFailure {
    ServiceFailure::new(409, "OP_ID_CONFLICT", "同一 opId 对应了不同内容")
        .with_details(json!({ "opId": operation_id }))
}

fn operation_matches(stored: &SyncPulledOperation, incoming: &SyncPushOperation) -> bool {
    stored.op_id == incoming.op_id
        && stored.entity_id == incoming.entity_id
        && stored.kind == incoming.kind
        && stored.lamport == incoming.lamport
        && stored.ciphertext == incoming.ciphertext
        && stored.nonce == incoming.nonce
}

fn valid_identifier(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
}

fn normalize_device_name(value: &str) -> Option<String> {
    let normalized = value.trim();
    if normalized.is_empty()
        || normalized.chars().count() > MAXIMUM_DEVICE_NAME_CHARACTERS
        || normalized.chars().any(char::is_control)
    {
        None
    } else {
        Some(normalized.to_owned())
    }
}

fn valid_32_byte_base64url(value: &str) -> bool {
    base64url_decode(value).is_ok_and(|decoded| decoded.len() == 32)
}

fn valid_envelope(envelope: &EncryptedEnvelope) -> bool {
    base64url_decode(&envelope.nonce).is_ok_and(|decoded| decoded.len() == 12)
        && base64url_decode(&envelope.ciphertext)
            .is_ok_and(|decoded| (16..=MAXIMUM_CIPHERTEXT_BYTES).contains(&decoded.len()))
}

fn valid_timestamp(value: i64) -> bool {
    (0..=MAXIMUM_WIRE_TIMESTAMP).contains(&value)
}

fn credential_hash(value: &str) -> String {
    base64url_encode(&Sha256::digest(value.as_bytes()))
}

fn constant_time_matches(value: &str, expected_hash: &str) -> bool {
    constant_time_equal(&credential_hash(value), expected_hash)
}

fn constant_time_equal(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.as_bytes()
        .iter()
        .zip(right.as_bytes())
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

fn validate_persisted_state(state: &PersistedState) -> Result<(), LocalServerError> {
    if state.version != STATE_VERSION
        || !valid_identifier(&state.vault_id)
        || state.next_server_sequence < 1
        || state.devices.is_empty()
        || state.devices.len() > MAXIMUM_DEVICES
    {
        return Err(LocalServerError::CorruptedState);
    }

    let mut device_ids = HashSet::new();
    let mut token_hashes = HashSet::new();
    for device in &state.devices {
        if !valid_identifier(&device.id)
            || normalize_device_name(&device.name).as_deref() != Some(device.name.as_str())
            || device
                .public_key
                .as_deref()
                .is_some_and(|key| !valid_32_byte_base64url(key))
            || !valid_32_byte_base64url(&device.token_hash)
            || !valid_timestamp(device.created_at)
            || device
                .last_seen_at
                .is_some_and(|value| !valid_timestamp(value))
            || device
                .revoked_at
                .is_some_and(|value| !valid_timestamp(value))
            || !device_ids.insert(device.id.as_str())
            || !token_hashes.insert(device.token_hash.as_str())
        {
            return Err(LocalServerError::CorruptedState);
        }
    }

    let mut operation_ids = HashSet::new();
    let first_sequence = state
        .operations
        .first()
        .map_or(1_i64, |operation| operation.server_seq);
    for (index, operation) in state.operations.iter().enumerate() {
        let expected_sequence = i64::try_from(index)
            .ok()
            .and_then(|value| first_sequence.checked_add(value))
            .ok_or(LocalServerError::CorruptedState)?;
        // 裁剪只发生在队首，剩余操作必须从 first.server_seq 起连续。
        if operation.server_seq != expected_sequence
            || !valid_identifier(&operation.op_id)
            || !valid_identifier(&operation.entity_id)
            || !device_ids.contains(operation.device_id.as_str())
            || operation.validate().is_err()
            || !operation_ids.insert(operation.op_id.as_str())
        {
            return Err(LocalServerError::CorruptedState);
        }
    }
    // 非空时 next 必须等于末条序号 + 1；为空时可能是全新状态（next 必须
    // 为 1），也可能是全部操作被确认裁剪（next 保持历史值且 confirmed
    // 非空），只有后者允许 next 大于 1。
    let expected_next = match state.operations.last() {
        Some(operation) => operation
            .server_seq
            .checked_add(1)
            .ok_or(LocalServerError::CorruptedState)?,
        None if state.confirmed_op_ids.is_empty() => 1,
        None => state.next_server_sequence,
    };
    if state.next_server_sequence != expected_next {
        return Err(LocalServerError::CorruptedState);
    }
    let mut confirmed_ids = HashSet::new();
    if state.confirmed_op_ids.len() > MAXIMUM_CONFIRMED_OPERATIONS {
        return Err(LocalServerError::CorruptedState);
    }
    for operation_id in &state.confirmed_op_ids {
        if !valid_identifier(operation_id) || !confirmed_ids.insert(operation_id.as_str()) {
            return Err(LocalServerError::CorruptedState);
        }
    }
    Ok(())
}

fn persist_atomically(path: &Path, state: &PersistedState) -> Result<(), LocalServerError> {
    let parent = path
        .parent()
        .filter(|value| !value.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|error| LocalServerError::Persistence(error.to_string()))?;
    let source = serde_json::to_vec(state)
        .map_err(|error| LocalServerError::Persistence(error.to_string()))?;
    if source.len() as u64 > MAXIMUM_STATE_BYTES {
        return Err(LocalServerError::Persistence(
            "状态文件超过安全上限".to_owned(),
        ));
    }

    let temporary = temporary_state_path(path)?;
    let write_result = (|| -> Result<(), std::io::Error> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(&source)?;
        file.sync_all()?;
        atomic_replace(&temporary, path)?;
        sync_parent_directory(parent);
        Ok(())
    })();
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temporary);
        return Err(LocalServerError::Persistence(error.to_string()));
    }
    Ok(())
}

fn temporary_state_path(path: &Path) -> Result<PathBuf, LocalServerError> {
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| LocalServerError::Persistence("状态文件名无效".to_owned()))?;
    for _ in 0..8 {
        let random = random_bytes::<8>()
            .map_err(|error| LocalServerError::Persistence(error.to_string()))?;
        let suffix = hex_identifier("tmp", &random);
        let candidate = path.with_file_name(format!(".{file_name}.{suffix}"));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err(LocalServerError::Persistence(
        "无法分配状态临时文件".to_owned(),
    ))
}

#[cfg(not(windows))]
fn atomic_replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::rename(source, destination)
}

#[cfg(windows)]
fn atomic_replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;

    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
    #[link(name = "Kernel32")]
    unsafe extern "system" {
        fn MoveFileExW(existing: *const u16, target: *const u16, flags: u32) -> i32;
    }

    let existing: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let target: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let result = unsafe {
        MoveFileExW(
            existing.as_ptr(),
            target.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(unix)]
fn sync_parent_directory(parent: &Path) {
    if let Ok(directory) = File::open(parent) {
        let _ = directory.sync_all();
    }
}

#[cfg(not(unix))]
fn sync_parent_directory(_parent: &Path) {}

fn system_time_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_millis()).ok())
        .filter(|value| valid_timestamp(*value))
        .unwrap_or(0)
}

fn hex_identifier(prefix: &str, bytes: &[u8]) -> String {
    let mut value = String::with_capacity(prefix.len() + 1 + bytes.len() * 2);
    value.push_str(prefix);
    value.push('-');
    for byte in bytes {
        let _ = write!(&mut value, "{byte:02x}");
    }
    value
}

fn request_identifier() -> String {
    static FALLBACK_COUNTER: AtomicU64 = AtomicU64::new(1);
    random_bytes::<16>().map_or_else(
        |_| {
            format!(
                "request-{}-{}",
                system_time_millis(),
                FALLBACK_COUNTER.fetch_add(1, Ordering::Relaxed)
            )
        },
        |bytes| hex_identifier("request", &bytes),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpParseError {
    BadRequest,
    HeaderTooLarge,
    PayloadTooLarge,
    ExpectationFailed,
}

pub fn parse_http_request(source: &[u8]) -> Result<Option<LocalHttpRequest>, HttpParseError> {
    if source.len() > MAXIMUM_REQUEST_BYTES {
        return Err(HttpParseError::PayloadTooLarge);
    }
    let Some(header_end) = find_bytes(source, b"\r\n\r\n") else {
        if source.len() > MAXIMUM_HEADER_BYTES {
            return Err(HttpParseError::HeaderTooLarge);
        }
        return Ok(None);
    };
    if header_end > MAXIMUM_HEADER_BYTES {
        return Err(HttpParseError::HeaderTooLarge);
    }
    let header_source = &source[..header_end];
    if !header_source.is_ascii() {
        return Err(HttpParseError::BadRequest);
    }
    let header_text = std::str::from_utf8(header_source).map_err(|_| HttpParseError::BadRequest)?;
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next().ok_or(HttpParseError::BadRequest)?;
    let parts: Vec<_> = request_line.split(' ').collect();
    if parts.len() != 3
        || parts[0].is_empty()
        || parts[0].len() > 16
        || !parts[0]
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte == b'-')
        || parts[1].is_empty()
        || parts[1].len() > MAXIMUM_PATH_BYTES
        || !parts[1].starts_with('/')
        || parts[1]
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte == b' ')
        || !matches!(parts[2], "HTTP/1.0" | "HTTP/1.1")
    {
        return Err(HttpParseError::BadRequest);
    }

    let mut headers = BTreeMap::new();
    for (index, line) in lines.enumerate() {
        if index >= MAXIMUM_HEADERS || line.is_empty() || line.starts_with([' ', '\t']) {
            return Err(HttpParseError::BadRequest);
        }
        let (name, raw_value) = line.split_once(':').ok_or(HttpParseError::BadRequest)?;
        if name.is_empty()
            || !name.bytes().all(is_http_token_byte)
            || raw_value
                .bytes()
                .any(|byte| byte.is_ascii_control() && byte != b'\t')
        {
            return Err(HttpParseError::BadRequest);
        }
        let name = name.to_ascii_lowercase();
        let value = raw_value.trim_matches([' ', '\t']).to_owned();
        if headers.insert(name, value).is_some() {
            return Err(HttpParseError::BadRequest);
        }
    }
    if parts[2] == "HTTP/1.1" && !headers.contains_key("host") {
        return Err(HttpParseError::BadRequest);
    }
    if headers.contains_key("transfer-encoding") {
        return Err(HttpParseError::BadRequest);
    }
    if headers.contains_key("expect") {
        return Err(HttpParseError::ExpectationFailed);
    }
    let content_length = match headers.get("content-length") {
        Some(value)
            if !value.is_empty()
                && value.bytes().all(|byte| byte.is_ascii_digit())
                && (value == "0" || !value.starts_with('0')) =>
        {
            value
                .parse::<usize>()
                .map_err(|_| HttpParseError::PayloadTooLarge)?
        }
        Some(_) => return Err(HttpParseError::BadRequest),
        None => 0,
    };
    if content_length > MAXIMUM_BODY_BYTES {
        return Err(HttpParseError::PayloadTooLarge);
    }
    let body_start = header_end + 4;
    let expected_length = body_start
        .checked_add(content_length)
        .ok_or(HttpParseError::PayloadTooLarge)?;
    if source.len() < expected_length {
        return Ok(None);
    }
    if source.len() != expected_length {
        return Err(HttpParseError::BadRequest);
    }
    Ok(Some(LocalHttpRequest {
        method: parts[0].to_owned(),
        path: parts[1].to_owned(),
        headers,
        body: source[body_start..].to_vec(),
    }))
}

fn find_bytes(source: &[u8], needle: &[u8]) -> Option<usize> {
    source
        .windows(needle.len())
        .position(|window| window == needle)
}

fn is_http_token_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric()
        || matches!(
            byte,
            b'!' | b'#'
                | b'$'
                | b'%'
                | b'&'
                | b'\''
                | b'*'
                | b'+'
                | b'-'
                | b'.'
                | b'^'
                | b'_'
                | b'`'
                | b'|'
                | b'~'
        )
}

pub struct LocalNetworkHttpServer {
    store: SharedLocalServerStore,
    listener: TcpListener,
    endpoint: String,
    running: Arc<AtomicBool>,
    accept_thread: Option<JoinHandle<()>>,
}

impl LocalNetworkHttpServer {
    pub fn bind_local_network(
        store: SharedLocalServerStore,
        port: u16,
    ) -> Result<Self, LocalServerError> {
        let advertised = preferred_private_ipv4()?;
        Self::bind(
            store,
            SocketAddr::from((Ipv4Addr::UNSPECIFIED, port)),
            IpAddr::V4(advertised),
        )
    }

    pub fn bind_default(store: SharedLocalServerStore) -> Result<Self, LocalServerError> {
        Self::bind_local_network(store, DEFAULT_LOCAL_SYNC_PORT)
    }

    pub fn bind(
        store: SharedLocalServerStore,
        bind_address: SocketAddr,
        advertised_address: IpAddr,
    ) -> Result<Self, LocalServerError> {
        if advertised_address.is_unspecified() || advertised_address.is_multicast() {
            return Err(LocalServerError::CannotResolveEndpoint);
        }
        let listener = TcpListener::bind(bind_address)
            .map_err(|error| LocalServerError::ListenerFailed(error.to_string()))?;
        listener
            .set_nonblocking(true)
            .map_err(|error| LocalServerError::ListenerFailed(error.to_string()))?;
        let port = listener
            .local_addr()
            .map_err(|error| LocalServerError::ListenerFailed(error.to_string()))?
            .port();
        let endpoint = match advertised_address {
            IpAddr::V4(address) => format!("http://{address}:{port}"),
            IpAddr::V6(address) => format!("http://[{address}]:{port}"),
        };
        Ok(Self {
            store,
            listener,
            endpoint,
            running: Arc::new(AtomicBool::new(false)),
            accept_thread: None,
        })
    }

    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    #[allow(dead_code)] // 供调用方在开启服务前确认水位与运行状态
    pub fn highest_lamport(&self) -> Result<i64, LocalServerError> {
        self.store
            .lock()
            .map(|store| store.highest_lamport())
            .map_err(|_| LocalServerError::CorruptedState)
    }

    #[cfg(test)]
    pub fn local_addr(&self) -> Result<SocketAddr, LocalServerError> {
        self.listener
            .local_addr()
            .map_err(|error| LocalServerError::ListenerFailed(error.to_string()))
    }

    #[allow(dead_code)] // 供调用方在开启服务前确认运行状态
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Acquire) && self.accept_thread.is_some()
    }

    pub fn start(&mut self) -> Result<(), LocalServerError> {
        if self.accept_thread.is_some() {
            return Ok(());
        }
        let listener = self
            .listener
            .try_clone()
            .map_err(|error| LocalServerError::ListenerFailed(error.to_string()))?;
        let store = Arc::clone(&self.store);
        let running = Arc::clone(&self.running);
        running.store(true, Ordering::Release);
        let thread_running = Arc::clone(&running);
        let spawn_result = thread::Builder::new()
            .name("woo-todo-local-sync".to_owned())
            .spawn(move || accept_connections(listener, store, thread_running));
        match spawn_result {
            Ok(handle) => {
                self.accept_thread = Some(handle);
                Ok(())
            }
            Err(error) => {
                running.store(false, Ordering::Release);
                Err(LocalServerError::ListenerFailed(error.to_string()))
            }
        }
    }

    pub fn stop(&mut self) -> Result<(), LocalServerError> {
        self.running.store(false, Ordering::Release);
        if self.accept_thread.is_some()
            && let Ok(address) = self.listener.local_addr()
        {
            let _ = TcpStream::connect_timeout(&wake_address(address), Duration::from_millis(100));
        }
        if let Some(handle) = self.accept_thread.take()
            && handle.join().is_err()
        {
            return Err(LocalServerError::ListenerFailed(
                "服务线程异常退出".to_owned(),
            ));
        }
        Ok(())
    }
}

impl Drop for LocalNetworkHttpServer {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

pub fn preferred_local_endpoint(port: u16) -> Result<String, LocalServerError> {
    let address = preferred_private_ipv4()?;
    Ok(format!("http://{address}:{port}"))
}

pub fn preferred_private_ipv4() -> Result<Ipv4Addr, LocalServerError> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))
        .map_err(|_| LocalServerError::CannotResolveEndpoint)?;
    for target in [
        SocketAddr::from(([192, 168, 0, 1], 9)),
        SocketAddr::from(([10, 0, 0, 1], 9)),
        SocketAddr::from(([172, 16, 0, 1], 9)),
    ] {
        if socket.connect(target).is_ok()
            && let Ok(SocketAddr::V4(local)) = socket.local_addr()
            && is_private_ipv4(*local.ip())
        {
            return Ok(*local.ip());
        }
    }
    Err(LocalServerError::CannotResolveEndpoint)
}

fn is_private_ipv4(address: Ipv4Addr) -> bool {
    let [first, second, _, _] = address.octets();
    first == 10 || (first == 172 && (16..=31).contains(&second)) || (first == 192 && second == 168)
}

fn wake_address(address: SocketAddr) -> SocketAddr {
    match address {
        SocketAddr::V4(address) => SocketAddr::from((Ipv4Addr::LOCALHOST, address.port())),
        SocketAddr::V6(address) => {
            SocketAddr::new(IpAddr::V6(std::net::Ipv6Addr::LOCALHOST), address.port())
        }
    }
}

fn accept_connections(
    listener: TcpListener,
    store: SharedLocalServerStore,
    running: Arc<AtomicBool>,
) {
    let active_clients = Arc::new(AtomicUsize::new(0));
    let mut workers: Vec<JoinHandle<()>> = Vec::new();
    while running.load(Ordering::Acquire) {
        workers = reap_workers(workers, false);
        match listener.accept() {
            Ok((mut stream, _)) => {
                if !running.load(Ordering::Acquire) {
                    break;
                }
                if active_clients
                    .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
                        (value < MAXIMUM_CLIENTS).then_some(value + 1)
                    })
                    .is_err()
                {
                    let response =
                        bare_error_response(503, "SERVER_BUSY", "局域网同步服务当前连接过多");
                    let _ = write_http_response(&mut stream, &response);
                    continue;
                }
                let worker_store = Arc::clone(&store);
                let worker_running = Arc::clone(&running);
                let worker_clients = Arc::clone(&active_clients);
                match thread::Builder::new()
                    .name("woo-todo-local-sync-client".to_owned())
                    .spawn(move || {
                        let _guard = ActiveClientGuard(worker_clients);
                        serve_connection(&mut stream, &worker_store, &worker_running);
                    }) {
                    Ok(worker) => workers.push(worker),
                    Err(_) => {
                        active_clients.fetch_sub(1, Ordering::AcqRel);
                    }
                }
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                thread::sleep(ACCEPT_POLL_INTERVAL);
            }
            Err(_) => {
                thread::sleep(ACCEPT_POLL_INTERVAL);
            }
        }
    }
    let _ = reap_workers(workers, true);
}

fn reap_workers(workers: Vec<JoinHandle<()>>, join_all: bool) -> Vec<JoinHandle<()>> {
    let mut pending = Vec::new();
    for worker in workers {
        if join_all || worker.is_finished() {
            let _ = worker.join();
        } else {
            pending.push(worker);
        }
    }
    pending
}

struct ActiveClientGuard(Arc<AtomicUsize>);

impl Drop for ActiveClientGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn serve_connection(stream: &mut TcpStream, store: &SharedLocalServerStore, running: &AtomicBool) {
    let _ = stream.set_nodelay(true);
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    let response = match read_http_request(stream, running) {
        Ok(request) => match store.lock() {
            Ok(mut store) => store.handle(request),
            Err(_) => bare_error_response(500, "INTERNAL_ERROR", "局域网同步状态锁已损坏"),
        },
        Err(ReadRequestError::Stopped) => return,
        Err(ReadRequestError::Parse(error)) => parse_error_response(error),
        Err(ReadRequestError::Io) => bare_error_response(400, "BAD_REQUEST", "HTTP 请求读取失败"),
    };
    let _ = write_http_response(stream, &response);
}

enum ReadRequestError {
    Stopped,
    Parse(HttpParseError),
    Io,
}

fn read_http_request(
    stream: &mut TcpStream,
    running: &AtomicBool,
) -> Result<LocalHttpRequest, ReadRequestError> {
    let deadline = Instant::now() + CONNECTION_LIFETIME;
    let mut source = Vec::with_capacity(4 * 1_024);
    let mut buffer = [0_u8; 16 * 1_024];
    loop {
        if !running.load(Ordering::Acquire) {
            return Err(ReadRequestError::Stopped);
        }
        if let Some(request) = parse_http_request(&source).map_err(ReadRequestError::Parse)? {
            return Ok(request);
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(ReadRequestError::Io);
        }
        let timeout = (deadline - now).min(SOCKET_POLL_INTERVAL);
        stream
            .set_read_timeout(Some(timeout))
            .map_err(|_| ReadRequestError::Io)?;
        match stream.read(&mut buffer) {
            Ok(0) => return Err(ReadRequestError::Io),
            Ok(count) => source.extend_from_slice(&buffer[..count]),
            Err(error) if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(_) => return Err(ReadRequestError::Io),
        }
    }
}

fn write_http_response(
    stream: &mut TcpStream,
    response: &LocalHttpResponse,
) -> std::io::Result<()> {
    let mut head = format!(
        "HTTP/1.1 {} {}\r\n",
        response.status,
        reason_phrase(response.status)
    );
    for (name, value) in &response.headers {
        if name.eq_ignore_ascii_case("content-length") || name.eq_ignore_ascii_case("connection") {
            continue;
        }
        write!(&mut head, "{name}: {value}\r\n").expect("写入 String 不会失败");
    }
    write!(
        &mut head,
        "Content-Length: {}\r\nConnection: close\r\n\r\n",
        response.body.len()
    )
    .expect("写入 String 不会失败");
    stream.write_all(head.as_bytes())?;
    stream.write_all(&response.body)?;
    stream.flush()
}

fn reason_phrase(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        410 => "Gone",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        417 => "Expectation Failed",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Unknown",
    }
}

fn parse_error_response(error: HttpParseError) -> LocalHttpResponse {
    match error {
        HttpParseError::HeaderTooLarge => {
            bare_error_response(431, "HEADER_TOO_LARGE", "HTTP 请求头超过局域网同步上限")
        }
        HttpParseError::PayloadTooLarge => {
            bare_error_response(413, "PAYLOAD_TOO_LARGE", "HTTP 请求体超过局域网同步上限")
        }
        HttpParseError::ExpectationFailed => bare_error_response(
            417,
            "EXPECTATION_FAILED",
            "局域网同步服务不支持 Expect 请求头",
        ),
        HttpParseError::BadRequest => bare_error_response(400, "BAD_REQUEST", "HTTP 请求格式无效"),
    }
}

fn bare_error_response(
    status: u16,
    code: &'static str,
    message: &'static str,
) -> LocalHttpResponse {
    failure_response(
        ServiceFailure::new(status, code, message),
        request_identifier(),
    )
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::sync::atomic::{AtomicI64, Ordering};

    use serde::Deserialize;
    use tempfile::tempdir;
    use woo_todo_core::{OperationKind, SyncPushOperation};

    use super::*;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct TestSuccess<T> {
        ok: bool,
        data: T,
        request_id: String,
    }

    #[derive(Deserialize)]
    struct TestFailureEnvelope {
        error: TestFailure,
    }

    #[derive(Deserialize)]
    struct TestFailure {
        code: String,
    }

    fn credentials(device_id: &str, token_byte: u8) -> SyncCredentials {
        SyncCredentials::LocalNetwork {
            endpoint: "http://192.168.8.21:48473".to_owned(),
            vault_id: "vault-local-network".to_owned(),
            device_id: device_id.to_owned(),
            device_token: base64url_encode(&[token_byte; 32]),
            vault_key: base64url_encode(&[2; 32]),
        }
    }

    fn token(credentials: &SyncCredentials) -> &str {
        credentials.device_token().unwrap()
    }

    fn json_request<T: Serialize>(method: &str, path: &str, value: &T) -> LocalHttpRequest {
        LocalHttpRequest::new(method, path, serde_json::to_vec(value).unwrap())
            .with_header("Content-Type", "application/json")
    }

    fn authenticated(mut request: LocalHttpRequest, token: &str) -> LocalHttpRequest {
        request
            .headers
            .insert("authorization".to_owned(), format!("Bearer {token}"));
        request
    }

    fn sync_request(token: &str, request: &SyncRequest) -> LocalHttpRequest {
        authenticated(json_request("POST", "/v1/sync", request), token)
    }

    fn success<T: DeserializeOwned>(response: LocalHttpResponse) -> T {
        assert!((200..300).contains(&response.status), "{:?}", response.body);
        let envelope: TestSuccess<T> = serde_json::from_slice(&response.body).unwrap();
        assert!(envelope.ok);
        assert!(!envelope.request_id.is_empty());
        envelope.data
    }

    fn failure_code(response: &LocalHttpResponse) -> String {
        serde_json::from_slice::<TestFailureEnvelope>(&response.body)
            .unwrap()
            .error
            .code
    }

    fn operation(id: &str, ciphertext_byte: u8) -> SyncPushOperation {
        SyncPushOperation {
            op_id: id.to_owned(),
            entity_id: "task-local-network-1".to_owned(),
            kind: OperationKind::Upsert,
            lamport: 1,
            ciphertext: base64url_encode(&[ciphertext_byte; 32]),
            nonce: base64url_encode(&[8; 12]),
        }
    }

    #[test]
    fn operation_replay_is_idempotent_across_restart_and_secrets_are_not_persisted() {
        let directory = tempdir().unwrap();
        let state_path = directory.path().join("state.json");
        let credentials = credentials("device-windows-local", 1);
        let pushed = operation("op-local-network-1", 7);
        let request = SyncRequest {
            cursor: 0,
            ack: Some(0),
            pull_limit: Some(100),
            push: vec![pushed.clone()],
        };

        let mut first = LocalServerStore::new_with_clock(
            &state_path,
            &credentials,
            "Windows 测试主机",
            || 1_000,
        )
        .unwrap();
        let first_data: SyncData =
            success(first.handle(sync_request(token(&credentials), &request)));
        assert_eq!(first_data.push.inserted, 1);
        assert_eq!(first_data.pull[0].op_id, pushed.op_id);
        assert_eq!(first_data.cursor, 1);

        let replay: SyncData = success(first.handle(sync_request(token(&credentials), &request)));
        assert_eq!(replay.push.inserted, 0);
        assert_eq!(replay.push.duplicates, 1);
        assert_eq!(first.highest_lamport(), 1);

        let persisted = fs::read_to_string(&state_path).unwrap();
        assert!(!persisted.contains(token(&credentials)));
        assert!(!persisted.contains(credentials.vault_key()));
        assert!(persisted.contains(&pushed.ciphertext));

        let mut restarted = LocalServerStore::new_with_clock(
            &state_path,
            &credentials,
            "Windows 测试主机",
            || 2_000,
        )
        .unwrap();
        assert_eq!(restarted.highest_lamport(), 1);
        let pulled: SyncData = success(restarted.handle(sync_request(
            token(&credentials),
            &SyncRequest {
                cursor: 0,
                ack: Some(0),
                pull_limit: Some(100),
                push: Vec::new(),
            },
        )));
        assert_eq!(pulled.pull, vec![first_data.pull[0].clone()]);
    }

    #[test]
    fn conflicting_operation_is_rejected_without_replacing_original() {
        let directory = tempdir().unwrap();
        let credentials = credentials("device-windows-local", 1);
        let mut store = LocalServerStore::new_with_clock(
            directory.path().join("state.json"),
            &credentials,
            "Windows",
            || 1_000,
        )
        .unwrap();
        let original = operation("op-local-conflict", 3);
        let changed = operation("op-local-conflict", 9);
        let push = |operation| SyncRequest {
            cursor: 0,
            ack: Some(0),
            pull_limit: Some(100),
            push: vec![operation],
        };
        let _: SyncData =
            success(store.handle(sync_request(token(&credentials), &push(original.clone()))));
        let conflict = store.handle(sync_request(token(&credentials), &push(changed)));
        assert_eq!(conflict.status, 409);
        assert_eq!(failure_code(&conflict), "OP_ID_CONFLICT");

        let pulled: SyncData = success(store.handle(sync_request(
            token(&credentials),
            &SyncRequest {
                cursor: 0,
                ack: Some(0),
                pull_limit: Some(100),
                push: Vec::new(),
            },
        )));
        assert_eq!(pulled.pull.len(), 1);
        assert_eq!(pulled.pull[0].ciphertext, original.ciphertext);
    }

    #[test]
    fn persisted_state_rejects_different_bootstrap_identity_and_corruption() {
        let directory = tempdir().unwrap();
        let state_path = directory.path().join("state.json");
        let credentials = credentials("device-windows-local", 1);
        LocalServerStore::new_with_clock(&state_path, &credentials, "Windows", || 1_000).unwrap();

        let mismatch = self::credentials("device-another-local", 1);
        assert!(matches!(
            LocalServerStore::new_with_clock(&state_path, &mismatch, "Windows", || 1_000),
            Err(LocalServerError::IdentityMismatch)
        ));

        let mut value: Value = serde_json::from_slice(&fs::read(&state_path).unwrap()).unwrap();
        value["nextServerSequence"] = json!(99);
        fs::write(&state_path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(matches!(
            LocalServerStore::new_with_clock(&state_path, &credentials, "Windows", || 1_000),
            Err(LocalServerError::CorruptedState)
        ));
    }

    #[test]
    fn bootstrap_requires_local_network_credentials() {
        let directory = tempdir().unwrap();
        let worker = SyncCredentials::Worker {
            endpoint: "https://sync.example.com".to_owned(),
            vault_id: "vault-local-network".to_owned(),
            device_id: "device-windows-local".to_owned(),
            device_token: base64url_encode(&[1; 32]),
            vault_key: base64url_encode(&[2; 32]),
        };
        assert!(matches!(
            LocalServerStore::new(directory.path().join("state.json"), &worker),
            Err(LocalServerError::InvalidBootstrapIdentity)
        ));
    }

    #[test]
    fn paired_device_can_sync_until_revoked() {
        let directory = tempdir().unwrap();
        let clock = Arc::new(AtomicI64::new(10_000));
        let clock_value = Arc::clone(&clock);
        let credentials = credentials("device-windows-local", 1);
        let mut store = LocalServerStore::new_with_clock(
            directory.path().join("state.json"),
            &credentials,
            "Windows",
            move || clock_value.load(Ordering::Relaxed),
        )
        .unwrap();
        let initiator_key = base64url_encode(&[3; 32]);
        let create = authenticated(
            json_request(
                "POST",
                "/v1/pairings",
                &CreatePairingRequest {
                    public_key: initiator_key.clone(),
                },
            ),
            token(&credentials),
        );
        let created: CreatePairingData = success(store.handle(create));
        assert_eq!(created.expires_at, 610_000);

        let device_token = base64url_encode(&[4; 32]);
        let claim_request = PairingClaimRequest {
            pairing_secret: created.pairing_secret.clone(),
            device_token: device_token.clone(),
            device: PairingDeviceRegistration {
                name: "Android 测试设备".to_owned(),
                platform: DevicePlatform::Android,
                public_key: base64url_encode(&[5; 32]),
            },
        };
        let claim: PairingClaimData = success(store.handle(json_request(
            "POST",
            &format!("/v1/pairings/{}/claim", created.pairing_id),
            &claim_request,
        )));
        let replayed_claim: PairingClaimData = success(store.handle(json_request(
            "POST",
            &format!("/v1/pairings/{}/claim", created.pairing_id),
            &claim_request,
        )));
        assert_eq!(claim.device_id, replayed_claim.device_id);

        let status_request = authenticated(
            LocalHttpRequest::new(
                "GET",
                format!("/v1/pairings/{}", created.pairing_id),
                Vec::new(),
            ),
            token(&credentials),
        );
        let status: PairingStatusData = success(store.handle(status_request));
        assert_eq!(status.status, PairingStatus::Claimed);
        assert_eq!(status.claim.unwrap().device_id, claim.device_id);

        let envelope = EncryptedEnvelope {
            ciphertext: base64url_encode(&[6; 32]),
            nonce: base64url_encode(&[7; 12]),
        };
        let confirm = authenticated(
            json_request(
                "POST",
                &format!("/v1/pairings/{}/confirm", created.pairing_id),
                &PairingConfirmRequest {
                    vault_key_envelope: envelope.clone(),
                },
            ),
            token(&credentials),
        );
        let confirmed: PairingConfirmData = success(store.handle(confirm));
        assert_eq!(confirmed.device_id, claim.device_id);

        let result: PairingResultData = success(store.handle(json_request(
            "POST",
            &format!("/v1/pairings/{}/result", created.pairing_id),
            &PairingResultRequest {
                pairing_secret: created.pairing_secret,
                device_token: device_token.clone(),
            },
        )));
        assert_eq!(result.status, PairingStatus::Confirmed);
        assert_eq!(result.vault_key_envelope, Some(envelope));

        let empty_sync = SyncRequest {
            cursor: 0,
            ack: Some(0),
            pull_limit: Some(100),
            push: Vec::new(),
        };
        assert_eq!(
            store
                .handle(sync_request(&device_token, &empty_sync))
                .status,
            200
        );
        let revoke = authenticated(
            LocalHttpRequest::new(
                "POST",
                format!("/v1/devices/{}/revoke", claim.device_id),
                Vec::new(),
            ),
            token(&credentials),
        );
        assert_eq!(store.handle(revoke).status, 200);
        let revoked = store.handle(sync_request(&device_token, &empty_sync));
        assert_eq!(revoked.status, 401);
        assert_eq!(failure_code(&revoked), "UNAUTHORIZED");
    }

    #[test]
    fn pairing_expires_after_ten_minutes_and_second_device_cannot_claim() {
        let directory = tempdir().unwrap();
        let clock = Arc::new(AtomicI64::new(1_000));
        let clock_value = Arc::clone(&clock);
        let credentials = credentials("device-windows-local", 1);
        let mut store = LocalServerStore::new_with_clock(
            directory.path().join("state.json"),
            &credentials,
            "Windows",
            move || clock_value.load(Ordering::Relaxed),
        )
        .unwrap();
        let created: CreatePairingData = success(store.handle(authenticated(
            json_request(
                "POST",
                "/v1/pairings",
                &CreatePairingRequest {
                    public_key: base64url_encode(&[3; 32]),
                },
            ),
            token(&credentials),
        )));
        let claim = |token_byte, key_byte| PairingClaimRequest {
            pairing_secret: created.pairing_secret.clone(),
            device_token: base64url_encode(&[token_byte; 32]),
            device: PairingDeviceRegistration {
                name: "设备".to_owned(),
                platform: DevicePlatform::Android,
                public_key: base64url_encode(&[key_byte; 32]),
            },
        };
        let path = format!("/v1/pairings/{}/claim", created.pairing_id);
        let _: PairingClaimData = success(store.handle(json_request("POST", &path, &claim(4, 5))));
        let conflict = store.handle(json_request("POST", &path, &claim(6, 7)));
        assert_eq!(conflict.status, 409);

        clock.store(601_000, Ordering::Relaxed);
        let expired = store.handle(json_request("POST", &path, &claim(4, 5)));
        assert_eq!(expired.status, 410);
        assert_eq!(failure_code(&expired), "PAIRING_EXPIRED");
    }

    #[test]
    fn cursor_paging_and_protocol_limits_are_enforced() {
        let directory = tempdir().unwrap();
        let credentials = credentials("device-windows-local", 1);
        let mut store = LocalServerStore::new_with_clock(
            directory.path().join("state.json"),
            &credentials,
            "Windows",
            || 1_000,
        )
        .unwrap();
        let initial: SyncData = success(store.handle(sync_request(
            token(&credentials),
            &SyncRequest {
                cursor: 0,
                ack: Some(0),
                pull_limit: Some(1),
                push: vec![operation("op-page-1", 1), operation("op-page-2", 2)],
            },
        )));
        assert_eq!(initial.pull.len(), 1);
        assert_eq!(initial.cursor, 1);
        assert!(initial.has_more);

        let second: SyncData = success(store.handle(sync_request(
            token(&credentials),
            &SyncRequest {
                cursor: initial.cursor,
                ack: Some(initial.cursor),
                pull_limit: Some(1),
                push: Vec::new(),
            },
        )));
        assert_eq!(second.pull[0].server_seq, 2);
        assert!(!second.has_more);

        let ahead = store.handle(sync_request(
            token(&credentials),
            &SyncRequest {
                cursor: 3,
                ack: Some(3),
                pull_limit: Some(1),
                push: Vec::new(),
            },
        ));
        assert_eq!(ahead.status, 409);
        assert_eq!(failure_code(&ahead), "CURSOR_AHEAD");

        let invalid_ack = store.handle(sync_request(
            token(&credentials),
            &SyncRequest {
                cursor: 2,
                ack: Some(3),
                pull_limit: Some(1),
                push: Vec::new(),
            },
        ));
        assert_eq!(invalid_ack.status, 400);

        let oversized =
            LocalHttpRequest::new("POST", "/v1/sync", vec![b' '; MAXIMUM_BODY_BYTES + 1]);
        assert_eq!(store.handle(oversized).status, 413);
    }

    #[test]
    fn methods_content_types_paths_and_bodies_are_strict() {
        let directory = tempdir().unwrap();
        let credentials = credentials("device-windows-local", 1);
        let mut store = LocalServerStore::new_with_clock(
            directory.path().join("state.json"),
            &credentials,
            "Windows",
            || 1_000,
        )
        .unwrap();
        assert_eq!(
            store
                .handle(LocalHttpRequest::new("POST", "/health", Vec::new()))
                .status,
            405
        );
        assert_eq!(
            store
                .handle(LocalHttpRequest::new("GET", "/health", b"{}".to_vec()))
                .status,
            400
        );
        assert_eq!(
            store
                .handle(LocalHttpRequest::new("GET", "/health?debug=1", Vec::new()))
                .status,
            400
        );
        let no_content_type = authenticated(
            LocalHttpRequest::new("POST", "/v1/sync", b"{}".to_vec()),
            token(&credentials),
        );
        assert_eq!(store.handle(no_content_type).status, 415);
        let unknown_field = authenticated(
            LocalHttpRequest::new(
                "POST",
                "/v1/sync",
                br#"{"cursor":0,"push":[],"extra":1}"#.to_vec(),
            )
            .with_header("Content-Type", "application/json"),
            token(&credentials),
        );
        assert_eq!(store.handle(unknown_field).status, 400);
    }

    #[test]
    fn http_parser_handles_partial_frames_and_rejects_ambiguous_requests() {
        let complete = b"POST /v1/sync HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}";
        assert!(
            parse_http_request(&complete[..complete.len() - 1])
                .unwrap()
                .is_none()
        );
        let parsed = parse_http_request(complete).unwrap().unwrap();
        assert_eq!(parsed.method, "POST");
        assert_eq!(parsed.path, "/v1/sync");
        assert_eq!(parsed.body, b"{}");

        let duplicate = b"GET /health HTTP/1.1\r\nHost: one\r\nhost: two\r\n\r\n";
        assert_eq!(
            parse_http_request(duplicate),
            Err(HttpParseError::BadRequest)
        );
        let chunked = b"POST /v1/sync HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
        assert_eq!(parse_http_request(chunked), Err(HttpParseError::BadRequest));
        let trailing = b"GET /health HTTP/1.1\r\nHost: x\r\n\r\nextra";
        assert_eq!(
            parse_http_request(trailing),
            Err(HttpParseError::BadRequest)
        );
        let too_large = format!(
            "POST /v1/sync HTTP/1.1\r\nHost: x\r\nContent-Length: {}\r\n\r\n",
            MAXIMUM_BODY_BYTES + 1
        );
        assert_eq!(
            parse_http_request(too_large.as_bytes()),
            Err(HttpParseError::PayloadTooLarge)
        );
        let huge_header = vec![b'a'; MAXIMUM_HEADER_BYTES + 1];
        assert_eq!(
            parse_http_request(&huge_header),
            Err(HttpParseError::HeaderTooLarge)
        );
    }

    #[test]
    fn tcp_server_serves_health_and_stop_converges() {
        let directory = tempdir().unwrap();
        let credentials = credentials("device-windows-local", 1);
        let store = Arc::new(Mutex::new(
            LocalServerStore::new_with_clock(
                directory.path().join("state.json"),
                &credentials,
                "Windows",
                || 1_000,
            )
            .unwrap(),
        ));
        let mut server = LocalNetworkHttpServer::bind(
            store,
            SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
            IpAddr::V4(Ipv4Addr::LOCALHOST),
        )
        .unwrap();
        server.start().unwrap();
        assert!(server.is_running());

        let mut stream = TcpStream::connect(server.local_addr().unwrap()).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        stream
            .write_all(b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            .unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(response.contains("woo-todo-local-sync"));

        let started = Instant::now();
        server.stop().unwrap();
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(!server.is_running());
    }

    fn sync_envelope(
        store: &mut LocalServerStore,
        credentials: &SyncCredentials,
        cursor: i64,
        ack: Option<i64>,
        push: Vec<SyncPushOperation>,
    ) -> SyncData {
        success(store.handle(sync_request(
            token(credentials),
            &SyncRequest {
                cursor,
                ack,
                pull_limit: Some(100),
                push,
            },
        )))
    }

    #[test]
    fn ack_driven_cleanup_trims_confirmed_operations_and_bounds_state_size() {
        let directory = tempdir().unwrap();
        let state_path = directory.path().join("state.json");
        let credentials = credentials("device-windows-local", 1);
        let mut store =
            LocalServerStore::new_with_clock(&state_path, &credentials, "Windows", || 1_000)
                .unwrap();

        // 第一轮：推送 3 个操作，游标推进到 3，未携带 ack 时不裁剪。
        let first = sync_envelope(
            &mut store,
            &credentials,
            0,
            None,
            vec![
                operation("op-trim-1", 1),
                operation("op-trim-2", 2),
                operation("op-trim-3", 3),
            ],
        );
        assert_eq!(first.cursor, 3);
        assert_eq!(store.state.operations.len(), 3);
        assert!(store.state.confirmed_op_ids.is_empty());

        // 第二轮：ack=3 确认全部操作，operations 被裁剪并记入 confirmed_op_ids。
        let second = sync_envelope(&mut store, &credentials, 3, Some(3), Vec::new());
        assert!(second.pull.is_empty());
        assert!(store.state.operations.is_empty());
        assert_eq!(
            store.state.confirmed_op_ids,
            vec![
                "op-trim-1".to_owned(),
                "op-trim-2".to_owned(),
                "op-trim-3".to_owned()
            ]
        );

        // 第三轮：已确认操作再次 push 被跳过（重复计数，不重新入队）。
        let third = sync_envelope(
            &mut store,
            &credentials,
            3,
            Some(3),
            vec![operation("op-trim-1", 1)],
        );
        assert_eq!(third.push.inserted, 0);
        assert_eq!(third.push.duplicates, 1);

        // 状态文件体积有界，且裁剪后的状态可正常重新加载。
        assert!(fs::metadata(&state_path).unwrap().len() < 8 * 1_024);
        let restarted =
            LocalServerStore::new_with_clock(&state_path, &credentials, "Windows", || 2_000)
                .unwrap();
        assert!(restarted.state.operations.is_empty());
        assert_eq!(restarted.state.confirmed_op_ids.len(), 3);
        assert_eq!(restarted.state.devices[0].ack_cursor, 3);
    }

    #[test]
    fn low_water_device_operations_survive_until_that_device_acks() {
        let directory = tempdir().unwrap();
        let clock = Arc::new(AtomicI64::new(10_000));
        let clock_value = Arc::clone(&clock);
        let credentials = credentials("device-windows-local", 1);
        let mut store = LocalServerStore::new_with_clock(
            directory.path().join("state.json"),
            &credentials,
            "Windows",
            move || clock_value.load(Ordering::Relaxed),
        )
        .unwrap();

        // 通过配对加入第二台设备 B。
        let created: CreatePairingData = success(store.handle(authenticated(
            json_request(
                "POST",
                "/v1/pairings",
                &CreatePairingRequest {
                    public_key: base64url_encode(&[3; 32]),
                },
            ),
            token(&credentials),
        )));
        let device_b_token = base64url_encode(&[4; 32]);
        let _: PairingClaimData = success(store.handle(json_request(
            "POST",
            &format!("/v1/pairings/{}/claim", created.pairing_id),
            &PairingClaimRequest {
                pairing_secret: created.pairing_secret.clone(),
                device_token: device_b_token.clone(),
                device: PairingDeviceRegistration {
                    name: "低水位设备".to_owned(),
                    platform: DevicePlatform::Android,
                    public_key: base64url_encode(&[5; 32]),
                },
            },
        )));
        let _: PairingConfirmData = success(store.handle(authenticated(
            json_request(
                "POST",
                &format!("/v1/pairings/{}/confirm", created.pairing_id),
                &PairingConfirmRequest {
                    vault_key_envelope: EncryptedEnvelope {
                        ciphertext: base64url_encode(&[6; 32]),
                        nonce: base64url_encode(&[7; 12]),
                    },
                },
            ),
            token(&credentials),
        )));
        let _: PairingResultData = success(store.handle(json_request(
            "POST",
            &format!("/v1/pairings/{}/result", created.pairing_id),
            &PairingResultRequest {
                pairing_secret: created.pairing_secret,
                device_token: device_b_token.clone(),
            },
        )));

        // 主机 A 推送 5 个操作并 ack=5；设备 B 尚未同步，水位为 0 → 不裁剪。
        sync_envelope(
            &mut store,
            &credentials,
            0,
            None,
            vec![
                operation("op-multi-1", 1),
                operation("op-multi-2", 2),
                operation("op-multi-3", 3),
                operation("op-multi-4", 4),
                operation("op-multi-5", 5),
            ],
        );
        sync_envelope(&mut store, &credentials, 5, Some(5), Vec::new());
        assert_eq!(store.state.operations.len(), 5);
        assert!(store.state.confirmed_op_ids.is_empty());

        // B 只同步到游标 2（ack=2）：阈值 = min(5, 2) = 2，裁剪 seq <= 2。
        let b_sync =
            |store: &mut LocalServerStore, cursor: i64, ack: i64, pull_limit: usize| -> SyncData {
                success(store.handle(sync_request(
                    &device_b_token,
                    &SyncRequest {
                        cursor,
                        ack: Some(ack),
                        pull_limit: Some(pull_limit),
                        push: Vec::new(),
                    },
                )))
            };
        // B 先拉取前 2 条（seq 1..2），游标与 ack 都停在 2。
        let first_pull = b_sync(&mut store, 0, 0, 2);
        assert_eq!(first_pull.pull.len(), 2);
        assert_eq!(first_pull.cursor, 2);
        assert!(first_pull.has_more);
        let second_pull = b_sync(&mut store, 2, 2, 100);
        assert_eq!(second_pull.pull.len(), 3);
        assert_eq!(second_pull.cursor, 5);
        assert!(!store.state.operations.is_empty());
        assert_eq!(
            store
                .state
                .operations
                .iter()
                .map(|op| op.server_seq)
                .collect::<Vec<_>>(),
            vec![3, 4, 5]
        );
        assert_eq!(
            store.state.confirmed_op_ids,
            vec!["op-multi-1".to_owned(), "op-multi-2".to_owned()]
        );
        // B 未确认的 seq 3..5 仍然可以拉取。
        let remaining = b_sync(&mut store, 2, 2, 100);
        assert_eq!(remaining.pull.len(), 3);
        assert_eq!(remaining.cursor, 5);

        // B 补上 ack=5 后，阈值 = 5，全部操作被裁剪。
        let final_round = b_sync(&mut store, 5, 5, 100);
        assert!(final_round.pull.is_empty());
        assert!(store.state.operations.is_empty());
        assert_eq!(store.state.confirmed_op_ids.len(), 5);
    }

    #[test]
    fn repushing_confirmed_operation_is_skipped_as_duplicate() {
        let directory = tempdir().unwrap();
        let credentials = credentials("device-windows-local", 1);
        let mut store = LocalServerStore::new_with_clock(
            directory.path().join("state.json"),
            &credentials,
            "Windows",
            || 1_000,
        )
        .unwrap();
        let pushed = operation("op-confirmed-repush", 3);
        sync_envelope(&mut store, &credentials, 0, Some(0), vec![pushed.clone()]);
        sync_envelope(&mut store, &credentials, 1, Some(1), Vec::new());
        assert!(store.state.operations.is_empty());
        assert!(store.state.confirmed_op_ids.contains(&pushed.op_id));

        // 同一 opId 再次推送：跳过（不在 operations 也不重新入队），按重复计数。
        let replay = sync_envelope(&mut store, &credentials, 1, Some(1), vec![pushed.clone()]);
        assert_eq!(replay.push.inserted, 0);
        assert_eq!(replay.push.duplicates, 1);
        assert!(store.state.operations.is_empty());
        assert_eq!(store.state.confirmed_op_ids.len(), 1);
    }

    #[test]
    fn legacy_state_file_without_ack_fields_loads_with_zero_watermarks() {
        let directory = tempdir().unwrap();
        let state_path = directory.path().join("state.json");
        let credentials = credentials("device-windows-local", 1);
        let token_hash = credential_hash(token(&credentials));
        fs::write(
            &state_path,
            format!(
                r#"{{
  "version": 1,
  "vaultId": "vault-local-network",
  "nextServerSequence": 1,
  "devices": [
    {{ "id": "device-windows-local", "name": "Windows 旧版主机", "platform": "windows",
       "publicKey": null, "tokenHash": "{token_hash}",
       "createdAt": 1000, "lastSeenAt": 1000, "revokedAt": null }}
  ],
  "operations": []
}}"#
            ),
        )
        .unwrap();

        let mut store =
            LocalServerStore::new_with_clock(&state_path, &credentials, "Windows", || 2_000)
                .unwrap();
        assert_eq!(store.state.devices[0].ack_cursor, 0);
        assert!(store.state.confirmed_op_ids.is_empty());

        // 旧格式状态文件仍可正常同步，ack 从零开始推进。
        let first = sync_envelope(
            &mut store,
            &credentials,
            0,
            Some(0),
            vec![operation("op-legacy-1", 1)],
        );
        assert_eq!(first.cursor, 1);
        sync_envelope(&mut store, &credentials, 1, Some(1), Vec::new());
        assert!(store.state.operations.is_empty());
        assert_eq!(store.state.devices[0].ack_cursor, 1);
    }
}
