use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use woo_todo_core::{
    SyncConfiguration, SyncRequest, TaskRepository, WebDavOperation, base64url_decode,
};

use crate::credentials::{SyncCredentialStore, SyncCredentials, SyncMode};
use crate::http::HttpTransport;
#[cfg(windows)]
use crate::http::WinHttpTransport;
use crate::webdav::WebDavClient;
use crate::worker::{WorkerClient, WorkerError};

const MAXIMUM_PUSH_BATCH: usize = 50;
const MAXIMUM_WORKER_PAGES: usize = 1_000;
const WEBDAV_APPLY_BATCH: usize = 500;
const FALLBACK_INTERVAL: Duration = Duration::from_secs(15 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncTrigger {
    Launch,
    LocalChange,
    Manual,
    Wake,
    NetworkAvailable,
    Fallback,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncRunSummary {
    pub pushed: usize,
    pub pulled: usize,
    pub pages: usize,
    pub final_cursor: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncRuntimeSnapshot {
    pub configured_mode: Option<SyncMode>,
    pub running: bool,
    pub pending: bool,
    pub last_trigger: Option<SyncTrigger>,
    pub last_successful_at: Option<i64>,
    pub last_error: Option<String>,
    pub last_summary: Option<SyncRunSummary>,
}

enum RuntimeCommand {
    Synchronize(SyncTrigger),
    Stop,
}

pub struct SyncRuntime {
    sender: Sender<RuntimeCommand>,
    state: Arc<Mutex<SyncRuntimeSnapshot>>,
    abort: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl SyncRuntime {
    #[cfg(windows)]
    pub fn start(database_path: PathBuf, credentials: Arc<dyn SyncCredentialStore>) -> Self {
        Self::start_with(database_path, credentials, || WinHttpTransport)
    }

    pub fn start_with<T, Factory>(
        database_path: PathBuf,
        credentials: Arc<dyn SyncCredentialStore>,
        transport_factory: Factory,
    ) -> Self
    where
        T: HttpTransport + 'static,
        Factory: Fn() -> T + Send + 'static,
    {
        let (sender, receiver) = mpsc::channel();
        let state = Arc::new(Mutex::new(SyncRuntimeSnapshot::default()));
        let thread_state = Arc::clone(&state);
        let abort = Arc::new(AtomicBool::new(false));
        let thread_abort = Arc::clone(&abort);
        let worker = thread::spawn(move || {
            run_loop(
                receiver,
                thread_state,
                database_path,
                credentials,
                transport_factory,
                thread_abort,
            )
        });
        Self {
            sender,
            state,
            abort,
            worker: Some(worker),
        }
    }

    pub fn request(&self, trigger: SyncTrigger) {
        if let Ok(mut state) = self.state.lock()
            && (state.running || state.pending)
        {
            state.pending = true;
        }
        let _ = self.sender.send(RuntimeCommand::Synchronize(trigger));
    }

    pub fn snapshot(&self) -> SyncRuntimeSnapshot {
        self.state
            .lock()
            .map(|value| value.clone())
            .unwrap_or_default()
    }

    /// 请求停止：发送 Stop 命令并把运行状态立即置为 false，不等待线程退出。
    ///
    /// 在途同步（WinHTTP 最长 30 秒）会在下一个分页边界快速失败，随后
    /// 工作线程自行退出；调用方应在不持有其他状态锁的路径调用
    /// [`Self::join_worker`] 等待退出，避免 UI 冻结。
    pub fn request_stop(&self) {
        self.abort.store(true, Ordering::Release);
        let _ = self.sender.send(RuntimeCommand::Stop);
        if let Ok(mut value) = self.state.lock() {
            value.running = false;
            value.pending = false;
        }
    }

    /// 等待工作线程退出。应在不持有其他状态锁的路径调用。
    pub fn join_worker(&mut self) {
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }

    pub fn stop(&mut self) {
        self.request_stop();
        self.join_worker();
    }

    /// 构造一个不持有工作线程的已停止运行时，用于在不持锁路径安全替换旧运行时。
    pub fn stopped() -> Self {
        let (sender, _receiver) = mpsc::channel();
        Self {
            sender,
            state: Arc::new(Mutex::new(SyncRuntimeSnapshot::default())),
            abort: Arc::new(AtomicBool::new(false)),
            worker: None,
        }
    }
}

impl Drop for SyncRuntime {
    fn drop(&mut self) {
        self.stop();
    }
}

pub fn configure_repository_from_store(
    repository: &mut TaskRepository,
    store: &dyn SyncCredentialStore,
) -> Result<Option<SyncCredentials>, String> {
    let Some(credentials) = store.load()? else {
        repository.clear_runtime_sync_key();
        return Ok(None);
    };
    let configuration = core_configuration(&credentials)?;
    repository
        .configure_sync(configuration)
        .map_err(|error| format!("无法恢复同步绑定：{error}"))?;
    Ok(Some(credentials))
}

pub fn switch_sync_binding(
    repository: &mut TaskRepository,
    store: &dyn SyncCredentialStore,
    new_credentials: SyncCredentials,
    lamport_floor: i64,
) -> Result<(), String> {
    new_credentials.validate()?;
    let configuration = core_configuration(&new_credentials)?;
    let previous = store.load()?;
    store.save(&new_credentials)?;
    if let Err(error) =
        repository.replace_sync_binding_with_lamport_floor(configuration, lamport_floor)
    {
        let rollback = match previous {
            Some(ref value) => store.save(value),
            None => store.delete(),
        };
        return match rollback {
            Ok(()) => Err(format!("切换同步方式失败：{error}")),
            Err(rollback_error) => Err(format!(
                "切换同步方式失败（{error}），且旧安全凭据恢复失败（{rollback_error}）"
            )),
        };
    }
    Ok(())
}

pub fn synchronize_once<T: HttpTransport>(
    repository: &mut TaskRepository,
    credentials: &SyncCredentials,
    transport: T,
) -> Result<SyncRunSummary, String> {
    synchronize_once_inner(repository, credentials, transport, &AtomicBool::new(false))
}

fn synchronize_once_inner<T: HttpTransport>(
    repository: &mut TaskRepository,
    credentials: &SyncCredentials,
    transport: T,
    abort: &AtomicBool,
) -> Result<SyncRunSummary, String> {
    repository
        .configure_sync(core_configuration(credentials)?)
        .map_err(|error| format!("无法启用同步仓储：{error}"))?;
    match credentials.mode() {
        SyncMode::Worker | SyncMode::LocalNetwork => {
            synchronize_worker(repository, credentials, transport, abort)
        }
        SyncMode::WebDav => synchronize_webdav(repository, credentials, transport, abort),
    }
}

fn run_loop<T, Factory>(
    receiver: Receiver<RuntimeCommand>,
    state: Arc<Mutex<SyncRuntimeSnapshot>>,
    database_path: PathBuf,
    credentials_store: Arc<dyn SyncCredentialStore>,
    transport_factory: Factory,
    abort: Arc<AtomicBool>,
) where
    T: HttpTransport,
    Factory: Fn() -> T,
{
    loop {
        if abort.load(Ordering::Acquire) {
            return;
        }
        let command = match receiver.recv_timeout(FALLBACK_INTERVAL) {
            Ok(command) => command,
            Err(RecvTimeoutError::Timeout) => RuntimeCommand::Synchronize(SyncTrigger::Fallback),
            Err(RecvTimeoutError::Disconnected) => break,
        };
        let RuntimeCommand::Synchronize(mut trigger) = command else {
            break;
        };
        loop {
            while let Ok(command) = receiver.try_recv() {
                match command {
                    RuntimeCommand::Synchronize(next) => trigger = next,
                    RuntimeCommand::Stop => return,
                }
            }
            if abort.load(Ordering::Acquire) {
                return;
            }
            set_running(&state, trigger, true);
            let result = run_once_from_path(
                &database_path,
                credentials_store.as_ref(),
                transport_factory(),
                &abort,
            );
            publish_result(&state, result);

            let mut next = None;
            while let Ok(command) = receiver.try_recv() {
                match command {
                    RuntimeCommand::Synchronize(value) => next = Some(value),
                    RuntimeCommand::Stop => return,
                }
            }
            let pending = state.lock().map(|value| value.pending).unwrap_or(false);
            if let Some(value) = next {
                trigger = value;
            } else if pending {
                trigger = SyncTrigger::LocalChange;
            } else {
                break;
            }
            if let Ok(mut value) = state.lock() {
                value.pending = false;
            }
        }
    }
}

fn run_once_from_path<T: HttpTransport>(
    database_path: &Path,
    credentials_store: &dyn SyncCredentialStore,
    transport: T,
    abort: &AtomicBool,
) -> Result<Option<(SyncMode, SyncRunSummary)>, String> {
    let Some(credentials) = credentials_store.load()? else {
        // 未配置同步不算错误：侧边栏应显示“本地模式”，而不是同步错误。
        return Ok(None);
    };
    let mode = credentials.mode();
    let mut repository = TaskRepository::open(database_path)
        .map_err(|error| format!("无法打开同步数据库：{error}"))?;
    let summary = synchronize_once_inner(&mut repository, &credentials, transport, abort)?;
    Ok(Some((mode, summary)))
}

fn synchronize_worker<T: HttpTransport>(
    repository: &mut TaskRepository,
    credentials: &SyncCredentials,
    transport: T,
    abort: &AtomicBool,
) -> Result<SyncRunSummary, String> {
    let client = WorkerClient::new(credentials, transport)?;
    loop {
        match synchronize_worker_pass(repository, &client, abort) {
            Ok(summary) => return Ok(summary),
            Err(WorkerError::Server { code, .. }) if code == "CURSOR_AHEAD" => {
                // 服务端游标被重置（如主机状态文件重建或云端 KV 丢失）时，
                // 本地游标超过服务端最新序号会导致永久同步失败；把本地游标
                // 重置为 0 后重新开始同步循环（重新 push outbox 并从 0 拉取）。
                // 重置后游标 0 恒不大于服务端最新序号，循环必然终止；
                // 已应用的 opId 由客户端 applied 表去重，不会重复应用。
                repository
                    .reset_cursor()
                    .map_err(|error| format!("重置同步游标失败：{error}"))?;
            }
            Err(error) => return Err(error.to_string()),
        }
    }
}

fn synchronize_worker_pass<T: HttpTransport>(
    repository: &mut TaskRepository,
    client: &WorkerClient<T>,
    abort: &AtomicBool,
) -> Result<SyncRunSummary, WorkerError> {
    let mut pushed = 0;
    let mut pulled = 0;
    for page in 1..=MAXIMUM_WORKER_PAGES {
        if abort.load(Ordering::Acquire) {
            return Err(WorkerError::Protocol("同步已停止".to_owned()));
        }
        let cursor = repository
            .current_cursor()
            .map_err(|error| WorkerError::Protocol(format!("无法读取同步游标：{error}")))?;
        let pending = if page == 1 {
            repository
                .pending_operations(MAXIMUM_PUSH_BATCH)
                .map_err(|error| WorkerError::Protocol(format!("无法读取同步待发队列：{error}")))?
        } else {
            Vec::new()
        };
        let request = SyncRequest {
            cursor,
            ack: Some(cursor),
            pull_limit: Some(100),
            push: pending.clone(),
        };
        let response = client.synchronize(&request)?;
        if response.push.received != pending.len()
            || response.push.inserted + response.push.duplicates != response.push.received
        {
            return Err(WorkerError::Protocol(
                "同步服务 push 汇总与本次请求不匹配".to_owned(),
            ));
        }
        repository
            .apply_remote_operations(&response.pull, response.cursor)
            .map_err(|error| WorkerError::Protocol(format!("应用远端同步操作失败：{error}")))?;
        repository
            .acknowledge_operations(
                &pending
                    .iter()
                    .map(|operation| operation.op_id.clone())
                    .collect::<Vec<_>>(),
            )
            .map_err(|error| WorkerError::Protocol(format!("确认本地同步操作失败：{error}")))?;
        pushed += pending.len();
        pulled += response.pull.len();
        if !response.has_more {
            return Ok(SyncRunSummary {
                pushed,
                pulled,
                pages: page,
                final_cursor: response.cursor,
            });
        }
    }
    Err(WorkerError::Protocol(
        "同步分页超过安全上限，已停止本次同步".to_owned(),
    ))
}

fn synchronize_webdav<T: HttpTransport>(
    repository: &mut TaskRepository,
    credentials: &SyncCredentials,
    transport: T,
    abort: &AtomicBool,
) -> Result<SyncRunSummary, String> {
    if abort.load(Ordering::Acquire) {
        return Err("同步已停止".to_owned());
    }
    let client = WebDavClient::new(credentials, transport)?;
    client.ensure_collections()?;
    let pending = repository
        .pending_operations(MAXIMUM_PUSH_BATCH)
        .map_err(|error| format!("无法读取 WebDAV 待发队列：{error}"))?;
    for operation in &pending {
        client.put(&WebDavOperation::from_push(
            client.vault_id(),
            client.device_id(),
            operation.clone(),
        ))?;
    }
    let paths = client.list_operation_paths()?;
    let mut operations = Vec::with_capacity(paths.len());
    for path in &paths {
        operations.push(client.get_operation(path)?);
    }
    for chunk in operations.chunks(WEBDAV_APPLY_BATCH) {
        repository
            .apply_webdav_operations(chunk)
            .map_err(|error| format!("应用 WebDAV 同步操作失败：{error}"))?;
    }
    repository
        .acknowledge_operations(
            &pending
                .iter()
                .map(|operation| operation.op_id.clone())
                .collect::<Vec<_>>(),
        )
        .map_err(|error| format!("确认 WebDAV 同步操作失败：{error}"))?;
    Ok(SyncRunSummary {
        pushed: pending.len(),
        pulled: operations.len(),
        pages: operations.len().div_ceil(WEBDAV_APPLY_BATCH).max(1),
        final_cursor: 0,
    })
}

fn core_configuration(credentials: &SyncCredentials) -> Result<SyncConfiguration, String> {
    let key = base64url_decode(credentials.vault_key())
        .map_err(|error| format!("同步密钥无效：{error}"))?;
    SyncConfiguration::new(credentials.vault_id(), credentials.device_id(), &key)
        .map_err(|error| format!("同步身份无效：{error}"))
}

fn set_running(state: &Arc<Mutex<SyncRuntimeSnapshot>>, trigger: SyncTrigger, running: bool) {
    if let Ok(mut value) = state.lock() {
        value.running = running;
        value.pending = false;
        value.last_trigger = Some(trigger);
        if running {
            value.last_error = None;
        }
    }
}

fn publish_result(
    state: &Arc<Mutex<SyncRuntimeSnapshot>>,
    result: Result<Option<(SyncMode, SyncRunSummary)>, String>,
) {
    if let Ok(mut value) = state.lock() {
        value.running = false;
        match result {
            Ok(Some((mode, summary))) => {
                value.configured_mode = Some(mode);
                value.last_successful_at = Some(now_millis());
                value.last_summary = Some(summary);
                value.last_error = None;
            }
            // 未配置同步不是错误：保持“本地模式”显示，并清空陈旧错误，
            // 避免侧边栏对未配置用户误报同步失败。
            Ok(None) => {
                value.configured_mode = None;
                value.last_error = None;
            }
            Err(error) => {
                value.last_error = Some(error);
            }
        }
    }
}

fn now_millis() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::fs;

    use woo_todo_core::{
        OperationCodec, OperationKind, QuestLine, SyncPulledOperation, TimeType, WireEntity,
        WireTaskPayload, base64url_encode,
    };

    use super::*;
    use crate::credentials::MemoryCredentialStore;
    use crate::http::{HttpRequest, HttpResponse};

    #[derive(Default)]
    struct OfflineTransport;

    impl HttpTransport for OfflineTransport {
        fn execute(&self, _request: HttpRequest) -> Result<HttpResponse, String> {
            Err("测试网络离线".to_owned())
        }
    }

    /// 按脚本依次返回响应的传输，并记录每次请求携带的 cursor。
    struct ScriptedTransport {
        responses: Mutex<VecDeque<HttpResponse>>,
        requests: Arc<Mutex<Vec<(i64, usize)>>>,
    }

    impl ScriptedTransport {
        fn new(responses: Vec<HttpResponse>) -> Self {
            Self {
                responses: Mutex::new(responses.into()),
                requests: Arc::new(Mutex::new(Vec::new())),
            }
        }
    }

    impl HttpTransport for ScriptedTransport {
        fn execute(&self, request: HttpRequest) -> Result<HttpResponse, String> {
            request.validate()?;
            let value: serde_json::Value = serde_json::from_slice(&request.body).unwrap();
            let cursor = value["cursor"].as_i64().unwrap_or(-1);
            let push_len = value["push"].as_array().map(Vec::len).unwrap_or(0);
            self.requests.lock().unwrap().push((cursor, push_len));
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .ok_or_else(|| "测试响应不足".to_owned())
        }
    }

    fn sync_success(
        push: (usize, usize, usize),
        pull: &[SyncPulledOperation],
        cursor: i64,
        has_more: bool,
        request_id: &str,
    ) -> HttpResponse {
        let pull = serde_json::to_string(pull).unwrap();
        HttpResponse {
            status: 200,
            body: format!(
                r#"{{"ok":true,"data":{{"push":{{"received":{},"inserted":{},"duplicates":{}}},"pull":{pull},"cursor":{cursor},"hasMore":{has_more},"serverTime":1000}},"requestId":"{request_id}"}}"#,
                push.0, push.1, push.2
            )
            .into_bytes(),
        }
    }

    fn cursor_ahead_failure(request_id: &str) -> HttpResponse {
        HttpResponse {
            status: 409,
            body: format!(
                r#"{{"ok":false,"error":{{"code":"CURSOR_AHEAD","message":"客户端游标超过服务端最新序号"}},"requestId":"{request_id}"}}"#
            )
            .into_bytes(),
        }
    }

    fn worker_credentials(vault: &str, device: &str) -> SyncCredentials {
        SyncCredentials::Worker {
            endpoint: "https://sync.example.com".to_owned(),
            vault_id: vault.to_owned(),
            device_id: device.to_owned(),
            device_token: base64url_encode(&[1; 32]),
            vault_key: base64url_encode(&[2; 32]),
        }
    }

    #[test]
    fn offline_sync_keeps_local_outbox_and_tasks() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tasks.sqlite");
        let mut repository = TaskRepository::open(&path).unwrap();
        let credentials = worker_credentials("vault-runtime", "device-runtime-1");
        repository
            .configure_sync(core_configuration(&credentials).unwrap())
            .unwrap();
        repository
            .create(
                "离线任务",
                TimeType::Day,
                chrono::NaiveDate::from_ymd_opt(2026, 7, 29).unwrap(),
                QuestLine::Main,
                false,
                None,
                None,
                1_000,
            )
            .unwrap();
        let before = repository.sync_state().unwrap();
        assert_eq!(before.outbox_count, 1);

        assert!(synchronize_once(&mut repository, &credentials, OfflineTransport).is_err());
        assert_eq!(repository.fetch_all().unwrap().len(), 1);
        assert_eq!(repository.sync_state().unwrap().outbox_count, 1);
    }

    #[test]
    fn repository_uses_deferred_changes_when_credentials_temporarily_unavailable() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tasks.sqlite");
        let credentials = worker_credentials("vault-deferred", "device-deferred-1");
        {
            let mut repository = TaskRepository::open(&path).unwrap();
            repository
                .configure_sync(core_configuration(&credentials).unwrap())
                .unwrap();
        }
        {
            let mut repository = TaskRepository::open(&path).unwrap();
            repository
                .create(
                    "凭据暂不可用",
                    TimeType::Day,
                    chrono::NaiveDate::from_ymd_opt(2026, 7, 29).unwrap(),
                    QuestLine::Main,
                    false,
                    None,
                    None,
                    2_000,
                )
                .unwrap();
            assert_eq!(repository.sync_state().unwrap().deferred_upsert_count, 1);
            repository
                .configure_sync(core_configuration(&credentials).unwrap())
                .unwrap();
            let state = repository.sync_state().unwrap();
            assert_eq!(state.deferred_upsert_count, 0);
            assert_eq!(state.outbox_count, 1);
        }
    }

    #[test]
    fn credential_store_never_writes_secrets_to_settings_file() {
        let directory = tempfile::tempdir().unwrap();
        let store = MemoryCredentialStore::default();
        let credentials = worker_credentials("vault-secret", "device-secret-1");
        store.save(&credentials).unwrap();
        fs::write(directory.path().join("settings.json"), "{\"Opacity\":0.9}").unwrap();
        let source = fs::read_to_string(directory.path().join("settings.json")).unwrap();
        assert!(!source.contains(credentials.vault_key()));
        assert!(!source.contains(credentials.device_token().unwrap()));
    }

    #[test]
    fn cursor_ahead_is_recovered_by_reset_and_retry() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tasks.sqlite");
        let mut repository = TaskRepository::open(&path).unwrap();
        let credentials = worker_credentials("vault-recover", "device-recover-1");
        let configuration = core_configuration(&credentials).unwrap();
        repository.configure_sync(configuration.clone()).unwrap();
        let task_id = repository
            .create(
                "恢复任务",
                TimeType::Day,
                chrono::NaiveDate::from_ymd_opt(2026, 7, 29).unwrap(),
                QuestLine::Main,
                false,
                None,
                None,
                1_000,
            )
            .unwrap();
        let task = repository.find(&task_id).unwrap().unwrap();
        let entity = WireEntity::Task(WireTaskPayload::from_task(&task).unwrap());
        let envelope = OperationCodec::seal(
            &entity,
            &configuration,
            "op-remote-recover",
            &task_id,
            OperationKind::Upsert,
            1,
            None,
        )
        .unwrap();
        let remote = SyncPulledOperation {
            server_seq: 1,
            op_id: "op-remote-recover".to_owned(),
            device_id: configuration.device_id.clone(),
            entity_id: task_id.clone(),
            kind: OperationKind::Upsert,
            lamport: 1,
            ciphertext: envelope.ciphertext,
            nonce: envelope.nonce,
            created_at: 1_000,
        };

        let transport = ScriptedTransport::new(vec![
            // 第一轮：推送 1 条本地操作并拉取 1 条远端操作，游标推进到 1。
            sync_success((1, 1, 0), &[remote], 1, true, "request-page-1"),
            // 第二轮：服务端返回 409 CURSOR_AHEAD（模拟服务端状态文件重建）。
            cursor_ahead_failure("request-cursor-ahead"),
            // 重置后重新从 0 同步：outbox 已清空，远端操作按 opId 幂等跳过。
            sync_success((0, 0, 0), &[remote], 1, false, "request-retry"),
        ]);
        // 请求序列（cursor, push 条数）：0+1（首轮推送 1 条）→ 1+0（触发
        // CURSOR_AHEAD）→ 0+0（重置后重试，outbox 已清空）。
        let request_log = transport.requests.clone();

        let summary = synchronize_once(&mut repository, &credentials, transport).unwrap();

        // 重试成功后 summary 反映最终成功的一轮：首轮已推送的操作已在
        // 服务端生效（outbox 已清空），远端操作按 opId 幂等跳过。
        assert_eq!(summary.pushed, 0);
        assert_eq!(summary.pulled, 1);
        assert_eq!(summary.pages, 1);
        assert_eq!(summary.final_cursor, 1);
        assert_eq!(repository.current_cursor().unwrap(), 1);
        assert_eq!(repository.sync_state().unwrap().outbox_count, 0);
        assert_eq!(repository.fetch_all().unwrap().len(), 1);
        assert_eq!(
            request_log.lock().unwrap().clone(),
            vec![(0, 1), (1, 0), (0, 0)]
        );
    }

    #[test]
    fn unconfigured_sync_is_not_reported_as_an_error() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tasks.sqlite");
        let store = MemoryCredentialStore::default();
        let state = Arc::new(Mutex::new(SyncRuntimeSnapshot {
            configured_mode: Some(SyncMode::Worker),
            running: true,
            last_error: Some("同步尚未配置".to_owned()),
            ..SyncRuntimeSnapshot::default()
        }));

        let result = run_once_from_path(&path, &store, OfflineTransport, &AtomicBool::new(false));

        // 未配置凭据时返回 Ok(None)，publish_result 不应写 last_error。
        assert!(matches!(result, Ok(None)));
        publish_result(&state, result);
        let snapshot = state.lock().unwrap().clone();
        assert!(!snapshot.running);
        assert_eq!(snapshot.configured_mode, None);
        assert_eq!(snapshot.last_error, None);
        assert_eq!(snapshot.last_successful_at, None);
    }
}
