use std::path::{Path, PathBuf};
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
use crate::worker::WorkerClient;

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
        let worker = thread::spawn(move || {
            run_loop(
                receiver,
                thread_state,
                database_path,
                credentials,
                transport_factory,
            )
        });
        Self {
            sender,
            state,
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

    pub fn stop(&mut self) {
        let _ = self.sender.send(RuntimeCommand::Stop);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
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

pub fn switch_sync_binding<Preflight>(
    repository: &mut TaskRepository,
    store: &dyn SyncCredentialStore,
    new_credentials: SyncCredentials,
    preflight: Preflight,
) -> Result<(), String>
where
    Preflight: FnOnce(&SyncCredentials) -> Result<(), String>,
{
    new_credentials.validate()?;
    preflight(&new_credentials)?;
    let configuration = core_configuration(&new_credentials)?;
    let previous = store.load()?;
    store.save(&new_credentials)?;
    if let Err(error) = repository.replace_sync_binding(configuration) {
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
    repository
        .configure_sync(core_configuration(credentials)?)
        .map_err(|error| format!("无法启用同步仓储：{error}"))?;
    match credentials.mode() {
        SyncMode::Worker | SyncMode::LocalNetwork => {
            synchronize_worker(repository, credentials, transport)
        }
        SyncMode::WebDav => synchronize_webdav(repository, credentials, transport),
    }
}

fn run_loop<T, Factory>(
    receiver: Receiver<RuntimeCommand>,
    state: Arc<Mutex<SyncRuntimeSnapshot>>,
    database_path: PathBuf,
    credentials_store: Arc<dyn SyncCredentialStore>,
    transport_factory: Factory,
) where
    T: HttpTransport,
    Factory: Fn() -> T,
{
    loop {
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
            set_running(&state, trigger, true);
            let result = run_once_from_path(
                &database_path,
                credentials_store.as_ref(),
                transport_factory(),
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
) -> Result<(SyncMode, SyncRunSummary), String> {
    let credentials = credentials_store
        .load()?
        .ok_or_else(|| "同步尚未配置".to_owned())?;
    let mode = credentials.mode();
    let mut repository = TaskRepository::open(database_path)
        .map_err(|error| format!("无法打开同步数据库：{error}"))?;
    let summary = synchronize_once(&mut repository, &credentials, transport)?;
    Ok((mode, summary))
}

fn synchronize_worker<T: HttpTransport>(
    repository: &mut TaskRepository,
    credentials: &SyncCredentials,
    transport: T,
) -> Result<SyncRunSummary, String> {
    let client = WorkerClient::new(credentials, transport)?;
    let mut pushed = 0;
    let mut pulled = 0;
    for page in 1..=MAXIMUM_WORKER_PAGES {
        let cursor = repository
            .current_cursor()
            .map_err(|error| format!("无法读取同步游标：{error}"))?;
        let pending = if page == 1 {
            repository
                .pending_operations(MAXIMUM_PUSH_BATCH)
                .map_err(|error| format!("无法读取同步待发队列：{error}"))?
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
            return Err("同步服务 push 汇总与本次请求不匹配".to_owned());
        }
        repository
            .apply_remote_operations(&response.pull, response.cursor)
            .map_err(|error| format!("应用远端同步操作失败：{error}"))?;
        repository
            .acknowledge_operations(
                &pending
                    .iter()
                    .map(|operation| operation.op_id.clone())
                    .collect::<Vec<_>>(),
            )
            .map_err(|error| format!("确认本地同步操作失败：{error}"))?;
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
    Err("同步分页超过安全上限，已停止本次同步".to_owned())
}

fn synchronize_webdav<T: HttpTransport>(
    repository: &mut TaskRepository,
    credentials: &SyncCredentials,
    transport: T,
) -> Result<SyncRunSummary, String> {
    let client = WebDavClient::new(credentials, transport)?;
    client.ensure_collections()?;
    let pending = repository
        .pending_operations(MAXIMUM_PUSH_BATCH)
        .map_err(|error| format!("无法读取坚果云待发队列：{error}"))?;
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
            .map_err(|error| format!("应用坚果云同步操作失败：{error}"))?;
    }
    repository
        .acknowledge_operations(
            &pending
                .iter()
                .map(|operation| operation.op_id.clone())
                .collect::<Vec<_>>(),
        )
        .map_err(|error| format!("确认坚果云同步操作失败：{error}"))?;
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
    result: Result<(SyncMode, SyncRunSummary), String>,
) {
    if let Ok(mut value) = state.lock() {
        value.running = false;
        match result {
            Ok((mode, summary)) => {
                value.configured_mode = Some(mode);
                value.last_successful_at = Some(now_millis());
                value.last_summary = Some(summary);
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
    use std::fs;

    use woo_todo_core::{QuestLine, TimeType, base64url_encode};

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
}
