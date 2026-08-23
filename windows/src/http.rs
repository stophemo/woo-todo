use std::net::{Ipv4Addr, Ipv6Addr};

use url::{Host, Url};

const MAXIMUM_REQUEST_BYTES: usize = 3 * 1_024 * 1_024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndpointScope {
    Worker,
    LocalNetwork,
    WebDav,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedEndpoint {
    url: Url,
}

impl ValidatedEndpoint {
    pub fn parse(value: &str, scope: EndpointScope) -> Result<Self, String> {
        if scope == EndpointScope::WebDav {
            validate_webdav_source(value)?;
        }
        let url = Url::parse(value).map_err(|_| "同步服务地址格式无效".to_owned())?;
        if !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err("同步服务地址不能包含凭据、查询参数或片段".to_owned());
        }
        match scope {
            EndpointScope::Worker => validate_worker(&url)?,
            EndpointScope::LocalNetwork => validate_local_network(&url)?,
            EndpointScope::WebDav => validate_webdav(&url)?,
        }
        Ok(Self { url })
    }

    pub fn as_str(&self) -> &str {
        self.url.as_str()
    }

    pub fn append_path(&self, components: &[&str]) -> Result<Url, String> {
        let mut value = self.url.clone();
        {
            let mut segments = value
                .path_segments_mut()
                .map_err(|_| "同步服务地址不支持路径拼接".to_owned())?;
            segments.pop_if_empty();
            for component in components {
                if component.is_empty() || matches!(*component, "." | "..") {
                    return Err("同步请求路径包含无效分段".to_owned());
                }
                segments.push(component);
            }
        }
        Ok(value)
    }
}

pub struct HttpRequest {
    pub method: &'static str,
    pub url: Url,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub maximum_response_bytes: usize,
}

impl HttpRequest {
    pub fn validate(&self) -> Result<(), String> {
        if !matches!(self.method, "GET" | "POST" | "PUT" | "MKCOL" | "PROPFIND") {
            return Err("同步 HTTP 方法不受支持".to_owned());
        }
        if self.url.scheme() != "https" && self.url.scheme() != "http" {
            return Err("同步请求只支持 HTTP 或 HTTPS".to_owned());
        }
        if !self.url.username().is_empty()
            || self.url.password().is_some()
            || self.url.fragment().is_some()
            || self.url.host().is_none()
        {
            return Err("同步请求地址无效".to_owned());
        }
        if self.body.len() > MAXIMUM_REQUEST_BYTES {
            return Err("同步请求体超过允许大小".to_owned());
        }
        if self.maximum_response_bytes == 0 || self.maximum_response_bytes > MAXIMUM_REQUEST_BYTES {
            return Err("同步响应大小上限无效".to_owned());
        }
        for (name, value) in &self.headers {
            if name.is_empty()
                || !name
                    .bytes()
                    .all(|value| value.is_ascii_alphanumeric() || matches!(value, b'-'))
                || value
                    .bytes()
                    .any(|value| value < b' ' && value != b'\t' || value == 0x7f)
            {
                return Err("同步 HTTP 请求头无效".to_owned());
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

pub trait HttpTransport: Send + Sync {
    fn execute(&self, request: HttpRequest) -> Result<HttpResponse, String>;
}

#[cfg(windows)]
#[derive(Default)]
pub struct WinHttpTransport;

#[cfg(windows)]
impl HttpTransport for WinHttpTransport {
    fn execute(&self, request: HttpRequest) -> Result<HttpResponse, String> {
        execute_winhttp(request)
    }
}

fn validate_worker(url: &Url) -> Result<(), String> {
    if !url.scheme().eq_ignore_ascii_case("https") || url.host().is_none() {
        return Err("Worker 同步必须使用有效 HTTPS 地址".to_owned());
    }
    if !is_valid_api_base_path(url.path()) {
        return Err("Worker 地址不能附加 /v1 或其他 API 路径".to_owned());
    }
    let host = url.host().expect("已检查 host");
    if is_current_device_host(&host) {
        return Err("localhost/127.0.0.1 只代表当前设备，不能用于跨设备同步".to_owned());
    }
    Ok(())
}

fn validate_local_network(url: &Url) -> Result<(), String> {
    if !url.scheme().eq_ignore_ascii_case("http")
        || url.port().is_none()
        || !is_valid_api_base_path(url.path())
    {
        return Err("同一网络同步地址必须是带端口的 HTTP 服务地址".to_owned());
    }
    let Some(host) = url.host() else {
        return Err("同一网络同步地址缺少主机".to_owned());
    };
    let current_device = is_current_device_host(&host);
    let allowed = match host {
        Host::Ipv4(value) => is_private_ipv4(value),
        Host::Ipv6(value) => is_private_ipv6(value),
        Host::Domain(value) => value.ends_with(".local") && value.len() > ".local".len(),
    };
    if !allowed || current_device {
        return Err("同一网络同步只接受可由其他设备访问的私有网段或 .local 地址".to_owned());
    }
    Ok(())
}

fn validate_webdav(url: &Url) -> Result<(), String> {
    if !url.scheme().eq_ignore_ascii_case("https") || url.host().is_none() {
        return Err("WebDAV 服务必须使用有效 HTTPS 地址".to_owned());
    }
    Ok(())
}

fn is_valid_api_base_path(path: &str) -> bool {
    let trimmed = path.trim_end_matches('/');
    trimmed.is_empty()
        || !trimmed
            .rsplit('/')
            .next()
            .is_some_and(|value| value.eq_ignore_ascii_case("v1"))
}

fn validate_webdav_source(value: &str) -> Result<(), String> {
    if value.len() > 2_048 || value.contains('\\') {
        return Err("WebDAV 服务地址包含无效路径".to_owned());
    }
    let path_and_authority = value.split(['?', '#']).next().unwrap_or(value);
    for segment in path_and_authority.split('/') {
        let decoded = decode_percent_encoded_segment(segment)?;
        if matches!(decoded.as_str(), "." | "..") || decoded.contains('/') || decoded.contains('\\')
        {
            return Err("WebDAV 服务地址包含无效路径".to_owned());
        }
    }
    Ok(())
}

fn decode_percent_encoded_segment(value: &str) -> Result<String, String> {
    let source = value.as_bytes();
    let mut output = Vec::with_capacity(source.len());
    let mut index = 0;
    while index < source.len() {
        if source[index] != b'%' {
            output.push(source[index]);
            index += 1;
            continue;
        }
        if index + 2 >= source.len() {
            return Err("WebDAV 服务地址百分号转义无效".to_owned());
        }
        let high = hex_value(source[index + 1])
            .ok_or_else(|| "WebDAV 服务地址百分号转义无效".to_owned())?;
        let low = hex_value(source[index + 2])
            .ok_or_else(|| "WebDAV 服务地址百分号转义无效".to_owned())?;
        output.push((high << 4) | low);
        index += 3;
    }
    String::from_utf8(output).map_err(|_| "WebDAV 服务地址路径编码无效".to_owned())
}

fn hex_value(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn is_current_device_host(host: &Host<&str>) -> bool {
    match host {
        Host::Domain(value) => value.eq_ignore_ascii_case("localhost"),
        Host::Ipv4(value) => value.is_loopback() || value.is_unspecified(),
        Host::Ipv6(value) => value.is_loopback() || value.is_unspecified(),
    }
}

fn is_private_ipv4(value: Ipv4Addr) -> bool {
    value.is_private() || value.is_link_local()
}

fn is_private_ipv6(value: Ipv6Addr) -> bool {
    let first = value.segments()[0];
    (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
}

#[cfg(windows)]
fn execute_winhttp(request: HttpRequest) -> Result<HttpResponse, String> {
    use std::ffi::c_void;
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::GetLastError;
    use windows_sys::Win32::Networking::WinHttp::*;

    struct InternetHandle(*mut c_void);
    impl Drop for InternetHandle {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { WinHttpCloseHandle(self.0) };
            }
        }
    }

    fn wide(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(Some(0)).collect()
    }

    fn failure(action: &str) -> String {
        format!("{action}失败，WinHTTP 错误：{}", unsafe {
            GetLastError()
        })
    }

    request.validate()?;
    let host = request
        .url
        .host_str()
        .ok_or_else(|| "同步请求地址缺少主机".to_owned())?;
    let port = request
        .url
        .port_or_known_default()
        .ok_or_else(|| "同步请求地址缺少有效端口".to_owned())?;
    let mut path = request.url.path().to_owned();
    if path.is_empty() {
        path.push('/');
    }
    if let Some(query) = request.url.query() {
        path.push('?');
        path.push_str(query);
    }
    let header_text = request
        .headers
        .iter()
        .map(|(name, value)| format!("{name}: {value}\r\n"))
        .collect::<String>();

    let agent = wide("Woo-Todo-Windows/Sync");
    let host = wide(host);
    let path = wide(&path);
    let method = wide(request.method);
    let headers = (!header_text.is_empty()).then(|| wide(&header_text));
    let access_type = if uses_direct_connection(&request.url) {
        WINHTTP_ACCESS_TYPE_NO_PROXY
    } else {
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
    };
    let session =
        InternetHandle(unsafe { WinHttpOpen(agent.as_ptr(), access_type, null(), null(), 0) });
    if session.0.is_null() {
        return Err(failure("初始化同步网络"));
    }
    if unsafe { WinHttpSetTimeouts(session.0, 5_000, 10_000, 20_000, 30_000) } == 0 {
        return Err(failure("设置同步网络超时"));
    }
    let connection = InternetHandle(unsafe { WinHttpConnect(session.0, host.as_ptr(), port, 0) });
    if connection.0.is_null() {
        return Err(failure("连接同步服务"));
    }
    let flags = if request.url.scheme() == "https" {
        WINHTTP_FLAG_SECURE
    } else {
        0
    };
    let handle = InternetHandle(unsafe {
        WinHttpOpenRequest(
            connection.0,
            method.as_ptr(),
            path.as_ptr(),
            null(),
            null(),
            null(),
            flags,
        )
    });
    if handle.0.is_null() {
        return Err(failure("创建同步请求"));
    }
    let redirect_policy = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if unsafe {
        WinHttpSetOption(
            handle.0,
            WINHTTP_OPTION_REDIRECT_POLICY,
            (&redirect_policy as *const u32).cast(),
            std::mem::size_of::<u32>() as u32,
        )
    } == 0
    {
        return Err(failure("限制同步请求重定向"));
    }
    let header_pointer = headers
        .as_ref()
        .map(|value| value.as_ptr())
        .unwrap_or(null());
    let header_length = headers.as_ref().map(|value| value.len() - 1).unwrap_or(0) as u32;
    let body_pointer = if request.body.is_empty() {
        null()
    } else {
        request.body.as_ptr().cast::<c_void>()
    };
    if unsafe {
        WinHttpSendRequest(
            handle.0,
            header_pointer,
            header_length,
            body_pointer,
            request.body.len() as u32,
            request.body.len() as u32,
            0,
        )
    } == 0
    {
        return Err(failure("发送同步请求"));
    }
    if unsafe { WinHttpReceiveResponse(handle.0, null_mut()) } == 0 {
        return Err(failure("接收同步响应"));
    }
    let mut status = 0_u32;
    let mut status_size = std::mem::size_of::<u32>() as u32;
    let mut header_index = 0_u32;
    if unsafe {
        WinHttpQueryHeaders(
            handle.0,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            null(),
            (&mut status as *mut u32).cast(),
            &mut status_size,
            &mut header_index,
        )
    } == 0
    {
        return Err(failure("读取同步响应状态"));
    }
    let status = u16::try_from(status).map_err(|_| "同步响应状态码无效".to_owned())?;
    let mut output = Vec::new();
    let mut buffer = [0_u8; 16 * 1_024];
    loop {
        let mut read = 0_u32;
        if unsafe {
            WinHttpReadData(
                handle.0,
                buffer.as_mut_ptr().cast(),
                buffer.len() as u32,
                &mut read,
            )
        } == 0
        {
            return Err(failure("读取同步响应"));
        }
        if read == 0 {
            break;
        }
        if output.len() + read as usize > request.maximum_response_bytes {
            return Err("同步响应超过允许大小".to_owned());
        }
        output.extend_from_slice(&buffer[..read as usize]);
    }
    Ok(HttpResponse {
        status,
        body: output,
    })
}

fn uses_direct_connection(url: &Url) -> bool {
    if url.scheme() != "http" {
        return false;
    }
    match url.host() {
        Some(Host::Ipv4(value)) => is_private_ipv4(value),
        Some(Host::Ipv6(value)) => is_private_ipv6(value),
        Some(Host::Domain(value)) => value.ends_with(".local") && value.len() > ".local".len(),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_policies_separate_remote_local_and_webdav() {
        assert!(
            ValidatedEndpoint::parse("https://sync.example.com", EndpointScope::Worker).is_ok()
        );
        assert!(
            ValidatedEndpoint::parse("https://sync.example.com/v1", EndpointScope::Worker).is_err()
        );
        assert!(
            ValidatedEndpoint::parse("http://192.168.8.21:48473", EndpointScope::LocalNetwork)
                .is_ok()
        );
        assert!(
            ValidatedEndpoint::parse("http://woo-todo.local:48473", EndpointScope::LocalNetwork)
                .is_ok()
        );
        for invalid in [
            "http://127.0.0.1:48473",
            "http://localhost:48473",
            "http://8.8.8.8:48473",
            "https://192.168.8.21:48473",
        ] {
            assert!(
                ValidatedEndpoint::parse(invalid, EndpointScope::LocalNetwork).is_err(),
                "{invalid}"
            );
        }
        assert!(
            ValidatedEndpoint::parse(
                "https://dav.example.com/remote.php/dav/",
                EndpointScope::WebDav
            )
            .is_ok()
        );
        assert!(
            ValidatedEndpoint::parse("http://dav.example.com/dav/", EndpointScope::WebDav).is_err()
        );
        for invalid in [
            "https://dav.example.com/root/../escape/",
            "https://dav.example.com/root/%2e%2e/escape/",
            "https://dav.example.com/root/encoded%2fslash/",
            "https://dav.example.com/root/encoded%5cbackslash/",
            "https://dav.example.com/root/invalid%ZZescape/",
            "https://dav.example.com\\escaped",
        ] {
            assert!(
                ValidatedEndpoint::parse(invalid, EndpointScope::WebDav).is_err(),
                "{invalid}"
            );
        }
    }

    #[test]
    fn path_segments_are_encoded_and_cannot_escape_the_base() {
        let endpoint = ValidatedEndpoint::parse(
            "https://dav.example.com/remote.php/dav/",
            EndpointScope::WebDav,
        )
        .unwrap();
        let url = endpoint.append_path(&["v1", "vault id", "ops"]).unwrap();
        assert_eq!(
            url.as_str(),
            "https://dav.example.com/remote.php/dav/v1/vault%20id/ops"
        );
        assert!(endpoint.append_path(&[".."]).is_err());
    }

    #[test]
    fn requests_reject_header_injection_and_unbounded_payloads() {
        let request = HttpRequest {
            method: "POST",
            url: Url::parse("https://sync.example.com/v1/sync").unwrap(),
            headers: vec![(
                "Authorization".to_owned(),
                "Bearer value\r\nInjected: true".to_owned(),
            )],
            body: Vec::new(),
            maximum_response_bytes: 1_024,
        };
        assert!(request.validate().is_err());

        let request = HttpRequest {
            method: "PATCH",
            url: Url::parse("https://sync.example.com/v1/sync").unwrap(),
            headers: Vec::new(),
            body: Vec::new(),
            maximum_response_bytes: 1_024,
        };
        assert!(request.validate().is_err());
    }

    #[test]
    fn private_address_classification_excludes_public_and_loopback() {
        assert!(is_private_ipv4(Ipv4Addr::new(10, 1, 2, 3)));
        assert!(is_private_ipv4(Ipv4Addr::new(172, 16, 0, 1)));
        assert!(is_private_ipv4(Ipv4Addr::new(192, 168, 1, 2)));
        assert!(!is_private_ipv4(Ipv4Addr::new(8, 8, 8, 8)));
        assert!(is_private_ipv6("fd00::1".parse::<Ipv6Addr>().unwrap()));
        assert!(!is_private_ipv6(
            "2001:4860:4860::8888".parse::<Ipv6Addr>().unwrap()
        ));
    }

    #[test]
    fn local_http_bypasses_system_proxy_but_remote_https_does_not() {
        assert!(uses_direct_connection(
            &Url::parse("http://192.168.1.20:48473/v1/sync").unwrap()
        ));
        assert!(uses_direct_connection(
            &Url::parse("http://woo-todo.local:48473/v1/sync").unwrap()
        ));
        assert!(!uses_direct_connection(
            &Url::parse("https://192.168.1.20/v1/sync").unwrap()
        ));
        assert!(!uses_direct_connection(
            &Url::parse("https://sync.example.com/v1/sync").unwrap()
        ));
    }
}
