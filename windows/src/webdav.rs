use std::collections::BTreeSet;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use quick_xml::Reader;
use quick_xml::events::Event;
use url::Url;
use woo_todo_core::WebDavOperation;

use crate::credentials::SyncCredentials;
use crate::http::{EndpointScope, HttpRequest, HttpResponse, HttpTransport, ValidatedEndpoint};

const MAXIMUM_OBJECT_BYTES: usize = 64 * 1_024;
const MAXIMUM_PROPFIND_BYTES: usize = 2 * 1_024 * 1_024;
const RETRY_DELAYS: [Duration; 3] = [
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
];

pub struct WebDavClient<T: HttpTransport> {
    endpoint: ValidatedEndpoint,
    username: String,
    app_password: String,
    vault_id: String,
    device_id: String,
    transport: T,
    retry_delays: Vec<Duration>,
    retry_sleep: fn(Duration),
}

impl<T: HttpTransport> WebDavClient<T> {
    pub fn new(credentials: &SyncCredentials, transport: T) -> Result<Self, String> {
        Self::new_with_options(
            credentials,
            transport,
            RETRY_DELAYS.to_vec(),
            std::thread::sleep,
        )
    }

    fn new_with_options(
        credentials: &SyncCredentials,
        transport: T,
        retry_delays: Vec<Duration>,
        retry_sleep: fn(Duration),
    ) -> Result<Self, String> {
        credentials.validate()?;
        let (username, app_password) = credentials
            .webdav_login()
            .ok_or_else(|| "当前安全凭据不是 WebDAV 同步方式".to_owned())?;
        let endpoint = credentials
            .endpoint()
            .ok_or_else(|| "WebDAV 同步凭据缺少服务地址".to_owned())?;
        Ok(Self {
            endpoint: ValidatedEndpoint::parse(endpoint, EndpointScope::WebDav)?,
            username: username.to_owned(),
            app_password: app_password.to_owned(),
            vault_id: credentials.vault_id().to_owned(),
            device_id: credentials.device_id().to_owned(),
            transport,
            retry_delays,
            retry_sleep,
        })
    }

    pub fn vault_id(&self) -> &str {
        &self.vault_id
    }

    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    pub fn ensure_collections(&self) -> Result<(), String> {
        for path in [
            vec!["v1"],
            vec!["v1", self.vault_id.as_str()],
            vec!["v1", self.vault_id.as_str(), "ops"],
        ] {
            self.request("MKCOL", &path, Vec::new(), &[], &[201, 405, 409], 1_024)?;
        }
        Ok(())
    }

    pub fn put(&self, operation: &WebDavOperation) -> Result<(), String> {
        operation
            .validate()
            .map_err(|error| format!("WebDAV 同步对象无效：{error}"))?;
        if operation.vault_id != self.vault_id || operation.device_id != self.device_id {
            return Err("WebDAV 同步对象与当前身份不匹配".to_owned());
        }
        let body = canonical_operation_json(operation)?;
        let path = operation_path(&operation.vault_id, &operation.op_id)?;
        let parent = path[..path.len() - 1]
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        self.request("MKCOL", &parent, Vec::new(), &[], &[201, 405, 409], 1_024)?;
        let parts = path.iter().map(String::as_str).collect::<Vec<_>>();
        let response = self.request(
            "PUT",
            &parts,
            body.clone(),
            &[("Content-Type", "application/json"), ("If-None-Match", "*")],
            &[200, 201, 204, 405, 409, 412],
            MAXIMUM_OBJECT_BYTES,
        )?;
        if matches!(response.status, 405 | 409 | 412) {
            let existing = self.get(&path)?;
            if existing != body {
                return Err(format!("WebDAV 对象发生冲突：{}", path.join("/")));
            }
        }
        Ok(())
    }

    pub fn list_operation_paths(&self) -> Result<Vec<Vec<String>>, String> {
        let root = vec!["v1".to_owned(), self.vault_id.clone(), "ops".to_owned()];
        let root_parts = root.iter().map(String::as_str).collect::<Vec<_>>();
        let shards = self
            .propfind(&root_parts)?
            .into_iter()
            .filter_map(|path| {
                (path.len() == root.len() + 1 && path[..root.len()] == root)
                    .then(|| path.last().cloned())
                    .flatten()
            })
            .filter(|value| valid_shard(value))
            .collect::<BTreeSet<_>>();
        let mut paths = BTreeSet::new();
        for shard in shards {
            let shard_path = ["v1", self.vault_id.as_str(), "ops", shard.as_str()];
            for path in self.propfind(&shard_path)? {
                if path.len() == root.len() + 2
                    && path[..root.len()] == root
                    && path[root.len()] == shard
                    && path.last().is_some_and(|value| value.ends_with(".json"))
                {
                    paths.insert(path);
                }
            }
        }
        Ok(paths.into_iter().collect())
    }

    pub fn get(&self, path: &[String]) -> Result<Vec<u8>, String> {
        let parts = path.iter().map(String::as_str).collect::<Vec<_>>();
        Ok(self
            .request("GET", &parts, Vec::new(), &[], &[200], MAXIMUM_OBJECT_BYTES)?
            .body)
    }

    pub fn get_operation(&self, path: &[String]) -> Result<WebDavOperation, String> {
        let source = self.get(path)?;
        let operation: WebDavOperation = serde_json::from_slice(&source)
            .map_err(|_| "WebDAV 同步对象 JSON 格式无效".to_owned())?;
        operation
            .validate()
            .map_err(|error| format!("WebDAV 同步对象无效：{error}"))?;
        if operation.vault_id != self.vault_id
            || operation_path(&operation.vault_id, &operation.op_id)? != path
        {
            return Err("WebDAV 同步对象路径或空间不匹配".to_owned());
        }
        Ok(operation)
    }

    pub fn highest_lamport(&self) -> Result<i64, String> {
        let mut highest = 0;
        for path in self.list_operation_paths()? {
            highest = highest.max(self.get_operation(&path)?.lamport);
        }
        Ok(highest)
    }

    fn propfind(&self, path: &[&str]) -> Result<Vec<Vec<String>>, String> {
        let body = br#"<?xml version="1.0" encoding="utf-8" ?><propfind xmlns="DAV:"><prop><resourcetype/></prop></propfind>"#.to_vec();
        let response = self.request(
            "PROPFIND",
            path,
            body,
            &[("Depth", "1"), ("Content-Type", "application/xml")],
            &[207],
            MAXIMUM_PROPFIND_BYTES,
        )?;
        parse_propfind_hrefs(&response.body, self.endpoint.as_str())
    }

    fn request(
        &self,
        method: &'static str,
        path: &[&str],
        body: Vec<u8>,
        headers: &[(&str, &str)],
        accepted_statuses: &[u16],
        maximum_response_bytes: usize,
    ) -> Result<HttpResponse, String> {
        let authorization = STANDARD.encode(format!("{}:{}", self.username, self.app_password));
        let mut request_headers =
            vec![("Authorization".to_owned(), format!("Basic {authorization}"))];
        request_headers.extend(
            headers
                .iter()
                .map(|(name, value)| ((*name).to_owned(), (*value).to_owned())),
        );
        let url = self.endpoint.append_path(path)?;
        let mut retry_index = 0;
        loop {
            let response = self.transport.execute(HttpRequest {
                method,
                url: url.clone(),
                headers: request_headers.clone(),
                body: body.clone(),
                maximum_response_bytes,
            })?;
            if accepted_statuses.contains(&response.status) {
                return Ok(response);
            }
            if !is_retryable_http_status(response.status) || retry_index >= self.retry_delays.len()
            {
                return Err(format!("WebDAV 服务返回 HTTP {}", response.status));
            }
            (self.retry_sleep)(self.retry_delays[retry_index]);
            retry_index += 1;
        }
    }
}

fn is_retryable_http_status(status: u16) -> bool {
    matches!(status, 408 | 425 | 429 | 500 | 502 | 503 | 504)
}

pub fn canonical_operation_json(operation: &WebDavOperation) -> Result<Vec<u8>, String> {
    operation
        .validate()
        .map_err(|error| format!("WebDAV 同步对象无效：{error}"))?;
    let value = serde_json::to_value(operation)
        .map_err(|error| format!("无法编码 WebDAV 同步对象：{error}"))?;
    serde_json::to_vec(&value).map_err(|error| format!("无法编码 WebDAV 同步对象：{error}"))
}

pub fn operation_path(vault_id: &str, operation_id: &str) -> Result<Vec<String>, String> {
    if !valid_path_component(vault_id)
        || operation_id.len() < 2
        || !valid_path_component(operation_id)
    {
        return Err("WebDAV 同步对象标识无效".to_owned());
    }
    Ok(vec![
        "v1".to_owned(),
        vault_id.to_owned(),
        "ops".to_owned(),
        operation_id[..2].to_owned(),
        format!("{operation_id}.json"),
    ])
}

fn valid_path_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.bytes().all(|value| {
            value.is_ascii_alphanumeric() || matches!(value, b'.' | b'_' | b':' | b'-')
        })
}

fn valid_shard(value: &str) -> bool {
    value.len() == 2 && valid_path_component(value)
}

fn parse_propfind_hrefs(source: &[u8], endpoint: &str) -> Result<Vec<Vec<String>>, String> {
    let mut reader = Reader::from_reader(source);
    reader.config_mut().trim_text(true);
    let mut current: Option<String> = None;
    let mut hrefs = Vec::new();
    loop {
        match reader.read_event() {
            Ok(Event::Start(element))
                if element.local_name().as_ref().eq_ignore_ascii_case(b"href") =>
            {
                if current.is_some() {
                    return Err("WebDAV PROPFIND href 嵌套无效".to_owned());
                }
                current = Some(String::new());
            }
            Ok(Event::Text(text)) => {
                if let Some(current) = &mut current {
                    let decoded = text
                        .xml_content()
                        .map_err(|_| "WebDAV PROPFIND 文本编码无效".to_owned())?;
                    let decoded = quick_xml::escape::unescape(&decoded)
                        .map_err(|_| "WebDAV PROPFIND 转义无效".to_owned())?;
                    current.push_str(&decoded);
                }
            }
            Ok(Event::CData(text)) => {
                if let Some(current) = &mut current {
                    current.push_str(
                        &text
                            .decode()
                            .map_err(|_| "WebDAV PROPFIND CDATA 编码无效".to_owned())?,
                    );
                }
            }
            Ok(Event::End(element))
                if element.local_name().as_ref().eq_ignore_ascii_case(b"href") =>
            {
                let value = current
                    .take()
                    .ok_or_else(|| "WebDAV PROPFIND href 结构无效".to_owned())?;
                hrefs.push(value);
            }
            Ok(Event::DocType(_)) => {
                return Err("WebDAV PROPFIND 不允许 DTD".to_owned());
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(_) => return Err("WebDAV PROPFIND XML 无法解析".to_owned()),
        }
    }
    if current.is_some() {
        return Err("WebDAV PROPFIND href 未闭合".to_owned());
    }
    let base = Url::parse(endpoint).map_err(|_| "WebDAV 服务地址无效".to_owned())?;
    let base_components = base
        .path_segments()
        .ok_or_else(|| "WebDAV 服务地址缺少路径".to_owned())?
        .filter(|value| !value.is_empty())
        .map(decode_path_segment)
        .collect::<Result<Vec<_>, _>>()?;
    let mut join_base = base.clone();
    if !join_base.path().ends_with('/') {
        join_base.set_path(&format!("{}/", join_base.path()));
    }
    let mut paths = BTreeSet::new();
    for raw in hrefs {
        let value = raw.trim();
        if value.is_empty() {
            return Err("WebDAV PROPFIND href 为空".to_owned());
        }
        validate_href_reference(value)?;
        let url = Url::parse(value)
            .or_else(|_| join_base.join(value))
            .map_err(|_| "WebDAV PROPFIND href 无效".to_owned())?;
        let components = url
            .path_segments()
            .ok_or_else(|| "WebDAV PROPFIND href 缺少路径".to_owned())?
            .filter(|value| !value.is_empty())
            .map(decode_path_segment)
            .collect::<Result<Vec<_>, _>>()?;
        if !components.starts_with(&base_components) {
            continue;
        }
        let path = components[base_components.len()..]
            .iter()
            .map(|value| (*value).to_owned())
            .collect::<Vec<_>>();
        if path.first().map(String::as_str) != Some("v1") {
            continue;
        }
        if path.iter().any(|value| !valid_path_component(value)) {
            return Err("WebDAV PROPFIND href 包含无效路径".to_owned());
        }
        paths.insert(path);
    }
    Ok(paths.into_iter().collect())
}

fn validate_href_reference(value: &str) -> Result<(), String> {
    if !has_valid_percent_encoding(value) {
        return Err("WebDAV PROPFIND href 百分号转义无效".to_owned());
    }
    let path_reference = value.split(['?', '#']).next().unwrap_or(value);
    for segment in path_reference.split('/') {
        let decoded = decode_path_segment(segment)?;
        if matches!(decoded.as_str(), "." | "..") || decoded.contains('/') || decoded.contains('\\')
        {
            return Err("WebDAV PROPFIND href 包含无效路径".to_owned());
        }
    }
    Ok(())
}

fn has_valid_percent_encoding(value: &str) -> bool {
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'%' {
            index += 1;
            continue;
        }
        if index + 2 >= bytes.len()
            || !bytes[index + 1].is_ascii_hexdigit()
            || !bytes[index + 2].is_ascii_hexdigit()
        {
            return false;
        }
        index += 3;
    }
    true
}

fn decode_path_segment(value: &str) -> Result<String, String> {
    let source = value.as_bytes();
    let mut output = Vec::with_capacity(source.len());
    let mut index = 0;
    while index < source.len() {
        if source[index] == b'%' {
            if index + 2 >= source.len() {
                return Err("WebDAV PROPFIND href 百分号转义无效".to_owned());
            }
            let high = hex_value(source[index + 1])
                .ok_or_else(|| "WebDAV PROPFIND href 百分号转义无效".to_owned())?;
            let low = hex_value(source[index + 2])
                .ok_or_else(|| "WebDAV PROPFIND href 百分号转义无效".to_owned())?;
            output.push((high << 4) | low);
            index += 3;
        } else {
            output.push(source[index]);
            index += 1;
        }
    }
    String::from_utf8(output).map_err(|_| "WebDAV PROPFIND href 路径编码无效".to_owned())
}

fn hex_value(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::Mutex;

    use woo_todo_core::{OperationKind, SyncPushOperation, base64url_encode};

    use super::*;

    #[derive(Default)]
    struct MockTransport {
        responses: Mutex<VecDeque<HttpResponse>>,
        requests: Mutex<Vec<HttpRequest>>,
    }

    impl MockTransport {
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

    fn no_sleep(_: Duration) {}

    fn key(value: char) -> String {
        std::iter::repeat_n(value, 43).collect()
    }

    fn credentials() -> SyncCredentials {
        SyncCredentials::WebDav {
            endpoint: "https://dav.example.com/remote.php/dav/files/person/woo-todo/".to_owned(),
            username: "user@example.com".to_owned(),
            app_password: "app-password".to_owned(),
            vault_id: "vault-windows".to_owned(),
            device_id: "device-windows-1".to_owned(),
            vault_key: key('a'),
        }
    }

    #[test]
    fn temporary_service_failures_are_retried_before_continuing() {
        let transport = MockTransport::with([
            HttpResponse {
                status: 503,
                body: Vec::new(),
            },
            HttpResponse {
                status: 503,
                body: Vec::new(),
            },
            HttpResponse {
                status: 503,
                body: Vec::new(),
            },
            HttpResponse {
                status: 201,
                body: Vec::new(),
            },
            HttpResponse {
                status: 201,
                body: Vec::new(),
            },
            HttpResponse {
                status: 201,
                body: Vec::new(),
            },
        ]);
        let client = WebDavClient::new_with_options(
            &credentials(),
            transport,
            vec![Duration::ZERO, Duration::ZERO, Duration::ZERO],
            no_sleep,
        )
        .unwrap();

        client.ensure_collections().unwrap();
    }

    #[test]
    fn exhausted_temporary_service_failures_return_the_http_status() {
        let transport = MockTransport::with([
            HttpResponse {
                status: 503,
                body: Vec::new(),
            },
            HttpResponse {
                status: 503,
                body: Vec::new(),
            },
            HttpResponse {
                status: 503,
                body: Vec::new(),
            },
            HttpResponse {
                status: 503,
                body: Vec::new(),
            },
        ]);
        let client = WebDavClient::new_with_options(
            &credentials(),
            transport,
            vec![Duration::ZERO, Duration::ZERO, Duration::ZERO],
            no_sleep,
        )
        .unwrap();

        assert_eq!(
            client.ensure_collections().unwrap_err(),
            "WebDAV 服务返回 HTTP 503"
        );
    }

    fn operation() -> WebDavOperation {
        WebDavOperation::from_push(
            "vault-windows",
            "device-windows-1",
            SyncPushOperation {
                op_id: "op-windows-0001".to_owned(),
                entity_id: "task-windows-0001".to_owned(),
                kind: OperationKind::Upsert,
                lamport: 7,
                ciphertext: base64url_encode(&[2; 32]),
                nonce: base64url_encode(&[3; 12]),
            },
        )
    }

    #[test]
    fn operation_json_is_sorted_and_path_is_deterministic() {
        let operation = operation();
        let source = String::from_utf8(canonical_operation_json(&operation).unwrap()).unwrap();
        assert!(source.starts_with("{\"ciphertext\":"));
        assert_eq!(
            operation_path(&operation.vault_id, &operation.op_id).unwrap(),
            ["v1", "vault-windows", "ops", "op", "op-windows-0001.json"]
        );
    }

    #[test]
    fn propfind_parser_handles_namespaces_absolute_urls_and_entities() {
        let source = br#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
          <d:response><d:href>https://dav.example.com/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/op/</d:href></d:response>
          <d:response><d:href>/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/op/op-windows-0001.json</d:href></d:response>
          <d:response><d:href>v1/vault-windows/ops/re/relative.json</d:href></d:response>
        </d:multistatus>"#;
        assert_eq!(
            parse_propfind_hrefs(
                source,
                "https://dav.example.com/remote.php/dav/files/person/woo-todo/",
            )
            .unwrap(),
            vec![
                vec!["v1", "vault-windows", "ops", "op"],
                vec!["v1", "vault-windows", "ops", "op", "op-windows-0001.json"],
                vec!["v1", "vault-windows", "ops", "re", "relative.json"],
            ]
        );
        assert!(
            parse_propfind_hrefs(
                br#"<!DOCTYPE foo><d:href>/v1/a</d:href>"#,
                "https://dav.example.com/woo-todo/",
            )
            .is_err()
        );
    }

    #[test]
    fn propfind_parser_rejects_unsafe_percent_encoded_paths() {
        for href in [
            "/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/%2e%2e/operation.json",
            "/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/op/operation%2fescape.json",
            "/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/op/operation%5cescape.json",
            "/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/op/operation%ZZ.json",
        ] {
            let source = format!(
                r#"<d:multistatus xmlns:d="DAV:"><d:response><d:href>{href}</d:href></d:response></d:multistatus>"#
            );
            assert!(
                parse_propfind_hrefs(
                    source.as_bytes(),
                    "https://dav.example.com/remote.php/dav/files/person/woo-todo/",
                )
                .is_err(),
                "{href}"
            );
        }
    }

    #[test]
    fn immutable_put_accepts_identical_replay_and_rejects_conflict() {
        let operation = operation();
        let body = canonical_operation_json(&operation).unwrap();
        let transport = MockTransport::with([
            HttpResponse {
                status: 405,
                body: Vec::new(),
            },
            HttpResponse {
                status: 412,
                body: Vec::new(),
            },
            HttpResponse {
                status: 200,
                body: body.clone(),
            },
        ]);
        let client = WebDavClient::new(&credentials(), transport).unwrap();
        client.put(&operation).unwrap();

        let transport = MockTransport::with([
            HttpResponse {
                status: 405,
                body: Vec::new(),
            },
            HttpResponse {
                status: 409,
                body: Vec::new(),
            },
            HttpResponse {
                status: 200,
                body: b"different".to_vec(),
            },
        ]);
        let client = WebDavClient::new(&credentials(), transport).unwrap();
        assert!(client.put(&operation).unwrap_err().contains("冲突"));
    }

    #[test]
    fn list_paths_scans_only_valid_shards_and_objects() {
        let root = br#"<d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/</d:href></d:response>
          <d:response><d:href>/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/op/</d:href></d:response>
          <d:response><d:href>/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/toolong/</d:href></d:response>
        </d:multistatus>"#;
        let shard = br#"<d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/op/op-windows-0001.json</d:href></d:response>
          <d:response><d:href>/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/op/ignored.txt</d:href></d:response>
        </d:multistatus>"#;
        let transport = MockTransport::with([
            HttpResponse {
                status: 207,
                body: root.to_vec(),
            },
            HttpResponse {
                status: 207,
                body: shard.to_vec(),
            },
        ]);
        let client = WebDavClient::new(&credentials(), transport).unwrap();
        assert_eq!(
            client.list_operation_paths().unwrap(),
            vec![vec![
                "v1",
                "vault-windows",
                "ops",
                "op",
                "op-windows-0001.json"
            ]]
        );
    }

    #[test]
    fn highest_lamport_reads_remote_operations() {
        let root = br#"<d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/op/</d:href></d:response>
        </d:multistatus>"#;
        let shard = br#"<d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/remote.php/dav/files/person/woo-todo/v1/vault-windows/ops/op/op-windows-0001.json</d:href></d:response>
        </d:multistatus>"#;
        let transport = MockTransport::with([
            HttpResponse {
                status: 207,
                body: root.to_vec(),
            },
            HttpResponse {
                status: 207,
                body: shard.to_vec(),
            },
            HttpResponse {
                status: 200,
                body: canonical_operation_json(&operation()).unwrap(),
            },
        ]);
        let client = WebDavClient::new(&credentials(), transport).unwrap();

        assert_eq!(client.highest_lamport().unwrap(), 7);
    }
}
