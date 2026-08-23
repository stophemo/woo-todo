use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::{NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use tauri::{
    AppHandle, Emitter, Manager, State, WebviewWindow,
    menu::{CheckMenuItemBuilder, MenuBuilder, MenuItemBuilder, SubmenuBuilder},
    tray::TrayIconBuilder,
};
use woo_todo_core::{
    QuestLine, Recurrence, ReminderTime, StatisticsSnapshot, TaskRepository, TaskState, TimeType,
    TodoTask, calculate_statistics, today_shanghai,
};

use crate::credentials::{SyncCredentialStore, SyncCredentials, SyncMode, WindowsCredentialStore};
use crate::display::DisplayConfiguration;
use crate::hotkeys::{HotkeyEvent, HotkeyManager};
use crate::http::WinHttpTransport;
use crate::local_server::{DEFAULT_LOCAL_SYNC_PORT, preferred_local_endpoint};
use crate::local_sync_host::{
    LocalSyncHost, generate_local_network_credentials, local_state_path,
};
use crate::lunar::TraditionalCalendarInfo;
use crate::settings::AppSettings;
use crate::shortcut::{ShortcutCommand, command_label, format_shortcut_binding};
use crate::sync_runtime::{
    SyncRuntime, SyncTrigger, configure_repository_from_store, switch_sync_binding,
};
use crate::ui_text::period_label;
use crate::worker::{PairingLink, WorkerClient};

struct RuntimeState {
    repository: Mutex<TaskRepository>,
    settings: Mutex<AppSettings>,
    credentials: Arc<dyn SyncCredentialStore>,
    database_path: PathBuf,
    sync_runtime: Mutex<SyncRuntime>,
    local_host: Mutex<Option<LocalSyncHost>>,
    hotkeys: Mutex<Option<HotkeyManager>>,
    shortcut_error: Mutex<Option<String>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct AppSnapshot {
    reference_date: NaiveDate,
    header: Option<String>,
    subtitle: Option<String>,
    lunar_date: String,
    lunar_annotation: Option<String>,
    tasks: Vec<TaskView>,
    statistics: StatisticsSnapshot,
    board: BoardPreferences,
    sync: SyncSummary,
    local_sync: LocalSyncSummary,
    shortcuts: Vec<ShortcutView>,
    shortcut_error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ShortcutView {
    label: String,
    display: String,
    icon: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TaskView {
    id: String,
    title: String,
    time_type: TimeType,
    period_start: Option<NaiveDate>,
    quest_line: QuestLine,
    state: TaskState,
    recurrence: Recurrence,
    reminder_time: Option<String>,
    deadline_date: Option<NaiveDate>,
    period_label: String,
}

impl From<TodoTask> for TaskView {
    fn from(task: TodoTask) -> Self {
        let rendered_period = period_label(&task);
        Self {
            id: task.id,
            title: task.title,
            time_type: task.time_type,
            period_start: task.period_start,
            quest_line: task.quest_line,
            state: task.state,
            recurrence: task.recurrence,
            reminder_time: task.reminder_time.map(ReminderTime::wire_value),
            deadline_date: task.deadline_date,
            period_label: rendered_period,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct BoardPreferences {
    opacity_percent: u8,
    always_on_top: bool,
    click_through: bool,
    desktop_widget: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncSummary {
    configured_mode: Option<&'static str>,
    running: bool,
    pending: bool,
    last_successful_at: Option<i64>,
    last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct LocalSyncSummary {
    enabled: bool,
    endpoint: Option<String>,
    vault_id: Option<String>,
    pairing: Option<crate::local_sync_host::LocalPairingView>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateTaskInput {
    title: String,
    time_type: TimeType,
    target_date: NaiveDate,
    quest_line: QuestLine,
    repeats: bool,
    reminder_time: Option<String>,
    deadline_date: Option<NaiveDate>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateTaskInput {
    id: String,
    #[serde(flatten)]
    task: CreateTaskInput,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BoardPreferencesInput {
    opacity_percent: u8,
    always_on_top: bool,
    click_through: bool,
    #[serde(default)]
    desktop_widget: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct JoinSyncInput {
    pairing_link: String,
    #[serde(default)]
    confirm_replace: bool,
    /// 加入已有同步空间时以远端数据为准：移除本地任务（不生成同步
    /// 操作，不会上传覆盖其他设备），再完整拉取同步空间的数据。
    #[serde(default)]
    clear_local_tasks: bool,
}

#[tauri::command]
fn get_snapshot(state: State<'_, RuntimeState>) -> Result<AppSnapshot, String> {
    snapshot(&state)
}

#[tauri::command]
fn create_task(
    state: State<'_, RuntimeState>,
    input: CreateTaskInput,
) -> Result<AppSnapshot, String> {
    let reminder_time = input
        .reminder_time
        .filter(|value| !value.is_empty())
        .map(|value| ReminderTime::parse(&value))
        .transpose()
        .map_err(|error| error.to_string())?;
    {
        let mut repository = lock(&state.repository, "任务库")?;
        repository
            .create(
                &input.title,
                input.time_type,
                input.target_date,
                input.quest_line,
                input.repeats,
                reminder_time,
                input.deadline_date,
                now_millis(),
            )
            .map_err(|error| error.to_string())?;
    }
    after_task_change(&state);
    snapshot(&state)
}

#[tauri::command]
fn update_task(
    state: State<'_, RuntimeState>,
    input: UpdateTaskInput,
) -> Result<AppSnapshot, String> {
    let reminder_time = input
        .task
        .reminder_time
        .filter(|value| !value.is_empty())
        .map(|value| ReminderTime::parse(&value))
        .transpose()
        .map_err(|error| error.to_string())?;
    {
        let mut repository = lock(&state.repository, "任务库")?;
        repository
            .update(
                &input.id,
                &input.task.title,
                input.task.time_type,
                input.task.target_date,
                input.task.quest_line,
                input.task.repeats,
                reminder_time,
                input.task.deadline_date,
                now_millis(),
            )
            .map_err(|error| error.to_string())?;
    }
    after_task_change(&state);
    snapshot(&state)
}

#[tauri::command]
fn toggle_task(state: State<'_, RuntimeState>, id: String) -> Result<AppSnapshot, String> {
    let reference_date = today_shanghai();
    {
        let mut repository = lock(&state.repository, "任务库")?;
        let task = repository
            .find(&id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| "任务不存在或已被删除".to_string())?;
        match task.state {
            TaskState::Pending => repository.complete(&id, now_millis()),
            TaskState::Completed => repository.reopen_completed(&id, reference_date, now_millis()),
            TaskState::Pass => Ok(false),
        }
        .map_err(|error| error.to_string())?;
    }
    after_task_change(&state);
    snapshot(&state)
}

#[tauri::command]
fn pass_task(state: State<'_, RuntimeState>, id: String) -> Result<AppSnapshot, String> {
    {
        let mut repository = lock(&state.repository, "任务库")?;
        repository
            .pass(&id, now_millis())
            .map_err(|error| error.to_string())?;
    }
    after_task_change(&state);
    snapshot(&state)
}

#[tauri::command]
fn delete_task(state: State<'_, RuntimeState>, id: String) -> Result<AppSnapshot, String> {
    {
        let mut repository = lock(&state.repository, "任务库")?;
        repository
            .delete(&id, now_millis())
            .map_err(|error| error.to_string())?;
    }
    after_task_change(&state);
    snapshot(&state)
}

#[tauri::command]
fn move_task(
    state: State<'_, RuntimeState>,
    id: String,
    offset: i32,
) -> Result<AppSnapshot, String> {
    {
        let mut repository = lock(&state.repository, "任务库")?;
        repository
            .move_task(&id, offset, now_millis())
            .map_err(|error| error.to_string())?;
    }
    after_task_change(&state);
    snapshot(&state)
}

#[tauri::command]
fn request_sync(state: State<'_, RuntimeState>) -> Result<AppSnapshot, String> {
    lock(&state.sync_runtime, "同步运行时")?.request(SyncTrigger::Manual);
    snapshot(&state)
}

#[tauri::command]
async fn join_sync_space(
    app: AppHandle,
    state: State<'_, RuntimeState>,
    input: JoinSyncInput,
) -> Result<AppSnapshot, String> {
    let link = PairingLink::parse(input.pairing_link.trim())?;
    let existing = state.credentials.load()?;
    if existing.is_some() && !input.confirm_replace {
        return Err(
            "Windows 已有同步身份。请再次点击加入并确认替换；本地任务和待同步数据会保留。"
                .to_owned(),
        );
    }
    if let (Some(existing), Some(link_vault_id)) = (&existing, link.vault_id.as_deref())
        && existing.vault_id() != link_vault_id
    {
        return Err(
            "配对链接属于另一个同步空间。Windows 没有替换现有同步身份，也没有修改本地任务。"
                .to_owned(),
        );
    }
    let expected_vault_id = existing.map(|credentials| credentials.vault_id().to_owned());
    let device_name = std::env::var("COMPUTERNAME")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty() && value.chars().count() <= 80)
        .unwrap_or_else(|| "Windows PC".to_owned());
    let endpoint_scheme = url::Url::parse(&link.endpoint)
        .map_err(|_| "配对服务地址格式无效".to_owned())?
        .scheme()
        .to_ascii_lowercase();
    let mode = match endpoint_scheme.as_str() {
        "https" => SyncMode::Worker,
        "http" => SyncMode::LocalNetwork,
        _ => return Err("配对服务只支持 HTTPS 或局域网 HTTP".to_owned()),
    };
    let pairing_link = link.clone();
    let joined = tauri::async_runtime::spawn_blocking(move || {
        let client = WorkerClient::for_pairing(&pairing_link, WinHttpTransport)?;
        let joined =
            client.join_pairing(&pairing_link, &device_name, expected_vault_id.as_deref())?;
        let credentials = match mode {
            SyncMode::Worker => SyncCredentials::Worker {
                endpoint: pairing_link.endpoint,
                vault_id: joined.vault_id,
                device_id: joined.device_id,
                device_token: joined.device_token,
                vault_key: joined.vault_key,
            },
            SyncMode::LocalNetwork => SyncCredentials::LocalNetwork {
                endpoint: pairing_link.endpoint,
                vault_id: joined.vault_id,
                device_id: joined.device_id,
                device_token: joined.device_token,
                vault_key: joined.vault_key,
            },
            SyncMode::WebDav => return Err("配对链接不能生成 WebDAV 同步身份".to_owned()),
        };
        credentials.validate()?;
        let lamport_floor = WorkerClient::new(&credentials, WinHttpTransport)?.highest_lamport()?;
        Ok::<_, String>((credentials, lamport_floor))
    })
    .await
    .map_err(|error| format!("配对后台任务失败：{error}"))??;

    lock(&state.sync_runtime, "同步运行时")?.stop();
    let switch_result = {
        let mut repository = lock(&state.repository, "任务库")?;
        if input.clear_local_tasks {
            // 先完成绑定再清空：清空不生成同步操作，但若绑定失败，
            // 本地任务仍然保留，不会造成"数据已删却未加入"的局面。
            switch_sync_binding(
                &mut repository,
                state.credentials.as_ref(),
                joined.0.clone(),
                joined.1,
            )?;
            repository
                .clear_local_tasks()
                .map_err(|error| format!("无法移除本地任务：{error}"))?;
            Ok(())
        } else {
            switch_sync_binding(&mut repository, state.credentials.as_ref(), joined.0, joined.1)
        }
    };
    let mut runtime = lock(&state.sync_runtime, "同步运行时")?;
    *runtime = SyncRuntime::start(state.database_path.clone(), Arc::clone(&state.credentials));
    switch_result?;
    runtime.request(SyncTrigger::Manual);
    notify_frontends(&app, "tray://refresh");
    snapshot(&state)
}

#[tauri::command]
fn start_local_sync(app: AppHandle, state: State<'_, RuntimeState>) -> Result<AppSnapshot, String> {
    // 锁顺序统一为：repository → settings → sync_runtime → local_host。
    // 这里先短锁检查是否已开启（不嵌套其他锁），创建服务期间不持锁，
    // 最后才持 local_host 锁赋值，避免与 get_snapshot 形成循环等待。
    {
        let host_guard = lock(&state.local_host, "局域网同步主机")?;
        if host_guard.is_some() {
            return snapshot(&state);
        }
    }
    if let Some(existing) = state.credentials.load()? {
        return Err(match existing.mode() {
            SyncMode::LocalNetwork => {
                "Windows 已属于另一个局域网同步空间。请直接使用该空间同步；如需让 Windows 作为主机，请先在设置中移除现有同步身份。".to_owned()
            }
            SyncMode::Worker | SyncMode::WebDav => {
                "Windows 已配置自建服务或 WebDAV 同步。同一网络主机模式只适用于尚未加入任何同步空间的 Windows。".to_owned()
            }
        });
    }
    let endpoint = preferred_local_endpoint(DEFAULT_LOCAL_SYNC_PORT)
        .map_err(|error| format!("无法解析本机局域网地址：{error}"))?;
    let credentials = generate_local_network_credentials(endpoint)?;
    let vault_id = credentials.vault_id().to_owned();
    let state_path = local_state_path(&data_directory()?, &vault_id);
    let host = LocalSyncHost::start(credentials.clone(), state_path)?;

    lock(&state.sync_runtime, "同步运行时")?.stop();
    let switch_result = {
        let mut repository = lock(&state.repository, "任务库")?;
        switch_sync_binding(&mut repository, state.credentials.as_ref(), credentials, 0)
    };
    if let Err(error) = switch_result {
        host.abort();
        return Err(format!("切换同步绑定失败：{error}"));
    }
    {
        let mut runtime = lock(&state.sync_runtime, "同步运行时")?;
        *runtime = SyncRuntime::start(state.database_path.clone(), Arc::clone(&state.credentials));
        runtime.request(SyncTrigger::Manual);
    }
    *lock(&state.local_host, "局域网同步主机")? = Some(host);
    notify_frontends(&app, "tray://refresh");
    snapshot(&state)
}

#[tauri::command]
fn stop_local_sync(app: AppHandle, state: State<'_, RuntimeState>) -> Result<AppSnapshot, String> {
    if let Some(mut host) = lock(&state.local_host, "局域网同步主机")?.take() {
        host.stop();
    }
    notify_frontends(&app, "tray://refresh");
    snapshot(&state)
}

#[tauri::command]
fn create_local_pairing(app: AppHandle, state: State<'_, RuntimeState>) -> Result<AppSnapshot, String> {
    {
        let host_guard = lock(&state.local_host, "局域网同步主机")?;
        let host = host_guard
            .as_ref()
            .ok_or_else(|| "局域网同步服务尚未开启".to_owned())?;
        host.create_pairing(&app)?;
    }
    snapshot(&state)
}

#[tauri::command]
fn respond_local_pairing(
    app: AppHandle,
    state: State<'_, RuntimeState>,
    accept: bool,
) -> Result<AppSnapshot, String> {
    {
        let host_guard = lock(&state.local_host, "局域网同步主机")?;
        let host = host_guard
            .as_ref()
            .ok_or_else(|| "局域网同步服务尚未开启".to_owned())?;
        host.respond_pairing(&app, accept)?;
    }
    snapshot(&state)
}

#[tauri::command]
fn toggle_board(app: AppHandle) -> Result<(), String> {
    let board = app
        .get_webview_window("board")
        .ok_or_else(|| "找不到悬浮任务板窗口".to_string())?;
    if board.is_visible().map_err(|error| error.to_string())? {
        board.hide().map_err(|error| error.to_string())
    } else {
        board.show().map_err(|error| error.to_string())?;
        board.set_focus().map_err(|error| error.to_string())
    }
}

#[tauri::command]
fn show_main(app: AppHandle) -> Result<(), String> {
    let main = app
        .get_webview_window("main")
        .ok_or_else(|| "找不到主窗口".to_string())?;
    main.show().map_err(|error| error.to_string())?;
    main.unminimize().map_err(|error| error.to_string())?;
    main.set_focus().map_err(|error| error.to_string())
}

#[tauri::command]
fn save_board_preferences(
    app: AppHandle,
    state: State<'_, RuntimeState>,
    input: BoardPreferencesInput,
) -> Result<AppSnapshot, String> {
    let normalized_opacity = input.opacity_percent.clamp(20, 100);
    let desktop_widget = input.desktop_widget.unwrap_or_else(|| {
        state
            .settings
            .lock()
            .map(|settings| settings.desktop_widget)
            .unwrap_or(false)
    }) && !input.always_on_top
        && !input.click_through;
    update_board_settings(
        &app,
        &state,
        normalized_opacity,
        input.always_on_top,
        input.click_through,
    )?;
    set_desktop_widget(&app, &state, desktop_widget)?;
    snapshot(&state)
}

fn update_board_settings(
    app: &AppHandle,
    state: &RuntimeState,
    opacity_percent: u8,
    always_on_top: bool,
    click_through: bool,
) -> Result<(), String> {
    let normalized_opacity = opacity_percent.clamp(20, 100);
    let desktop_widget = {
        let mut settings = lock(&state.settings, "设置")?;
        settings.opacity = f64::from(normalized_opacity) / 100.0;
        settings.topmost = always_on_top;
        settings.click_through = click_through;
        if always_on_top || click_through {
            settings.desktop_widget = false;
        }
        settings.save()?;
        settings.desktop_widget
    };
    let board = app
        .get_webview_window("board")
        .ok_or_else(|| "找不到悬浮任务板窗口".to_string())?;
    board
        .set_always_on_bottom(desktop_widget)
        .map_err(|error| error.to_string())?;
    board
        .set_always_on_top(always_on_top)
        .map_err(|error| error.to_string())?;
    board
        .set_ignore_cursor_events(click_through)
        .map_err(|error| error.to_string())?;
    // The opacity is rendered from the snapshot, so reload the small board after
    // a tray change instead of leaving the old value visible until the next task edit.
    board.reload().map_err(|error| error.to_string())?;
    notify_frontends(app, "tray://refresh");
    Ok(())
}

fn notify_frontends(app: &AppHandle, event: &str) {
    for label in ["main", "board"] {
        if let Some(window) = app.get_webview_window(label) {
            let _ = window.emit(event, ());
        }
    }
}

fn tray_toggle_board_setting(app: &AppHandle, setting: &str) -> Result<(), String> {
    let state = app.state::<RuntimeState>();
    let current = {
        let settings = lock(&state.settings, "设置")?;
        (
            settings.opacity_percent(),
            settings.topmost,
            settings.click_through,
        )
    };
    match setting {
        "topmost" => update_board_settings(app, &state, current.0, !current.1, current.2),
        "click-through" => update_board_settings(app, &state, current.0, current.1, !current.2),
        "desktop-widget" => set_desktop_widget(app, &state, !{
            let settings = lock(&state.settings, "设置")?;
            settings.desktop_widget
        }),
        value if value.starts_with("opacity:") => {
            let percent = value
                .strip_prefix("opacity:")
                .and_then(|value| value.parse::<u8>().ok())
                .ok_or_else(|| "不透明度设置无效".to_string())?;
            update_board_settings(app, &state, percent, current.1, current.2)
        }
        _ => Err("未知悬浮板设置".to_string()),
    }
}

fn set_desktop_widget(app: &AppHandle, state: &RuntimeState, enabled: bool) -> Result<(), String> {
    let (topmost, click_through) = {
        let mut settings = lock(&state.settings, "设置")?;
        settings.desktop_widget = enabled;
        if enabled {
            settings.topmost = false;
            settings.click_through = false;
        }
        settings.save()?;
        (settings.topmost, settings.click_through)
    };
    let board = app
        .get_webview_window("board")
        .ok_or_else(|| "找不到悬浮任务板窗口".to_string())?;
    board
        .set_always_on_bottom(enabled)
        .map_err(|error| error.to_string())?;
    board
        .set_always_on_top(topmost)
        .map_err(|error| error.to_string())?;
    board
        .set_ignore_cursor_events(click_through)
        .map_err(|error| error.to_string())?;
    board.reload().map_err(|error| error.to_string())?;
    notify_frontends(app, "tray://refresh");
    Ok(())
}

#[tauri::command]
fn window_action(window: WebviewWindow, action: String) -> Result<(), String> {
    match action.as_str() {
        "minimize" => window.minimize(),
        "maximize" => {
            if window.is_maximized().map_err(|error| error.to_string())? {
                window.unmaximize()
            } else {
                window.maximize()
            }
        }
        "close" => window.close(),
        "hide" => window.hide(),
        _ => return Err("未知窗口操作".to_string()),
    }
    .map_err(|error| error.to_string())
}

pub fn run() -> Result<(), String> {
    let state = build_runtime()?;
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.unminimize();
                let _ = window.set_focus();
            }
        }))
        .manage(state)
        .setup(|app| {
            let _ = crate::integration::ensure_registered();
            install_hotkey_handler(app.handle())?;
            let state = app.state::<RuntimeState>();
            let (opacity_percent, always_on_top, click_through, desktop_widget) = {
                let settings = lock(&state.settings, "设置")?;
                (
                    settings.opacity_percent(),
                    settings.topmost,
                    settings.click_through,
                    settings.desktop_widget,
                )
            };
            if let Some(board) = app.get_webview_window("board") {
                board.set_always_on_bottom(desktop_widget)?;
                board.set_always_on_top(always_on_top)?;
                board.set_ignore_cursor_events(click_through)?;
            }

            let shortcuts = lock(&state.settings, "设置")?.shortcuts.clone();
            let shortcut_hint = |command: ShortcutCommand| {
                shortcuts
                    .binding(command)
                    .map(format_shortcut_binding)
                    .unwrap_or_default()
            };

            let click_through_item = CheckMenuItemBuilder::with_id(
                "toggle-click-through",
                format!(
                    "鼠标穿透\t{}",
                    shortcut_hint(ShortcutCommand::ToggleClickThrough)
                ),
            )
            .checked(click_through)
            .build(app)?;
            let topmost_item = CheckMenuItemBuilder::with_id(
                "toggle-topmost",
                format!(
                    "任务板始终置顶\t{}",
                    shortcut_hint(ShortcutCommand::ToggleAlwaysOnTop)
                ),
            )
            .checked(always_on_top)
            .build(app)?;
            let desktop_widget_item = CheckMenuItemBuilder::with_id(
                "desktop-widget",
                format!(
                    "桌面小组件模式\t{}",
                    shortcut_hint(ShortcutCommand::ToggleDesktopWidget)
                ),
            )
            .checked(desktop_widget)
            .build(app)?;
            let current_opacity = i32::from(opacity_percent);
            let opacity_items = (20..=100)
                .step_by(10)
                .map(|percent| {
                    CheckMenuItemBuilder::with_id(
                        format!("opacity-{percent}"),
                        format!("{percent}%"),
                    )
                    .checked(percent == current_opacity)
                    .build(app)
                })
                .collect::<Result<Vec<_>, _>>()?;
            let mut opacity_menu_builder = SubmenuBuilder::with_id(app, "opacity", "不透明度");
            for item in &opacity_items {
                opacity_menu_builder = opacity_menu_builder.item(item);
            }
            let opacity_menu = opacity_menu_builder.build()?;
            let click_through_item_for_event = click_through_item.clone();
            let topmost_item_for_event = topmost_item.clone();
            let desktop_widget_item_for_event = desktop_widget_item.clone();
            let opacity_items_for_event = opacity_items.clone();
            let menu = MenuBuilder::new(app)
                .item(
                    &MenuItemBuilder::with_id(
                        "quick-add",
                        format!("快速新增任务\t{}", shortcut_hint(ShortcutCommand::QuickAdd)),
                    )
                    .build(app)?,
                )
                .text("open", "任务详情与统计")
                .text("settings", "设置")
                .item(
                    &MenuItemBuilder::with_id(
                        "board",
                        format!(
                            "显示/隐藏悬浮任务板\t{}",
                            shortcut_hint(ShortcutCommand::ToggleTaskPanel)
                        ),
                    )
                    .build(app)?,
                )
                .separator()
                .text("sync", "立即同步")
                .item(&click_through_item)
                .item(&topmost_item)
                .item(&desktop_widget_item)
                .item(&opacity_menu)
                .separator()
                .text("quit", "退出 Woo Todo")
                .build()?;
            if let Some(icon) = app.default_window_icon().cloned() {
                TrayIconBuilder::new()
                    .icon(icon)
                    .menu(&menu)
                    .tooltip("Woo Todo")
                    .on_menu_event(move |app, event| {
                        let id = event.id().as_ref();
                        match id {
                            "quick-add" => {
                                let _ = show_main(app.clone());
                                if let Some(window) = app.get_webview_window("main") {
                                    let _ = window.emit("tray://new-task", ());
                                }
                            }
                            "open" => {
                                let _ = show_main(app.clone());
                            }
                            "settings" => {
                                let _ = show_main(app.clone());
                                if let Some(window) = app.get_webview_window("main") {
                                    let _ = window.emit("tray://settings", ());
                                }
                            }
                            "board" => {
                                let _ = toggle_board(app.clone());
                            }
                            "sync" => {
                                if let Ok(runtime) = app.state::<RuntimeState>().sync_runtime.lock()
                                {
                                    runtime.request(SyncTrigger::Manual);
                                }
                            }
                            "toggle-click-through" => {
                                let _ = tray_toggle_board_setting(app, "click-through");
                            }
                            "toggle-topmost" => {
                                let _ = tray_toggle_board_setting(app, "topmost");
                            }
                            "desktop-widget" => {
                                let _ = tray_toggle_board_setting(app, "desktop-widget");
                            }
                            id if id.starts_with("opacity-") => {
                                let _ = tray_toggle_board_setting(
                                    app,
                                    &format!("opacity:{}", id.trim_start_matches("opacity-")),
                                );
                            }
                            "quit" => app.exit(0),
                            _ => {}
                        }
                        if matches!(
                            id,
                            "toggle-click-through" | "toggle-topmost" | "desktop-widget"
                        ) || id.starts_with("opacity-")
                        {
                            let state = app.state::<RuntimeState>();
                            if let Ok(settings) = state.settings.lock() {
                                let _ = click_through_item_for_event
                                    .set_checked(settings.click_through);
                                let _ = topmost_item_for_event.set_checked(settings.topmost);
                                let _ = desktop_widget_item_for_event
                                    .set_checked(settings.desktop_widget);
                                let current = settings.opacity_percent();
                                for (index, item) in opacity_items_for_event.iter().enumerate() {
                                    let percent = 20 + index as u8 * 10;
                                    let _ = item.set_checked(percent == current);
                                }
                            }
                        }
                    })
                    .build(app)?;
            }
            lock(&state.sync_runtime, "同步运行时")?.request(SyncTrigger::Launch);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            create_task,
            update_task,
            toggle_task,
            pass_task,
            delete_task,
            move_task,
            request_sync,
            join_sync_space,
            start_local_sync,
            stop_local_sync,
            create_local_pairing,
            respond_local_pairing,
            toggle_board,
            show_main,
            save_board_preferences,
            window_action,
        ])
        .run(tauri::generate_context!())
        .map_err(|error| format!("Tauri 运行失败：{error}"))
}

fn build_runtime() -> Result<RuntimeState, String> {
    let data_directory = data_directory()?;
    std::fs::create_dir_all(&data_directory)
        .map_err(|error| format!("无法创建应用数据目录：{error}"))?;
    let database_path = data_directory.join("woo-todo.sqlite3");
    let mut repository = TaskRepository::open(&database_path)
        .map_err(|error| format!("无法打开本地任务库：{error}"))?;
    repository
        .settle_expired(today_shanghai(), now_millis())
        .map_err(|error| format!("无法结算已结束周期：{error}"))?;
    let credential_store: Arc<dyn SyncCredentialStore> =
        Arc::new(WindowsCredentialStore::default());
    configure_repository_from_store(&mut repository, credential_store.as_ref())?;
    let settings = AppSettings::load(&data_directory);
    let sync_runtime = SyncRuntime::start(database_path.clone(), Arc::clone(&credential_store));
    Ok(RuntimeState {
        repository: Mutex::new(repository),
        settings: Mutex::new(settings),
        credentials: credential_store,
        database_path,
        sync_runtime: Mutex::new(sync_runtime),
        local_host: Mutex::new(None),
        hotkeys: Mutex::new(None),
        shortcut_error: Mutex::new(None),
    })
}

fn install_hotkey_handler(app: &AppHandle) -> Result<(), String> {
    let state = app.state::<RuntimeState>();
    let configuration = lock(&state.settings, "设置")?.shortcuts.clone();
    let handle = app.clone();
    let manager = HotkeyManager::start(configuration, move |event| match event {
        HotkeyEvent::Triggered(command) => handle_hotkey(&handle, command),
        HotkeyEvent::RegistrationFailed(error) => {
            if let Ok(state) = handle.state::<RuntimeState>().shortcut_error.lock() {
                let mut state = state;
                *state = Some(error.clone());
            }
            let _ = handle.emit("hotkey://error", error);
        }
    });
    *lock(&state.hotkeys, "快捷键")? = Some(manager);
    Ok(())
}

fn handle_hotkey(app: &AppHandle, command: ShortcutCommand) {
    let result = match command {
        ShortcutCommand::QuickAdd => show_main(app.clone()).and_then(|_| {
            app.get_webview_window("main")
                .ok_or_else(|| "找不到主窗口".to_owned())?
                .emit("tray://new-task", ())
                .map_err(|error| error.to_string())
        }),
        ShortcutCommand::ToggleTaskPanel => toggle_board(app.clone()),
        ShortcutCommand::ToggleAlwaysOnTop => tray_toggle_board_setting(app, "topmost"),
        ShortcutCommand::ToggleClickThrough => tray_toggle_board_setting(app, "click-through"),
        ShortcutCommand::IncreaseOpacity | ShortcutCommand::DecreaseOpacity => {
            let state = app.state::<RuntimeState>();
            let current = lock(&state.settings, "设置")
                .map(|settings| i32::from(settings.opacity_percent()))
                .map_err(|error| error.to_string());
            current.and_then(|value| {
                let delta = if command == ShortcutCommand::IncreaseOpacity {
                    10
                } else {
                    -10
                };
                tray_toggle_board_setting(
                    app,
                    &format!("opacity:{}", (value + delta).clamp(20, 100)),
                )
            })
        }
        ShortcutCommand::ToggleDesktopWidget => tray_toggle_board_setting(app, "desktop-widget"),
    };
    if let Err(error) = result {
        let _ = app.emit("hotkey://error", error);
    }
}

fn snapshot(state: &RuntimeState) -> Result<AppSnapshot, String> {
    let (tasks, display) = {
        let repository = lock(&state.repository, "任务库")?;
        let tasks = repository.fetch_all().map_err(|error| error.to_string())?;
        let display = repository
            .display_configuration()
            .map_err(|error| error.to_string())?
            .map(|value| DisplayConfiguration {
                header_template: value.header_template,
                subtitle_template: value.subtitle_template,
                start_date: value.start_date,
                deadline_date: value.deadline_date,
            })
            .unwrap_or_else(|| {
                lock(&state.settings, "设置")
                    .map(|settings| settings.display.clone())
                    .unwrap_or_default()
            });
        (tasks, display)
    };
    let reference_date = today_shanghai();
    let (header, subtitle) = display.render(reference_date);
    let traditional = TraditionalCalendarInfo::render(reference_date);
    let statistics = calculate_statistics(&tasks, reference_date, 20);
    let sync = lock(&state.sync_runtime, "同步运行时")?.snapshot();
    let local_sync = match lock(&state.local_host, "局域网同步主机")?.as_ref() {
        Some(host) => LocalSyncSummary {
            enabled: true,
            endpoint: Some(host.endpoint().to_owned()),
            vault_id: Some(host.vault_id().to_owned()),
            pairing: host.pairing_view(),
        },
        None => LocalSyncSummary {
            enabled: false,
            endpoint: None,
            vault_id: None,
            pairing: None,
        },
    };
    let shortcut_error = lock(&state.shortcut_error, "快捷键")?.clone();
    let board = {
        let settings = lock(&state.settings, "设置")?;
        BoardPreferences {
            opacity_percent: settings.opacity_percent(),
            always_on_top: settings.topmost,
            click_through: settings.click_through,
            desktop_widget: settings.desktop_widget,
        }
    };
    let shortcuts = {
        let settings = lock(&state.settings, "设置")?;
        ShortcutCommand::ALL
            .into_iter()
            .filter_map(|command| {
                settings
                    .shortcuts
                    .binding(command)
                    .map(|binding| ShortcutView {
                        label: command_label(command).to_owned(),
                        display: format_shortcut_binding(binding),
                        icon: shortcut_icon(command),
                    })
            })
            .collect::<Vec<_>>()
    };
    Ok(AppSnapshot {
        reference_date,
        header,
        subtitle,
        lunar_date: traditional.lunar_date,
        lunar_annotation: traditional.annotation,
        tasks: tasks.into_iter().map(TaskView::from).collect(),
        statistics,
        board,
        sync: SyncSummary {
            configured_mode: sync.configured_mode.map(sync_mode_name),
            running: sync.running,
            pending: sync.pending,
            last_successful_at: sync.last_successful_at,
            last_error: sync.last_error,
        },
        local_sync,
        shortcut_error,
        shortcuts,
    })
}

fn after_task_change(state: &RuntimeState) {
    if let Ok(runtime) = state.sync_runtime.lock() {
        runtime.request(SyncTrigger::LocalChange);
    }
    if let Ok(repository) = state.repository.lock()
        && let Ok(tasks) = repository.fetch_all()
    {
        let _ = crate::notifications::reconcile(&tasks);
    }
}

fn sync_mode_name(mode: SyncMode) -> &'static str {
    match mode {
        SyncMode::Worker => "worker",
        SyncMode::LocalNetwork => "localNetwork",
        SyncMode::WebDav => "webDav",
    }
}

fn shortcut_icon(command: ShortcutCommand) -> &'static str {
    match command {
        ShortcutCommand::QuickAdd => "plus",
        ShortcutCommand::ToggleTaskPanel => "panel-right",
        ShortcutCommand::ToggleAlwaysOnTop => "pin",
        ShortcutCommand::ToggleClickThrough => "mouse-pointer-2",
        ShortcutCommand::IncreaseOpacity => "sun",
        ShortcutCommand::DecreaseOpacity => "moon",
        ShortcutCommand::ToggleDesktopWidget => "layout-panel-top",
    }
}

fn data_directory() -> Result<PathBuf, String> {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .map(|path| path.join("Woo Todo"))
        .ok_or_else(|| "无法确定 LOCALAPPDATA".to_string())
}

fn lock<'a, T>(mutex: &'a Mutex<T>, label: &str) -> Result<MutexGuard<'a, T>, String> {
    mutex.lock().map_err(|_| format!("{label}状态不可用"))
}

fn now_millis() -> i64 {
    Utc::now().timestamp_millis()
}
