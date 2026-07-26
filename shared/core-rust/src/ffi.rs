use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::{CoreError, CoreResult};
use crate::model::{QuestLine, ReminderTime, TimeType, TodoTask, validate_title};
use crate::notification::notification_plans;
use crate::period::{next_start, normalize_start, occurrence_id, today_shanghai};
use crate::repository::TaskRepository;
use crate::settlement::settle;
use crate::statistics::calculate_statistics;

static REPOSITORIES: LazyLock<Mutex<HashMap<u64, TaskRepository>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Deserialize)]
#[serde(
    tag = "action",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum CoreRequest {
    Today,
    NormalizeStart {
        time_type: TimeType,
        date: NaiveDate,
    },
    NextStart {
        time_type: TimeType,
        date: NaiveDate,
    },
    OccurrenceId {
        series_id: String,
        time_type: TimeType,
        period_start: NaiveDate,
    },
    ValidateTitle {
        title: String,
    },
    ValidateTask {
        task: TodoTask,
    },
    Settle {
        tasks: Vec<TodoTask>,
        reference_date: NaiveDate,
        now: i64,
        #[serde(default)]
        reserved_task_ids: HashSet<String>,
    },
    Statistics {
        tasks: Vec<TodoTask>,
        reference_date: NaiveDate,
        #[serde(default = "default_history_limit")]
        history_limit: usize,
    },
    NotificationPlan {
        tasks: Vec<TodoTask>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(
    tag = "action",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum RepositoryRequest {
    FetchAll,
    Find {
        id: String,
    },
    DeletedTaskIds,
    FetchScope {
        time_type: TimeType,
        reference_date: NaiveDate,
        #[serde(default = "default_true")]
        include_planned: bool,
    },
    Create {
        title: String,
        time_type: TimeType,
        target_date: NaiveDate,
        quest_line: QuestLine,
        repeats: bool,
        reminder_time: Option<ReminderTime>,
        now: i64,
    },
    Update {
        id: String,
        title: String,
        time_type: TimeType,
        target_date: NaiveDate,
        quest_line: QuestLine,
        repeats: bool,
        reminder_time: Option<ReminderTime>,
        now: i64,
    },
    Complete {
        id: String,
        now: i64,
    },
    Pass {
        id: String,
        now: i64,
    },
    Move {
        id: String,
        offset: i32,
        now: i64,
    },
    Delete {
        id: String,
        now: i64,
    },
    SettleExpired {
        reference_date: NaiveDate,
        now: i64,
    },
    Save {
        task: TodoTask,
    },
    SaveMany {
        tasks: Vec<TodoTask>,
    },
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Envelope {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    value: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ErrorPayload>,
}

#[derive(Debug, Serialize)]
struct ErrorPayload {
    code: &'static str,
    message: String,
}

#[unsafe(no_mangle)]
pub extern "C" fn woo_todo_core_call(request_json: *const c_char) -> *mut c_char {
    boundary(|| call_core(read_c_string(request_json)))
}

#[unsafe(no_mangle)]
pub extern "C" fn woo_todo_repository_open(database_path: *const c_char) -> *mut c_char {
    boundary(|| {
        read_c_string(database_path).and_then(|path| {
            let repository = TaskRepository::open(path)?;
            let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
            repositories()?.insert(handle, repository);
            Ok(json!(handle))
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn woo_todo_repository_call(
    handle: u64,
    request_json: *const c_char,
) -> *mut c_char {
    boundary(|| {
        read_c_string(request_json).and_then(|request| {
            let request: RepositoryRequest = serde_json::from_str(&request)?;
            let mut repositories = repositories()?;
            let repository = repositories
                .get_mut(&handle)
                .ok_or_else(|| CoreError::not_found("共享核心仓储句柄不存在或已关闭"))?;
            call_repository(repository, request)
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn woo_todo_repository_close(handle: u64) -> *mut c_char {
    boundary(|| repositories().map(|mut values| json!(values.remove(&handle).is_some())))
}

#[unsafe(no_mangle)]
pub extern "C" fn woo_todo_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    // SAFETY: 指针只能来自本模块 CString::into_raw，且调用约定要求只释放一次。
    unsafe {
        drop(CString::from_raw(value));
    }
}

fn call_core(request: CoreResult<String>) -> CoreResult<Value> {
    let request: CoreRequest = serde_json::from_str(&request?)?;
    match request {
        CoreRequest::Today => serialize(today_shanghai()),
        CoreRequest::NormalizeStart { time_type, date } => {
            serialize(normalize_start(time_type, date))
        }
        CoreRequest::NextStart { time_type, date } => serialize(next_start(time_type, date)),
        CoreRequest::OccurrenceId {
            series_id,
            time_type,
            period_start,
        } => serialize(occurrence_id(&series_id, time_type, period_start)),
        CoreRequest::ValidateTitle { title } => serialize(validate_title(&title)?),
        CoreRequest::ValidateTask { task } => {
            task.validate()?;
            Ok(json!(true))
        }
        CoreRequest::Settle {
            tasks,
            reference_date,
            now,
            reserved_task_ids,
        } => serialize(settle(&tasks, reference_date, now, &reserved_task_ids)),
        CoreRequest::Statistics {
            tasks,
            reference_date,
            history_limit,
        } => serialize(calculate_statistics(&tasks, reference_date, history_limit)),
        CoreRequest::NotificationPlan { tasks } => serialize(notification_plans(&tasks)),
    }
}

fn call_repository(
    repository: &mut TaskRepository,
    request: RepositoryRequest,
) -> CoreResult<Value> {
    match request {
        RepositoryRequest::FetchAll => serialize(repository.fetch_all()?),
        RepositoryRequest::Find { id } => serialize(repository.find(&id)?),
        RepositoryRequest::DeletedTaskIds => {
            let mut values: Vec<String> = repository.deleted_task_ids()?.into_iter().collect();
            values.sort();
            serialize(values)
        }
        RepositoryRequest::FetchScope {
            time_type,
            reference_date,
            include_planned,
        } => serialize(repository.fetch_scope(time_type, reference_date, include_planned)?),
        RepositoryRequest::Create {
            title,
            time_type,
            target_date,
            quest_line,
            repeats,
            reminder_time,
            now,
        } => serialize(repository.create(
            &title,
            time_type,
            target_date,
            quest_line,
            repeats,
            reminder_time,
            now,
        )?),
        RepositoryRequest::Update {
            id,
            title,
            time_type,
            target_date,
            quest_line,
            repeats,
            reminder_time,
            now,
        } => serialize(repository.update(
            &id,
            &title,
            time_type,
            target_date,
            quest_line,
            repeats,
            reminder_time,
            now,
        )?),
        RepositoryRequest::Complete { id, now } => serialize(repository.complete(&id, now)?),
        RepositoryRequest::Pass { id, now } => serialize(repository.pass(&id, now)?),
        RepositoryRequest::Move { id, offset, now } => {
            serialize(repository.move_task(&id, offset, now)?)
        }
        RepositoryRequest::Delete { id, now } => serialize(repository.delete(&id, now)?),
        RepositoryRequest::SettleExpired {
            reference_date,
            now,
        } => serialize(repository.settle_expired(reference_date, now)?),
        RepositoryRequest::Save { task } => {
            repository.save(&task)?;
            Ok(json!(true))
        }
        RepositoryRequest::SaveMany { tasks } => {
            repository.save_many(&tasks)?;
            Ok(json!(true))
        }
    }
}

fn repositories() -> CoreResult<std::sync::MutexGuard<'static, HashMap<u64, TaskRepository>>> {
    REPOSITORIES
        .lock()
        .map_err(|_| CoreError::new("internal", "共享核心仓储锁已损坏"))
}

fn read_c_string(value: *const c_char) -> CoreResult<String> {
    if value.is_null() {
        return Err(CoreError::new("invalid_argument", "FFI 字符串指针不能为空"));
    }
    // SAFETY: 调用方保证传入以 NUL 结尾、在本次调用期间有效的 C 字符串。
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| CoreError::new("invalid_argument", "FFI 字符串必须是 UTF-8"))
}

fn serialize(value: impl Serialize) -> CoreResult<Value> {
    serde_json::to_value(value).map_err(Into::into)
}

fn boundary(action: impl FnOnce() -> CoreResult<Value>) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(action)).unwrap_or_else(|_| {
        Err(CoreError::new(
            "internal",
            "共享核心发生未预期错误，操作已安全终止",
        ))
    });
    encode(result)
}

fn encode(result: CoreResult<Value>) -> *mut c_char {
    let envelope = match result {
        Ok(value) => Envelope {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => Envelope {
            ok: false,
            value: None,
            error: Some(ErrorPayload {
                code: error.code,
                message: error.message,
            }),
        },
    };
    let json = serde_json::to_string(&envelope).unwrap_or_else(|_| {
        "{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"无法编码共享核心响应\"}}"
            .to_owned()
    });
    CString::new(json)
        .expect("JSON 编码结果不能包含 NUL")
        .into_raw()
}

const fn default_true() -> bool {
    true
}

const fn default_history_limit() -> usize {
    30
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_accepts_camel_case_fields_and_preserves_null_values() {
        let normalized =
            core_call(r#"{"action":"normalizeStart","timeType":"week","date":"2026-07-24"}"#);
        assert_eq!(normalized["ok"], true);
        assert_eq!(normalized["value"], "2026-07-20");

        let someday =
            core_call(r#"{"action":"normalizeStart","timeType":"someday","date":"2026-07-24"}"#);
        assert_eq!(someday["ok"], true);
        assert!(someday.get("value").is_some_and(Value::is_null));

        let directory = tempfile::tempdir().expect("创建测试目录");
        let database = directory.path().join("ffi.sqlite3");
        let path = CString::new(database.to_string_lossy().as_bytes()).expect("数据库路径");
        let opened = decode(woo_todo_repository_open(path.as_ptr()));
        let handle = opened["value"].as_u64().expect("仓储句柄");
        let request = CString::new(
            r#"{"action":"fetchScope","timeType":"day","referenceDate":"2026-07-24","includePlanned":true}"#,
        )
        .expect("仓储请求");
        let response = decode(woo_todo_repository_call(handle, request.as_ptr()));
        assert_eq!(response["ok"], true);
        assert_eq!(response["value"], json!([]));
        let closed = decode(woo_todo_repository_close(handle));
        assert_eq!(closed["value"], true);
    }

    fn core_call(request: &str) -> Value {
        let request = CString::new(request).expect("核心请求");
        decode(woo_todo_core_call(request.as_ptr()))
    }

    fn decode(pointer: *mut c_char) -> Value {
        assert!(!pointer.is_null());
        // SAFETY: 测试只读取本模块刚返回且尚未释放的 NUL 结尾字符串。
        let source = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .expect("FFI 响应 UTF-8")
            .to_owned();
        woo_todo_string_free(pointer);
        serde_json::from_str(&source).expect("FFI 响应 JSON")
    }
}
