use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::thread;
use std::time::Duration;
use woo_todo_core::{
    EncryptedEnvelope, PairingKeyPair, SyncData, SyncRequest, base64url_decode, base64url_encode,
    open_pairing_vault_key, random_bytes,
};
use zeroize::Zeroize;

use crate::credentials::{SyncCredentials, SyncMode};
use crate::http::{EndpointScope, HttpRequest, HttpResponse, HttpTransport, ValidatedEndpoint};

const MAXIMUM_RESPONSE_BYTES: usize = 3 * 1_024 * 1_024;
const MAXIMUM_DEVICE_NAME_CHARACTERS: usize = 80;
const MAXIMUM_PREFLIGHT_PAGES: usize = 1_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DevicePlatform {
    Macos,
    Android,
    Windows,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub platform: DevicePlatform,
    pub public_key: Option<String>,
    pub created_at: i64,
    pub last_seen_at: Option<i64>,
    pub revoked_at: Option<i64>,
    pub is_current: bool,
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

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreatedPairing {
    pub pairing_id: String,
    pub pairing_secret: String,
    pub initiator_public_key: String,
    pub expires_at: i64,
    pub server_time: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingClaimInfo {
    pub device_id: String,
    pub name: String,
    pub platform: DevicePlatform,
    pub public_key: String,
    pub claimed_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingState {
    pub pairing_id: String,
    pub status: PairingStatus,
    pub expires_at: i64,
    pub claim: Option<PairingClaimInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreatedVault {
    pub endpoint: String,
    pub vault_id: String,
    pub device_id: String,
    pub device_token: String,
    pub vault_key: String,
}

impl CreatedVault {
    pub fn into_credentials(self) -> SyncCredentials {
        SyncCredentials::Worker {
            endpoint: self.endpoint,
            vault_id: self.vault_id,
            device_id: self.device_id,
            device_token: self.device_token,
            vault_key: self.vault_key,
        }
    }
}

pub struct WorkerClient<T: HttpTransport> {
    endpoint: ValidatedEndpoint,
    token: String,
    transport: T,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingLink {
    pub endpoint: String,
    pub pairing_id: String,
    pub pairing_secret: String,
    pub initiator_public_key: String,
    pub vault_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JoinedPairing {
    pub vault_id: String,
    pub device_id: String,
    pub device_token: String,
    pub vault_key: String,
}

impl PairingLink {
    pub fn parse(source: &str) -> Result<Self, String> {
        let url = url::Url::parse(source).map_err(|_| "配对链接格式无效".to_owned())?;
        if !url.scheme().eq_ignore_ascii_case("wootodo")
            || !url
                .host_str()
                .is_some_and(|host| host.eq_ignore_ascii_case("pair"))
            || url.path() != ""
            || url.fragment().is_some()
        {
            return Err("配对链接格式无效".to_owned());
        }
        let mut values = std::collections::BTreeMap::new();
        for (key, value) in url.query_pairs() {
            if !matches!(
                key.as_ref(),
                "endpoint" | "pairingId" | "pairingSecret" | "initiatorPublicKey" | "vaultId"
            ) || values
                .insert(key.into_owned(), value.into_owned())
                .is_some()
            {
                return Err("配对链接包含未知或重复字段".to_owned());
            }
        }
        for key in [
            "endpoint",
            "pairingId",
            "pairingSecret",
            "initiatorPublicKey",
        ] {
            if values.get(key).is_none_or(String::is_empty) {
                return Err(format!("配对链接缺少字段：{key}"));
            }
        }
        let endpoint = values.remove("endpoint").expect("已检查 endpoint");
        let parsed_endpoint =
            url::Url::parse(&endpoint).map_err(|_| "配对服务地址无效".to_owned())?;
        let scope = if parsed_endpoint.scheme().eq_ignore_ascii_case("https") {
            EndpointScope::Worker
        } else if parsed_endpoint.scheme().eq_ignore_ascii_case("http") {
            EndpointScope::LocalNetwork
        } else {
            return Err("配对服务只支持 HTTPS 或局域网 HTTP".to_owned());
        };
        ValidatedEndpoint::parse(&endpoint, scope)?;
        let pairing_id = values.remove("pairingId").expect("已检查 pairingId");
        validate_pairing_identifier(&pairing_id)?;
        let pairing_secret = values
            .remove("pairingSecret")
            .expect("已检查 pairingSecret");
        if base64url_decode(&pairing_secret).map_or(true, |value| value.len() != 32) {
            return Err("配对 secret 必须是 32 字节 Base64URL".to_owned());
        }
        let initiator_public_key = values
            .remove("initiatorPublicKey")
            .expect("已检查 initiatorPublicKey");
        if base64url_decode(&initiator_public_key).map_or(true, |value| value.len() != 32) {
            return Err("配对发起方公钥必须是 32 字节 Base64URL".to_owned());
        }
        let vault_id = values.remove("vaultId");
        if let Some(value) = &vault_id {
            validate_identifier(value, "vaultId")?;
        }
        Ok(Self {
            endpoint,
            pairing_id,
            pairing_secret,
            initiator_public_key,
            vault_id,
        })
    }
}

impl<T: HttpTransport> WorkerClient<T> {
    pub fn new(credentials: &SyncCredentials, transport: T) -> Result<Self, String> {
        credentials.validate()?;
        let scope = match credentials.mode() {
            SyncMode::Worker => EndpointScope::Worker,
            SyncMode::LocalNetwork => EndpointScope::LocalNetwork,
            SyncMode::WebDav => return Err("当前安全凭据不是 Worker 或同一网络同步".to_owned()),
        };
        let endpoint = ValidatedEndpoint::parse(
            credentials
                .endpoint()
                .ok_or_else(|| "同步凭据缺少服务地址".to_owned())?,
            scope,
        )?;
        Ok(Self {
            endpoint,
            token: credentials
                .device_token()
                .ok_or_else(|| "同步凭据缺少设备令牌".to_owned())?
                .to_owned(),
            transport,
        })
    }

    pub fn for_pairing(link: &PairingLink, transport: T) -> Result<Self, String> {
        let parsed =
            url::Url::parse(&link.endpoint).map_err(|_| "配对服务地址格式无效".to_owned())?;
        let scope = if parsed.scheme().eq_ignore_ascii_case("https") {
            EndpointScope::Worker
        } else if parsed.scheme().eq_ignore_ascii_case("http") {
            EndpointScope::LocalNetwork
        } else {
            return Err("配对服务只支持 HTTPS 或局域网 HTTP".to_owned());
        };
        Ok(Self {
            endpoint: ValidatedEndpoint::parse(&link.endpoint, scope)?,
            token: String::new(),
            transport,
        })
    }

    pub fn create_vault(
        endpoint: &str,
        invite_code: &str,
        device_name: &str,
        transport: T,
    ) -> Result<CreatedVault, String> {
        let endpoint = ValidatedEndpoint::parse(endpoint, EndpointScope::Worker)?;
        validate_invite_code(invite_code)?;
        validate_device_name(device_name)?;
        let request = CreateVaultRequest {
            device: DeviceRegistration {
                name: device_name.to_owned(),
                platform: DevicePlatform::Windows,
                public_key: None,
            },
            recovery_envelope: None,
        };
        let body = serde_json::to_vec(&request)
            .map_err(|error| format!("无法编码创建同步空间请求：{error}"))?;
        let response = transport.execute(HttpRequest {
            method: "POST",
            url: endpoint.append_path(&["v1", "vaults"])?,
            headers: vec![
                ("Content-Type".to_owned(), "application/json".to_owned()),
                ("X-Woo-Todo-Invite-Code".to_owned(), invite_code.to_owned()),
            ],
            body,
            maximum_response_bytes: MAXIMUM_RESPONSE_BYTES,
        })?;
        let data: CreateVaultData = decode_response(response, &[201])?;
        validate_identifier(&data.vault_id, "vaultId")?;
        validate_identifier(&data.device.id, "device.id")?;
        validate_device_name(&data.device.name)?;
        if data.device.platform != DevicePlatform::Windows
            || base64url_decode(&data.device.token).map_or(true, |value| value.len() != 32)
            || data.server_time < 0
        {
            return Err("创建同步空间响应字段无效".to_owned());
        }
        let vault_key = base64url_encode(
            &random_bytes::<32>().map_err(|error| format!("无法生成同步密钥：{error}"))?,
        );
        Ok(CreatedVault {
            endpoint: endpoint.as_str().to_owned(),
            vault_id: data.vault_id,
            device_id: data.device.id,
            device_token: data.device.token,
            vault_key,
        })
    }

    pub fn synchronize(&self, request: &SyncRequest) -> Result<SyncData, String> {
        request
            .validate()
            .map_err(|error| format!("同步请求无效：{error}"))?;
        let response: SyncData = self.send_json("POST", &["v1", "sync"], request, &[200])?;
        response
            .validate()
            .map_err(|error| format!("同步响应无效：{error}"))?;
        Ok(response)
    }

    pub fn list_devices(&self) -> Result<Vec<DeviceInfo>, String> {
        let response = self.send("GET", &["v1", "devices"], Vec::new(), &[200])?;
        let data: DeviceListData = decode_response(response, &[200])?;
        for device in &data.devices {
            validate_identifier(&device.id, "device.id")?;
            validate_device_name(&device.name)?;
            if device.created_at < 0
                || device.last_seen_at.is_some_and(|value| value < 0)
                || device.revoked_at.is_some_and(|value| value < 0)
            {
                return Err("设备列表包含无效时间戳".to_owned());
            }
        }
        Ok(data.devices)
    }

    pub fn highest_lamport(&self) -> Result<i64, String> {
        let mut cursor = 0;
        let mut highest = 0;
        for _ in 0..MAXIMUM_PREFLIGHT_PAGES {
            let response = self.synchronize(&SyncRequest {
                cursor,
                ack: None,
                pull_limit: Some(100),
                push: Vec::new(),
            })?;
            highest = response
                .pull
                .iter()
                .map(|operation| operation.lamport)
                .max()
                .unwrap_or(0)
                .max(highest);
            if !response.has_more {
                return Ok(highest);
            }
            if response.cursor <= cursor {
                return Err("同步服务在预检期间未推进游标".to_owned());
            }
            cursor = response.cursor;
        }
        Err("同步服务在预检期间超过分页安全上限".to_owned())
    }

    pub fn revoke_device(&self, device_id: &str) -> Result<i64, String> {
        validate_identifier(device_id, "deviceId")?;
        let data: RevokeDeviceData = self.send_json(
            "POST",
            &["v1", "devices", device_id, "revoke"],
            &EmptyObject {},
            &[200],
        )?;
        if data.device_id != device_id || data.revoked_at < 0 {
            return Err("撤销设备响应无效".to_owned());
        }
        Ok(data.revoked_at)
    }

    pub fn create_pairing(&self, public_key: &str) -> Result<CreatedPairing, String> {
        if base64url_decode(public_key).map_or(true, |value| value.len() != 32) {
            return Err("发起方 X25519 公钥无效".to_owned());
        }
        let data: CreatedPairing = self.send_json(
            "POST",
            &["v1", "pairings"],
            &CreatePairingRequest {
                public_key: public_key.to_owned(),
            },
            &[201],
        )?;
        validate_pairing_identifier(&data.pairing_id)?;
        if data.initiator_public_key != public_key
            || base64url_decode(&data.pairing_secret).map_or(true, |value| value.len() != 32)
            || data.expires_at <= data.server_time
            || data.server_time < 0
        {
            return Err("创建配对会话响应无效".to_owned());
        }
        Ok(data)
    }

    pub fn pairing_status(&self, pairing_id: &str) -> Result<PairingState, String> {
        validate_pairing_identifier(pairing_id)?;
        let response = self.send("GET", &["v1", "pairings", pairing_id], Vec::new(), &[200])?;
        let data: PairingState = decode_response(response, &[200])?;
        validate_pairing_state(pairing_id, &data)?;
        Ok(data)
    }

    pub fn join_pairing(
        &self,
        link: &PairingLink,
        device_name: &str,
        expected_vault_id: Option<&str>,
    ) -> Result<JoinedPairing, String> {
        let key_pair = PairingKeyPair::generate().map_err(|error| error.to_string())?;
        let mut token_bytes = random_bytes::<32>().map_err(|error| error.to_string())?;
        let device_token = base64url_encode(&token_bytes);
        let public_key = key_pair.public_key_base64url();
        let result = (|| {
            validate_pairing_identifier(&link.pairing_id)?;
            validate_device_name(device_name)?;
            let claim = self.claim_pairing(
                &link.pairing_id,
                &link.pairing_secret,
                &device_token,
                device_name,
                &public_key,
            )?;
            if claim.pairing_id != link.pairing_id
                || claim.status != PairingStatus::Claimed
                || claim.expires_at <= 0
            {
                return Err("配对认领响应无效".to_owned());
            }
            let session_key = zeroize::Zeroizing::new(
                key_pair
                    .session_key_base64url(
                        &link.initiator_public_key,
                        &link.pairing_id,
                        &link.pairing_secret,
                    )
                    .map_err(|error| error.to_string())?,
            );
            let result = loop {
                let value =
                    self.pairing_result(&link.pairing_id, &link.pairing_secret, &device_token)?;
                if value.pairing_id != link.pairing_id || value.expires_at != claim.expires_at {
                    return Err("配对结果与当前会话不一致".to_owned());
                }
                match value.status {
                    PairingStatus::Claimed => {
                        if value.vault_id.is_some()
                            || value.device_id.is_some()
                            || value.initiator_public_key.is_some()
                            || value.vault_key_envelope.is_some()
                        {
                            return Err("配对等待结果携带了不应出现的密钥字段".to_owned());
                        }
                        if chrono::Utc::now().timestamp_millis()
                            >= value.expires_at.saturating_add(30_000)
                        {
                            return Err("配对二维码已过期，请重新生成".to_owned());
                        }
                        thread::sleep(Duration::from_secs(2));
                    }
                    PairingStatus::Confirmed => break value,
                    PairingStatus::Expired => {
                        return Err("配对二维码已过期，请重新生成".to_owned());
                    }
                    PairingStatus::Canceled => {
                        return Err("配对已取消，请重新生成二维码".to_owned());
                    }
                    PairingStatus::Open => return Err("配对结果状态无效".to_owned()),
                }
            };
            let vault_id = result
                .vault_id
                .filter(|value| !value.is_empty())
                .ok_or_else(|| "配对结果缺少同步空间标识".to_owned())?;
            validate_identifier(&vault_id, "vaultId")?;
            if link
                .vault_id
                .as_deref()
                .is_some_and(|value| value != vault_id)
                || expected_vault_id.is_some_and(|value| value != vault_id)
            {
                return Err("配对二维码属于另一个同步空间，Windows 没有切换本地同步身份".to_owned());
            }
            let device_id = result
                .device_id
                .filter(|value| !value.is_empty())
                .ok_or_else(|| "配对结果缺少设备标识".to_owned())?;
            validate_identifier(&device_id, "deviceId")?;
            if device_id != claim.device_id {
                return Err("配对结果中的设备标识与认领响应不一致".to_owned());
            }
            if result.initiator_public_key.as_deref() != Some(link.initiator_public_key.as_str()) {
                return Err("配对结果中的发起方公钥不一致".to_owned());
            }
            let envelope = result
                .vault_key_envelope
                .ok_or_else(|| "配对结果缺少同步密钥".to_owned())?;
            let mut vault_key =
                open_pairing_vault_key(&envelope, &session_key[..], &link.pairing_id, &device_id)
                    .map_err(|error| error.to_string())?;
            let encoded_vault_key = base64url_encode(&vault_key);
            vault_key.zeroize();
            Ok(JoinedPairing {
                vault_id,
                device_id,
                device_token: device_token.clone(),
                vault_key: encoded_vault_key,
            })
        })();
        token_bytes.zeroize();
        result
    }

    fn claim_pairing(
        &self,
        pairing_id: &str,
        pairing_secret: &str,
        device_token: &str,
        device_name: &str,
        public_key: &str,
    ) -> Result<PairingClaimData, String> {
        let data: PairingClaimData = self.send_public_json(
            "POST",
            &["v1", "pairings", pairing_id, "claim"],
            &PairingClaimRequest {
                pairing_secret: pairing_secret.to_owned(),
                device_token: device_token.to_owned(),
                device: DeviceRegistration {
                    name: device_name.trim().to_owned(),
                    platform: DevicePlatform::Windows,
                    public_key: Some(public_key.to_owned()),
                },
            },
            &[202],
        )?;
        validate_identifier(&data.device_id, "deviceId")?;
        Ok(data)
    }

    fn pairing_result(
        &self,
        pairing_id: &str,
        pairing_secret: &str,
        device_token: &str,
    ) -> Result<PairingResultData, String> {
        self.send_public_json(
            "POST",
            &["v1", "pairings", pairing_id, "result"],
            &PairingResultRequest {
                pairing_secret: pairing_secret.to_owned(),
                device_token: device_token.to_owned(),
            },
            &[200, 202],
        )
    }

    pub fn confirm_pairing(
        &self,
        pairing_id: &str,
        claimed_device_id: &str,
        vault_key_envelope: EncryptedEnvelope,
    ) -> Result<(), String> {
        validate_pairing_identifier(pairing_id)?;
        validate_identifier(claimed_device_id, "deviceId")?;
        if base64url_decode(&vault_key_envelope.nonce).map_or(true, |value| value.len() != 12)
            || base64url_decode(&vault_key_envelope.ciphertext)
                .map_or(true, |value| value.len() < 16)
        {
            return Err("配对密钥信封无效".to_owned());
        }
        let data: PairingConfirmData = self.send_json(
            "POST",
            &["v1", "pairings", pairing_id, "confirm"],
            &PairingConfirmRequest { vault_key_envelope },
            &[200],
        )?;
        if data.pairing_id != pairing_id
            || data.status != PairingStatus::Confirmed
            || data.device_id != claimed_device_id
        {
            return Err("确认配对响应与当前会话不一致".to_owned());
        }
        Ok(())
    }

    fn send_public_json<Input: Serialize, Output: DeserializeOwned>(
        &self,
        method: &'static str,
        path: &[&str],
        input: &Input,
        accepted: &[u16],
    ) -> Result<Output, String> {
        let body =
            serde_json::to_vec(input).map_err(|error| format!("无法编码配对请求：{error}"))?;
        let response = self.transport.execute(HttpRequest {
            method,
            url: self.endpoint.append_path(path)?,
            headers: vec![("Content-Type".to_owned(), "application/json".to_owned())],
            body,
            maximum_response_bytes: MAXIMUM_RESPONSE_BYTES,
        })?;
        decode_response(response, accepted)
    }

    fn send_json<Input: Serialize, Output: DeserializeOwned>(
        &self,
        method: &'static str,
        path: &[&str],
        input: &Input,
        accepted: &[u16],
    ) -> Result<Output, String> {
        let body =
            serde_json::to_vec(input).map_err(|error| format!("无法编码同步请求：{error}"))?;
        decode_response(self.send(method, path, body, accepted)?, accepted)
    }

    fn send(
        &self,
        method: &'static str,
        path: &[&str],
        body: Vec<u8>,
        _accepted: &[u16],
    ) -> Result<HttpResponse, String> {
        self.transport.execute(HttpRequest {
            method,
            url: self.endpoint.append_path(path)?,
            headers: vec![
                ("Authorization".to_owned(), format!("Bearer {}", self.token)),
                ("Content-Type".to_owned(), "application/json".to_owned()),
            ],
            body,
            maximum_response_bytes: MAXIMUM_RESPONSE_BYTES,
        })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CreateVaultRequest {
    device: DeviceRegistration,
    #[serde(skip_serializing_if = "Option::is_none")]
    recovery_envelope: Option<woo_todo_core::EncryptedEnvelope>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CreatePairingRequest {
    public_key: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingClaimRequest {
    pairing_secret: String,
    device_token: String,
    device: DeviceRegistration,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairingClaimData {
    pairing_id: String,
    status: PairingStatus,
    device_id: String,
    expires_at: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingResultRequest {
    pairing_secret: String,
    device_token: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairingResultData {
    pairing_id: String,
    status: PairingStatus,
    vault_id: Option<String>,
    device_id: Option<String>,
    initiator_public_key: Option<String>,
    vault_key_envelope: Option<EncryptedEnvelope>,
    expires_at: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingConfirmRequest {
    vault_key_envelope: EncryptedEnvelope,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairingConfirmData {
    pairing_id: String,
    status: PairingStatus,
    device_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceRegistration {
    name: String,
    platform: DevicePlatform,
    #[serde(skip_serializing_if = "Option::is_none")]
    public_key: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateVaultData {
    vault_id: String,
    device: CreatedDevice,
    server_time: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreatedDevice {
    id: String,
    name: String,
    platform: DevicePlatform,
    token: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DeviceListData {
    devices: Vec<DeviceInfo>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RevokeDeviceData {
    device_id: String,
    revoked_at: i64,
}

#[derive(Serialize)]
struct EmptyObject {}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SuccessEnvelope<T> {
    ok: bool,
    data: T,
    request_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FailureEnvelope {
    ok: bool,
    error: FailurePayload,
    #[serde(default)]
    request_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FailurePayload {
    code: String,
    message: String,
    #[serde(default)]
    details: Option<Value>,
}

fn decode_response<T: DeserializeOwned>(
    response: HttpResponse,
    accepted: &[u16],
) -> Result<T, String> {
    if !accepted.contains(&response.status) {
        let failure: FailureEnvelope = serde_json::from_slice(&response.body)
            .map_err(|_| format!("同步服务返回 HTTP {}", response.status))?;
        if failure.ok
            || failure.error.code.is_empty()
            || failure.error.message.is_empty()
            || failure
                .request_id
                .as_ref()
                .is_some_and(|value| value.is_empty())
        {
            return Err(format!("同步服务返回 HTTP {}", response.status));
        }
        let _ = failure.error.details;
        return Err(format!("{}：{}", failure.error.code, failure.error.message));
    }
    let envelope: SuccessEnvelope<T> = serde_json::from_slice(&response.body)
        .map_err(|_| "同步服务成功响应 JSON 格式无效".to_owned())?;
    if !envelope.ok || envelope.request_id.is_empty() {
        return Err("同步服务成功响应包络无效".to_owned());
    }
    Ok(envelope.data)
}

fn validate_invite_code(value: &str) -> Result<(), String> {
    if !(16..=256).contains(&value.len())
        || !value
            .bytes()
            .all(|value| value.is_ascii_graphic() && !value.is_ascii_whitespace())
    {
        return Err("创建空间邀请码须为 16 到 256 位无空格可打印 ASCII 字符".to_owned());
    }
    Ok(())
}

fn validate_device_name(value: &str) -> Result<(), String> {
    let normalized = value.trim();
    if normalized.is_empty()
        || normalized.chars().count() > MAXIMUM_DEVICE_NAME_CHARACTERS
        || normalized.chars().any(char::is_control)
    {
        return Err("设备名称长度或字符无效".to_owned());
    }
    Ok(())
}

fn validate_identifier(value: &str, field: &str) -> Result<(), String> {
    if !(8..=128).contains(&value.len())
        || !value.bytes().enumerate().all(|(index, value)| {
            value.is_ascii_alphanumeric()
                || (index > 0 && matches!(value, b'.' | b'_' | b':' | b'-'))
        })
    {
        return Err(format!("{field} 标识符无效"));
    }
    Ok(())
}

fn validate_pairing_identifier(value: &str) -> Result<(), String> {
    validate_identifier(value, "pairingId")
}

fn validate_pairing_state(pairing_id: &str, value: &PairingState) -> Result<(), String> {
    if value.pairing_id != pairing_id || value.expires_at <= 0 {
        return Err("配对状态与当前会话不一致".to_owned());
    }
    match (&value.status, &value.claim) {
        (PairingStatus::Open, None)
        | (PairingStatus::Expired, None)
        | (PairingStatus::Canceled, None) => {}
        (PairingStatus::Claimed | PairingStatus::Confirmed, Some(claim)) => {
            validate_identifier(&claim.device_id, "claim.deviceId")?;
            validate_device_name(&claim.name)?;
            if base64url_decode(&claim.public_key).map_or(true, |decoded| decoded.len() != 32)
                || claim.claimed_at < 0
            {
                return Err("配对认领信息无效".to_owned());
            }
        }
        _ => return Err("配对状态字段组合无效".to_owned()),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::Mutex;

    use super::*;

    struct MockTransport {
        responses: Mutex<VecDeque<HttpResponse>>,
        requests: Mutex<Vec<HttpRequest>>,
    }

    impl MockTransport {
        fn new(response: HttpResponse) -> Self {
            Self {
                responses: Mutex::new(VecDeque::from([response])),
                requests: Mutex::new(Vec::new()),
            }
        }

        fn with(responses: impl IntoIterator<Item = HttpResponse>) -> Self {
            Self {
                responses: Mutex::new(responses.into_iter().collect()),
                requests: Mutex::new(Vec::new()),
            }
        }
    }

    impl HttpTransport for MockTransport {
        fn execute(&self, request: HttpRequest) -> Result<HttpResponse, String> {
            request.validate()?;
            self.requests.lock().unwrap().push(request);
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .ok_or_else(|| "测试响应不足".to_owned())
        }
    }

    fn response(status: u16, body: &str) -> HttpResponse {
        HttpResponse {
            status,
            body: body.as_bytes().to_vec(),
        }
    }

    fn credentials() -> SyncCredentials {
        SyncCredentials::Worker {
            endpoint: "https://sync.example.com".to_owned(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            device_token: base64url_encode(&[7; 32]),
            vault_key: base64url_encode(&[8; 32]),
        }
    }

    fn sync_page(cursor: i64, has_more: bool, lamport: i64, request_id: &str) -> HttpResponse {
        let ciphertext = base64url_encode(&[2; 32]);
        let nonce = base64url_encode(&[3; 12]);
        response(
            200,
            &format!(
                r#"{{"ok":true,"data":{{"push":{{"received":0,"inserted":0,"duplicates":0}},"pull":[{{"serverSeq":{cursor},"opId":"operation-{cursor:08}","deviceId":"device-remote-1","entityId":"task-remote-0001","kind":"upsert","lamport":{lamport},"ciphertext":"{ciphertext}","nonce":"{nonce}","createdAt":1000}}],"cursor":{cursor},"hasMore":{has_more},"serverTime":1000}},"requestId":"{request_id}"}}"#
            ),
        )
    }

    #[test]
    fn pairing_link_parses_vault_id_and_rejects_unknown_fields() {
        let secret = base64url_encode(&[4; 32]);
        let public_key = base64url_encode(&[5; 32]);
        let source = format!(
            "wootodo://pair?endpoint=https%3A%2F%2Fsync.example.com&pairingId=pair-demo-001&pairingSecret={secret}&initiatorPublicKey={public_key}&vaultId=vault-demo-001"
        );
        let parsed = PairingLink::parse(&source).unwrap();
        assert_eq!(parsed.endpoint, "https://sync.example.com");
        assert_eq!(parsed.vault_id.as_deref(), Some("vault-demo-001"));
        assert!(PairingLink::parse(&format!("{source}&extra=1")).is_err());
        assert!(PairingLink::parse(&format!("{source}&vaultId=vault-demo-002")).is_err());
    }

    #[test]
    fn legacy_pairing_link_without_vault_id_remains_supported() {
        let secret = base64url_encode(&[4; 32]);
        let public_key = base64url_encode(&[5; 32]);
        let source = format!(
            "wootodo://pair?endpoint=https%3A%2F%2Fsync.example.com&pairingId=pair-demo-001&pairingSecret={secret}&initiatorPublicKey={public_key}"
        );
        assert_eq!(PairingLink::parse(&source).unwrap().vault_id, None);
    }

    #[test]
    fn create_vault_registers_windows_and_keeps_key_client_side() {
        let token = base64url_encode(&[7; 32]);
        let transport = MockTransport::new(response(
            201,
            &format!(
                r#"{{"ok":true,"data":{{"vaultId":"vault-windows","device":{{"id":"device-windows-1","name":"Windows PC","platform":"windows","token":"{token}"}},"serverTime":1000}},"requestId":"request-1"}}"#
            ),
        ));
        let created = WorkerClient::create_vault(
            "https://sync.example.com",
            "1234567890abcdef",
            "Windows PC",
            transport,
        )
        .unwrap();
        assert_eq!(created.device_token, token);
        assert_eq!(base64url_decode(&created.vault_key).unwrap().len(), 32);
        assert_eq!(created.into_credentials().mode(), SyncMode::Worker);
    }

    #[test]
    fn highest_lamport_scans_all_pages_without_pushing() {
        let transport = MockTransport::with([
            sync_page(1, true, 7, "request-lamport-1"),
            sync_page(2, false, 42, "request-lamport-2"),
        ]);
        let client = WorkerClient::new(&credentials(), transport).unwrap();

        assert_eq!(client.highest_lamport().unwrap(), 42);
    }

    #[test]
    fn server_failure_is_decoded_without_echoing_request_secrets() {
        let error = decode_response::<Value>(
            response(
                401,
                r#"{"ok":false,"error":{"code":"UNAUTHORIZED","message":"设备令牌无效"},"requestId":"request-2"}"#,
            ),
            &[200],
        )
        .unwrap_err();
        assert_eq!(error, "UNAUTHORIZED：设备令牌无效");
    }

    #[test]
    fn success_and_failure_envelopes_are_strict() {
        assert!(
            decode_response::<Value>(
                response(
                    200,
                    r#"{"ok":true,"data":{},"requestId":"request-3","extra":1}"#,
                ),
                &[200],
            )
            .is_err()
        );
        assert!(
            decode_response::<Value>(
                response(
                    400,
                    r#"{"ok":false,"error":{"code":"BAD","message":"bad","extra":1}}"#,
                ),
                &[200],
            )
            .is_err()
        );
    }

    #[test]
    fn pairing_creation_validates_echoed_public_key_and_expiry() {
        let public_key = base64url_encode(&[3; 32]);
        let secret = base64url_encode(&[4; 32]);
        let transport = MockTransport::new(response(
            201,
            &format!(
                r#"{{"ok":true,"data":{{"pairingId":"pair-windows-1","pairingSecret":"{secret}","initiatorPublicKey":"{public_key}","expiresAt":601000,"serverTime":1000}},"requestId":"request-pair-1"}}"#
            ),
        ));
        let created = WorkerClient::new(&credentials(), transport)
            .unwrap()
            .create_pairing(&public_key)
            .unwrap();
        assert_eq!(created.pairing_id, "pair-windows-1");
        assert_eq!(created.pairing_secret, secret);
    }

    #[test]
    fn pairing_status_requires_a_valid_claim() {
        let claim_key = base64url_encode(&[5; 32]);
        let transport = MockTransport::new(response(
            200,
            &format!(
                r#"{{"ok":true,"data":{{"pairingId":"pair-windows-1","status":"claimed","expiresAt":601000,"claim":{{"deviceId":"device-android-1","name":"Android","platform":"android","publicKey":"{claim_key}","claimedAt":2000}}}},"requestId":"request-pair-2"}}"#
            ),
        ));
        let state = WorkerClient::new(&credentials(), transport)
            .unwrap()
            .pairing_status("pair-windows-1")
            .unwrap();
        assert_eq!(state.status, PairingStatus::Claimed);
        assert_eq!(state.claim.unwrap().device_id, "device-android-1");
    }

    #[test]
    fn pairing_confirmation_rejects_a_mismatched_device() {
        let transport = MockTransport::new(response(
            200,
            r#"{"ok":true,"data":{"pairingId":"pair-windows-1","status":"confirmed","deviceId":"device-other-1"},"requestId":"request-pair-3"}"#,
        ));
        let error = WorkerClient::new(&credentials(), transport)
            .unwrap()
            .confirm_pairing(
                "pair-windows-1",
                "device-android-1",
                EncryptedEnvelope {
                    nonce: base64url_encode(&[1; 12]),
                    ciphertext: base64url_encode(&[2; 48]),
                },
            )
            .unwrap_err();
        assert_eq!(error, "确认配对响应与当前会话不一致");
    }
}
