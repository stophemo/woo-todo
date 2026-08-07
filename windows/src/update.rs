use serde::Deserialize;
#[cfg(windows)]
use sha2::{Digest, Sha256};
use std::fmt;
#[cfg(windows)]
use std::path::PathBuf;

const REPOSITORY: &str = "stophemo/woo-todo";
const MAX_RELEASE_RESPONSE_BYTES: usize = 1024 * 1024;
pub(crate) const AUTOMATIC_CHECK_INTERVAL_MILLIS: i64 = 12 * 60 * 60 * 1_000;
pub(crate) const FAILED_CHECK_RETRY_INTERVAL_MILLIS: i64 = 15 * 60 * 1_000;
#[cfg(windows)]
const MAX_UPDATE_ARCHIVE_BYTES: usize = 64 * 1024 * 1024;

pub(crate) fn should_automatically_check(
    last_successful_check_at: i64,
    last_attempt_at: i64,
    now: i64,
) -> bool {
    elapsed(last_successful_check_at, now) >= AUTOMATIC_CHECK_INTERVAL_MILLIS
        && elapsed(last_attempt_at, now) >= FAILED_CHECK_RETRY_INTERVAL_MILLIS
}

fn elapsed(previous: i64, now: i64) -> i64 {
    if previous <= 0 || now < previous {
        i64::MAX
    } else {
        now - previous
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct AppVersion {
    major: u64,
    minor: u64,
    patch: u64,
}

impl AppVersion {
    fn parse(value: &str) -> Result<Self, String> {
        let source = value.strip_prefix('v').unwrap_or(value);
        if source.is_empty() || source.split('.').count() != 3 {
            return Err("版本号必须是三段式稳定版本".into());
        }
        let mut values = [0_u64; 3];
        for (index, part) in source.split('.').enumerate() {
            if part.is_empty()
                || (part.len() > 1 && part.starts_with('0'))
                || !part.bytes().all(|byte| byte.is_ascii_digit())
            {
                return Err("版本号格式无效".into());
            }
            values[index] = part.parse().map_err(|_| "版本号数值溢出")?;
        }
        Ok(Self {
            major: values[0],
            minor: values[1],
            patch: values[2],
        })
    }
}

impl fmt::Display for AppVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

#[derive(Debug, Clone)]
pub(crate) struct UpdateRelease {
    pub version: AppVersion,
    pub asset_path: String,
    pub digest: [u8; 32],
}

#[cfg(windows)]
#[derive(Debug)]
pub(crate) struct PreparedUpdate {
    pub version: AppVersion,
    pub archive_path: PathBuf,
    digest: [u8; 32],
}

#[derive(Deserialize)]
struct ReleasePayload {
    tag_name: String,
    draft: bool,
    prerelease: bool,
    assets: Vec<ReleaseAsset>,
}

#[derive(Deserialize)]
struct ReleaseAsset {
    name: String,
    browser_download_url: String,
    digest: Option<String>,
}

fn parse_release(source: &[u8], current_version: &str) -> Result<Option<UpdateRelease>, String> {
    if source.len() > MAX_RELEASE_RESPONSE_BYTES {
        return Err("GitHub Release 响应过大".into());
    }
    let payload: ReleasePayload = serde_json::from_slice(source)
        .map_err(|error| format!("无法解析 GitHub Release：{error}"))?;
    if payload.draft || payload.prerelease {
        return Err("GitHub 最新 Release 不是正式版本".into());
    }
    let version = AppVersion::parse(&payload.tag_name)?;
    if payload.tag_name != format!("v{version}") {
        return Err("GitHub Release 标签格式无效".into());
    }
    let current = AppVersion::parse(current_version)?;
    if version <= current {
        return Ok(None);
    }

    let expected_name = format!("Woo-Todo-v{version}-windows-x64.zip");
    let expected_path = format!("/{REPOSITORY}/releases/download/v{version}/{expected_name}");
    let expected_url = format!("https://github.com{expected_path}");
    let asset = payload
        .assets
        .iter()
        .find(|asset| asset.name == expected_name && asset.browser_download_url == expected_url)
        .ok_or(
            "Windows 当前为实验版（不保证可用），不参与正式版自动更新；请手动获取 Windows 实验版 Prerelease",
        )?;
    let digest = parse_sha256(
        asset
            .digest
            .as_deref()
            .ok_or("Windows ZIP 缺少 SHA-256 digest")?,
    )?;
    Ok(Some(UpdateRelease {
        version,
        asset_path: expected_path,
        digest,
    }))
}

fn parse_sha256(value: &str) -> Result<[u8; 32], String> {
    let source = value
        .strip_prefix("sha256:")
        .ok_or("更新包 digest 算法不是 SHA-256")?;
    if source.len() != 64 || !source.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("更新包 SHA-256 digest 格式无效".into());
    }
    let mut output = [0_u8; 32];
    for (index, byte) in output.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&source[index * 2..index * 2 + 2], 16)
            .map_err(|_| "更新包 SHA-256 digest 格式无效")?;
    }
    Ok(output)
}

#[cfg(windows)]
fn sha256_hex(digest: &[u8; 32]) -> String {
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(windows)]
pub(crate) fn check_latest() -> Result<Option<UpdateRelease>, String> {
    let source = winhttp_get(
        "api.github.com",
        "/repos/stophemo/woo-todo/releases/latest",
        "Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n",
        MAX_RELEASE_RESPONSE_BYTES,
    )?;
    parse_release(&source, env!("CARGO_PKG_VERSION"))
}

#[cfg(windows)]
pub(crate) fn download(release: UpdateRelease) -> Result<PreparedUpdate, String> {
    let source = winhttp_get(
        "github.com",
        &release.asset_path,
        "Accept: application/octet-stream\r\n",
        MAX_UPDATE_ARCHIVE_BYTES,
    )?;
    let actual: [u8; 32] = Sha256::digest(&source).into();
    if actual != release.digest {
        return Err("更新包 SHA-256 校验失败，文件可能损坏".into());
    }
    let directory = std::env::temp_dir().join("WooTodo").join("updates");
    std::fs::create_dir_all(&directory).map_err(|error| format!("无法创建更新目录：{error}"))?;
    let archive_path = directory.join(format!("Woo-Todo-v{}-windows-x64.zip", release.version));
    let partial_path = archive_path.with_extension("zip.part");
    if partial_path.exists() {
        std::fs::remove_file(&partial_path).map_err(|error| format!("无法清理旧更新：{error}"))?;
    }
    std::fs::write(&partial_path, source).map_err(|error| format!("无法保存更新包：{error}"))?;
    if archive_path.exists() {
        std::fs::remove_file(&archive_path).map_err(|error| format!("无法替换旧更新：{error}"))?;
    }
    std::fs::rename(&partial_path, &archive_path)
        .map_err(|error| format!("无法完成更新包写入：{error}"))?;
    Ok(PreparedUpdate {
        version: release.version,
        archive_path,
        digest: release.digest,
    })
}

#[cfg(windows)]
pub(crate) fn launch_helper(update: &PreparedUpdate) -> Result<(), String> {
    use std::process::Command;
    use windows_sys::Win32::System::Threading::GetCurrentProcessId;

    let executable =
        std::env::current_exe().map_err(|error| format!("无法定位当前程序：{error}"))?;
    let helper = std::env::temp_dir().join(format!(
        "WooTodoUpdater-{}-{}.exe",
        update.version,
        unsafe { GetCurrentProcessId() }
    ));
    std::fs::copy(&executable, &helper).map_err(|error| format!("无法创建更新 helper：{error}"))?;
    Command::new(&helper)
        .arg("--woo-todo-apply-update")
        .arg(&update.archive_path)
        .arg(&executable)
        .arg(unsafe { GetCurrentProcessId() }.to_string())
        .arg(update.version.to_string())
        .arg(sha256_hex(&update.digest))
        .spawn()
        .map_err(|error| format!("无法启动更新 helper：{error}"))?;
    Ok(())
}

#[cfg(windows)]
pub(crate) fn run_helper_from_args() -> Option<Result<(), String>> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.get(1).and_then(|value| value.to_str()) != Some("--woo-todo-apply-update") {
        return None;
    }
    Some((|| {
        if args.len() != 7 {
            return Err("更新 helper 参数不完整".into());
        }
        let archive = PathBuf::from(&args[2]);
        let executable = PathBuf::from(&args[3]);
        let pid = args[4]
            .to_str()
            .ok_or("主进程 ID 格式无效")?
            .parse::<u32>()
            .map_err(|_| "主进程 ID 格式无效")?;
        let version = AppVersion::parse(args[5].to_str().ok_or("更新版本格式无效")?)?;
        let digest_source = args[6].to_str().ok_or("更新 digest 格式无效")?;
        let digest = parse_sha256(&format!("sha256:{digest_source}"))?;
        apply_update(&archive, &executable, pid, version, digest)
    })())
}

#[cfg(windows)]
fn apply_update(
    archive: &std::path::Path,
    executable: &std::path::Path,
    pid: u32,
    expected_version: AppVersion,
    expected_digest: [u8; 32],
) -> Result<(), String> {
    use std::fs::{File, OpenOptions};
    use std::io::{Read, Write};
    use std::process::Command;
    use zip::ZipArchive;

    wait_for_process(pid)?;
    let bytes = std::fs::read(archive).map_err(|error| format!("无法读取更新包：{error}"))?;
    if bytes.len() > MAX_UPDATE_ARCHIVE_BYTES
        || <Sha256 as Digest>::digest(&bytes)[..] != expected_digest
    {
        return Err("更新 helper 复核 SHA-256 失败".into());
    }

    let file = File::open(archive).map_err(|error| format!("无法打开更新 ZIP：{error}"))?;
    let mut zip = ZipArchive::new(file).map_err(|error| format!("更新 ZIP 格式无效：{error}"))?;
    if zip.len() != 1 {
        return Err("更新 ZIP 必须只包含 WooTodo.exe".into());
    }
    let mut entry = zip
        .by_index(0)
        .map_err(|error| format!("无法读取更新 ZIP：{error}"))?;
    if entry.name() != "WooTodo.exe"
        || !entry.is_file()
        || entry.size() == 0
        || entry.size() > 64 * 1024 * 1024
    {
        return Err("更新 ZIP 的目录结构无效".into());
    }

    let new_path = executable.with_extension("update.exe");
    let old_path = executable.with_extension("previous.exe");
    if new_path.exists() {
        std::fs::remove_file(&new_path).map_err(|error| format!("无法清理旧临时程序：{error}"))?;
    }
    if old_path.exists() {
        std::fs::remove_file(&old_path).map_err(|error| format!("无法清理旧版程序：{error}"))?;
    }
    let mut output = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&new_path)
        .map_err(|error| format!("无法创建新版程序：{error}"))?;
    let mut copied = 0_u64;
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let count = entry
            .read(&mut buffer)
            .map_err(|error| format!("无法解压新版程序：{error}"))?;
        if count == 0 {
            break;
        }
        copied += count as u64;
        if copied > 64 * 1024 * 1024 {
            return Err("解压后的新版程序过大".into());
        }
        output
            .write_all(&buffer[..count])
            .map_err(|error| format!("无法写入新版程序：{error}"))?;
    }
    output
        .sync_all()
        .map_err(|error| format!("无法落盘新版程序：{error}"))?;
    drop(output);
    drop(entry);
    drop(zip);

    std::fs::rename(executable, &old_path).map_err(|error| format!("无法备份当前程序：{error}"))?;
    if let Err(error) = std::fs::rename(&new_path, executable) {
        let _ = std::fs::rename(&old_path, executable);
        return Err(format!("无法替换当前程序：{error}"));
    }
    if let Err(error) = Command::new(executable)
        .arg("--updated-from")
        .arg(expected_version.to_string())
        .spawn()
    {
        let _ = std::fs::rename(executable, &new_path);
        let _ = std::fs::rename(&old_path, executable);
        return Err(format!("新版程序无法启动，已恢复旧版：{error}"));
    }
    let _ = std::fs::remove_file(&old_path);
    let _ = std::fs::remove_file(archive);
    Ok(())
}

#[cfg(windows)]
fn wait_for_process(pid: u32) -> Result<(), String> {
    use windows_sys::Win32::Foundation::{
        CloseHandle, ERROR_INVALID_PARAMETER, GetLastError, WAIT_OBJECT_0,
    };
    use windows_sys::Win32::System::Threading::{OpenProcess, WaitForSingleObject};

    const PROCESS_SYNCHRONIZE_ACCESS: u32 = 0x0010_0000;

    let process = unsafe { OpenProcess(PROCESS_SYNCHRONIZE_ACCESS, 0, pid) };
    if process.is_null() {
        return if unsafe { GetLastError() } == ERROR_INVALID_PARAMETER {
            Ok(())
        } else {
            Err(format!("无法等待主程序退出：{}", unsafe {
                GetLastError()
            }))
        };
    }
    let result = unsafe { WaitForSingleObject(process, 60_000) };
    unsafe { CloseHandle(process) };
    if result == WAIT_OBJECT_0 {
        Ok(())
    } else {
        Err("等待主程序退出超时".into())
    }
}

#[cfg(windows)]
fn winhttp_get(
    host: &str,
    path: &str,
    headers: &str,
    maximum_bytes: usize,
) -> Result<Vec<u8>, String> {
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
        value.encode_utf16().chain(std::iter::once(0)).collect()
    }
    fn failure(action: &str) -> String {
        format!("{action}失败，WinHTTP 错误：{}", unsafe {
            GetLastError()
        })
    }

    let agent = wide("Woo-Todo-Windows");
    let host = wide(host);
    let path = wide(path);
    let method = wide("GET");
    let headers = wide(headers);
    let session = InternetHandle(unsafe {
        WinHttpOpen(
            agent.as_ptr(),
            WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
            null(),
            null(),
            0,
        )
    });
    if session.0.is_null() {
        return Err(failure("初始化更新网络"));
    }
    if unsafe { WinHttpSetTimeouts(session.0, 5_000, 10_000, 15_000, 30_000) } == 0 {
        return Err(failure("设置更新网络超时"));
    }
    let connection = InternetHandle(unsafe {
        WinHttpConnect(session.0, host.as_ptr(), INTERNET_DEFAULT_HTTPS_PORT, 0)
    });
    if connection.0.is_null() {
        return Err(failure("连接更新服务器"));
    }
    let request = InternetHandle(unsafe {
        WinHttpOpenRequest(
            connection.0,
            method.as_ptr(),
            path.as_ptr(),
            null(),
            null(),
            null(),
            WINHTTP_FLAG_SECURE,
        )
    });
    if request.0.is_null() {
        return Err(failure("创建更新请求"));
    }
    if unsafe {
        WinHttpSendRequest(
            request.0,
            headers.as_ptr(),
            (headers.len() - 1) as u32,
            null(),
            0,
            0,
            0,
        )
    } == 0
    {
        return Err(failure("发送更新请求"));
    }
    if unsafe { WinHttpReceiveResponse(request.0, null_mut()) } == 0 {
        return Err(failure("接收更新响应"));
    }
    let mut status = 0_u32;
    let mut status_size = std::mem::size_of::<u32>() as u32;
    let mut header_index = 0_u32;
    if unsafe {
        WinHttpQueryHeaders(
            request.0,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            null(),
            (&mut status as *mut u32).cast(),
            &mut status_size,
            &mut header_index,
        )
    } == 0
    {
        return Err(failure("读取更新响应状态"));
    }
    if status != 200 {
        return Err(format!("更新服务器返回 HTTP {status}"));
    }

    let mut output = Vec::new();
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let mut read = 0_u32;
        if unsafe {
            WinHttpReadData(
                request.0,
                buffer.as_mut_ptr().cast(),
                buffer.len() as u32,
                &mut read,
            )
        } == 0
        {
            return Err(failure("读取更新响应"));
        }
        if read == 0 {
            break;
        }
        if output.len() + read as usize > maximum_bytes {
            return Err("更新响应超过允许大小".into());
        }
        output.extend_from_slice(&buffer[..read as usize]);
    }
    if output.is_empty() {
        return Err("更新服务器返回空响应".into());
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release_json(tag: &str, digest: &str) -> Vec<u8> {
        format!(
            r#"{{
                "tag_name":"{tag}","draft":false,"prerelease":false,
                "assets":[{{
                    "name":"Woo-Todo-{tag}-windows-x64.zip",
                    "browser_download_url":"https://github.com/stophemo/woo-todo/releases/download/{tag}/Woo-Todo-{tag}-windows-x64.zip",
                    "digest":"{digest}"
                }}]
            }}"#
        )
        .into_bytes()
    }

    #[test]
    fn stable_versions_compare_numerically() {
        assert!(AppVersion::parse("0.10.0").unwrap() > AppVersion::parse("v0.9.9").unwrap());
        for invalid in ["1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "V1.2.3"] {
            assert!(AppVersion::parse(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn automatic_checks_use_twelve_hour_success_and_fifteen_minute_retry_boundaries() {
        let now = 200_000_000;
        assert!(should_automatically_check(0, 0, now));
        assert!(!should_automatically_check(
            now - AUTOMATIC_CHECK_INTERVAL_MILLIS + 1,
            now - FAILED_CHECK_RETRY_INTERVAL_MILLIS,
            now,
        ));
        assert!(should_automatically_check(
            now - AUTOMATIC_CHECK_INTERVAL_MILLIS,
            now - FAILED_CHECK_RETRY_INTERVAL_MILLIS,
            now,
        ));
        assert!(!should_automatically_check(
            0,
            now - FAILED_CHECK_RETRY_INTERVAL_MILLIS + 1,
            now,
        ));
        assert!(should_automatically_check(now + 1, now + 1, now));
    }

    #[test]
    fn release_requires_exact_asset_url_and_sha256_digest() {
        let digest = format!("sha256:{}", "ab".repeat(32));
        let release = parse_release(&release_json("v0.1.14", &digest), "0.1.13")
            .unwrap()
            .unwrap();
        assert_eq!(release.version.to_string(), "0.1.14");
        assert_eq!(release.digest, [0xab; 32]);
        assert_eq!(
            release.asset_path,
            "/stophemo/woo-todo/releases/download/v0.1.14/Woo-Todo-v0.1.14-windows-x64.zip"
        );
        assert!(
            parse_release(&release_json("v0.1.13", &digest), "0.1.13")
                .unwrap()
                .is_none()
        );
        assert!(parse_release(&release_json("v0.1.14", "sha512:abcd"), "0.1.13").is_err());

        let mut external = String::from_utf8(release_json("v0.1.14", &digest)).unwrap();
        external = external.replace("https://github.com", "https://example.com");
        assert!(parse_release(external.as_bytes(), "0.1.13").is_err());
    }

    #[test]
    fn draft_prerelease_and_malformed_tags_are_rejected() {
        let digest = format!("sha256:{}", "00".repeat(32));
        let mut draft = String::from_utf8(release_json("v0.1.14", &digest)).unwrap();
        draft = draft.replace("\"draft\":false", "\"draft\":true");
        assert!(parse_release(draft.as_bytes(), "0.1.13").is_err());
        assert!(parse_release(&release_json("0.1.14", &digest), "0.1.13").is_err());
    }

    #[test]
    fn experimental_asset_is_not_accepted_as_a_formal_windows_update() {
        let digest = format!("sha256:{}", "00".repeat(32));
        let experimental = String::from_utf8(release_json("v0.1.14", &digest))
            .unwrap()
            .replace("windows-x64.zip", "windows-x64-experimental.zip");

        let error = parse_release(experimental.as_bytes(), "0.1.13").unwrap_err();

        assert!(error.contains("实验版（不保证可用）"));
    }
}
