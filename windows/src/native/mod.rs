#![allow(unsafe_op_in_unsafe_fn)]

use std::cmp::Reverse;
use std::ffi::c_void;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::mem::{size_of, zeroed};
use std::path::PathBuf;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;

use chrono::{Days, NaiveDate, Utc};
use qrcode::{Color, QrCode};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Graphics::Gdi::*;
use windows_sys::Win32::System::Com::*;
use windows_sys::Win32::System::DataExchange::*;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock};
use windows_sys::Win32::System::Threading::*;
use windows_sys::Win32::UI::Controls::Dialogs::*;
use windows_sys::Win32::UI::Controls::*;
use windows_sys::Win32::UI::HiDpi::*;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
use windows_sys::Win32::UI::Shell::*;
use windows_sys::Win32::UI::WindowsAndMessaging::*;
use woo_todo_core::{
    QuestLine, Recurrence, ReminderTime, TaskRepository, TaskState, TimeType, TodoTask,
    calculate_statistics, today_shanghai,
};
use zeroize::{Zeroize, Zeroizing};

use crate::credentials::{SyncCredentialStore, SyncCredentials, SyncMode, WindowsCredentialStore};
use crate::display::{CounterVariable, DisplayConfiguration};
use crate::http::WinHttpTransport;
use crate::local_server::{
    DEFAULT_LOCAL_SYNC_PORT, LocalNetworkHttpServer, LocalServerStore, preferred_local_endpoint,
};
use crate::notifications;
use crate::settings::AppSettings;
use crate::shortcut::{ShortcutBinding, ShortcutCommand, ShortcutConfiguration, ShortcutModifiers};
use crate::sync_runtime::{
    SyncRuntime, SyncTrigger, configure_repository_from_store, switch_sync_binding,
};
use crate::ui_text::{
    date_with_weekday, period_label, quest_line_label, state_label, task_badges, time_type_label,
};
use crate::update::{self, PreparedUpdate, UpdateRelease};
use crate::webdav::WebDavClient;
use crate::worker::{PairingClaimInfo, PairingState, PairingStatus, WorkerClient};

const APP_ID: &str = "stophemo.WooTodo";
const MAIN_CLASS: &str = "WooTodo.Native.Main.v1";
const FLOAT_CLASS: &str = "WooTodo.Native.Float.v1";
const EDITOR_CLASS: &str = "WooTodo.Native.Editor.v1";
const MUTEX_NAME: &str = "Local\\WooTodo.WindowsApp";
const WM_TRAY: u32 = WM_APP + 1;
const WM_UPDATE_EVENT: u32 = WM_APP + 3;
const UPDATE_CHECK_TIMER_ID: usize = 1;
const PERIOD_REFRESH_TIMER_ID: usize = 2;
const SYNC_STATUS_TIMER_ID: usize = 3;
const PERIOD_REFRESH_INTERVAL_MILLIS: u32 = 60_000;
const SYNC_STATUS_INTERVAL_MILLIS: u32 = 1_000;
const UPDATE_CHECK_POLL_INTERVAL_MILLIS: u32 = update::FAILED_CHECK_RETRY_INTERVAL_MILLIS as u32;
const STATIC_LEFT: u32 = 0;
const STATIC_RIGHT: u32 = 2;
const STATIC_BITMAP: u32 = 14;
const STATIC_CENTER_IMAGE: u32 = 512;
const TRACKBAR_GET_POSITION: u32 = WM_USER;
const CLIPBOARD_UNICODE_TEXT: u32 = 13;

const INK: COLORREF = rgb(23, 24, 23);
const INK_SOFT: COLORREF = rgb(37, 39, 37);
const PAPER_BRIGHT: COLORREF = rgb(250, 251, 248);
const TEXT_ON_DARK: COLORREF = rgb(240, 242, 238);
const MUTED_ON_DARK: COLORREF = rgb(174, 178, 172);
const TEXT_ON_LIGHT: COLORREF = rgb(23, 24, 23);
const PURPLE_LIGHT: COLORREF = rgb(169, 154, 232);

const ID_NAV: i32 = 100;
const ID_TASKS: i32 = 101;
const ID_CONTENT: i32 = 102;
const ID_ADD: i32 = 110;
const ID_EDIT: i32 = 111;
const ID_COMPLETE: i32 = 112;
const ID_PASS: i32 = 113;
const ID_DELETE: i32 = 114;
const ID_UP: i32 = 115;
const ID_DOWN: i32 = 116;
const ID_REFRESH: i32 = 117;
const ID_OPACITY: i32 = 120;
const ID_TOPMOST: i32 = 121;
const ID_CLICK_THROUGH: i32 = 122;
const ID_DISPLAY_HEADER: i32 = 130;
const ID_DISPLAY_SUBTITLE: i32 = 131;
const ID_DISPLAY_ELAPSED_DATE: i32 = 132;
const ID_DISPLAY_INSERT_ELAPSED_DAYS: i32 = 133;
const ID_DISPLAY_INSERT_DEADLINE_DAYS: i32 = 134;
const ID_DISPLAY_INSERT_ELAPSED_MONTHS: i32 = 135;
const ID_DISPLAY_INSERT_DEADLINE_MONTHS: i32 = 136;
const ID_DISPLAY_SAVE: i32 = 137;
const ID_DISPLAY_RESET: i32 = 138;
const ID_DISPLAY_DEADLINE_DATE: i32 = 139;
const ID_SHORTCUT_QUICK_ADD: i32 = 140;
const ID_SHORTCUT_TOGGLE_BOARD: i32 = 141;
const ID_SHORTCUT_TOPMOST: i32 = 142;
const ID_SHORTCUT_CLICK_THROUGH: i32 = 143;
const ID_SHORTCUT_SAVE: i32 = 144;
const ID_SHORTCUT_RESET: i32 = 145;
const ID_SYNC_MODE: i32 = 150;
const ID_SYNC_ENDPOINT: i32 = 151;
const ID_SYNC_INVITE: i32 = 152;
const ID_SYNC_USERNAME: i32 = 153;
const ID_SYNC_SECRET: i32 = 154;
const ID_SYNC_VAULT: i32 = 155;
const ID_SYNC_DEVICE: i32 = 156;
const ID_SYNC_TOKEN: i32 = 157;
const ID_SYNC_KEY: i32 = 158;
const ID_SYNC_SETUP: i32 = 159;
const ID_SYNC_SAVE: i32 = 160;
const ID_SYNC_NOW: i32 = 161;
const ID_SYNC_DEVICES: i32 = 162;
const ID_SYNC_REVOKE_DEVICE: i32 = 163;
const ID_SYNC_REVOKE: i32 = 164;
const ID_SYNC_OUTPUT: i32 = 165;
const ID_SYNC_PAIR: i32 = 166;
const ID_SYNC_PAIR_COPY: i32 = 167;
const ID_SYNC_PAIR_CONFIRM: i32 = 168;
const ID_SYNC_PAIR_QR: i32 = 169;
const ID_BACKUP_PASSPHRASE: i32 = 170;
const ID_BACKUP_CONFIRMATION: i32 = 171;
const ID_BACKUP_INCLUDE_IDENTITY: i32 = 172;
const ID_BACKUP_EXPORT: i32 = 173;
const ID_BACKUP_IMPORT: i32 = 174;

const ID_FLOAT_LIST: i32 = 200;
const ID_FLOAT_EDIT: i32 = 201;
const ID_FLOAT_ADD: i32 = 202;
const ID_FLOAT_OPEN: i32 = 203;
const ID_FLOAT_COMPLETE: i32 = 204;
const ID_FLOAT_PASS: i32 = 205;
const ID_FLOAT_TASK_EDIT: i32 = 206;
const ID_FLOAT_DELETE: i32 = 207;

const ID_EDITOR_TITLE: i32 = 300;
const ID_EDITOR_TIME_TYPE: i32 = 301;
const ID_EDITOR_QUEST: i32 = 302;
const ID_EDITOR_DATE: i32 = 303;
const ID_EDITOR_REPEAT: i32 = 304;
const ID_EDITOR_REMINDER_ENABLED: i32 = 305;
const ID_EDITOR_REMINDER_TIME: i32 = 306;
const ID_EDITOR_DEADLINE_ENABLED: i32 = 307;
const ID_EDITOR_DEADLINE_DATE: i32 = 308;
const ID_EDITOR_SAVE: i32 = IDOK;
const ID_EDITOR_CANCEL: i32 = IDCANCEL;

const ID_TRAY_SHOW_MAIN: i32 = 400;
const ID_TRAY_TOGGLE_BOARD: i32 = 401;
const ID_TRAY_QUICK_ADD: i32 = 402;
const ID_TRAY_TOPMOST: i32 = 403;
const ID_TRAY_RESTORE: i32 = 404;
const ID_TRAY_EXIT: i32 = 405;
const ID_TRAY_CHECK_UPDATE: i32 = 406;

const HOTKEY_QUICK_ADD: i32 = 1;
const HOTKEY_TOGGLE_BOARD: i32 = 2;
const HOTKEY_TOPMOST: i32 = 3;
const HOTKEY_CLICK_THROUGH: i32 = 4;

static QUICK_EDIT_PROC: AtomicIsize = AtomicIsize::new(0);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Section {
    Today,
    Tomorrow,
    Week,
    Month,
    Someday,
    History,
    Statistics,
    Settings,
    Sync,
}

impl Section {
    fn from_index(index: i32) -> Self {
        match index {
            1 => Self::Tomorrow,
            2 => Self::Week,
            3 => Self::Month,
            4 => Self::Someday,
            5 => Self::History,
            6 => Self::Statistics,
            7 => Self::Settings,
            8 => Self::Sync,
            _ => Self::Today,
        }
    }
}

#[derive(Default)]
struct MainControls {
    nav: HWND,
    title: HWND,
    subtitle: HWND,
    tasks: HWND,
    content: HWND,
    add: HWND,
    edit: HWND,
    complete: HWND,
    pass: HWND,
    delete: HWND,
    up: HWND,
    down: HWND,
    refresh: HWND,
    opacity_label: HWND,
    opacity: HWND,
    opacity_value: HWND,
    topmost: HWND,
    click_through: HWND,
    display_heading: HWND,
    display_header_label: HWND,
    display_header: HWND,
    display_subtitle_label: HWND,
    display_subtitle: HWND,
    display_preview: HWND,
    display_elapsed_date_label: HWND,
    display_elapsed_date: HWND,
    display_deadline_date_label: HWND,
    display_deadline_date: HWND,
    display_insert_elapsed_days: HWND,
    display_insert_deadline_days: HWND,
    display_insert_elapsed_months: HWND,
    display_insert_deadline_months: HWND,
    display_save: HWND,
    display_reset: HWND,
    shortcut_heading: HWND,
    shortcut_labels: [HWND; 4],
    shortcut_edits: [HWND; 4],
    shortcut_save: HWND,
    shortcut_reset: HWND,
}

#[derive(Default)]
struct FloatControls {
    heading: HWND,
    date: HWND,
    subtitle: HWND,
    progress: HWND,
    tasks: HWND,
    quick_edit: HWND,
    add: HWND,
    open: HWND,
}

#[derive(Default)]
struct SyncControls {
    heading: HWND,
    status: HWND,
    mode_label: HWND,
    mode: HWND,
    field_labels: [HWND; 8],
    endpoint: HWND,
    invite: HWND,
    username: HWND,
    secret: HWND,
    vault_id: HWND,
    device_id: HWND,
    device_token: HWND,
    vault_key: HWND,
    setup: HWND,
    save: HWND,
    sync_now: HWND,
    devices: HWND,
    revoke_label: HWND,
    revoke_device: HWND,
    revoke: HWND,
    output: HWND,
    pair: HWND,
    pair_copy: HWND,
    pair_confirm: HWND,
    pair_qr: HWND,
    backup_heading: HWND,
    backup_passphrase_label: HWND,
    backup_passphrase: HWND,
    backup_confirmation_label: HWND,
    backup_confirmation: HWND,
    backup_include_identity: HWND,
    backup_export: HWND,
    backup_import: HWND,
}

struct ThemeResources {
    paper_brush: HBRUSH,
    ink_brush: HBRUSH,
    ink_soft_brush: HBRUSH,
    heading_font: HFONT,
    subheading_font: HFONT,
}

impl ThemeResources {
    unsafe fn new() -> Self {
        let face = wide("Segoe UI Variable Display");
        Self {
            paper_brush: CreateSolidBrush(PAPER_BRIGHT),
            ink_brush: CreateSolidBrush(INK),
            ink_soft_brush: CreateSolidBrush(INK_SOFT),
            heading_font: CreateFontW(
                -25,
                0,
                0,
                0,
                FW_SEMIBOLD as i32,
                0,
                0,
                0,
                u32::from(DEFAULT_CHARSET),
                u32::from(OUT_DEFAULT_PRECIS),
                u32::from(CLIP_DEFAULT_PRECIS),
                u32::from(CLEARTYPE_QUALITY),
                u32::from(DEFAULT_PITCH | FF_DONTCARE),
                face.as_ptr(),
            ),
            subheading_font: CreateFontW(
                -17,
                0,
                0,
                0,
                FW_SEMIBOLD as i32,
                0,
                0,
                0,
                u32::from(DEFAULT_CHARSET),
                u32::from(OUT_DEFAULT_PRECIS),
                u32::from(CLIP_DEFAULT_PRECIS),
                u32::from(CLEARTYPE_QUALITY),
                u32::from(DEFAULT_PITCH | FF_DONTCARE),
                face.as_ptr(),
            ),
        }
    }
}

impl Drop for ThemeResources {
    fn drop(&mut self) {
        unsafe {
            DeleteObject(self.paper_brush);
            DeleteObject(self.ink_brush);
            DeleteObject(self.ink_soft_brush);
            DeleteObject(self.heading_font);
            DeleteObject(self.subheading_font);
        }
    }
}

struct App {
    instance: HINSTANCE,
    main: HWND,
    floating: HWND,
    main_controls: MainControls,
    float_controls: FloatControls,
    sync_controls: SyncControls,
    repository: TaskRepository,
    database_path: PathBuf,
    settings: AppSettings,
    section: Section,
    visible_tasks: Vec<TodoTask>,
    floating_tasks: Vec<TodoTask>,
    populating_main_tasks: bool,
    populating_float_tasks: bool,
    exiting: bool,
    tray_added: bool,
    mutex: HANDLE,
    theme: ThemeResources,
    update_sender: Sender<UpdateEvent>,
    update_receiver: Receiver<UpdateEvent>,
    update_state: UpdateState,
    available_update: Option<UpdateRelease>,
    current_date: NaiveDate,
    credential_store: Arc<WindowsCredentialStore>,
    sync_runtime: SyncRuntime,
    last_sync_successful_at: Option<i64>,
    last_sync_error: Option<String>,
    data_directory: PathBuf,
    local_network_server: Option<LocalNetworkHttpServer>,
    pairing: Option<PairingContext>,
    pairing_job_running: bool,
    pairing_next_poll_at: i64,
    pairing_generation: u64,
    pairing_qr_bitmap: HBITMAP,
    webdav_setup_link: Option<Zeroizing<String>>,
    sync_ui_sender: Sender<SyncUiEvent>,
    sync_ui_receiver: Receiver<SyncUiEvent>,
    backup_job_running: bool,
    network_job_running: bool,
}

struct PairingContext {
    key_pair: Option<woo_todo_core::PairingKeyPair>,
    pairing_id: String,
    pairing_secret: Option<String>,
    expires_at: i64,
    claim: Option<PairingClaimInfo>,
    session_key: Option<[u8; 32]>,
    deep_link: Option<String>,
    verification_code: Option<String>,
    confirmed: bool,
}

impl Drop for PairingContext {
    fn drop(&mut self) {
        if let Some(secret) = self.pairing_secret.as_mut() {
            secret.zeroize();
        }
        if let Some(session_key) = self.session_key.as_mut() {
            session_key.zeroize();
        }
        if let Some(link) = self.deep_link.as_mut() {
            link.zeroize();
        }
    }
}

enum SyncUiEvent {
    PairingCreated {
        generation: u64,
        result: Result<
            (
                woo_todo_core::PairingKeyPair,
                crate::worker::CreatedPairing,
                String,
            ),
            String,
        >,
    },
    PairingStatus {
        generation: u64,
        pairing_id: String,
        result: Result<PairingState, String>,
    },
    PairingConfirmed {
        generation: u64,
        pairing_id: String,
        result: Result<(), String>,
    },
    BackupExported {
        path: PathBuf,
        result: Result<(), String>,
    },
    BackupOpened {
        path: PathBuf,
        result: Result<woo_todo_core::BackupSnapshot, String>,
    },
    WorkerVaultCreated(Result<SyncCredentials, String>),
    SyncPreflighted(Result<SyncCredentials, String>),
    DevicesLoaded(Result<String, String>),
    DeviceRevoked(Result<String, String>),
}

enum UpdateEvent {
    Checked {
        manual: bool,
        result: Result<Option<UpdateRelease>, String>,
    },
    Downloaded(Result<PreparedUpdate, String>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum UpdateState {
    Idle,
    Checking,
    Downloading,
}

#[derive(Debug, Clone)]
struct TaskInput {
    title: String,
    time_type: TimeType,
    target_date: NaiveDate,
    quest_line: QuestLine,
    repeats: bool,
    reminder_time: Option<ReminderTime>,
    deadline_date: Option<NaiveDate>,
}

#[derive(Default)]
struct EditorControls {
    title: HWND,
    time_type: HWND,
    quest: HWND,
    date: HWND,
    repeats: HWND,
    reminder_enabled: HWND,
    reminder_time: HWND,
    deadline_enabled: HWND,
    deadline_date: HWND,
}

struct EditorState {
    controls: EditorControls,
    input: Option<TaskInput>,
    initial_type: TimeType,
    initial_date: NaiveDate,
    existing: Option<TodoTask>,
}

pub fn run() -> Result<(), String> {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let _ = CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32);
        let application_id = wide(APP_ID);
        let _ = SetCurrentProcessExplicitAppUserModelID(application_id.as_ptr());
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_LISTVIEW_CLASSES | ICC_DATE_CLASSES | ICC_BAR_CLASSES,
        };
        if InitCommonControlsEx(&controls) == 0 {
            return Err(last_error("无法初始化 Windows 通用控件"));
        }

        let mutex_name = wide(MUTEX_NAME);
        let mutex = CreateMutexW(null(), 1, mutex_name.as_ptr());
        if mutex.is_null() {
            return Err(last_error("无法创建单实例互斥量"));
        }
        if GetLastError() == ERROR_ALREADY_EXISTS {
            forward_to_running_instance();
            CloseHandle(mutex);
            CoUninitialize();
            return Ok(());
        }

        let integration_warning =
            if std::env::var_os("WOO_TODO_SKIP_PORTABLE_INTEGRATION").is_none() {
                crate::integration::ensure_registered().err()
            } else {
                None
            };

        let instance = GetModuleHandleW(null());
        if instance.is_null() {
            return Err(last_error("无法获取应用模块"));
        }
        let theme = ThemeResources::new();
        register_window_class(
            instance,
            MAIN_CLASS,
            Some(main_window_proc),
            theme.paper_brush,
        )?;
        register_window_class(
            instance,
            FLOAT_CLASS,
            Some(float_window_proc),
            theme.ink_brush,
        )?;
        register_window_class(
            instance,
            EDITOR_CLASS,
            Some(editor_window_proc),
            theme.paper_brush,
        )?;

        let data_directory = data_directory();
        let database = data_directory.join("woo-todo.sqlite3");
        let mut repository = TaskRepository::open(&database)
            .map_err(|error| format!("无法打开本地任务库：{error}"))?;
        let mut settings = AppSettings::load(&data_directory);
        if repository
            .display_configuration()
            .map_err(|error| format!("无法读取显示配置：{error}"))?
            .is_none()
        {
            let payload = woo_todo_core::WireDisplayConfigurationPayload::new(
                settings.display.header_template.clone(),
                settings.display.subtitle_template.clone(),
                settings.display.start_date,
                settings.display.deadline_date,
            )
            .map_err(|error| format!("无法初始化显示配置：{error}"))?;
            repository
                .seed_display_configuration(&payload)
                .map_err(|error| format!("无法初始化显示配置：{error}"))?;
        }
        let credential_store = Arc::new(WindowsCredentialStore::default());
        let mut sync_warnings = Vec::new();
        if settings.local_network_host {
            match credential_store.load() {
                Ok(Some(credentials)) if credentials.mode() == SyncMode::LocalNetwork => {
                    match preferred_local_endpoint(DEFAULT_LOCAL_SYNC_PORT)
                        .map_err(|error| error.to_string())
                        .and_then(|endpoint| credentials.with_endpoint(endpoint))
                        .and_then(|updated| credential_store.save(&updated).map(|()| updated))
                    {
                        Ok(_) => {}
                        Err(error) => {
                            sync_warnings.push(format!("无法刷新局域网主机地址：{error}"))
                        }
                    }
                }
                Ok(_) => {
                    settings.local_network_host = false;
                    if let Err(error) = settings.save() {
                        sync_warnings.push(format!("无法修正局域网主机设置：{error}"));
                    }
                }
                Err(error) => sync_warnings.push(error),
            }
        }
        if let Err(error) =
            configure_repository_from_store(&mut repository, credential_store.as_ref())
        {
            sync_warnings.push(error);
        }
        if let Ok(Some(display)) = repository.display_configuration() {
            let configuration = DisplayConfiguration {
                header_template: display.header_template,
                subtitle_template: display.subtitle_template,
                start_date: display.start_date,
                deadline_date: display.deadline_date,
            };
            if configuration.validate().is_ok() && configuration != settings.display {
                settings.display = configuration;
                if let Err(error) = settings.save() {
                    sync_warnings.push(format!("无法保存同步的显示配置：{error}"));
                }
            }
        }
        let configured_credentials = credential_store.load().ok().flatten();
        let mut local_network_server = None;
        if settings.local_network_host {
            match configured_credentials.as_ref() {
                Some(credentials) if credentials.mode() == SyncMode::LocalNetwork => {
                    match start_local_network_host(&data_directory, credentials) {
                        Ok(server) => local_network_server = Some(server),
                        Err(error) => sync_warnings.push(error),
                    }
                }
                _ => {
                    settings.local_network_host = false;
                    if let Err(error) = settings.save() {
                        sync_warnings.push(format!("无法修正局域网主机设置：{error}"));
                    }
                }
            }
        }
        let sync_warning = (!sync_warnings.is_empty()).then(|| sync_warnings.join("\n"));
        let sync_configured = configured_credentials.is_some();
        repository
            .settle_expired(today_shanghai(), now_millis())
            .map_err(|error| format!("无法结算已结束周期：{error}"))?;
        let sync_runtime = SyncRuntime::start(database.clone(), credential_store.clone());

        let (update_sender, update_receiver) = mpsc::channel();
        let (sync_ui_sender, sync_ui_receiver) = mpsc::channel();
        let mut app = Box::new(App {
            instance,
            main: null_mut(),
            floating: null_mut(),
            main_controls: MainControls::default(),
            float_controls: FloatControls::default(),
            sync_controls: SyncControls::default(),
            repository,
            database_path: database,
            settings,
            section: Section::Today,
            visible_tasks: Vec::new(),
            floating_tasks: Vec::new(),
            populating_main_tasks: false,
            populating_float_tasks: false,
            exiting: false,
            tray_added: false,
            mutex,
            theme,
            update_sender,
            update_receiver,
            update_state: UpdateState::Idle,
            available_update: None,
            current_date: today_shanghai(),
            credential_store,
            sync_runtime,
            last_sync_successful_at: None,
            last_sync_error: None,
            data_directory,
            local_network_server,
            pairing: None,
            pairing_job_running: false,
            pairing_next_poll_at: 0,
            pairing_generation: 0,
            pairing_qr_bitmap: null_mut(),
            webdav_setup_link: None,
            sync_ui_sender,
            sync_ui_receiver,
            backup_job_running: false,
            network_job_running: false,
        });
        let app_pointer = (&mut *app) as *mut App;

        app.main = create_top_window(
            MAIN_CLASS,
            "Woo Todo · 任务详情、统计与设置",
            WS_OVERLAPPEDWINDOW,
            0,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1040,
            700,
            app_pointer.cast(),
        )?;
        if let Err(error) = create_main_controls(&mut app) {
            destroy_startup_windows(&mut app);
            return Err(error);
        }

        app.floating = match create_top_window(
            FLOAT_CLASS,
            "今日任务",
            WS_POPUP | WS_THICKFRAME,
            WS_EX_TOOLWINDOW | WS_EX_LAYERED,
            app.settings.board_left.round() as i32,
            app.settings.board_top.round() as i32,
            app.settings.board_width.round() as i32,
            app.settings.board_height.round() as i32,
            app_pointer.cast(),
        ) {
            Ok(window) => window,
            Err(error) => {
                destroy_startup_windows(&mut app);
                return Err(error);
            }
        };
        if let Err(error) = create_float_controls(&mut app) {
            destroy_startup_windows(&mut app);
            return Err(error);
        }
        apply_floating_settings(&app);
        keep_floating_on_screen(&app);
        if let Err(error) = add_tray_icon(&mut app) {
            destroy_startup_windows(&mut app);
            return Err(error);
        }
        if let Some(error) = integration_warning {
            show_tray_warning(&app, "系统提醒配置未完成", &error);
        }
        if let Some(error) = sync_warning {
            show_tray_warning(&app, "同步配置未能恢复", &error);
        }
        register_hotkeys(&app);
        refresh_all(&mut app);
        SetTimer(
            app.main,
            PERIOD_REFRESH_TIMER_ID,
            PERIOD_REFRESH_INTERVAL_MILLIS,
            None,
        );
        SetTimer(
            app.main,
            SYNC_STATUS_TIMER_ID,
            SYNC_STATUS_INTERVAL_MILLIS,
            None,
        );
        if sync_configured {
            app.sync_runtime.request(SyncTrigger::Launch);
        }

        ShowWindow(
            app.floating,
            if app.settings.click_through {
                SW_SHOWNOACTIVATE
            } else {
                SW_SHOW
            },
        );
        UpdateWindow(app.floating);
        handle_activation_args(&mut app);
        if std::env::var_os("WOO_TODO_SKIP_UPDATE_CHECK").is_none() {
            begin_update_check(&mut app, false);
            SetTimer(
                app.main,
                UPDATE_CHECK_TIMER_ID,
                UPDATE_CHECK_POLL_INTERVAL_MILLIS,
                None,
            );
        }

        let mut message: MSG = zeroed();
        loop {
            let result = GetMessageW(&mut message, null_mut(), 0, 0);
            if result == -1 {
                break;
            }
            if result == 0 {
                break;
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        remove_tray_icon(&mut app);
        unregister_hotkeys(&app);
        app.sync_runtime.stop();
        if let Some(mut server) = app.local_network_server.take() {
            let _ = server.stop();
        }
        clear_pairing(&mut app);
        CloseHandle(app.mutex);
        CoUninitialize();
        Ok(())
    }
}

pub fn show_fatal_error(message: &str) {
    unsafe {
        let title = wide("Woo Todo 无法启动");
        let text = wide(message);
        MessageBoxW(
            null_mut(),
            text.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

unsafe fn register_window_class(
    instance: HINSTANCE,
    name: &str,
    proc: WNDPROC,
    background: HBRUSH,
) -> Result<(), String> {
    let class_name = wide(name);
    let icon = LoadIconW(instance, resource_id(1));
    let fallback_icon = if icon.is_null() {
        LoadIconW(null_mut(), IDI_APPLICATION)
    } else {
        icon
    };
    let class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS,
        lpfnWndProc: proc,
        hInstance: instance,
        hIcon: fallback_icon,
        hCursor: LoadCursorW(null_mut(), IDC_ARROW),
        hbrBackground: background,
        lpszClassName: class_name.as_ptr(),
        hIconSm: fallback_icon,
        ..Default::default()
    };
    if RegisterClassExW(&class) == 0 {
        return Err(last_error(&format!("无法注册窗口类 {name}")));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
unsafe fn create_top_window(
    class: &str,
    title: &str,
    style: u32,
    ex_style: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parameter: *const c_void,
) -> Result<HWND, String> {
    let class = wide(class);
    let title = wide(title);
    let window = CreateWindowExW(
        ex_style,
        class.as_ptr(),
        title.as_ptr(),
        style,
        x,
        y,
        width,
        height,
        null_mut(),
        null_mut(),
        GetModuleHandleW(null()),
        parameter,
    );
    if window.is_null() {
        Err(last_error("无法创建窗口"))
    } else {
        Ok(window)
    }
}

unsafe fn create_child(
    parent: HWND,
    class: &str,
    text: &str,
    style: u32,
    ex_style: u32,
    id: i32,
) -> Result<HWND, String> {
    let class = wide(class);
    let text = wide(text);
    let child = CreateWindowExW(
        ex_style,
        class.as_ptr(),
        text.as_ptr(),
        style | WS_CHILD,
        0,
        0,
        0,
        0,
        parent,
        id as usize as HMENU,
        GetModuleHandleW(null()),
        null(),
    );
    if child.is_null() {
        return Err(last_error(&format!("无法创建控件 {class:?}")));
    }
    SendMessageW(
        child,
        WM_SETFONT,
        GetStockObject(DEFAULT_GUI_FONT) as usize,
        1,
    );
    Ok(child)
}

unsafe fn create_main_controls(app: &mut App) -> Result<(), String> {
    let parent = app.main;
    let visible = WS_VISIBLE;
    app.main_controls.nav = create_child(
        parent,
        "LISTBOX",
        "",
        visible | WS_VSCROLL | LBS_NOTIFY as u32,
        0,
        ID_NAV,
    )?;
    for label in [
        "今日",
        "明日",
        "本周",
        "本月",
        "闲时",
        "历史",
        "统计",
        "显示与快捷键",
        "同步",
    ] {
        let value = wide(label);
        SendMessageW(
            app.main_controls.nav,
            LB_ADDSTRING,
            0,
            value.as_ptr() as isize,
        );
    }
    SendMessageW(app.main_controls.nav, LB_SETCURSEL, 0, 0);
    app.main_controls.title = create_child(parent, "STATIC", "今日", visible | STATIC_LEFT, 0, 0)?;
    app.main_controls.subtitle = create_child(parent, "STATIC", "", visible | STATIC_LEFT, 0, 0)?;
    app.main_controls.tasks = create_child(
        parent,
        "SysListView32",
        "",
        visible | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS,
        0,
        ID_TASKS,
    )?;
    SendMessageW(
        app.main_controls.tasks,
        LVM_SETEXTENDEDLISTVIEWSTYLE,
        0,
        (LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_CHECKBOXES) as isize,
    );
    add_list_column(app.main_controls.tasks, 0, "状态", 80);
    add_list_column(app.main_controls.tasks, 1, "任务", 390);
    add_list_column(app.main_controls.tasks, 2, "周期", 130);
    add_list_column(app.main_controls.tasks, 3, "级别", 90);
    add_list_column(app.main_controls.tasks, 4, "提醒与截止", 210);
    app.main_controls.content = create_child(
        parent,
        "EDIT",
        "",
        WS_BORDER | WS_VSCROLL | ES_MULTILINE as u32 | ES_READONLY as u32 | ES_AUTOVSCROLL as u32,
        WS_EX_CLIENTEDGE,
        ID_CONTENT,
    )?;

    app.main_controls.add = button(parent, "新增", ID_ADD)?;
    app.main_controls.edit = button(parent, "编辑", ID_EDIT)?;
    app.main_controls.complete = button(parent, "完成", ID_COMPLETE)?;
    app.main_controls.pass = button(parent, "Pass", ID_PASS)?;
    app.main_controls.delete = button(parent, "删除", ID_DELETE)?;
    app.main_controls.up = button(parent, "上移", ID_UP)?;
    app.main_controls.down = button(parent, "下移", ID_DOWN)?;
    app.main_controls.refresh = button(parent, "刷新", ID_REFRESH)?;

    app.main_controls.opacity_label =
        create_child(parent, "STATIC", "不透明度", STATIC_LEFT, 0, 0)?;
    app.main_controls.opacity = create_child(
        parent,
        "msctls_trackbar32",
        "",
        TBS_AUTOTICKS,
        0,
        ID_OPACITY,
    )?;
    SendMessageW(app.main_controls.opacity, TBM_SETRANGEMIN, 1, 20);
    SendMessageW(app.main_controls.opacity, TBM_SETRANGEMAX, 1, 100);
    SendMessageW(app.main_controls.opacity, TBM_SETTICFREQ, 5, 0);
    app.main_controls.opacity_value = create_child(parent, "STATIC", "", STATIC_RIGHT, 0, 0)?;
    app.main_controls.topmost = create_child(
        parent,
        "BUTTON",
        "任务板始终置顶",
        BS_AUTOCHECKBOX as u32,
        0,
        ID_TOPMOST,
    )?;
    app.main_controls.click_through = create_child(
        parent,
        "BUTTON",
        "鼠标穿透",
        BS_AUTOCHECKBOX as u32,
        0,
        ID_CLICK_THROUGH,
    )?;

    app.main_controls.display_heading =
        create_child(parent, "STATIC", "悬浮任务板标题", STATIC_LEFT, 0, 0)?;
    app.main_controls.display_header_label =
        create_child(parent, "STATIC", "标题", STATIC_LEFT, 0, 0)?;
    app.main_controls.display_header = create_child(
        parent,
        "EDIT",
        "",
        WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL as u32,
        WS_EX_CLIENTEDGE,
        ID_DISPLAY_HEADER,
    )?;
    SendMessageW(app.main_controls.display_header, EM_LIMITTEXT, 160, 0);
    app.main_controls.display_subtitle_label =
        create_child(parent, "STATIC", "副标题", STATIC_LEFT, 0, 0)?;
    app.main_controls.display_subtitle = create_child(
        parent,
        "EDIT",
        "",
        WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL as u32,
        WS_EX_CLIENTEDGE,
        ID_DISPLAY_SUBTITLE,
    )?;
    SendMessageW(app.main_controls.display_subtitle, EM_LIMITTEXT, 320, 0);
    app.main_controls.display_preview = create_child(parent, "STATIC", "", STATIC_LEFT, 0, 0)?;
    app.main_controls.display_elapsed_date_label =
        create_child(parent, "STATIC", "耗时起始日", STATIC_LEFT, 0, 0)?;
    app.main_controls.display_elapsed_date = create_child(
        parent,
        "SysDateTimePick32",
        "",
        WS_TABSTOP | DTS_SHORTDATEFORMAT,
        0,
        ID_DISPLAY_ELAPSED_DATE,
    )?;
    app.main_controls.display_deadline_date_label =
        create_child(parent, "STATIC", "截止日期", STATIC_LEFT, 0, 0)?;
    app.main_controls.display_deadline_date = create_child(
        parent,
        "SysDateTimePick32",
        "",
        WS_TABSTOP | DTS_SHORTDATEFORMAT,
        0,
        ID_DISPLAY_DEADLINE_DATE,
    )?;
    app.main_controls.display_insert_elapsed_days =
        hidden_button(parent, "插入耗时天数", ID_DISPLAY_INSERT_ELAPSED_DAYS)?;
    app.main_controls.display_insert_deadline_days =
        hidden_button(parent, "插入截止天数", ID_DISPLAY_INSERT_DEADLINE_DAYS)?;
    app.main_controls.display_insert_elapsed_months =
        hidden_button(parent, "插入耗时月日", ID_DISPLAY_INSERT_ELAPSED_MONTHS)?;
    app.main_controls.display_insert_deadline_months =
        hidden_button(parent, "插入截止月日", ID_DISPLAY_INSERT_DEADLINE_MONTHS)?;
    app.main_controls.display_save = hidden_button(parent, "保存显示", ID_DISPLAY_SAVE)?;
    app.main_controls.display_reset = hidden_button(parent, "恢复默认", ID_DISPLAY_RESET)?;

    app.main_controls.shortcut_heading =
        create_child(parent, "STATIC", "全局快捷键", STATIC_LEFT, 0, 0)?;
    for (index, label) in ["快速新增", "显示任务板", "切换置顶", "切换穿透"]
        .into_iter()
        .enumerate()
    {
        app.main_controls.shortcut_labels[index] =
            create_child(parent, "STATIC", label, STATIC_LEFT, 0, 0)?;
    }
    for (index, id) in [
        ID_SHORTCUT_QUICK_ADD,
        ID_SHORTCUT_TOGGLE_BOARD,
        ID_SHORTCUT_TOPMOST,
        ID_SHORTCUT_CLICK_THROUGH,
    ]
    .into_iter()
    .enumerate()
    {
        app.main_controls.shortcut_edits[index] = create_child(
            parent,
            "EDIT",
            "",
            WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL as u32,
            WS_EX_CLIENTEDGE,
            id,
        )?;
        SendMessageW(app.main_controls.shortcut_edits[index], EM_LIMITTEXT, 64, 0);
    }
    app.main_controls.shortcut_save = hidden_button(parent, "应用快捷键", ID_SHORTCUT_SAVE)?;
    app.main_controls.shortcut_reset = hidden_button(parent, "重置快捷键", ID_SHORTCUT_RESET)?;

    app.sync_controls.heading = create_child(parent, "STATIC", "同步方式", STATIC_LEFT, 0, 0)?;
    app.sync_controls.status = create_child(parent, "STATIC", "", STATIC_LEFT, 0, 0)?;
    app.sync_controls.mode_label = create_child(parent, "STATIC", "当前配置", STATIC_LEFT, 0, 0)?;
    app.sync_controls.mode = create_child(
        parent,
        "COMBOBOX",
        "",
        WS_TABSTOP | CBS_DROPDOWNLIST as u32,
        0,
        ID_SYNC_MODE,
    )?;
    for label in ["Worker 在线同步", "同一网络同步", "坚果云 WebDAV"] {
        combo_add(app.sync_controls.mode, label);
    }
    for label in [
        "Worker 地址",
        "创建邀请码",
        "坚果云账号",
        "应用密码",
        "空间 ID",
        "设备 ID",
        "设备令牌",
        "同步密钥",
    ] {
        let index = app
            .sync_controls
            .field_labels
            .iter()
            .position(|value| value.is_null())
            .unwrap_or(0);
        app.sync_controls.field_labels[index] =
            create_child(parent, "STATIC", label, STATIC_LEFT, 0, 0)?;
    }
    app.sync_controls.endpoint = sync_edit(parent, ID_SYNC_ENDPOINT, false)?;
    app.sync_controls.invite = sync_edit(parent, ID_SYNC_INVITE, true)?;
    app.sync_controls.username = sync_edit(parent, ID_SYNC_USERNAME, false)?;
    app.sync_controls.secret = sync_edit(parent, ID_SYNC_SECRET, true)?;
    app.sync_controls.vault_id = sync_edit(parent, ID_SYNC_VAULT, false)?;
    app.sync_controls.device_id = sync_edit(parent, ID_SYNC_DEVICE, false)?;
    app.sync_controls.device_token = sync_edit(parent, ID_SYNC_TOKEN, true)?;
    app.sync_controls.vault_key = sync_edit(parent, ID_SYNC_KEY, true)?;
    app.sync_controls.setup = hidden_button(parent, "创建空间", ID_SYNC_SETUP)?;
    app.sync_controls.save = hidden_button(parent, "保存并切换", ID_SYNC_SAVE)?;
    app.sync_controls.sync_now = hidden_button(parent, "立即同步", ID_SYNC_NOW)?;
    app.sync_controls.devices = hidden_button(parent, "刷新设备", ID_SYNC_DEVICES)?;
    app.sync_controls.revoke_label =
        create_child(parent, "STATIC", "撤销设备 ID", STATIC_LEFT, 0, 0)?;
    app.sync_controls.revoke_device = sync_edit(parent, ID_SYNC_REVOKE_DEVICE, false)?;
    app.sync_controls.revoke = hidden_button(parent, "撤销", ID_SYNC_REVOKE)?;
    app.sync_controls.pair = hidden_button(parent, "生成配对", ID_SYNC_PAIR)?;
    app.sync_controls.pair_copy = hidden_button(parent, "复制链接", ID_SYNC_PAIR_COPY)?;
    app.sync_controls.pair_confirm = hidden_button(parent, "核对一致", ID_SYNC_PAIR_CONFIRM)?;
    app.sync_controls.pair_qr = create_child(
        parent,
        "STATIC",
        "",
        STATIC_BITMAP | STATIC_CENTER_IMAGE,
        WS_EX_CLIENTEDGE,
        ID_SYNC_PAIR_QR,
    )?;
    app.sync_controls.output = create_child(
        parent,
        "EDIT",
        "",
        WS_BORDER | WS_VSCROLL | ES_MULTILINE as u32 | ES_READONLY as u32 | ES_AUTOVSCROLL as u32,
        WS_EX_CLIENTEDGE,
        ID_SYNC_OUTPUT,
    )?;
    app.sync_controls.backup_heading =
        create_child(parent, "STATIC", "加密备份", STATIC_LEFT, 0, 0)?;
    app.sync_controls.backup_passphrase_label =
        create_child(parent, "STATIC", "备份口令", STATIC_LEFT, 0, 0)?;
    app.sync_controls.backup_passphrase = sync_edit(parent, ID_BACKUP_PASSPHRASE, true)?;
    app.sync_controls.backup_confirmation_label =
        create_child(parent, "STATIC", "确认口令", STATIC_LEFT, 0, 0)?;
    app.sync_controls.backup_confirmation = sync_edit(parent, ID_BACKUP_CONFIRMATION, true)?;
    app.sync_controls.backup_include_identity = create_child(
        parent,
        "BUTTON",
        "备份 Worker/局域网同步身份",
        WS_TABSTOP | BS_AUTOCHECKBOX as u32,
        0,
        ID_BACKUP_INCLUDE_IDENTITY,
    )?;
    app.sync_controls.backup_export = hidden_button(parent, "导出 .wootodo", ID_BACKUP_EXPORT)?;
    app.sync_controls.backup_import = hidden_button(parent, "恢复 .wootodo", ID_BACKUP_IMPORT)?;

    set_control_font(app.main_controls.title, app.theme.heading_font);
    set_control_font(app.main_controls.subtitle, app.theme.subheading_font);
    set_list_palette(app.main_controls.tasks, PAPER_BRIGHT, TEXT_ON_LIGHT);

    layout_main(app);
    Ok(())
}

unsafe fn sync_edit(parent: HWND, id: i32, secret: bool) -> Result<HWND, String> {
    let style = WS_TABSTOP
        | WS_BORDER
        | ES_AUTOHSCROLL as u32
        | if secret { ES_PASSWORD as u32 } else { 0 };
    let edit = create_child(parent, "EDIT", "", style, WS_EX_CLIENTEDGE, id)?;
    SendMessageW(edit, EM_LIMITTEXT, 2_048, 0);
    Ok(edit)
}

unsafe fn create_float_controls(app: &mut App) -> Result<(), String> {
    let parent = app.floating;
    let visible = WS_VISIBLE;
    app.float_controls.heading =
        create_child(parent, "STATIC", "今日任务", visible | STATIC_LEFT, 0, 0)?;
    app.float_controls.date = create_child(parent, "STATIC", "", visible | STATIC_RIGHT, 0, 0)?;
    app.float_controls.subtitle = create_child(parent, "STATIC", "", visible | STATIC_LEFT, 0, 0)?;
    app.float_controls.progress = create_child(
        parent,
        "STATIC",
        "今日进度  0 / 0",
        visible | STATIC_LEFT,
        0,
        0,
    )?;
    app.float_controls.tasks = create_child(
        parent,
        "SysListView32",
        "",
        visible | LVS_REPORT | LVS_SINGLESEL | LVS_NOCOLUMNHEADER | LVS_SHOWSELALWAYS,
        0,
        ID_FLOAT_LIST,
    )?;
    SendMessageW(
        app.float_controls.tasks,
        LVM_SETEXTENDEDLISTVIEWSTYLE,
        0,
        (LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_CHECKBOXES) as isize,
    );
    add_list_column(app.float_controls.tasks, 0, "任务", 300);
    app.float_controls.quick_edit = create_child(
        parent,
        "EDIT",
        "",
        visible | WS_BORDER | ES_AUTOHSCROLL as u32,
        WS_EX_CLIENTEDGE,
        ID_FLOAT_EDIT,
    )?;
    app.float_controls.add = button(parent, "添加", ID_FLOAT_ADD)?;
    app.float_controls.open = button(parent, "详情", ID_FLOAT_OPEN)?;
    set_control_font(app.float_controls.heading, app.theme.heading_font);
    set_control_font(app.float_controls.subtitle, app.theme.subheading_font);
    set_control_font(app.float_controls.progress, app.theme.subheading_font);
    set_list_palette(app.float_controls.tasks, INK_SOFT, TEXT_ON_DARK);
    apply_dark_control_theme(app.float_controls.tasks);
    apply_dark_control_theme(app.float_controls.quick_edit);
    apply_dark_control_theme(app.float_controls.add);
    apply_dark_control_theme(app.float_controls.open);
    let previous = SetWindowLongPtrW(
        app.float_controls.quick_edit,
        GWLP_WNDPROC,
        quick_edit_proc as *const () as isize,
    );
    QUICK_EDIT_PROC.store(previous, Ordering::Release);
    layout_floating(app);
    Ok(())
}

unsafe fn button(parent: HWND, text: &str, id: i32) -> Result<HWND, String> {
    create_child(
        parent,
        "BUTTON",
        text,
        WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON as u32,
        0,
        id,
    )
}

unsafe fn hidden_button(parent: HWND, text: &str, id: i32) -> Result<HWND, String> {
    create_child(
        parent,
        "BUTTON",
        text,
        WS_TABSTOP | BS_PUSHBUTTON as u32,
        0,
        id,
    )
}

unsafe fn layout_main(app: &App) {
    let mut area: RECT = zeroed();
    GetClientRect(app.main, &mut area);
    let width = area.right.max(820);
    let height = area.bottom.max(560);
    let nav_width = 190;
    MoveWindow(
        app.main_controls.nav,
        16,
        18,
        nav_width - 28,
        height - 36,
        1,
    );
    MoveWindow(
        app.main_controls.title,
        nav_width + 22,
        20,
        width - nav_width - 180,
        30,
        1,
    );
    MoveWindow(
        app.main_controls.subtitle,
        nav_width + 22,
        52,
        width - nav_width - 44,
        22,
        1,
    );
    MoveWindow(
        app.main_controls.tasks,
        nav_width + 22,
        88,
        width - nav_width - 44,
        height - 148,
        1,
    );
    let task_list_width = width - nav_width - 44;
    let title_column_width = (task_list_width - 72 - 120 - 72 - 160).max(170);
    for (column, column_width) in [
        (0, 72),
        (1, title_column_width),
        (2, 120),
        (3, 72),
        (4, 160),
    ] {
        SendMessageW(
            app.main_controls.tasks,
            LVM_SETCOLUMNWIDTH,
            column,
            column_width as isize,
        );
    }
    MoveWindow(
        app.main_controls.content,
        nav_width + 22,
        88,
        width - nav_width - 44,
        height - 110,
        1,
    );

    let mut x = nav_width + 22;
    for control in [
        app.main_controls.add,
        app.main_controls.edit,
        app.main_controls.complete,
        app.main_controls.pass,
        app.main_controls.up,
        app.main_controls.down,
        app.main_controls.delete,
        app.main_controls.refresh,
    ] {
        MoveWindow(control, x, height - 48, 72, 30, 1);
        x += 78;
    }
    let settings_left = nav_width + 30;
    let settings_width = width - settings_left - 22;
    MoveWindow(
        app.main_controls.display_heading,
        settings_left,
        88,
        settings_width,
        24,
        1,
    );
    MoveWindow(
        app.main_controls.display_header_label,
        settings_left,
        120,
        70,
        24,
        1,
    );
    MoveWindow(
        app.main_controls.display_header,
        settings_left + 76,
        116,
        settings_width - 76,
        30,
        1,
    );
    MoveWindow(
        app.main_controls.display_subtitle_label,
        settings_left,
        154,
        70,
        24,
        1,
    );
    MoveWindow(
        app.main_controls.display_subtitle,
        settings_left + 76,
        150,
        settings_width - 76,
        30,
        1,
    );
    MoveWindow(
        app.main_controls.display_preview,
        settings_left,
        186,
        settings_width,
        22,
        1,
    );
    let date_group_width = (settings_width - 18) / 2;
    MoveWindow(
        app.main_controls.display_elapsed_date_label,
        settings_left,
        218,
        78,
        24,
        1,
    );
    MoveWindow(
        app.main_controls.display_elapsed_date,
        settings_left + 82,
        214,
        date_group_width - 82,
        30,
        1,
    );
    MoveWindow(
        app.main_controls.display_deadline_date_label,
        settings_left + date_group_width + 18,
        218,
        70,
        24,
        1,
    );
    MoveWindow(
        app.main_controls.display_deadline_date,
        settings_left + date_group_width + 94,
        214,
        date_group_width - 76,
        30,
        1,
    );
    let counter_width = (settings_width - 18) / 4;
    for (index, control) in [
        app.main_controls.display_insert_elapsed_days,
        app.main_controls.display_insert_deadline_days,
        app.main_controls.display_insert_elapsed_months,
        app.main_controls.display_insert_deadline_months,
    ]
    .into_iter()
    .enumerate()
    {
        MoveWindow(
            control,
            settings_left + index as i32 * (counter_width + 6),
            252,
            counter_width,
            28,
            1,
        );
    }
    MoveWindow(
        app.main_controls.display_reset,
        settings_left,
        288,
        92,
        28,
        1,
    );
    MoveWindow(
        app.main_controls.display_save,
        settings_left + 100,
        288,
        92,
        28,
        1,
    );

    MoveWindow(
        app.main_controls.shortcut_heading,
        settings_left,
        328,
        settings_width,
        24,
        1,
    );
    let shortcut_column_width = (settings_width - 18) / 2;
    for index in 0..4 {
        let column = index % 2;
        let row = index / 2;
        let x = settings_left + column as i32 * (shortcut_column_width + 18);
        let y = 358 + row as i32 * 36;
        MoveWindow(
            app.main_controls.shortcut_labels[index],
            x,
            y + 4,
            82,
            24,
            1,
        );
        MoveWindow(
            app.main_controls.shortcut_edits[index],
            x + 86,
            y,
            shortcut_column_width - 86,
            30,
            1,
        );
    }
    MoveWindow(
        app.main_controls.shortcut_reset,
        settings_left,
        432,
        104,
        28,
        1,
    );
    MoveWindow(
        app.main_controls.shortcut_save,
        settings_left + 112,
        432,
        104,
        28,
        1,
    );

    MoveWindow(
        app.main_controls.opacity_label,
        settings_left,
        480,
        80,
        24,
        1,
    );
    MoveWindow(
        app.main_controls.opacity,
        settings_left + 82,
        470,
        (settings_width - 150).max(120),
        40,
        1,
    );
    MoveWindow(
        app.main_controls.opacity_value,
        settings_left + settings_width - 60,
        480,
        60,
        24,
        1,
    );
    MoveWindow(app.main_controls.topmost, settings_left, 514, 240, 28, 1);
    MoveWindow(
        app.main_controls.click_through,
        settings_left,
        548,
        240,
        28,
        1,
    );

    MoveWindow(
        app.sync_controls.heading,
        settings_left,
        88,
        settings_width,
        24,
        1,
    );
    MoveWindow(
        app.sync_controls.status,
        settings_left,
        114,
        settings_width,
        22,
        1,
    );
    MoveWindow(app.sync_controls.mode_label, settings_left, 144, 78, 24, 1);
    MoveWindow(app.sync_controls.mode, settings_left + 82, 140, 210, 220, 1);
    let sync_column_width = (settings_width - 18) / 2;
    let sync_edits = [
        app.sync_controls.endpoint,
        app.sync_controls.invite,
        app.sync_controls.username,
        app.sync_controls.secret,
        app.sync_controls.vault_id,
        app.sync_controls.device_id,
        app.sync_controls.device_token,
        app.sync_controls.vault_key,
    ];
    for (index, edit) in sync_edits.into_iter().enumerate() {
        let column = index % 2;
        let row = index / 2;
        let x = settings_left + column as i32 * (sync_column_width + 18);
        let y = 178 + row as i32 * 34;
        MoveWindow(app.sync_controls.field_labels[index], x, y + 4, 82, 22, 1);
        MoveWindow(edit, x + 84, y, sync_column_width - 84, 28, 1);
    }
    let sync_action_gap = 8;
    let sync_action_width = ((settings_width - sync_action_gap * 6) / 7).max(72);
    for (index, control) in [
        app.sync_controls.setup,
        app.sync_controls.save,
        app.sync_controls.sync_now,
        app.sync_controls.devices,
        app.sync_controls.pair,
        app.sync_controls.pair_copy,
        app.sync_controls.pair_confirm,
    ]
    .into_iter()
    .enumerate()
    {
        MoveWindow(
            control,
            settings_left + index as i32 * (sync_action_width + sync_action_gap),
            318,
            sync_action_width,
            28,
            1,
        );
    }
    MoveWindow(
        app.sync_controls.revoke_label,
        settings_left,
        354,
        88,
        24,
        1,
    );
    MoveWindow(
        app.sync_controls.revoke_device,
        settings_left + 92,
        350,
        (settings_width - 180).max(180),
        28,
        1,
    );
    MoveWindow(
        app.sync_controls.revoke,
        settings_left + settings_width - 80,
        350,
        80,
        28,
        1,
    );
    MoveWindow(app.sync_controls.pair_qr, settings_left, 386, 172, 172, 1);
    let sync_qr_visible = (app
        .pairing
        .as_ref()
        .is_some_and(|context| context.deep_link.is_some())
        || app.webdav_setup_link.is_some())
        && !app.pairing_qr_bitmap.is_null();
    MoveWindow(
        app.sync_controls.output,
        if sync_qr_visible {
            settings_left + 184
        } else {
            settings_left
        },
        386,
        if sync_qr_visible {
            settings_width - 184
        } else {
            settings_width
        },
        172,
        1,
    );
    MoveWindow(
        app.sync_controls.backup_heading,
        settings_left,
        474,
        settings_width,
        24,
        1,
    );
    let backup_field_width = (settings_width - 210) / 2;
    MoveWindow(
        app.sync_controls.backup_passphrase_label,
        settings_left,
        506,
        72,
        24,
        1,
    );
    MoveWindow(
        app.sync_controls.backup_passphrase,
        settings_left + 76,
        502,
        backup_field_width,
        28,
        1,
    );
    MoveWindow(
        app.sync_controls.backup_confirmation_label,
        settings_left + 88 + backup_field_width,
        506,
        72,
        24,
        1,
    );
    MoveWindow(
        app.sync_controls.backup_confirmation,
        settings_left + 164 + backup_field_width,
        502,
        backup_field_width,
        28,
        1,
    );
    MoveWindow(
        app.sync_controls.backup_include_identity,
        settings_left,
        540,
        250,
        28,
        1,
    );
    MoveWindow(
        app.sync_controls.backup_export,
        settings_left + settings_width - 246,
        540,
        118,
        28,
        1,
    );
    MoveWindow(
        app.sync_controls.backup_import,
        settings_left + settings_width - 120,
        540,
        120,
        28,
        1,
    );
}

unsafe fn layout_floating(app: &App) {
    let mut area: RECT = zeroed();
    GetClientRect(app.floating, &mut area);
    let width = area.right.max(320);
    let height = area.bottom.max(360);
    MoveWindow(app.float_controls.heading, 18, 14, width / 2 - 24, 30, 1);
    MoveWindow(
        app.float_controls.date,
        width / 2 - 2,
        18,
        width / 2 - 16,
        22,
        1,
    );
    MoveWindow(app.float_controls.subtitle, 18, 45, width - 36, 20, 1);
    MoveWindow(app.float_controls.progress, 18, 70, width - 36, 22, 1);
    MoveWindow(
        app.float_controls.tasks,
        18,
        98,
        width - 36,
        height - 156,
        1,
    );
    SendMessageW(
        app.float_controls.tasks,
        LVM_SETCOLUMNWIDTH,
        0,
        (width - 42) as isize,
    );
    MoveWindow(
        app.float_controls.quick_edit,
        18,
        height - 46,
        width - 184,
        28,
        1,
    );
    MoveWindow(app.float_controls.open, width - 154, height - 46, 62, 28, 1);
    MoveWindow(app.float_controls.add, width - 86, height - 46, 68, 28, 1);
}

unsafe fn refresh_all(app: &mut App) {
    app.current_date = today_shanghai();
    refresh_main(app);
    refresh_floating(app);
    if let Err(error) = reconcile_notifications(app) {
        show_tray_warning(app, "任务提醒未能更新", &error);
    }
}

unsafe fn refresh_main(app: &mut App) {
    let today = today_shanghai();
    if let Ok(result) = app.repository.settle_expired(today, now_millis())
        && (!result.changed_task_ids.is_empty() || !result.generated_task_ids.is_empty())
    {
        app.sync_runtime.request(SyncTrigger::LocalChange);
    }
    hide_settings(app);
    match app.section {
        Section::Statistics => show_statistics(app, today),
        Section::Settings => show_settings(app),
        Section::Sync => show_sync_settings(app),
        section => show_tasks(app, section, today),
    }
}

unsafe fn show_tasks(app: &mut App, section: Section, today: NaiveDate) {
    let (title, subtitle, result) = match section {
        Section::Today => (
            "今日",
            today.format("%Y年%m月%d日").to_string(),
            app.repository.fetch_scope(TimeType::Day, today, true),
        ),
        Section::Tomorrow => {
            let tomorrow = today.checked_add_days(Days::new(1)).unwrap_or(today);
            (
                "明日",
                tomorrow.format("%Y年%m月%d日").to_string(),
                app.repository.fetch_scope(TimeType::Day, tomorrow, false),
            )
        }
        Section::Week => (
            "本周",
            "本周与已规划的每周任务".to_owned(),
            app.repository.fetch_scope(TimeType::Week, today, true),
        ),
        Section::Month => (
            "本月",
            "本月与已规划的每月任务".to_owned(),
            app.repository.fetch_scope(TimeType::Month, today, true),
        ),
        Section::Someday => (
            "闲时",
            "没有截止时间的闲时任务".to_owned(),
            app.repository.fetch_scope(TimeType::Someday, today, true),
        ),
        Section::History => {
            let mut tasks = app.repository.fetch_all().unwrap_or_default();
            tasks.retain(|task| task.state != TaskState::Pending);
            tasks.sort_by_key(|task| Reverse(task.settled_at));
            ("历史", "已完成与 Pass 的只读记录".to_owned(), Ok(tasks))
        }
        _ => return,
    };
    set_text(app.main_controls.title, title);
    set_text(app.main_controls.subtitle, &subtitle);
    ShowWindow(app.main_controls.tasks, SW_SHOW);
    ShowWindow(app.main_controls.content, SW_HIDE);
    let history = section == Section::History;
    for control in [
        app.main_controls.add,
        app.main_controls.edit,
        app.main_controls.complete,
        app.main_controls.pass,
        app.main_controls.delete,
        app.main_controls.up,
        app.main_controls.down,
        app.main_controls.refresh,
    ] {
        ShowWindow(control, SW_SHOW);
    }
    if history {
        for control in [
            app.main_controls.add,
            app.main_controls.edit,
            app.main_controls.complete,
            app.main_controls.pass,
            app.main_controls.delete,
            app.main_controls.up,
            app.main_controls.down,
        ] {
            ShowWindow(control, SW_HIDE);
        }
    }
    app.visible_tasks = result.unwrap_or_else(|error| {
        show_error(app.main, "无法读取任务", &error.to_string());
        Vec::new()
    });
    app.populating_main_tasks = true;
    populate_task_list(app.main_controls.tasks, &app.visible_tasks, section, today);
    app.populating_main_tasks = false;
    update_main_action_state(app);
}

unsafe fn show_statistics(app: &mut App, today: NaiveDate) {
    set_text(app.main_controls.title, "统计");
    set_text(app.main_controls.subtitle, "履约率只统计已经结束的周期");
    ShowWindow(app.main_controls.tasks, SW_HIDE);
    ShowWindow(app.main_controls.content, SW_SHOW);
    hide_action_buttons(app);
    let tasks = app.repository.fetch_all().unwrap_or_default();
    let snapshot = calculate_statistics(&tasks, today, 100);
    let rate = |completed: usize, pass: usize| {
        let total = completed + pass;
        if total == 0 {
            "--".to_owned()
        } else {
            format!("{:.0}%", completed as f64 * 100.0 / total as f64)
        }
    };
    let mut text = format!(
        "周期履约率  {}    样本 {}    完成 {} · Pass {}\r\n主线履约率  {}    样本 {}    完成 {} · Pass {}\r\n\r\n按时间范围\r\n",
        rate(
            snapshot.ended_periods.completed,
            snapshot.ended_periods.pass
        ),
        snapshot.ended_periods.completed + snapshot.ended_periods.pass,
        snapshot.ended_periods.completed,
        snapshot.ended_periods.pass,
        rate(
            snapshot.main_ended_periods.completed,
            snapshot.main_ended_periods.pass
        ),
        snapshot.main_ended_periods.completed + snapshot.main_ended_periods.pass,
        snapshot.main_ended_periods.completed,
        snapshot.main_ended_periods.pass,
    );
    for kind in [
        TimeType::Day,
        TimeType::Week,
        TimeType::Month,
        TimeType::Someday,
    ] {
        if let Some(counts) = snapshot.by_time_type.get(&kind) {
            text.push_str(&format!(
                "{:<6}  待完成 {}    完成 {}    Pass {}\r\n",
                time_type_label(kind),
                counts.pending,
                counts.completed,
                counts.pass
            ));
        }
    }
    text.push_str("\r\n按任务级别\r\n");
    for line in [QuestLine::Main, QuestLine::Side, QuestLine::Extra] {
        if let Some(counts) = snapshot.by_quest_line.get(&line) {
            text.push_str(&format!(
                "{:<6}  待完成 {}    完成 {}    Pass {}\r\n",
                quest_line_label(line),
                counts.pending,
                counts.completed,
                counts.pass
            ));
        }
    }
    text.push_str("\r\n最近 7 日（每日任务）\r\n");
    for bucket in &snapshot.daily_trend {
        let sample = bucket.completed + bucket.pass;
        text.push_str(&format!(
            "{}    履约率 {}    样本 {}    完成 {}    Pass {}\r\n",
            bucket.start,
            if bucket.is_ended {
                rate(bucket.completed, bucket.pass)
            } else {
                "进行中".to_owned()
            },
            sample,
            bucket.completed,
            bucket.pass,
        ));
    }
    text.push_str("\r\n最近 8 周（每周任务）\r\n");
    for bucket in &snapshot.weekly_trend {
        let sample = bucket.completed + bucket.pass;
        text.push_str(&format!(
            "{} 起    履约率 {}    样本 {}    完成 {}    Pass {}\r\n",
            bucket.start,
            if bucket.is_ended {
                rate(bucket.completed, bucket.pass)
            } else {
                "进行中".to_owned()
            },
            sample,
            bucket.completed,
            bucket.pass,
        ));
    }
    text.push_str("\r\n最近 6 月（每月任务）\r\n");
    for bucket in &snapshot.monthly_trend {
        let sample = bucket.completed + bucket.pass;
        text.push_str(&format!(
            "{}    履约率 {}    样本 {}    完成 {}    Pass {}\r\n",
            bucket.start.format("%Y-%m"),
            if bucket.is_ended {
                rate(bucket.completed, bucket.pass)
            } else {
                "进行中".to_owned()
            },
            sample,
            bucket.completed,
            bucket.pass,
        ));
    }
    set_text(app.main_controls.content, &text);
}

unsafe fn show_settings(app: &mut App) {
    set_text(app.main_controls.title, "显示与快捷键");
    set_text(app.main_controls.subtitle, "任务板外观与全局操作");
    ShowWindow(app.main_controls.tasks, SW_HIDE);
    ShowWindow(app.main_controls.content, SW_HIDE);
    hide_action_buttons(app);
    for control in settings_controls(app) {
        ShowWindow(control, SW_SHOW);
    }
    set_text(
        app.main_controls.display_header,
        &app.settings.display.header_template,
    );
    set_text(
        app.main_controls.display_subtitle,
        &app.settings.display.subtitle_template,
    );
    set_date(app.main_controls.display_elapsed_date, today_shanghai());
    set_date(app.main_controls.display_deadline_date, today_shanghai());
    update_display_preview(app);
    populate_shortcut_edits(app, &app.settings.shortcuts);
    SendMessageW(
        app.main_controls.opacity,
        TBM_SETPOS,
        1,
        app.settings.opacity_percent() as isize,
    );
    set_text(
        app.main_controls.opacity_value,
        &format!("{}%", app.settings.opacity_percent()),
    );
    SendMessageW(
        app.main_controls.topmost,
        BM_SETCHECK,
        if app.settings.topmost {
            BST_CHECKED
        } else {
            BST_UNCHECKED
        } as usize,
        0,
    );
    SendMessageW(
        app.main_controls.click_through,
        BM_SETCHECK,
        if app.settings.click_through {
            BST_CHECKED
        } else {
            BST_UNCHECKED
        } as usize,
        0,
    );
}

unsafe fn show_sync_settings(app: &mut App) {
    set_text(app.main_controls.title, "同步");
    set_text(
        app.main_controls.subtitle,
        "同步方式互斥；本地任务始终可离线使用",
    );
    ShowWindow(app.main_controls.tasks, SW_HIDE);
    ShowWindow(app.main_controls.content, SW_HIDE);
    hide_action_buttons(app);
    for control in sync_settings_controls(app) {
        ShowWindow(control, SW_SHOW);
    }
    populate_sync_form(app);
    update_pairing_controls(app);
}

unsafe fn hide_settings(app: &App) {
    for control in settings_controls(app) {
        ShowWindow(control, SW_HIDE);
    }
    for control in sync_settings_controls(app) {
        ShowWindow(control, SW_HIDE);
    }
}

fn settings_controls(app: &App) -> Vec<HWND> {
    let mut controls = vec![
        app.main_controls.opacity_label,
        app.main_controls.opacity,
        app.main_controls.opacity_value,
        app.main_controls.topmost,
        app.main_controls.click_through,
        app.main_controls.display_heading,
        app.main_controls.display_header_label,
        app.main_controls.display_header,
        app.main_controls.display_subtitle_label,
        app.main_controls.display_subtitle,
        app.main_controls.display_preview,
        app.main_controls.display_elapsed_date_label,
        app.main_controls.display_elapsed_date,
        app.main_controls.display_deadline_date_label,
        app.main_controls.display_deadline_date,
        app.main_controls.display_insert_elapsed_days,
        app.main_controls.display_insert_deadline_days,
        app.main_controls.display_insert_elapsed_months,
        app.main_controls.display_insert_deadline_months,
        app.main_controls.display_save,
        app.main_controls.display_reset,
        app.main_controls.shortcut_heading,
        app.main_controls.shortcut_save,
        app.main_controls.shortcut_reset,
    ];
    controls.extend(app.main_controls.shortcut_labels);
    controls.extend(app.main_controls.shortcut_edits);
    controls
}

fn sync_settings_controls(app: &App) -> Vec<HWND> {
    let mut controls = vec![
        app.sync_controls.heading,
        app.sync_controls.status,
        app.sync_controls.mode_label,
        app.sync_controls.mode,
        app.sync_controls.endpoint,
        app.sync_controls.invite,
        app.sync_controls.username,
        app.sync_controls.secret,
        app.sync_controls.vault_id,
        app.sync_controls.device_id,
        app.sync_controls.device_token,
        app.sync_controls.vault_key,
        app.sync_controls.setup,
        app.sync_controls.save,
        app.sync_controls.sync_now,
        app.sync_controls.devices,
        app.sync_controls.revoke_label,
        app.sync_controls.revoke_device,
        app.sync_controls.revoke,
        app.sync_controls.pair,
        app.sync_controls.pair_copy,
        app.sync_controls.pair_confirm,
        app.sync_controls.pair_qr,
        app.sync_controls.output,
    ];
    controls.extend(app.sync_controls.field_labels);
    controls
}

unsafe fn populate_sync_form(app: &mut App) {
    for control in [
        app.sync_controls.endpoint,
        app.sync_controls.invite,
        app.sync_controls.username,
        app.sync_controls.secret,
        app.sync_controls.vault_id,
        app.sync_controls.device_id,
        app.sync_controls.device_token,
        app.sync_controls.vault_key,
    ] {
        set_text(control, "");
    }
    match app.credential_store.load() {
        Ok(Some(credentials)) => {
            let mode_index = sync_mode_index(credentials.mode());
            SendMessageW(app.sync_controls.mode, CB_SETCURSEL, mode_index as usize, 0);
            set_text(app.sync_controls.vault_id, credentials.vault_id());
            set_text(app.sync_controls.device_id, credentials.device_id());
            match credentials {
                SyncCredentials::Worker { endpoint, .. }
                | SyncCredentials::LocalNetwork { endpoint, .. } => {
                    set_text(app.sync_controls.endpoint, &endpoint);
                }
                SyncCredentials::WebDav { username, .. } => {
                    set_text(app.sync_controls.username, &username);
                }
            }
        }
        Ok(None) => {
            SendMessageW(app.sync_controls.mode, CB_SETCURSEL, 0, 0);
        }
        Err(error) => set_text(app.sync_controls.output, &error),
    }
    update_sync_form(app);
    update_sync_status(app);
}

unsafe fn update_sync_status(app: &App) {
    let snapshot = app.sync_runtime.snapshot();
    let configured = app
        .credential_store
        .load()
        .ok()
        .flatten()
        .map(|credentials| sync_mode_label(credentials.mode()).to_owned())
        .unwrap_or_else(|| "未配置".to_owned());
    let state = if snapshot.running {
        "正在同步".to_owned()
    } else if snapshot.pending {
        "等待再次同步".to_owned()
    } else if let Some(error) = snapshot.last_error {
        format!("上次失败：{error}")
    } else if let Some(timestamp) = snapshot.last_successful_at {
        format!("上次成功：{}", format_sync_timestamp(timestamp))
    } else {
        "尚未同步".to_owned()
    };
    set_text(
        app.sync_controls.status,
        &format!("当前方式：{configured}  ·  {state}"),
    );
}

unsafe fn update_sync_form(app: &App) {
    let mode = selected_sync_mode(app).unwrap_or(SyncMode::Worker);
    let worker = mode == SyncMode::Worker;
    let local = mode == SyncMode::LocalNetwork;
    let webdav = mode == SyncMode::WebDav;
    for (control, visible) in [
        (app.sync_controls.field_labels[0], worker || local),
        (app.sync_controls.endpoint, worker || local),
        (app.sync_controls.field_labels[1], worker),
        (app.sync_controls.invite, worker),
        (app.sync_controls.field_labels[2], webdav),
        (app.sync_controls.username, webdav),
        (app.sync_controls.field_labels[3], webdav),
        (app.sync_controls.secret, webdav),
        (app.sync_controls.field_labels[4], true),
        (app.sync_controls.vault_id, true),
        (app.sync_controls.field_labels[5], true),
        (app.sync_controls.device_id, true),
        (app.sync_controls.field_labels[6], worker || local),
        (app.sync_controls.device_token, worker || local),
        (app.sync_controls.field_labels[7], true),
        (app.sync_controls.vault_key, true),
        (app.sync_controls.devices, worker || local),
        (app.sync_controls.revoke_label, worker || local),
        (app.sync_controls.revoke_device, worker || local),
        (app.sync_controls.revoke, worker || local),
    ] {
        ShowWindow(control, if visible { SW_SHOW } else { SW_HIDE });
    }
    set_text(
        app.sync_controls.setup,
        match mode {
            SyncMode::Worker => "创建空间",
            SyncMode::LocalNetwork => "开启本机主机",
            SyncMode::WebDav => "生成新空间",
        },
    );
    let can_include_identity =
        app.credential_store
            .load()
            .ok()
            .flatten()
            .is_some_and(|credentials| match credentials.mode() {
                SyncMode::Worker => true,
                SyncMode::LocalNetwork => app.settings.local_network_host,
                SyncMode::WebDav => false,
            });
    EnableWindow(
        app.sync_controls.backup_include_identity,
        can_include_identity as i32,
    );
    if !can_include_identity {
        SendMessageW(
            app.sync_controls.backup_include_identity,
            BM_SETCHECK,
            BST_UNCHECKED as usize,
            0,
        );
    }
    update_network_controls(app);
    update_backup_controls(app);
    update_pairing_controls(app);
}

unsafe fn update_pairing_controls(app: &App) {
    let configured_mode = app
        .credential_store
        .load()
        .ok()
        .flatten()
        .map(|credentials| credentials.mode());
    let selected_mode = selected_sync_mode(app);
    let selected_is_configured = selected_mode == configured_mode;
    let can_pair = selected_is_configured
        && matches!(
            configured_mode,
            Some(SyncMode::Worker | SyncMode::LocalNetwork)
        );
    let can_share_webdav = selected_is_configured && configured_mode == Some(SyncMode::WebDav);
    let context = app.pairing.as_ref();
    let awaiting_scan =
        context.is_some_and(|value| value.deep_link.is_some()) || app.webdav_setup_link.is_some();
    let awaiting_confirmation = context.is_some_and(|value| {
        value.claim.is_some() && value.session_key.is_some() && !value.confirmed
    });
    let confirmed = context.is_some_and(|value| value.confirmed);

    ShowWindow(
        app.sync_controls.pair,
        if can_pair || can_share_webdav {
            SW_SHOW
        } else {
            SW_HIDE
        },
    );
    set_text(
        app.sync_controls.pair,
        if can_share_webdav && app.webdav_setup_link.is_some() {
            "隐藏配置码"
        } else if can_share_webdav {
            "生成配置码"
        } else if context.is_some() && !confirmed {
            "取消配对"
        } else if confirmed {
            "继续配对"
        } else {
            "生成配对"
        },
    );
    EnableWindow(
        app.sync_controls.pair,
        ((can_pair || can_share_webdav) && !app.pairing_job_running) as i32,
    );
    set_text(
        app.sync_controls.pair_copy,
        if app.webdav_setup_link.is_some() {
            "复制配置"
        } else {
            "复制链接"
        },
    );
    ShowWindow(
        app.sync_controls.pair_copy,
        if awaiting_scan { SW_SHOW } else { SW_HIDE },
    );
    EnableWindow(app.sync_controls.pair_copy, awaiting_scan as i32);
    ShowWindow(
        app.sync_controls.pair_confirm,
        if awaiting_confirmation {
            SW_SHOW
        } else {
            SW_HIDE
        },
    );
    EnableWindow(
        app.sync_controls.pair_confirm,
        (awaiting_confirmation && !app.pairing_job_running) as i32,
    );
    ShowWindow(
        app.sync_controls.pair_qr,
        if awaiting_scan && !app.pairing_qr_bitmap.is_null() {
            SW_SHOW
        } else {
            SW_HIDE
        },
    );

    for control in [
        app.sync_controls.backup_heading,
        app.sync_controls.backup_passphrase_label,
        app.sync_controls.backup_passphrase,
        app.sync_controls.backup_confirmation_label,
        app.sync_controls.backup_confirmation,
        app.sync_controls.backup_include_identity,
        app.sync_controls.backup_export,
        app.sync_controls.backup_import,
    ] {
        ShowWindow(control, SW_HIDE);
    }
    layout_main(app);
}

fn sync_mode_index(mode: SyncMode) -> i32 {
    match mode {
        SyncMode::Worker => 0,
        SyncMode::LocalNetwork => 1,
        SyncMode::WebDav => 2,
    }
}

fn sync_mode_label(mode: SyncMode) -> &'static str {
    match mode {
        SyncMode::Worker => "Worker 在线同步",
        SyncMode::LocalNetwork => "同一网络同步",
        SyncMode::WebDav => "坚果云 WebDAV",
    }
}

unsafe fn selected_sync_mode(app: &App) -> Option<SyncMode> {
    match SendMessageW(app.sync_controls.mode, CB_GETCURSEL, 0, 0) as i32 {
        0 => Some(SyncMode::Worker),
        1 => Some(SyncMode::LocalNetwork),
        2 => Some(SyncMode::WebDav),
        _ => None,
    }
}

fn format_sync_timestamp(timestamp: i64) -> String {
    let Some(value) = chrono::DateTime::<Utc>::from_timestamp_millis(timestamp) else {
        return "时间无效".to_owned();
    };
    let Some(offset) = chrono::FixedOffset::east_opt(8 * 60 * 60) else {
        return value.format("%Y-%m-%d %H:%M:%S UTC").to_string();
    };
    value
        .with_timezone(&offset)
        .format("%Y-%m-%d %H:%M:%S")
        .to_string()
}

unsafe fn hide_action_buttons(app: &App) {
    for control in [
        app.main_controls.add,
        app.main_controls.edit,
        app.main_controls.complete,
        app.main_controls.pass,
        app.main_controls.delete,
        app.main_controls.up,
        app.main_controls.down,
        app.main_controls.refresh,
    ] {
        ShowWindow(control, SW_HIDE);
    }
}

unsafe fn refresh_floating(app: &mut App) {
    let today = today_shanghai();
    let (heading, subtitle) = app.settings.display.render(today);
    set_text(app.float_controls.heading, heading.as_deref().unwrap_or(""));
    set_text(
        app.float_controls.subtitle,
        subtitle.as_deref().unwrap_or(""),
    );
    set_text(app.float_controls.date, &date_with_weekday(today));
    app.floating_tasks = app
        .repository
        .fetch_scope(TimeType::Day, today, true)
        .unwrap_or_default();
    let completed = app
        .floating_tasks
        .iter()
        .filter(|task| task.state == TaskState::Completed)
        .count();
    set_text(
        app.float_controls.progress,
        &format!("今日进度  {completed} / {}", app.floating_tasks.len()),
    );
    smoke_trace(&format!(
        "refresh_floating date={today} count={}",
        app.floating_tasks.len()
    ));
    app.populating_float_tasks = true;
    SendMessageW(app.float_controls.tasks, LVM_DELETEALLITEMS, 0, 0);
    SendMessageW(app.float_controls.tasks, LVM_REMOVEALLGROUPS, 0, 0);
    if app.floating_tasks.is_empty() {
        SendMessageW(app.float_controls.tasks, LVM_ENABLEGROUPVIEW, 0, 0);
        insert_list_item(app.float_controls.tasks, 0, 0, "今日暂无任务");
        set_list_state_image(app.float_controls.tasks, 0, 0);
        EnableWindow(app.float_controls.tasks, 0);
    } else {
        EnableWindow(app.float_controls.tasks, 1);
        SendMessageW(app.float_controls.tasks, LVM_ENABLEGROUPVIEW, 1, 0);
        for (index, line) in [QuestLine::Main, QuestLine::Side, QuestLine::Extra]
            .into_iter()
            .enumerate()
        {
            insert_list_group(
                app.float_controls.tasks,
                index as i32,
                quest_group_id(line),
                quest_line_label(line),
            );
        }
        for (index, task) in app.floating_tasks.iter().enumerate() {
            let badges = task_badges(task, today);
            let text = if badges.is_empty() {
                task.title.clone()
            } else {
                format!("{}  · {}", task.title, badges)
            };
            insert_grouped_list_item(
                app.float_controls.tasks,
                index as i32,
                0,
                &text,
                quest_group_id(task.quest_line),
            );
            set_list_checked(
                app.float_controls.tasks,
                index as i32,
                task.state == TaskState::Completed,
            );
        }
    }
    app.populating_float_tasks = false;
}

unsafe fn populate_task_list(list: HWND, tasks: &[TodoTask], section: Section, today: NaiveDate) {
    SendMessageW(list, LVM_DELETEALLITEMS, 0, 0);
    SendMessageW(list, LVM_REMOVEALLGROUPS, 0, 0);
    if tasks.is_empty() {
        SendMessageW(list, LVM_ENABLEGROUPVIEW, 0, 0);
        return;
    }
    SendMessageW(list, LVM_ENABLEGROUPVIEW, 1, 0);
    let groups = task_list_groups(tasks, section, today);
    for (index, (id, label)) in groups.iter().enumerate() {
        insert_list_group(list, index as i32, *id, label);
    }
    for (index, task) in tasks.iter().enumerate() {
        insert_grouped_list_item(
            list,
            index as i32,
            0,
            state_label(task.state),
            task_group_id(task, section, today),
        );
        set_list_subitem(list, index as i32, 1, &task.title);
        set_list_subitem(list, index as i32, 2, &period_label(task));
        set_list_subitem(list, index as i32, 3, quest_line_label(task.quest_line));
        set_list_subitem(list, index as i32, 4, &task_badges(task, today));
        set_list_checked(list, index as i32, task.state == TaskState::Completed);
    }
}

fn task_list_groups(tasks: &[TodoTask], section: Section, today: NaiveDate) -> Vec<(i32, String)> {
    let mut groups = Vec::new();
    if section == Section::Today {
        for (stage, stage_label) in [(0, "待处理"), (1, "今日"), (2, "已规划")] {
            for line in [QuestLine::Main, QuestLine::Side, QuestLine::Extra] {
                let id = today_group_id(stage, line);
                if tasks
                    .iter()
                    .any(|task| task_group_id(task, section, today) == id)
                {
                    groups.push((id, format!("{stage_label} · {}", quest_line_label(line))));
                }
            }
        }
    } else {
        for line in [QuestLine::Main, QuestLine::Side, QuestLine::Extra] {
            let id = quest_group_id(line);
            if tasks.iter().any(|task| task.quest_line == line) {
                groups.push((id, quest_line_label(line).to_owned()));
            }
        }
    }
    groups
}

fn task_group_id(task: &TodoTask, section: Section, today: NaiveDate) -> i32 {
    if section == Section::Today {
        let stage = match task.period_start {
            Some(date)
                if task.state == TaskState::Pending
                    && task.recurrence == Recurrence::Once
                    && date < today =>
            {
                0
            }
            Some(date) if date > today => 2,
            _ => 1,
        };
        today_group_id(stage, task.quest_line)
    } else {
        quest_group_id(task.quest_line)
    }
}

fn today_group_id(stage: i32, line: QuestLine) -> i32 {
    100 + stage * 10 + quest_group_id(line)
}

fn quest_group_id(line: QuestLine) -> i32 {
    match line {
        QuestLine::Main => 1,
        QuestLine::Side => 2,
        QuestLine::Extra => 3,
    }
}

unsafe fn set_list_checked(list: HWND, row: i32, checked: bool) {
    set_list_state_image(list, row, if checked { 2 } else { 1 });
}

unsafe fn set_list_state_image(list: HWND, row: i32, state_image: u32) {
    let item = LVITEMW {
        state: state_image << 12,
        stateMask: LVIS_STATEIMAGEMASK,
        ..Default::default()
    };
    SendMessageW(
        list,
        LVM_SETITEMSTATE,
        row as usize,
        &item as *const _ as isize,
    );
}

unsafe fn add_list_column(list: HWND, index: i32, title: &str, width: i32) {
    let mut title = wide(title);
    let column = LVCOLUMNW {
        mask: LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM,
        cx: width,
        pszText: title.as_mut_ptr(),
        iSubItem: index,
        ..Default::default()
    };
    SendMessageW(
        list,
        LVM_INSERTCOLUMNW,
        index as usize,
        &column as *const _ as isize,
    );
}

unsafe fn insert_list_item(list: HWND, row: i32, column: i32, text: &str) {
    let mut text = wide(text);
    let item = LVITEMW {
        mask: LVIF_TEXT,
        iItem: row,
        iSubItem: column,
        pszText: text.as_mut_ptr(),
        ..Default::default()
    };
    SendMessageW(list, LVM_INSERTITEMW, 0, &item as *const _ as isize);
}

unsafe fn insert_grouped_list_item(list: HWND, row: i32, column: i32, text: &str, group_id: i32) {
    let mut text = wide(text);
    let item = LVITEMW {
        mask: LVIF_TEXT | LVIF_GROUPID,
        iItem: row,
        iSubItem: column,
        pszText: text.as_mut_ptr(),
        iGroupId: group_id,
        ..Default::default()
    };
    SendMessageW(list, LVM_INSERTITEMW, 0, &item as *const _ as isize);
}

unsafe fn insert_list_group(list: HWND, index: i32, id: i32, header: &str) {
    let mut header = wide(header);
    let group = LVGROUP {
        cbSize: size_of::<LVGROUP>() as u32,
        mask: LVGF_HEADER | LVGF_GROUPID,
        pszHeader: header.as_mut_ptr(),
        cchHeader: (header.len().saturating_sub(1)) as i32,
        iGroupId: id,
        ..Default::default()
    };
    SendMessageW(
        list,
        LVM_INSERTGROUP,
        index as usize,
        &group as *const _ as isize,
    );
}

unsafe fn set_list_subitem(list: HWND, row: i32, column: i32, text: &str) {
    let mut text = wide(text);
    let item = LVITEMW {
        iItem: row,
        iSubItem: column,
        pszText: text.as_mut_ptr(),
        ..Default::default()
    };
    SendMessageW(
        list,
        LVM_SETITEMTEXTW,
        row as usize,
        &item as *const _ as isize,
    );
}

unsafe fn selected_main_task(app: &App) -> Option<TodoTask> {
    let index = SendMessageW(
        app.main_controls.tasks,
        LVM_GETNEXTITEM,
        usize::MAX,
        LVNI_SELECTED as isize,
    ) as i32;
    app.visible_tasks.get(index as usize).cloned()
}

unsafe fn selected_float_task(app: &App) -> Option<TodoTask> {
    let index = SendMessageW(
        app.float_controls.tasks,
        LVM_GETNEXTITEM,
        usize::MAX,
        LVNI_SELECTED as isize,
    ) as i32;
    app.floating_tasks.get(index as usize).cloned()
}

unsafe fn mutate(
    app: &mut App,
    action: impl FnOnce(&mut TaskRepository) -> woo_todo_core::CoreResult<bool>,
) {
    match action(&mut app.repository) {
        Ok(changed) => {
            if changed {
                app.sync_runtime.request(SyncTrigger::LocalChange);
            }
            refresh_all(app);
        }
        Err(error) => show_error(app.main, "任务操作失败", &error.to_string()),
    }
}

unsafe fn toggle_task_completion(app: &mut App, task: TodoTask) {
    let id = task.id;
    match task.state {
        TaskState::Pending => mutate(app, |repo| repo.complete(&id, now_millis())),
        TaskState::Completed => mutate(app, |repo| {
            repo.reopen_completed(&id, today_shanghai(), now_millis())
        }),
        TaskState::Pass => refresh_all(app),
    }
}

unsafe fn update_main_action_state(app: &App) {
    let selected = selected_main_task(app);
    let pending = selected
        .as_ref()
        .is_some_and(|task| task.state == TaskState::Pending);
    let completed = selected
        .as_ref()
        .is_some_and(|task| task.state == TaskState::Completed);
    set_text(
        app.main_controls.complete,
        if completed { "取消完成" } else { "完成" },
    );
    EnableWindow(app.main_controls.complete, (pending || completed) as i32);
    for control in [
        app.main_controls.edit,
        app.main_controls.pass,
        app.main_controls.delete,
        app.main_controls.up,
        app.main_controls.down,
    ] {
        EnableWindow(control, pending as i32);
    }
}

unsafe fn handle_main_item_changed(app: &mut App, notification: &NMLISTVIEW) {
    if app.populating_main_tasks
        || notification.iItem < 0
        || notification.uChanged & LVIF_STATE == 0
    {
        return;
    }
    let old_check = (notification.uOldState & LVIS_STATEIMAGEMASK) >> 12;
    let new_check = (notification.uNewState & LVIS_STATEIMAGEMASK) >> 12;
    if old_check == new_check || !matches!(new_check, 1 | 2) {
        return;
    }
    let Some(task) = app.visible_tasks.get(notification.iItem as usize).cloned() else {
        return;
    };
    if app.section == Section::History {
        refresh_main(app);
        return;
    }
    let valid_transition = (new_check == 2 && task.state == TaskState::Pending)
        || (new_check == 1 && task.state == TaskState::Completed);
    if valid_transition {
        toggle_task_completion(app, task);
    } else {
        refresh_main(app);
    }
}

unsafe fn handle_float_item_changed(app: &mut App, notification: &NMLISTVIEW) {
    if app.populating_float_tasks
        || notification.iItem < 0
        || notification.uChanged & LVIF_STATE == 0
    {
        return;
    }
    let old_check = (notification.uOldState & LVIS_STATEIMAGEMASK) >> 12;
    let new_check = (notification.uNewState & LVIS_STATEIMAGEMASK) >> 12;
    if old_check == new_check || !matches!(new_check, 1 | 2) {
        return;
    }
    let Some(task) = app.floating_tasks.get(notification.iItem as usize).cloned() else {
        return;
    };
    let valid_transition = (new_check == 2 && task.state == TaskState::Pending)
        || (new_check == 1 && task.state == TaskState::Completed);
    if valid_transition {
        toggle_task_completion(app, task);
    } else {
        refresh_floating(app);
    }
}

unsafe fn create_task(app: &mut App, quick_title: Option<String>) {
    let today = today_shanghai();
    let (default_type, default_date) = match app.section {
        Section::Tomorrow => (
            TimeType::Day,
            today.checked_add_days(Days::new(1)).unwrap_or(today),
        ),
        Section::Week => (TimeType::Week, today),
        Section::Month => (TimeType::Month, today),
        Section::Someday => (TimeType::Someday, today),
        _ => (TimeType::Day, today),
    };
    let input = if let Some(title) = quick_title {
        Some(TaskInput {
            title,
            time_type: TimeType::Day,
            target_date: today,
            quest_line: QuestLine::Main,
            repeats: false,
            reminder_time: None,
            deadline_date: None,
        })
    } else {
        show_task_editor(app.main, app.floating, default_type, default_date, None)
    };
    let Some(input) = input else { return };
    smoke_trace(&format!(
        "create_task title={:?} type={:?} date={}",
        input.title, input.time_type, input.target_date
    ));
    match app.repository.create(
        &input.title,
        input.time_type,
        input.target_date,
        input.quest_line,
        input.repeats,
        input.reminder_time,
        input.deadline_date,
        now_millis(),
    ) {
        Ok(id) => {
            smoke_trace(&format!("create_task success id={id}"));
            app.sync_runtime.request(SyncTrigger::LocalChange);
            refresh_all(app);
        }
        Err(error) => {
            smoke_trace(&format!("create_task error={error}"));
            show_error(app.main, "无法新增任务", &error.to_string());
        }
    }
}

unsafe fn edit_task(app: &mut App, task: TodoTask, owner: HWND) {
    if task.state != TaskState::Pending {
        return;
    }
    let date = task.period_start.unwrap_or_else(today_shanghai);
    let secondary = if owner == app.floating {
        app.main
    } else {
        app.floating
    };
    let Some(input) = show_task_editor(owner, secondary, task.time_type, date, Some(task.clone()))
    else {
        return;
    };
    match app.repository.update(
        &task.id,
        &input.title,
        input.time_type,
        input.target_date,
        input.quest_line,
        input.repeats,
        input.reminder_time,
        input.deadline_date,
        now_millis(),
    ) {
        Ok(changed) => {
            if changed {
                app.sync_runtime.request(SyncTrigger::LocalChange);
            }
            refresh_all(app);
        }
        Err(error) => show_error(app.main, "无法更新任务", &error.to_string()),
    }
}

unsafe fn poll_sync_runtime(app: &mut App) {
    let snapshot = app.sync_runtime.snapshot();
    if snapshot.last_successful_at != app.last_sync_successful_at {
        app.last_sync_successful_at = snapshot.last_successful_at;
        if snapshot.last_successful_at.is_some() {
            if let Ok(Some(display)) = app.repository.display_configuration() {
                let configuration = DisplayConfiguration {
                    header_template: display.header_template,
                    subtitle_template: display.subtitle_template,
                    start_date: display.start_date,
                    deadline_date: display.deadline_date,
                };
                if configuration.validate().is_ok() && configuration != app.settings.display {
                    let previous = app.settings.display.clone();
                    app.settings.display = configuration;
                    if app.settings.save().is_err() {
                        app.settings.display = previous;
                    }
                }
            }
            refresh_all(app);
        }
    }
    if snapshot.last_error != app.last_sync_error {
        app.last_sync_error = snapshot.last_error.clone();
        if let Some(error) = snapshot.last_error {
            show_tray_warning(app, "同步暂未完成", &error);
        }
    }
    if app.section == Section::Sync {
        update_sync_status(app);
    }
}

unsafe fn update_display_preview(app: &App) {
    let mut configuration = app.settings.display.clone();
    configuration.header_template = get_text(app.main_controls.display_header);
    configuration.subtitle_template = get_text(app.main_controls.display_subtitle);
    let (header, subtitle) = configuration.render(today_shanghai());
    let preview = match (header, subtitle) {
        (Some(header), Some(subtitle)) => format!("预览：{header}  ·  {subtitle}"),
        (Some(header), None) => format!("预览：{header}"),
        (None, Some(subtitle)) => format!("预览：{subtitle}"),
        (None, None) => "预览：（标题与副标题均为空）".to_owned(),
    };
    set_text(app.main_controls.display_preview, &preview);
}

unsafe fn save_display_settings(app: &mut App) -> Result<(), String> {
    let previous = app.settings.display.clone();
    let mut configuration = previous.clone();
    configuration.header_template = get_text(app.main_controls.display_header);
    configuration.subtitle_template = get_text(app.main_controls.display_subtitle);
    configuration
        .validate()
        .map_err(|error| format!("显示模板不合法：{error:?}"))?;
    let payload = woo_todo_core::WireDisplayConfigurationPayload::new(
        configuration.header_template.clone(),
        configuration.subtitle_template.clone(),
        configuration.start_date,
        configuration.deadline_date,
    )
    .map_err(|error| format!("显示配置无法同步：{error}"))?;
    app.settings.display = configuration;
    if let Err(error) = app.settings.save() {
        app.settings.display = previous;
        return Err(error);
    }
    if let Err(error) = app.repository.save_display_configuration(&payload) {
        app.settings.display = previous;
        let _ = app.settings.save();
        return Err(format!("无法写入显示配置：{error}"));
    }
    app.sync_runtime.request(SyncTrigger::LocalChange);
    update_display_preview(app);
    refresh_floating(app);
    Ok(())
}

unsafe fn insert_display_counter(app: &App, variable: CounterVariable) -> Result<(), String> {
    let date = get_date(match variable {
        CounterVariable::ElapsedDays | CounterVariable::ElapsedMonthsDays => {
            app.main_controls.display_elapsed_date
        }
        CounterVariable::DeadlineDays | CounterVariable::DeadlineMonthsDays => {
            app.main_controls.display_deadline_date
        }
    })?;
    let token = DisplayConfiguration::counter_token(variable, date);
    let focus = GetFocus();
    let target = if focus == app.main_controls.display_header {
        app.main_controls.display_header
    } else {
        app.main_controls.display_subtitle
    };
    let token = wide(&token);
    SendMessageW(target, EM_REPLACESEL, 1, token.as_ptr() as isize);
    SetFocus(target);
    update_display_preview(app);
    Ok(())
}

unsafe fn populate_shortcut_edits(app: &App, configuration: &ShortcutConfiguration) {
    for (index, command) in ShortcutCommand::ALL.into_iter().enumerate() {
        let text = configuration
            .binding(command)
            .map(format_shortcut_binding)
            .unwrap_or_default();
        set_text(app.main_controls.shortcut_edits[index], &text);
    }
}

fn format_shortcut_binding(binding: &ShortcutBinding) -> String {
    let mut parts = Vec::new();
    if binding.modifiers.contains(ShortcutModifiers::CONTROL) {
        parts.push("Ctrl".to_owned());
    }
    if binding.modifiers.contains(ShortcutModifiers::ALT) {
        parts.push("Alt".to_owned());
    }
    if binding.modifiers.contains(ShortcutModifiers::SHIFT) {
        parts.push("Shift".to_owned());
    }
    if binding.modifiers.contains(ShortcutModifiers::WINDOWS) {
        parts.push("Win".to_owned());
    }
    parts.push(virtual_key_label(binding.virtual_key));
    parts.join("+")
}

fn virtual_key_label(key: u32) -> String {
    match key {
        0x30..=0x39 | 0x41..=0x5a => char::from_u32(key).unwrap_or('?').to_string(),
        0x70..=0x7a => format!("F{}", key - 0x6f),
        0x09 => "Tab".to_owned(),
        0x0d => "Enter".to_owned(),
        0x20 => "Space".to_owned(),
        0x25 => "Left".to_owned(),
        0x26 => "Up".to_owned(),
        0x27 => "Right".to_owned(),
        0x28 => "Down".to_owned(),
        _ => format!("VK-{key:02X}"),
    }
}

fn parse_shortcut_binding(source: &str) -> Result<ShortcutBinding, String> {
    let mut modifiers = ShortcutModifiers::default();
    let mut virtual_key = None;
    for raw in source.split('+') {
        let value = raw.trim().to_ascii_lowercase();
        match value.as_str() {
            "ctrl" | "control" => modifiers |= ShortcutModifiers::CONTROL,
            "alt" => modifiers |= ShortcutModifiers::ALT,
            "shift" => modifiers |= ShortcutModifiers::SHIFT,
            "win" | "windows" => modifiers |= ShortcutModifiers::WINDOWS,
            "" => return Err("快捷键不能包含空按键".to_owned()),
            _ if virtual_key.is_none() => virtual_key = Some(parse_virtual_key(&value)?),
            _ => return Err("每项快捷键只能包含一个普通按键".to_owned()),
        }
    }
    let binding = ShortcutBinding::new(
        modifiers,
        virtual_key.ok_or_else(|| "快捷键缺少普通按键".to_owned())?,
    );
    binding
        .validate()
        .map_err(|error| format!("快捷键不合法：{error:?}"))?;
    Ok(binding)
}

fn parse_virtual_key(value: &str) -> Result<u32, String> {
    if value.len() == 1 {
        let byte = value.as_bytes()[0].to_ascii_uppercase();
        if byte.is_ascii_alphanumeric() {
            return Ok(byte as u32);
        }
    }
    if let Some(number) = value
        .strip_prefix('f')
        .and_then(|value| value.parse::<u32>().ok())
        && (1..=11).contains(&number)
    {
        return Ok(0x6f + number);
    }
    match value {
        "tab" => Ok(0x09),
        "enter" | "return" => Ok(0x0d),
        "space" => Ok(0x20),
        "left" => Ok(0x25),
        "up" => Ok(0x26),
        "right" => Ok(0x27),
        "down" => Ok(0x28),
        _ => Err(format!("无法识别按键 {value:?}")),
    }
}

unsafe fn shortcut_configuration_from_edits(app: &App) -> Result<ShortcutConfiguration, String> {
    let mut configuration = ShortcutConfiguration::default();
    for (index, command) in ShortcutCommand::ALL.into_iter().enumerate() {
        let binding = parse_shortcut_binding(&get_text(app.main_controls.shortcut_edits[index]))?;
        configuration.bindings.insert(command, binding);
    }
    configuration
        .validate()
        .map_err(|error| format!("快捷键存在冲突：{error:?}"))?;
    Ok(configuration)
}

unsafe fn apply_shortcut_edits(app: &mut App) -> Result<(), String> {
    let candidate = shortcut_configuration_from_edits(app)?;
    let previous = app.settings.shortcuts.clone();
    unregister_hotkeys(app);
    if let Err(error) = try_register_hotkeys(app, &candidate) {
        let _ = try_register_hotkeys(app, &previous);
        populate_shortcut_edits(app, &previous);
        return Err(format!("无法注册新快捷键：{error}"));
    }
    app.settings.shortcuts = candidate.clone();
    if let Err(error) = app.settings.save() {
        unregister_hotkeys(app);
        let _ = try_register_hotkeys(app, &previous);
        app.settings.shortcuts = previous.clone();
        populate_shortcut_edits(app, &previous);
        return Err(error);
    }
    populate_shortcut_edits(app, &candidate);
    Ok(())
}

unsafe fn sync_credentials_from_form(app: &App) -> Result<SyncCredentials, String> {
    let mode = selected_sync_mode(app).ok_or_else(|| "请选择同步方式".to_owned())?;
    let vault_id = get_text(app.sync_controls.vault_id).trim().to_owned();
    let device_id = get_text(app.sync_controls.device_id).trim().to_owned();
    let vault_key = get_text(app.sync_controls.vault_key).trim().to_owned();
    let credentials = match mode {
        SyncMode::Worker => SyncCredentials::Worker {
            endpoint: get_text(app.sync_controls.endpoint).trim().to_owned(),
            vault_id,
            device_id,
            device_token: get_text(app.sync_controls.device_token).trim().to_owned(),
            vault_key,
        },
        SyncMode::LocalNetwork => SyncCredentials::LocalNetwork {
            endpoint: get_text(app.sync_controls.endpoint).trim().to_owned(),
            vault_id,
            device_id,
            device_token: get_text(app.sync_controls.device_token).trim().to_owned(),
            vault_key,
        },
        SyncMode::WebDav => SyncCredentials::WebDav {
            username: get_text(app.sync_controls.username).trim().to_owned(),
            app_password: get_text(app.sync_controls.secret),
            vault_id,
            device_id,
            vault_key,
        },
    };
    let saved = app.credential_store.load()?;
    credentials.reuse_empty_secrets(saved.as_ref())
}

fn preflight_sync_credentials(credentials: &SyncCredentials) -> Result<(), String> {
    match credentials.mode() {
        SyncMode::Worker | SyncMode::LocalNetwork => {
            WorkerClient::new(credentials, WinHttpTransport)?.list_devices()?;
        }
        SyncMode::WebDav => {
            WebDavClient::new(credentials, WinHttpTransport)?.ensure_collections()?;
        }
    }
    Ok(())
}

fn local_network_state_path(directory: &std::path::Path, credentials: &SyncCredentials) -> PathBuf {
    directory
        .join("local-sync")
        .join(format!("{}.json", credentials.vault_id()))
}

fn start_local_network_host(
    directory: &std::path::Path,
    credentials: &SyncCredentials,
) -> Result<LocalNetworkHttpServer, String> {
    credentials.validate()?;
    if credentials.mode() != SyncMode::LocalNetwork {
        return Err("只有同一网络同步身份可以启动本机主机".to_owned());
    }
    let store = LocalServerStore::new(
        local_network_state_path(directory, credentials),
        credentials,
    )
    .map_err(|error| error.to_string())?;
    let mut server = LocalNetworkHttpServer::bind_default(Arc::new(Mutex::new(store)))
        .map_err(|error| error.to_string())?;
    let configured_endpoint = credentials
        .endpoint()
        .ok_or_else(|| "局域网同步身份缺少服务地址".to_owned())?
        .trim_end_matches('/');
    if server.endpoint().trim_end_matches('/') != configured_endpoint {
        return Err("局域网地址在启动期间发生变化，请重试".to_owned());
    }
    server.start().map_err(|error| error.to_string())?;
    Ok(server)
}

unsafe fn refresh_local_network_host(app: &mut App) -> Result<(), String> {
    if !app.settings.local_network_host {
        return Ok(());
    }
    let previous = app
        .credential_store
        .load()?
        .ok_or_else(|| "局域网主机同步身份不存在".to_owned())?;
    if previous.mode() != SyncMode::LocalNetwork {
        return Err("当前同步方式不是同一网络同步".to_owned());
    }
    let endpoint =
        preferred_local_endpoint(DEFAULT_LOCAL_SYNC_PORT).map_err(|error| error.to_string())?;
    if app
        .local_network_server
        .as_ref()
        .is_some_and(|server| server.is_running() && server.endpoint() == endpoint)
    {
        return Ok(());
    }
    let updated = previous.with_endpoint(endpoint)?;
    if let Some(mut server) = app.local_network_server.take() {
        let _ = server.stop();
    }
    app.sync_runtime.stop();
    app.credential_store.save(&updated)?;
    match start_local_network_host(&app.data_directory, &updated) {
        Ok(server) => {
            app.local_network_server = Some(server);
            app.sync_runtime =
                SyncRuntime::start(app.database_path.clone(), app.credential_store.clone());
            app.sync_runtime.request(SyncTrigger::NetworkAvailable);
            Ok(())
        }
        Err(error) => {
            let rollback = app.credential_store.save(&previous);
            let restart = start_local_network_host(&app.data_directory, &previous);
            if let Ok(server) = restart {
                app.local_network_server = Some(server);
            }
            app.sync_runtime =
                SyncRuntime::start(app.database_path.clone(), app.credential_store.clone());
            match rollback {
                Ok(()) => Err(error),
                Err(rollback_error) => {
                    Err(format!("{error}；旧局域网身份恢复失败：{rollback_error}"))
                }
            }
        }
    }
}

unsafe fn apply_sync_credentials_with_host(
    app: &mut App,
    credentials: SyncCredentials,
    mut new_local_server: Option<LocalNetworkHttpServer>,
) -> Result<(), String> {
    clear_pairing(app);
    let previous_credentials = app.credential_store.load()?;
    let previous_was_host = app.settings.local_network_host;
    let new_is_host = new_local_server.is_some();

    app.settings.local_network_host = new_is_host;
    if let Err(error) = app.settings.save() {
        app.settings.local_network_host = previous_was_host;
        if let Some(mut server) = new_local_server.take() {
            let _ = server.stop();
        }
        return Err(format!("无法保存局域网主机角色，同步方式未切换：{error}"));
    }

    if let Some(mut server) = app.local_network_server.take() {
        let _ = server.stop();
    }
    app.sync_runtime.stop();
    let result = switch_sync_binding(
        &mut app.repository,
        app.credential_store.as_ref(),
        credentials,
        |_| Ok(()),
    );
    if let Err(error) = result {
        let mut recovery_errors = Vec::new();
        if let Some(mut server) = new_local_server.take() {
            let _ = server.stop();
        }
        app.settings.local_network_host = previous_was_host;
        if let Err(rollback_error) = app.settings.save() {
            recovery_errors.push(format!("旧主机角色恢复失败：{rollback_error}"));
        }
        if previous_was_host && let Some(previous) = previous_credentials.as_ref() {
            match start_local_network_host(&app.data_directory, previous) {
                Ok(server) => app.local_network_server = Some(server),
                Err(restart_error) => {
                    recovery_errors.push(format!("旧局域网主机未能重新启动：{restart_error}"))
                }
            }
        }
        app.sync_runtime =
            SyncRuntime::start(app.database_path.clone(), app.credential_store.clone());
        if app.credential_store.load().ok().flatten().is_some() {
            app.sync_runtime.request(SyncTrigger::Launch);
        }
        return if recovery_errors.is_empty() {
            Err(error)
        } else {
            Err(format!("{error}；{}", recovery_errors.join("；")))
        };
    }
    app.local_network_server = new_local_server;
    app.sync_runtime = SyncRuntime::start(app.database_path.clone(), app.credential_store.clone());
    app.sync_runtime.request(SyncTrigger::Manual);
    set_text(app.sync_controls.output, "同步方式已保存，首次同步已排队。");
    populate_sync_form(app);
    Ok(())
}

unsafe fn setup_selected_sync_mode(app: &mut App) -> Result<(), String> {
    match selected_sync_mode(app).ok_or_else(|| "请选择同步方式".to_owned())? {
        SyncMode::Worker => {
            let endpoint = get_text(app.sync_controls.endpoint).trim().to_owned();
            let invite = get_text(app.sync_controls.invite);
            begin_worker_vault_creation(app, endpoint, invite.trim().to_owned())?;
        }
        SyncMode::LocalNetwork => {
            if app.settings.local_network_host {
                refresh_local_network_host(app)?;
                if let Some(server) = app.local_network_server.as_ref() {
                    set_text(
                        app.sync_controls.output,
                        &format!(
                            "本机局域网主机已在运行：{}。点击“生成配对”让 Android 扫码加入。",
                            server.endpoint()
                        ),
                    );
                    return Ok(());
                }
            }
            let endpoint = preferred_local_endpoint(DEFAULT_LOCAL_SYNC_PORT)
                .map_err(|error| error.to_string())?;
            let credentials = SyncCredentials::LocalNetwork {
                endpoint,
                vault_id: random_sync_identifier("vault")?,
                device_id: random_sync_identifier("device")?,
                device_token: woo_todo_core::base64url_encode(
                    &woo_todo_core::random_bytes::<32>().map_err(|error| error.to_string())?,
                ),
                vault_key: woo_todo_core::base64url_encode(
                    &woo_todo_core::random_bytes::<32>().map_err(|error| error.to_string())?,
                ),
            };
            let state_path = local_network_state_path(&app.data_directory, &credentials);
            let server = start_local_network_host(&app.data_directory, &credentials)?;
            if let Err(error) = apply_sync_credentials_with_host(app, credentials, Some(server)) {
                let _ = fs::remove_file(state_path);
                return Err(error);
            }
            let endpoint = app
                .local_network_server
                .as_ref()
                .map(LocalNetworkHttpServer::endpoint)
                .unwrap_or("未知地址");
            set_text(
                app.sync_controls.output,
                &format!("本机局域网主机已启动：{endpoint}。点击“生成配对”让 Android 扫码加入。"),
            );
        }
        SyncMode::WebDav => {
            let vault_id = random_sync_identifier("vault")?;
            let device_id = random_sync_identifier("device")?;
            let vault_key = woo_todo_core::base64url_encode(
                &woo_todo_core::random_bytes::<32>().map_err(|error| error.to_string())?,
            );
            set_text(app.sync_controls.vault_id, &vault_id);
            set_text(app.sync_controls.device_id, &device_id);
            set_text(app.sync_controls.vault_key, &vault_key);
            set_text(
                app.sync_controls.output,
                "已生成新的坚果云空间参数。填写账号与应用密码后点击“保存并切换”。",
            );
        }
    }
    Ok(())
}

unsafe fn begin_worker_vault_creation(
    app: &mut App,
    endpoint: String,
    invite: String,
) -> Result<(), String> {
    if app.network_job_running {
        return Ok(());
    }
    let device_name = std::env::var("COMPUTERNAME")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty() && value.chars().count() <= 80)
        .unwrap_or_else(|| "Windows PC".to_owned());
    let sender = app.sync_ui_sender.clone();
    app.network_job_running = true;
    set_text(app.sync_controls.invite, "");
    set_text(app.sync_controls.output, "正在后台创建 Worker 同步空间…");
    update_network_controls(app);
    thread::Builder::new()
        .name("woo-todo-worker-create".to_owned())
        .spawn(move || {
            let mut invite = invite;
            let result =
                WorkerClient::create_vault(&endpoint, &invite, &device_name, WinHttpTransport)
                    .map(|created| created.into_credentials());
            invite.zeroize();
            let _ = sender.send(SyncUiEvent::WorkerVaultCreated(result));
        })
        .map_err(|error| {
            app.network_job_running = false;
            format!("无法启动 Worker 创建任务：{error}")
        })?;
    Ok(())
}

unsafe fn begin_sync_preflight(app: &mut App, credentials: SyncCredentials) -> Result<(), String> {
    if app.network_job_running {
        return Ok(());
    }
    credentials.validate()?;
    let sender = app.sync_ui_sender.clone();
    app.network_job_running = true;
    set_text(app.sync_controls.output, "正在后台验证新的同步方式…");
    update_network_controls(app);
    thread::Builder::new()
        .name("woo-todo-sync-preflight".to_owned())
        .spawn(move || {
            let result = preflight_sync_credentials(&credentials).map(|()| credentials);
            let _ = sender.send(SyncUiEvent::SyncPreflighted(result));
        })
        .map_err(|error| {
            app.network_job_running = false;
            format!("无法启动同步验证任务：{error}")
        })?;
    Ok(())
}

fn random_sync_identifier(prefix: &str) -> Result<String, String> {
    let random = woo_todo_core::random_bytes::<12>().map_err(|error| error.to_string())?;
    Ok(format!(
        "{prefix}-{}",
        woo_todo_core::base64url_encode(&random)
    ))
}

fn pairing_deep_link(
    endpoint: &str,
    pairing_id: &str,
    pairing_secret: &str,
    initiator_public_key: &str,
) -> Result<String, String> {
    let mut link =
        url::Url::parse("wootodo://pair").map_err(|_| "无法构造 Woo Todo 配对链接".to_owned())?;
    link.query_pairs_mut()
        .append_pair("endpoint", endpoint)
        .append_pair("pairingId", pairing_id)
        .append_pair("pairingSecret", pairing_secret)
        .append_pair("initiatorPublicKey", initiator_public_key);
    Ok(link.to_string())
}

unsafe fn begin_sync_sharing(app: &mut App) -> Result<(), String> {
    let credentials = app
        .credential_store
        .load()?
        .ok_or_else(|| "请先保存同步方式".to_owned())?;
    if selected_sync_mode(app) != Some(credentials.mode()) {
        return Err("请先在“当前配置”中选择已经保存的同步方式".to_owned());
    }
    if credentials.mode() != SyncMode::WebDav {
        return begin_pairing(app);
    }

    if app.webdav_setup_link.is_some() {
        clear_pairing(app);
        set_text(
            app.sync_controls.output,
            "已隐藏坚果云配置二维码。临时配置链接已清除。",
        );
        update_pairing_controls(app);
        return Ok(());
    }
    clear_pairing(app);
    let link = Zeroizing::new(credentials.webdav_setup_link()?);
    let bitmap = create_qr_bitmap(link.as_str(), 172)?;
    replace_pairing_qr_bitmap(app, bitmap);
    app.webdav_setup_link = Some(link);
    set_text(
        app.sync_controls.output,
        "请用 Android Woo Todo 扫描左侧二维码。二维码包含坚果云应用密码和同步密钥，离开本页或关闭窗口后会立即清除。",
    );
    update_pairing_controls(app);
    Ok(())
}

unsafe fn begin_pairing(app: &mut App) -> Result<(), String> {
    if app
        .pairing
        .as_ref()
        .is_some_and(|context| !context.confirmed)
    {
        clear_pairing(app);
        set_text(app.sync_controls.output, "已取消显示本次配对会话。");
        update_pairing_controls(app);
        return Ok(());
    }
    if app.pairing.is_some() {
        clear_pairing(app);
    }
    if app.pairing_job_running {
        return Ok(());
    }
    let credentials = app
        .credential_store
        .load()?
        .ok_or_else(|| "请先配置 Worker 或同一网络同步".to_owned())?;
    if credentials.mode() == SyncMode::WebDav {
        return Err("坚果云方式使用配置二维码，不使用设备配对会话".to_owned());
    }
    if credentials.mode() == SyncMode::LocalNetwork
        && app.settings.local_network_host
        && app
            .local_network_server
            .as_ref()
            .is_none_or(|server| !server.is_running())
    {
        return Err("局域网主机尚未运行，请先重新开启本机主机".to_owned());
    }

    let sender = app.sync_ui_sender.clone();
    app.pairing_generation = app.pairing_generation.wrapping_add(1);
    let generation = app.pairing_generation;
    app.pairing_job_running = true;
    set_text(app.sync_controls.output, "正在创建 10 分钟配对会话…");
    update_pairing_controls(app);
    thread::Builder::new()
        .name("woo-todo-pairing-create".to_owned())
        .spawn(move || {
            let result = (|| {
                let key_pair =
                    woo_todo_core::PairingKeyPair::generate().map_err(|error| error.to_string())?;
                let public_key = key_pair.public_key_base64url();
                let created = WorkerClient::new(&credentials, WinHttpTransport)?
                    .create_pairing(&public_key)?;
                let link = pairing_deep_link(
                    credentials
                        .endpoint()
                        .ok_or_else(|| "同步身份缺少服务地址".to_owned())?,
                    &created.pairing_id,
                    &created.pairing_secret,
                    &created.initiator_public_key,
                )?;
                Ok((key_pair, created, link))
            })();
            let _ = sender.send(SyncUiEvent::PairingCreated { generation, result });
        })
        .map_err(|error| {
            app.pairing_job_running = false;
            format!("无法启动配对后台任务：{error}")
        })?;
    Ok(())
}

unsafe fn request_pairing_status(app: &mut App) {
    if app.pairing_job_running {
        return;
    }
    let Some(context) = app.pairing.as_ref() else {
        return;
    };
    if context.claim.is_some() || context.confirmed {
        return;
    }
    if now_millis() >= context.expires_at {
        set_text(app.sync_controls.output, "配对二维码已过期，请重新生成。");
        clear_pairing(app);
        update_pairing_controls(app);
        return;
    }
    let pairing_id = context.pairing_id.clone();
    let generation = app.pairing_generation;
    let Ok(Some(credentials)) = app.credential_store.load() else {
        return;
    };
    let sender = app.sync_ui_sender.clone();
    app.pairing_job_running = true;
    let thread_pairing_id = pairing_id.clone();
    if thread::Builder::new()
        .name("woo-todo-pairing-poll".to_owned())
        .spawn(move || {
            let result = WorkerClient::new(&credentials, WinHttpTransport)
                .and_then(|client| client.pairing_status(&thread_pairing_id));
            let _ = sender.send(SyncUiEvent::PairingStatus {
                generation,
                pairing_id,
                result,
            });
        })
        .is_err()
    {
        app.pairing_job_running = false;
        app.pairing_next_poll_at = now_millis() + 2_000;
    }
}

unsafe fn confirm_pairing(app: &mut App) -> Result<(), String> {
    if app.pairing_job_running {
        return Ok(());
    }
    let context = app
        .pairing
        .as_ref()
        .ok_or_else(|| "当前没有待确认的配对会话".to_owned())?;
    let claim = context
        .claim
        .as_ref()
        .ok_or_else(|| "尚无设备认领当前配对会话".to_owned())?;
    let session_key = context
        .session_key
        .as_ref()
        .ok_or_else(|| "配对 session key 已不可用".to_owned())?;
    let credentials = app
        .credential_store
        .load()?
        .ok_or_else(|| "同步身份已不可用".to_owned())?;
    let vault_key = woo_todo_core::base64url_decode(credentials.vault_key())
        .map_err(|error| format!("同步密钥无效：{error}"))?;
    let envelope = woo_todo_core::seal_pairing_vault_key(
        &vault_key,
        session_key,
        &context.pairing_id,
        &claim.device_id,
        None,
    )
    .map_err(|error| error.to_string())?;
    let pairing_id = context.pairing_id.clone();
    let generation = app.pairing_generation;
    let claimed_device_id = claim.device_id.clone();
    let sender = app.sync_ui_sender.clone();
    app.pairing_job_running = true;
    set_text(app.sync_controls.output, "正在加密传递同步密钥…");
    update_pairing_controls(app);
    let thread_pairing_id = pairing_id.clone();
    thread::Builder::new()
        .name("woo-todo-pairing-confirm".to_owned())
        .spawn(move || {
            let result = WorkerClient::new(&credentials, WinHttpTransport).and_then(|client| {
                client.confirm_pairing(&thread_pairing_id, &claimed_device_id, envelope)
            });
            let _ = sender.send(SyncUiEvent::PairingConfirmed {
                generation,
                pairing_id,
                result,
            });
        })
        .map_err(|error| {
            app.pairing_job_running = false;
            format!("无法启动配对确认任务：{error}")
        })?;
    Ok(())
}

unsafe fn poll_sync_ui_events(app: &mut App) {
    while let Ok(event) = app.sync_ui_receiver.try_recv() {
        match event {
            SyncUiEvent::PairingCreated { generation, result } => {
                if generation != app.pairing_generation {
                    continue;
                }
                app.pairing_job_running = false;
                match result {
                    Ok((key_pair, created, link)) => {
                        match create_qr_bitmap(&link, 172) {
                            Ok(bitmap) => replace_pairing_qr_bitmap(app, bitmap),
                            Err(error) => {
                                set_text(app.sync_controls.output, &error);
                                clear_pairing(app);
                                continue;
                            }
                        }
                        app.pairing = Some(PairingContext {
                            key_pair: Some(key_pair),
                            pairing_id: created.pairing_id,
                            pairing_secret: Some(created.pairing_secret),
                            expires_at: created.expires_at,
                            claim: None,
                            session_key: None,
                            deep_link: Some(link),
                            verification_code: None,
                            confirmed: false,
                        });
                        app.pairing_next_poll_at = now_millis();
                        set_text(
                            app.sync_controls.output,
                            "请用 Android Woo Todo 扫描左侧二维码。两端随后会显示相同的六位核对码。",
                        );
                    }
                    Err(error) => set_text(
                        app.sync_controls.output,
                        &format!("创建配对会话失败：{error}"),
                    ),
                }
            }
            SyncUiEvent::PairingStatus {
                generation,
                pairing_id,
                result,
            } => {
                if generation != app.pairing_generation {
                    continue;
                }
                app.pairing_job_running = false;
                if app
                    .pairing
                    .as_ref()
                    .is_none_or(|context| context.pairing_id != pairing_id)
                {
                    continue;
                }
                match result {
                    Ok(state) if state.status == PairingStatus::Open => {
                        app.pairing_next_poll_at = now_millis() + 2_000;
                    }
                    Ok(state) if state.status == PairingStatus::Claimed => {
                        if let Some(claim) = state.claim
                            && let Err(error) = accept_pairing_claim(app, claim)
                        {
                            set_text(
                                app.sync_controls.output,
                                &format!("无法校验配对认领：{error}"),
                            );
                            clear_pairing(app);
                        }
                    }
                    Ok(state)
                        if matches!(
                            state.status,
                            PairingStatus::Expired | PairingStatus::Canceled
                        ) =>
                    {
                        set_text(app.sync_controls.output, "配对会话已失效，请重新生成。");
                        clear_pairing(app);
                    }
                    Ok(_) => {
                        set_text(app.sync_controls.output, "配对服务返回了不一致的状态。");
                        clear_pairing(app);
                    }
                    Err(error) => {
                        set_text(
                            app.sync_controls.output,
                            &format!("暂时无法检查配对状态，将自动重试：{error}"),
                        );
                        app.pairing_next_poll_at = now_millis() + 2_000;
                    }
                }
            }
            SyncUiEvent::PairingConfirmed {
                generation,
                pairing_id,
                result,
            } => {
                if generation != app.pairing_generation {
                    continue;
                }
                app.pairing_job_running = false;
                let Some(context) = app.pairing.as_mut() else {
                    continue;
                };
                if context.pairing_id != pairing_id {
                    continue;
                }
                match result {
                    Ok(()) => {
                        context.session_key = None;
                        context.confirmed = true;
                        set_text(
                            app.sync_controls.output,
                            "设备绑定成功。Android 将保存身份并自动执行首次同步。",
                        );
                        app.sync_runtime.request(SyncTrigger::Manual);
                    }
                    Err(error) => set_text(
                        app.sync_controls.output,
                        &format!("确认配对失败，可以重试：{error}"),
                    ),
                }
            }
            SyncUiEvent::BackupExported { path, result } => {
                app.backup_job_running = false;
                update_backup_controls(app);
                match result {
                    Ok(()) => {
                        set_text(
                            app.sync_controls.output,
                            &format!("加密备份已导出：{}", path.display()),
                        );
                        show_message(
                            app.main,
                            "备份已导出",
                            "任务已写入加密 .wootodo 文件。请把备份口令与文件分开保管。",
                            MB_OK | MB_ICONINFORMATION,
                        );
                    }
                    Err(error) => show_error(app.main, "无法导出备份", &error),
                }
            }
            SyncUiEvent::BackupOpened { path, result } => {
                app.backup_job_running = false;
                update_backup_controls(app);
                match result {
                    Ok(snapshot) => {
                        if let Err(error) = apply_backup_snapshot(app, snapshot, &path) {
                            show_error(app.main, "无法恢复备份", &error);
                        }
                    }
                    Err(error) => show_error(app.main, "无法恢复备份", &error),
                }
            }
            SyncUiEvent::WorkerVaultCreated(result) => {
                app.network_job_running = false;
                update_network_controls(app);
                match result {
                    Ok(credentials) => {
                        if let Err(error) = apply_sync_credentials_with_host(app, credentials, None)
                        {
                            show_error(app.main, "无法保存 Worker 同步空间", &error);
                        } else {
                            set_text(
                                app.sync_controls.output,
                                "Worker 同步空间已创建并保存；邀请码没有写入本机。",
                            );
                        }
                    }
                    Err(error) => show_error(app.main, "无法创建 Worker 同步空间", &error),
                }
            }
            SyncUiEvent::SyncPreflighted(result) => {
                app.network_job_running = false;
                update_network_controls(app);
                match result {
                    Ok(credentials) => {
                        if let Err(error) = apply_sync_credentials_with_host(app, credentials, None)
                        {
                            show_error(app.main, "无法切换同步方式", &error);
                        }
                    }
                    Err(error) => show_error(app.main, "同步方式验证失败", &error),
                }
            }
            SyncUiEvent::DevicesLoaded(result) => {
                app.network_job_running = false;
                update_network_controls(app);
                match result {
                    Ok(output) => set_text(app.sync_controls.output, &output),
                    Err(error) => show_error(app.main, "无法读取设备列表", &error),
                }
            }
            SyncUiEvent::DeviceRevoked(result) => {
                app.network_job_running = false;
                update_network_controls(app);
                match result {
                    Ok(device_id) => {
                        set_text(
                            app.sync_controls.output,
                            &format!("设备已撤销：{device_id}。正在刷新设备列表…"),
                        );
                        if let Err(error) = refresh_sync_devices(app) {
                            show_error(app.main, "无法刷新设备列表", &error);
                        }
                    }
                    Err(error) => show_error(app.main, "无法撤销设备", &error),
                }
            }
        }
        update_pairing_controls(app);
    }
    if app.pairing.is_some() && !app.pairing_job_running && now_millis() >= app.pairing_next_poll_at
    {
        request_pairing_status(app);
    }
}

unsafe fn accept_pairing_claim(app: &mut App, claim: PairingClaimInfo) -> Result<(), String> {
    let context = app
        .pairing
        .as_mut()
        .ok_or_else(|| "配对会话已结束".to_owned())?;
    let key_pair = context
        .key_pair
        .take()
        .ok_or_else(|| "配对临时私钥已不可用".to_owned())?;
    let pairing_secret = context
        .pairing_secret
        .take()
        .ok_or_else(|| "配对 secret 已不可用".to_owned())?;
    let session_key = key_pair
        .session_key_base64url(&claim.public_key, &context.pairing_id, &pairing_secret)
        .map_err(|error| error.to_string())?;
    let claim_public_key =
        woo_todo_core::base64url_decode(&claim.public_key).map_err(|error| error.to_string())?;
    let code = woo_todo_core::pairing_verification_code(
        &session_key,
        key_pair.public_key(),
        &claim_public_key,
    )
    .map_err(|error| error.to_string())?;
    context.session_key = Some(session_key);
    context.verification_code = Some(code.clone());
    context.claim = Some(claim.clone());
    context.deep_link = None;
    replace_pairing_qr_bitmap(app, null_mut());
    set_text(
        app.sync_controls.output,
        &format!(
            "{} 已扫描。请确认 Android 显示相同核对码：{}；一致后点击“核对一致”。",
            claim.name, code
        ),
    );
    Ok(())
}

unsafe fn clear_pairing(app: &mut App) {
    app.pairing_generation = app.pairing_generation.wrapping_add(1);
    app.pairing = None;
    app.pairing_job_running = false;
    app.pairing_next_poll_at = 0;
    if let Some(mut link) = app.webdav_setup_link.take() {
        link.zeroize();
    }
    replace_pairing_qr_bitmap(app, null_mut());
}

fn visible_sync_share_link(app: &App) -> Option<&str> {
    app.pairing
        .as_ref()
        .and_then(|context| context.deep_link.as_deref())
        .or_else(|| app.webdav_setup_link.as_ref().map(|link| link.as_str()))
}

unsafe fn replace_pairing_qr_bitmap(app: &mut App, bitmap: HBITMAP) {
    if !app.sync_controls.pair_qr.is_null() {
        SendMessageW(
            app.sync_controls.pair_qr,
            STM_SETIMAGE,
            IMAGE_BITMAP as usize,
            bitmap as isize,
        );
    }
    if !app.pairing_qr_bitmap.is_null() {
        DeleteObject(app.pairing_qr_bitmap);
    }
    app.pairing_qr_bitmap = bitmap;
}

unsafe fn create_qr_bitmap(payload: &str, size: i32) -> Result<HBITMAP, String> {
    let code = QrCode::new(payload.as_bytes())
        .map_err(|_| "同步配置链接过长，无法生成二维码".to_owned())?;
    let modules = i32::try_from(code.width()).map_err(|_| "二维码尺寸无效".to_owned())?;
    let quiet = 4;
    let scale = size / (modules + quiet * 2);
    if scale < 1 {
        return Err("配对链接生成的二维码超过显示上限".to_owned());
    }
    let mut bits: *mut c_void = null_mut();
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: size,
            biHeight: -size,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            biSizeImage: (size * size * 4) as u32,
            ..Default::default()
        },
        ..Default::default()
    };
    let bitmap = CreateDIBSection(null_mut(), &info, DIB_RGB_COLORS, &mut bits, null_mut(), 0);
    if bitmap.is_null() || bits.is_null() {
        return Err(last_error("无法创建配对二维码位图"));
    }
    let pixels = std::slice::from_raw_parts_mut(bits as *mut u32, (size * size) as usize);
    pixels.fill(0x00ff_ffff);
    let rendered = (modules + quiet * 2) * scale;
    let offset = (size - rendered) / 2 + quiet * scale;
    for y in 0..modules {
        for x in 0..modules {
            if code[(x as usize, y as usize)] != Color::Dark {
                continue;
            }
            let left = offset + x * scale;
            let top = offset + y * scale;
            for row in top..top + scale {
                let start = (row * size + left) as usize;
                pixels[start..start + scale as usize].fill(0x0000_0000);
            }
        }
    }
    Ok(bitmap)
}

unsafe fn refresh_sync_devices(app: &mut App) -> Result<(), String> {
    if app.network_job_running {
        return Ok(());
    }
    let credentials = app
        .credential_store
        .load()?
        .ok_or_else(|| "尚未配置同步".to_owned())?;
    if credentials.mode() == SyncMode::WebDav {
        return Err("坚果云方式没有设备目录；每台设备使用独立 device ID".to_owned());
    }
    let sender = app.sync_ui_sender.clone();
    app.network_job_running = true;
    set_text(app.sync_controls.output, "正在后台读取设备列表…");
    update_network_controls(app);
    thread::Builder::new()
        .name("woo-todo-device-list".to_owned())
        .spawn(move || {
            let result = WorkerClient::new(&credentials, WinHttpTransport)
                .and_then(|client| client.list_devices())
                .map(format_device_list);
            let _ = sender.send(SyncUiEvent::DevicesLoaded(result));
        })
        .map_err(|error| {
            app.network_job_running = false;
            format!("无法启动设备列表任务：{error}")
        })?;
    Ok(())
}

fn format_device_list(devices: Vec<crate::worker::DeviceInfo>) -> String {
    let mut output = String::new();
    for device in devices {
        let platform = match device.platform {
            crate::worker::DevicePlatform::Macos => "macOS",
            crate::worker::DevicePlatform::Android => "Android",
            crate::worker::DevicePlatform::Windows => "Windows",
        };
        let state = if device.revoked_at.is_some() {
            "已撤销"
        } else if device.is_current {
            "当前设备"
        } else {
            "可同步"
        };
        output.push_str(&format!(
            "{}  ·  {}  ·  {}  ·  {}\r\n",
            device.name, platform, state, device.id
        ));
    }
    if output.is_empty() {
        output.push_str("同步空间没有设备记录");
    }
    output.trim_end().to_owned()
}

unsafe fn revoke_sync_device(app: &mut App) -> Result<(), String> {
    if app.network_job_running {
        return Ok(());
    }
    let credentials = app
        .credential_store
        .load()?
        .ok_or_else(|| "尚未配置同步".to_owned())?;
    if credentials.mode() == SyncMode::WebDav {
        return Err("坚果云设备应通过撤销对应应用密码来断开".to_owned());
    }
    let device_id = get_text(app.sync_controls.revoke_device).trim().to_owned();
    if device_id == credentials.device_id() {
        return Err("不能在当前设备上撤销自身".to_owned());
    }
    if show_message(
        app.main,
        "确认撤销设备",
        &format!("撤销后该设备不能继续同步：\r\n{device_id}"),
        MB_YESNO | MB_ICONWARNING,
    ) != IDYES
    {
        return Ok(());
    }
    let sender = app.sync_ui_sender.clone();
    app.network_job_running = true;
    set_text(app.sync_controls.revoke_device, "");
    set_text(app.sync_controls.output, "正在后台撤销设备…");
    update_network_controls(app);
    thread::Builder::new()
        .name("woo-todo-device-revoke".to_owned())
        .spawn(move || {
            let result = WorkerClient::new(&credentials, WinHttpTransport)
                .and_then(|client| client.revoke_device(&device_id))
                .map(|_| device_id);
            let _ = sender.send(SyncUiEvent::DeviceRevoked(result));
        })
        .map_err(|error| {
            app.network_job_running = false;
            format!("无法启动设备撤销任务：{error}")
        })?;
    Ok(())
}

unsafe fn export_encrypted_backup(app: &mut App) -> Result<(), String> {
    if app.backup_job_running {
        return Ok(());
    }
    let passphrase = confirmed_backup_passphrase(app)?;
    let include_identity =
        SendMessageW(app.sync_controls.backup_include_identity, BM_GETCHECK, 0, 0)
            == BST_CHECKED as isize;
    let sync_credentials = if include_identity {
        let credentials = app
            .credential_store
            .load()?
            .ok_or_else(|| "当前没有可写入备份的同步身份".to_owned())?;
        match credentials {
            SyncCredentials::Worker {
                endpoint,
                vault_id,
                device_id,
                device_token,
                vault_key,
            } => Some(woo_todo_core::BackupSyncCredentials {
                endpoint,
                vault_id,
                device_id,
                device_token,
                vault_key,
            }),
            SyncCredentials::LocalNetwork {
                endpoint,
                vault_id,
                device_id,
                device_token,
                vault_key,
            } if app.settings.local_network_host => Some(woo_todo_core::BackupSyncCredentials {
                endpoint,
                vault_id,
                device_id,
                device_token,
                vault_key,
            }),
            SyncCredentials::LocalNetwork { .. } => {
                return Err(
                    "局域网客户端身份不能作为主机备份；请在承载局域网服务的设备导出".to_owned(),
                );
            }
            SyncCredentials::WebDav { .. } => {
                return Err("坚果云账号和应用密码不会写入备份，请取消勾选同步身份".to_owned());
            }
        }
    } else {
        None
    };
    let Some(path) = choose_backup_file(app.main, true)? else {
        return Ok(());
    };
    let snapshot = app
        .repository
        .make_backup_snapshot(now_millis(), sync_credentials)
        .map_err(|error| format!("无法生成备份快照：{error}"))?;
    let sender = app.sync_ui_sender.clone();
    let thread_path = path.clone();
    app.backup_job_running = true;
    clear_backup_passphrases(app);
    set_text(app.sync_controls.output, "正在后台加密并写入备份…");
    update_backup_controls(app);
    thread::Builder::new()
        .name("woo-todo-backup-export".to_owned())
        .spawn(move || {
            let mut passphrase = passphrase;
            let result = woo_todo_core::seal_backup(
                &snapshot,
                &passphrase,
                woo_todo_core::BackupSealOptions::default(),
            )
            .map_err(|error| format!("无法生成加密备份：{error}"))
            .and_then(|data| write_backup_atomically(&thread_path, &data));
            passphrase.zeroize();
            let _ = sender.send(SyncUiEvent::BackupExported { path, result });
        })
        .map_err(|error| {
            app.backup_job_running = false;
            format!("无法启动备份后台任务：{error}")
        })?;
    Ok(())
}

unsafe fn import_encrypted_backup(app: &mut App) -> Result<(), String> {
    if app.backup_job_running {
        return Ok(());
    }
    let passphrase = confirmed_backup_passphrase(app)?;
    if app.credential_store.load()?.is_some() {
        return Err("当前安装已有同步身份；加密备份只能恢复到全新空白安装".to_owned());
    }
    let Some(path) = choose_backup_file(app.main, false)? else {
        return Ok(());
    };
    let sender = app.sync_ui_sender.clone();
    let thread_path = path.clone();
    app.backup_job_running = true;
    clear_backup_passphrases(app);
    set_text(app.sync_controls.output, "正在后台读取并解密备份…");
    update_backup_controls(app);
    thread::Builder::new()
        .name("woo-todo-backup-import".to_owned())
        .spawn(move || {
            let mut passphrase = passphrase;
            let result = (|| {
                let metadata = fs::metadata(&thread_path)
                    .map_err(|error| format!("无法读取备份文件：{error}"))?;
                if metadata.len() > woo_todo_core::BACKUP_MAXIMUM_FILE_BYTES as u64 {
                    return Err("备份文件超过安全大小限制".to_owned());
                }
                let data =
                    fs::read(&thread_path).map_err(|error| format!("无法读取备份文件：{error}"))?;
                woo_todo_core::open_backup(&data, &passphrase)
                    .map_err(|error| format!("无法解密备份：{error}"))
            })();
            passphrase.zeroize();
            let _ = sender.send(SyncUiEvent::BackupOpened { path, result });
        })
        .map_err(|error| {
            app.backup_job_running = false;
            format!("无法启动备份恢复任务：{error}")
        })?;
    Ok(())
}

unsafe fn apply_backup_snapshot(
    app: &mut App,
    snapshot: woo_todo_core::BackupSnapshot,
    path: &std::path::Path,
) -> Result<(), String> {
    let mut restored_credentials = snapshot
        .sync_credentials
        .as_ref()
        .map(sync_credentials_from_backup)
        .transpose()?;
    if restored_credentials
        .as_ref()
        .is_some_and(|credentials| credentials.mode() == SyncMode::LocalNetwork)
    {
        let endpoint =
            preferred_local_endpoint(DEFAULT_LOCAL_SYNC_PORT).map_err(|error| error.to_string())?;
        restored_credentials = restored_credentials
            .as_ref()
            .map(|credentials| credentials.with_endpoint(endpoint))
            .transpose()?;
    }
    let configuration = snapshot
        .sync_credentials
        .as_ref()
        .map(|credentials| {
            let key = credentials
                .decoded_vault_key()
                .map_err(|error| error.to_string())?;
            woo_todo_core::SyncConfiguration::new(
                credentials.vault_id.clone(),
                credentials.device_id.clone(),
                &key,
            )
            .map_err(|error| error.to_string())
        })
        .transpose()?;

    let local_state_path = restored_credentials
        .as_ref()
        .filter(|credentials| credentials.mode() == SyncMode::LocalNetwork)
        .map(|credentials| local_network_state_path(&app.data_directory, credentials));
    let local_state_existed = local_state_path.as_ref().is_some_and(|path| path.exists());
    let mut restored_local_server = restored_credentials
        .as_ref()
        .filter(|credentials| credentials.mode() == SyncMode::LocalNetwork)
        .map(|credentials| start_local_network_host(&app.data_directory, credentials))
        .transpose()?;

    app.sync_runtime.stop();
    let wrote_credentials = if let Some(credentials) = restored_credentials.as_ref() {
        if let Err(error) = app.credential_store.save(credentials) {
            if let Some(mut server) = restored_local_server.take() {
                let _ = server.stop();
            }
            if !local_state_existed && let Some(path) = local_state_path.as_ref() {
                let _ = fs::remove_file(path);
            }
            app.sync_runtime =
                SyncRuntime::start(app.database_path.clone(), app.credential_store.clone());
            return Err(error);
        }
        true
    } else {
        false
    };
    let restore_result = app
        .repository
        .restore_backup_snapshot_and_configure(&snapshot, configuration)
        .map_err(|error| format!("无法恢复备份：{error}"));
    if let Err(error) = restore_result {
        if let Some(mut server) = restored_local_server.take() {
            let _ = server.stop();
        }
        if !local_state_existed && let Some(path) = local_state_path.as_ref() {
            let _ = fs::remove_file(path);
        }
        if wrote_credentials && let Err(rollback_error) = app.credential_store.delete() {
            app.sync_runtime =
                SyncRuntime::start(app.database_path.clone(), app.credential_store.clone());
            return Err(format!(
                "{error}；Windows 安全凭据回滚也失败：{rollback_error}"
            ));
        }
        app.sync_runtime =
            SyncRuntime::start(app.database_path.clone(), app.credential_store.clone());
        return Err(error);
    }
    app.local_network_server = restored_local_server;
    app.settings.local_network_host = app.local_network_server.is_some();
    let settings_warning = app
        .settings
        .save()
        .err()
        .map(|error| format!("局域网主机角色未能持久化：{error}"));
    app.sync_runtime = SyncRuntime::start(app.database_path.clone(), app.credential_store.clone());
    if wrote_credentials {
        app.sync_runtime.request(SyncTrigger::Launch);
    }
    refresh_all(app);
    let status = if let Some(warning) = settings_warning.as_deref() {
        format!("加密备份已恢复：{}；{warning}", path.display())
    } else {
        format!("加密备份已恢复：{}", path.display())
    };
    set_text(app.sync_controls.output, &status);
    let completion_message = settings_warning
        .as_deref()
        .map(|warning| {
            format!("任务和同步身份已经恢复，但 {warning}。下次启动前请检查设置目录是否可写。")
        })
        .unwrap_or_else(|| {
            "任务已经恢复。若备份携带 Worker 或局域网身份，首次同步也已排队。".to_owned()
        });
    show_message(
        app.main,
        "恢复完成",
        &completion_message,
        MB_OK | MB_ICONINFORMATION,
    );
    Ok(())
}

unsafe fn update_backup_controls(app: &App) {
    EnableWindow(
        app.sync_controls.backup_export,
        (!app.backup_job_running) as i32,
    );
    EnableWindow(
        app.sync_controls.backup_import,
        (!app.backup_job_running) as i32,
    );
}

unsafe fn update_network_controls(app: &App) {
    for control in [
        app.sync_controls.setup,
        app.sync_controls.save,
        app.sync_controls.devices,
        app.sync_controls.revoke,
    ] {
        EnableWindow(control, (!app.network_job_running) as i32);
    }
}

unsafe fn confirmed_backup_passphrase(app: &App) -> Result<String, String> {
    let passphrase = get_text(app.sync_controls.backup_passphrase);
    let confirmation = get_text(app.sync_controls.backup_confirmation);
    if passphrase != confirmation {
        return Err("两次输入的备份口令不一致".to_owned());
    }
    woo_todo_core::normalize_backup_passphrase(&passphrase).map_err(|error| error.to_string())
}

unsafe fn clear_backup_passphrases(app: &App) {
    set_text(app.sync_controls.backup_passphrase, "");
    set_text(app.sync_controls.backup_confirmation, "");
}

unsafe fn clear_sensitive_sync_fields(app: &App) {
    for control in [
        app.sync_controls.invite,
        app.sync_controls.secret,
        app.sync_controls.device_token,
        app.sync_controls.vault_key,
        app.sync_controls.backup_passphrase,
        app.sync_controls.backup_confirmation,
    ] {
        set_text(control, "");
    }
}

unsafe fn copy_to_clipboard(owner: HWND, value: &str) -> Result<(), String> {
    let encoded = wide(value);
    let bytes = encoded
        .len()
        .checked_mul(size_of::<u16>())
        .ok_or_else(|| "剪贴板文本过长".to_owned())?;
    let memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if memory.is_null() {
        return Err(last_error("无法分配剪贴板内存"));
    }
    let destination = GlobalLock(memory) as *mut u16;
    if destination.is_null() {
        GlobalFree(memory);
        return Err(last_error("无法锁定剪贴板内存"));
    }
    std::ptr::copy_nonoverlapping(encoded.as_ptr(), destination, encoded.len());
    GlobalUnlock(memory);

    if OpenClipboard(owner) == 0 {
        GlobalFree(memory);
        return Err(last_error("无法打开剪贴板"));
    }
    if EmptyClipboard() == 0 || SetClipboardData(CLIPBOARD_UNICODE_TEXT, memory).is_null() {
        let error = last_error("无法写入剪贴板");
        CloseClipboard();
        GlobalFree(memory);
        return Err(error);
    }
    CloseClipboard();
    Ok(())
}

fn sync_credentials_from_backup(
    credentials: &woo_todo_core::BackupSyncCredentials,
) -> Result<SyncCredentials, String> {
    let value = if credentials.endpoint.starts_with("https://") {
        SyncCredentials::Worker {
            endpoint: credentials.endpoint.clone(),
            vault_id: credentials.vault_id.clone(),
            device_id: credentials.device_id.clone(),
            device_token: credentials.device_token.clone(),
            vault_key: credentials.vault_key.clone(),
        }
    } else if credentials.endpoint.starts_with("http://") {
        SyncCredentials::LocalNetwork {
            endpoint: credentials.endpoint.clone(),
            vault_id: credentials.vault_id.clone(),
            device_id: credentials.device_id.clone(),
            device_token: credentials.device_token.clone(),
            vault_key: credentials.vault_key.clone(),
        }
    } else {
        return Err("备份中的同步服务地址无效".to_owned());
    };
    value.validate()?;
    Ok(value)
}

unsafe fn choose_backup_file(owner: HWND, save: bool) -> Result<Option<PathBuf>, String> {
    let mut file = vec![0_u16; 32_768];
    if save {
        let name = format!("Woo-Todo-backup-{}.wootodo", today_shanghai());
        let encoded = name.encode_utf16().collect::<Vec<_>>();
        file[..encoded.len()].copy_from_slice(&encoded);
    }
    let filter = wide("Woo Todo 备份 (*.wootodo)\0*.wootodo\0所有文件 (*.*)\0*.*\0");
    let title = wide(if save {
        "导出加密备份"
    } else {
        "恢复加密备份"
    });
    let extension = wide("wootodo");
    let mut dialog = OPENFILENAMEW {
        lStructSize: size_of::<OPENFILENAMEW>() as u32,
        hwndOwner: owner,
        lpstrFilter: filter.as_ptr(),
        nFilterIndex: 1,
        lpstrFile: file.as_mut_ptr(),
        nMaxFile: file.len() as u32,
        lpstrTitle: title.as_ptr(),
        Flags: OFN_EXPLORER
            | OFN_NOCHANGEDIR
            | OFN_PATHMUSTEXIST
            | if save {
                OFN_OVERWRITEPROMPT
            } else {
                OFN_FILEMUSTEXIST
            },
        lpstrDefExt: extension.as_ptr(),
        ..Default::default()
    };
    let accepted = if save {
        GetSaveFileNameW(&mut dialog)
    } else {
        GetOpenFileNameW(&mut dialog)
    };
    if accepted == 0 {
        let error = CommDlgExtendedError();
        return if error == 0 {
            Ok(None)
        } else {
            Err(format!("Windows 文件选择器失败（错误 {error}）"))
        };
    }
    let length = file
        .iter()
        .position(|value| *value == 0)
        .unwrap_or(file.len());
    Ok(Some(PathBuf::from(String::from_utf16_lossy(
        &file[..length],
    ))))
}

fn write_backup_atomically(path: &std::path::Path, data: &[u8]) -> Result<(), String> {
    let suffix = woo_todo_core::base64url_encode(
        &woo_todo_core::random_bytes::<9>().map_err(|error| error.to_string())?,
    );
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("backup.wootodo");
    let staging = path.with_file_name(format!(".{name}.{suffix}.tmp"));
    let previous = path.with_file_name(format!(".{name}.{suffix}.previous"));
    fs::write(&staging, data).map_err(|error| format!("无法写入临时备份：{error}"))?;
    let had_previous = path.exists();
    if had_previous && let Err(error) = fs::rename(path, &previous) {
        let _ = fs::remove_file(&staging);
        return Err(format!("无法准备替换旧备份：{error}"));
    }
    if let Err(error) = fs::rename(&staging, path) {
        if had_previous {
            let _ = fs::rename(&previous, path);
        }
        let _ = fs::remove_file(&staging);
        return Err(format!("无法保存备份：{error}"));
    }
    if had_previous {
        let _ = fs::remove_file(previous);
    }
    Ok(())
}

unsafe fn handle_main_command(app: &mut App, id: i32, notification: u16) {
    match id {
        ID_NAV if notification == LBN_SELCHANGE as u16 => {
            let index = SendMessageW(app.main_controls.nav, LB_GETCURSEL, 0, 0) as i32;
            let next = Section::from_index(index);
            if app.section == Section::Sync && next != Section::Sync {
                clear_pairing(app);
                clear_sensitive_sync_fields(app);
            }
            app.section = next;
            refresh_main(app);
        }
        ID_ADD => create_task(app, None),
        ID_EDIT => {
            if let Some(task) = selected_main_task(app) {
                edit_task(app, task, app.main);
            }
        }
        ID_COMPLETE => {
            if let Some(task) = selected_main_task(app) {
                toggle_task_completion(app, task);
            }
        }
        ID_PASS => {
            if let Some(task) = selected_main_task(app) {
                let id = task.id;
                mutate(app, |repo| repo.pass(&id, now_millis()));
            }
        }
        ID_DELETE => {
            if let Some(task) = selected_main_task(app) {
                let id = task.id;
                mutate(app, |repo| repo.delete(&id, now_millis()));
            }
        }
        ID_UP => {
            if let Some(task) = selected_main_task(app) {
                let id = task.id;
                mutate(app, |repo| repo.move_task(&id, -1, now_millis()));
            }
        }
        ID_DOWN => {
            if let Some(task) = selected_main_task(app) {
                let id = task.id;
                mutate(app, |repo| repo.move_task(&id, 1, now_millis()));
            }
        }
        ID_REFRESH => refresh_all(app),
        ID_DISPLAY_HEADER | ID_DISPLAY_SUBTITLE if notification == EN_CHANGE as u16 => {
            update_display_preview(app);
        }
        ID_DISPLAY_INSERT_ELAPSED_DAYS => {
            if let Err(error) = insert_display_counter(app, CounterVariable::ElapsedDays) {
                show_error(app.main, "无法插入变量", &error);
            }
        }
        ID_DISPLAY_INSERT_DEADLINE_DAYS => {
            if let Err(error) = insert_display_counter(app, CounterVariable::DeadlineDays) {
                show_error(app.main, "无法插入变量", &error);
            }
        }
        ID_DISPLAY_INSERT_ELAPSED_MONTHS => {
            if let Err(error) = insert_display_counter(app, CounterVariable::ElapsedMonthsDays) {
                show_error(app.main, "无法插入变量", &error);
            }
        }
        ID_DISPLAY_INSERT_DEADLINE_MONTHS => {
            if let Err(error) = insert_display_counter(app, CounterVariable::DeadlineMonthsDays) {
                show_error(app.main, "无法插入变量", &error);
            }
        }
        ID_DISPLAY_SAVE => {
            if let Err(error) = save_display_settings(app) {
                show_error(app.main, "无法保存显示设置", &error);
            }
        }
        ID_DISPLAY_RESET => {
            let defaults = DisplayConfiguration::default();
            set_text(app.main_controls.display_header, &defaults.header_template);
            set_text(
                app.main_controls.display_subtitle,
                &defaults.subtitle_template,
            );
            if let Err(error) = save_display_settings(app) {
                show_error(app.main, "无法恢复显示设置", &error);
            }
        }
        ID_SHORTCUT_SAVE => {
            if let Err(error) = apply_shortcut_edits(app) {
                show_error(app.main, "无法应用快捷键", &error);
            }
        }
        ID_SHORTCUT_RESET => {
            let defaults = ShortcutConfiguration::default();
            populate_shortcut_edits(app, &defaults);
            if let Err(error) = apply_shortcut_edits(app) {
                show_error(app.main, "无法重置快捷键", &error);
            }
        }
        ID_SYNC_MODE if notification == CBN_SELCHANGE as u16 => {
            clear_pairing(app);
            update_sync_form(app);
        }
        ID_SYNC_SETUP => {
            if let Err(error) = setup_selected_sync_mode(app) {
                show_error(app.main, "无法配置同步", &error);
            }
        }
        ID_SYNC_SAVE => match sync_credentials_from_form(app) {
            Ok(credentials) => {
                if let Err(error) = begin_sync_preflight(app, credentials) {
                    show_error(app.main, "无法验证同步方式", &error);
                }
            }
            Err(error) => show_error(app.main, "同步配置无效", &error),
        },
        ID_SYNC_NOW => {
            app.sync_runtime.request(SyncTrigger::Manual);
            set_text(app.sync_controls.output, "已请求立即同步。");
            update_sync_status(app);
        }
        ID_SYNC_DEVICES => {
            if let Err(error) = refresh_sync_devices(app) {
                show_error(app.main, "无法读取设备列表", &error);
            }
        }
        ID_SYNC_REVOKE => {
            if let Err(error) = revoke_sync_device(app) {
                show_error(app.main, "无法撤销设备", &error);
            }
        }
        ID_SYNC_PAIR => {
            if let Err(error) = begin_sync_sharing(app) {
                show_error(app.main, "无法生成同步二维码", &error);
            }
        }
        ID_SYNC_PAIR_COPY => {
            if let Some(link) = visible_sync_share_link(app)
                && let Err(error) = copy_to_clipboard(app.main, link)
            {
                show_error(app.main, "无法复制同步配置", &error);
            }
        }
        ID_SYNC_PAIR_CONFIRM => {
            if let Err(error) = confirm_pairing(app) {
                show_error(app.main, "无法确认配对", &error);
            }
        }
        ID_BACKUP_EXPORT => {
            if let Err(error) = export_encrypted_backup(app) {
                show_error(app.main, "无法导出备份", &error);
            }
        }
        ID_BACKUP_IMPORT => {
            if let Err(error) = import_encrypted_backup(app) {
                show_error(app.main, "无法恢复备份", &error);
            }
        }
        ID_TOPMOST => {
            app.settings.topmost =
                SendMessageW(app.main_controls.topmost, BM_GETCHECK, 0, 0) == BST_CHECKED as isize;
            apply_floating_settings(app);
            let _ = app.settings.save();
        }
        ID_CLICK_THROUGH => {
            app.settings.click_through =
                SendMessageW(app.main_controls.click_through, BM_GETCHECK, 0, 0)
                    == BST_CHECKED as isize;
            apply_floating_settings(app);
            let _ = app.settings.save();
        }
        ID_TRAY_SHOW_MAIN => show_main(app),
        ID_TRAY_TOGGLE_BOARD => toggle_board(app),
        ID_TRAY_QUICK_ADD => show_quick_add(app),
        ID_TRAY_TOPMOST => toggle_topmost(app),
        ID_TRAY_RESTORE => restore_interaction(app),
        ID_TRAY_CHECK_UPDATE => begin_update_check(app, true),
        ID_TRAY_EXIT => exit_application(app),
        _ => {}
    }
}

unsafe fn handle_float_command(app: &mut App, id: i32) {
    match id {
        ID_FLOAT_ADD => {
            let title = get_text(app.float_controls.quick_edit);
            smoke_trace(&format!("float_add title={title:?}"));
            if !title.trim().is_empty() {
                create_task(app, Some(title));
                set_text(app.float_controls.quick_edit, "");
            }
        }
        ID_FLOAT_OPEN => show_main(app),
        ID_FLOAT_COMPLETE => {
            if let Some(task) = selected_float_task(app) {
                toggle_task_completion(app, task);
            }
        }
        ID_FLOAT_PASS => {
            if let Some(task) = selected_float_task(app) {
                let id = task.id;
                mutate(app, |repo| repo.pass(&id, now_millis()));
            }
        }
        ID_FLOAT_TASK_EDIT => {
            if let Some(task) = selected_float_task(app) {
                edit_task(app, task, app.floating);
            }
        }
        ID_FLOAT_DELETE => {
            if let Some(task) = selected_float_task(app) {
                let id = task.id;
                mutate(app, |repo| repo.delete(&id, now_millis()));
            }
        }
        _ => {}
    }
}

unsafe fn show_main(app: &mut App) {
    refresh_main(app);
    ShowWindow(app.main, SW_RESTORE);
    SetForegroundWindow(app.main);
    begin_automatic_update_check(app);
}

unsafe fn toggle_board(app: &App) {
    if IsWindowVisible(app.floating) != 0 {
        ShowWindow(app.floating, SW_HIDE);
    } else {
        ShowWindow(
            app.floating,
            if app.settings.click_through {
                SW_SHOWNOACTIVATE
            } else {
                SW_SHOW
            },
        );
    }
}

unsafe fn show_quick_add(app: &mut App) {
    if app.settings.click_through {
        app.settings.click_through = false;
        apply_floating_settings(app);
        let _ = app.settings.save();
    }
    ShowWindow(app.floating, SW_SHOW);
    SetForegroundWindow(app.floating);
    SetFocus(app.float_controls.quick_edit);
}

unsafe fn toggle_topmost(app: &mut App) {
    app.settings.topmost = !app.settings.topmost;
    apply_floating_settings(app);
    let _ = app.settings.save();
    if app.section == Section::Settings {
        show_settings(app);
    }
}

unsafe fn toggle_click_through(app: &mut App) {
    app.settings.click_through = !app.settings.click_through;
    apply_floating_settings(app);
    let _ = app.settings.save();
    if app.section == Section::Settings {
        show_settings(app);
    }
}

unsafe fn restore_interaction(app: &mut App) {
    app.settings.click_through = false;
    apply_floating_settings(app);
    let _ = app.settings.save();
    ShowWindow(app.floating, SW_SHOW);
    SetForegroundWindow(app.floating);
}

unsafe fn apply_floating_settings(app: &App) {
    let mut style = GetWindowLongPtrW(app.floating, GWL_EXSTYLE);
    style |= WS_EX_LAYERED as isize;
    if app.settings.click_through {
        style |= (WS_EX_TRANSPARENT | WS_EX_NOACTIVATE) as isize;
    } else {
        style &= !((WS_EX_TRANSPARENT | WS_EX_NOACTIVATE) as isize);
    }
    SetWindowLongPtrW(app.floating, GWL_EXSTYLE, style);
    let alpha = (app.settings.opacity.clamp(0.20, 1.0) * 255.0).round() as u8;
    SetLayeredWindowAttributes(app.floating, 0, alpha, LWA_ALPHA);
    SetWindowPos(
        app.floating,
        if app.settings.topmost {
            HWND_TOPMOST
        } else {
            HWND_NOTOPMOST
        },
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED,
    );
}

unsafe fn keep_floating_on_screen(app: &App) {
    let monitor = MonitorFromWindow(app.floating, MONITOR_DEFAULTTONEAREST);
    let mut info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    if monitor.is_null() || GetMonitorInfoW(monitor, &mut info) == 0 {
        return;
    }
    let mut rect: RECT = zeroed();
    GetWindowRect(app.floating, &mut rect);
    let width = (rect.right - rect.left).clamp(320, info.rcWork.right - info.rcWork.left);
    let height = (rect.bottom - rect.top).clamp(360, info.rcWork.bottom - info.rcWork.top);
    let x = rect.left.clamp(info.rcWork.left, info.rcWork.right - width);
    let y = rect.top.clamp(info.rcWork.top, info.rcWork.bottom - height);
    SetWindowPos(
        app.floating,
        null_mut(),
        x,
        y,
        width,
        height,
        SWP_NOZORDER | SWP_NOACTIVATE,
    );
}

unsafe fn save_floating_bounds(app: &mut App) {
    let mut rect: RECT = zeroed();
    if GetWindowRect(app.floating, &mut rect) != 0 {
        app.settings.board_left = rect.left as f64;
        app.settings.board_top = rect.top as f64;
        app.settings.board_width = (rect.right - rect.left) as f64;
        app.settings.board_height = (rect.bottom - rect.top) as f64;
        let _ = app.settings.save();
    }
}

unsafe fn register_hotkeys(app: &App) {
    if let Err(error) = try_register_hotkeys(app, &app.settings.shortcuts) {
        show_tray_warning(
            app,
            "全局快捷键不可用",
            &format!("{error}。可能已被其他应用占用。"),
        );
    }
}

unsafe fn try_register_hotkeys(
    app: &App,
    configuration: &ShortcutConfiguration,
) -> Result<(), String> {
    let mut registered = Vec::new();
    for command in ShortcutCommand::ALL {
        let binding = configuration
            .binding(command)
            .ok_or_else(|| format!("缺少 {}", shortcut_command_label(command)))?;
        let id = hotkey_id(command);
        if RegisterHotKey(
            app.main,
            id,
            binding.modifiers.bits() | MOD_NOREPEAT,
            binding.virtual_key,
        ) == 0
        {
            for registered_id in registered {
                UnregisterHotKey(app.main, registered_id);
            }
            return Err(format!(
                "{}（{}）注册失败",
                shortcut_command_label(command),
                format_shortcut_binding(binding)
            ));
        }
        registered.push(id);
    }
    Ok(())
}

fn hotkey_id(command: ShortcutCommand) -> i32 {
    match command {
        ShortcutCommand::QuickAdd => HOTKEY_QUICK_ADD,
        ShortcutCommand::ToggleTaskPanel => HOTKEY_TOGGLE_BOARD,
        ShortcutCommand::ToggleAlwaysOnTop => HOTKEY_TOPMOST,
        ShortcutCommand::ToggleClickThrough => HOTKEY_CLICK_THROUGH,
    }
}

fn shortcut_command_label(command: ShortcutCommand) -> &'static str {
    match command {
        ShortcutCommand::QuickAdd => "快速新增",
        ShortcutCommand::ToggleTaskPanel => "显示任务板",
        ShortcutCommand::ToggleAlwaysOnTop => "切换置顶",
        ShortcutCommand::ToggleClickThrough => "切换穿透",
    }
}

unsafe fn unregister_hotkeys(app: &App) {
    for id in [
        HOTKEY_QUICK_ADD,
        HOTKEY_TOGGLE_BOARD,
        HOTKEY_TOPMOST,
        HOTKEY_CLICK_THROUGH,
    ] {
        UnregisterHotKey(app.main, id);
    }
}

unsafe fn handle_hotkey(app: &mut App, id: i32) {
    match id {
        HOTKEY_QUICK_ADD => show_quick_add(app),
        HOTKEY_TOGGLE_BOARD => toggle_board(app),
        HOTKEY_TOPMOST => toggle_topmost(app),
        HOTKEY_CLICK_THROUGH => toggle_click_through(app),
        _ => {}
    }
}

unsafe fn add_tray_icon(app: &mut App) -> Result<(), String> {
    let mut data = tray_data(app);
    if Shell_NotifyIconW(NIM_ADD, &data) == 0 {
        return Err(last_error("无法创建系统托盘图标"));
    }
    data.Anonymous.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &data);
    app.tray_added = true;
    Ok(())
}

unsafe fn remove_tray_icon(app: &mut App) {
    if app.tray_added {
        Shell_NotifyIconW(NIM_DELETE, &tray_data(app));
        app.tray_added = false;
    }
}

unsafe fn tray_data(app: &App) -> NOTIFYICONDATAW {
    let mut data = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: app.main,
        uID: 1,
        uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
        uCallbackMessage: WM_TRAY,
        hIcon: LoadIconW(app.instance, resource_id(1)),
        ..Default::default()
    };
    if data.hIcon.is_null() {
        data.hIcon = LoadIconW(null_mut(), IDI_APPLICATION);
    }
    copy_wide(&mut data.szTip, "无我待办");
    data
}

unsafe fn show_tray_warning(app: &App, title: &str, message: &str) {
    if !app.tray_added {
        return;
    }
    let mut data = tray_data(app);
    data.uFlags = NIF_INFO;
    data.dwInfoFlags = NIIF_WARNING;
    copy_wide(&mut data.szInfoTitle, title);
    copy_wide(&mut data.szInfo, message);
    Shell_NotifyIconW(NIM_MODIFY, &data);
}

unsafe fn show_tray_information(app: &App, title: &str, message: &str) {
    if !app.tray_added {
        return;
    }
    let mut data = tray_data(app);
    data.uFlags = NIF_INFO;
    data.dwInfoFlags = NIIF_INFO;
    copy_wide(&mut data.szInfoTitle, title);
    copy_wide(&mut data.szInfo, message);
    Shell_NotifyIconW(NIM_MODIFY, &data);
}

unsafe fn begin_update_check(app: &mut App, manual: bool) {
    if app.update_state != UpdateState::Idle {
        if manual {
            show_tray_information(
                app,
                "Woo Todo 更新",
                match app.update_state {
                    UpdateState::Checking => "正在检查更新，请稍候。",
                    UpdateState::Downloading => "正在下载更新，请稍候。",
                    UpdateState::Idle => "",
                },
            );
        }
        return;
    }
    if manual && let Some(release) = app.available_update.clone() {
        begin_update_download(app, release);
        return;
    }
    if manual {
        show_tray_information(app, "Woo Todo 更新", "正在后台检查，完成后会提示结果。");
    }
    app.settings.last_update_attempt_at = now_millis();
    let _ = app.settings.save();
    app.update_state = UpdateState::Checking;
    let sender = app.update_sender.clone();
    let window = app.main as usize;
    std::thread::spawn(move || {
        let _ = sender.send(UpdateEvent::Checked {
            manual,
            result: update::check_latest(),
        });
        unsafe {
            PostMessageW(window as HWND, WM_UPDATE_EVENT, 0, 0);
        }
    });
}

unsafe fn begin_automatic_update_check(app: &mut App) {
    if std::env::var_os("WOO_TODO_SKIP_UPDATE_CHECK").is_some()
        || app.main.is_null()
        || app.update_state != UpdateState::Idle
    {
        return;
    }
    let now = now_millis();
    if update::should_automatically_check(
        app.settings.last_update_successful_check_at,
        app.settings.last_update_attempt_at,
        now,
    ) {
        begin_update_check(app, false);
    }
}

unsafe fn begin_update_download(app: &mut App, release: UpdateRelease) {
    app.available_update = None;
    app.update_state = UpdateState::Downloading;
    show_tray_information(
        app,
        "Woo Todo 正在更新",
        &format!("正在后台下载 v{}，完成后会自动重启。", release.version),
    );
    let sender = app.update_sender.clone();
    let window = app.main as usize;
    std::thread::spawn(move || {
        let _ = sender.send(UpdateEvent::Downloaded(update::download(release)));
        unsafe {
            PostMessageW(window as HWND, WM_UPDATE_EVENT, 0, 0);
        }
    });
}

unsafe fn handle_update_events(app: &mut App) {
    while let Ok(event) = app.update_receiver.try_recv() {
        match event {
            UpdateEvent::Checked { manual, result } => {
                app.update_state = UpdateState::Idle;
                if result.is_ok() {
                    app.settings.last_update_successful_check_at = now_millis();
                    let _ = app.settings.save();
                }
                match result {
                    Ok(Some(release)) => {
                        show_tray_information(
                            app,
                            "Woo Todo 有新版本",
                            &format!(
                                "v{} 已显示在托盘菜单中，点击即可一键更新。",
                                release.version
                            ),
                        );
                        app.available_update = Some(release);
                    }
                    Ok(None) if manual => {
                        app.available_update = None;
                        show_tray_information(
                            app,
                            "Woo Todo 更新",
                            &format!("当前已是最新版本（v{}）。", env!("CARGO_PKG_VERSION")),
                        );
                    }
                    Ok(None) => app.available_update = None,
                    Err(error) if manual => {
                        show_tray_warning(app, "无法检查更新", &error);
                    }
                    Err(_) => {}
                }
            }
            UpdateEvent::Downloaded(result) => {
                app.update_state = UpdateState::Idle;
                match result {
                    Ok(prepared) => {
                        if let Err(error) = update::launch_helper(&prepared) {
                            show_tray_warning(app, "无法安装更新", &error);
                        } else {
                            exit_application(app);
                        }
                    }
                    Err(error) => {
                        show_tray_warning(app, "更新下载失败", &error);
                    }
                }
            }
        }
    }
}

unsafe fn show_message(window: HWND, title: &str, message: &str, style: MESSAGEBOX_STYLE) -> i32 {
    let title = wide(title);
    let message = wide(message);
    MessageBoxW(window, message.as_ptr(), title.as_ptr(), style)
}

unsafe fn show_tray_menu(app: &mut App) {
    let menu = CreatePopupMenu();
    if menu.is_null() {
        return;
    }
    append_menu(menu, ID_TRAY_SHOW_MAIN, "任务详情与统计...");
    append_menu(
        menu,
        ID_TRAY_TOGGLE_BOARD,
        if IsWindowVisible(app.floating) != 0 {
            "隐藏任务板"
        } else {
            "显示任务板"
        },
    );
    append_menu(menu, ID_TRAY_QUICK_ADD, "快速新增...");
    append_menu(
        menu,
        ID_TRAY_TOPMOST,
        if app.settings.topmost {
            "取消始终置顶"
        } else {
            "任务板始终置顶"
        },
    );
    append_menu(menu, ID_TRAY_RESTORE, "恢复可交互");
    AppendMenuW(menu, MF_SEPARATOR, 0, null());
    let update_title = match app.update_state {
        UpdateState::Checking => "正在检查更新...".to_owned(),
        UpdateState::Downloading => "正在下载更新...".to_owned(),
        UpdateState::Idle => app
            .available_update
            .as_ref()
            .map(|release| format!("更新到 v{}", release.version))
            .unwrap_or_else(|| "检查更新...".to_owned()),
    };
    append_menu(menu, ID_TRAY_CHECK_UPDATE, &update_title);
    append_menu(menu, ID_TRAY_EXIT, "退出 Woo Todo");
    let mut point: POINT = zeroed();
    GetCursorPos(&mut point);
    SetForegroundWindow(app.main);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON, point.x, point.y, 0, app.main, null());
    DestroyMenu(menu);
}

unsafe fn append_menu(menu: HMENU, id: i32, text: &str) {
    let text = wide(text);
    AppendMenuW(menu, MF_STRING, id as usize, text.as_ptr());
}

unsafe fn show_float_menu(app: &mut App) {
    let Some(task) = selected_float_task(app) else {
        return;
    };
    let menu = CreatePopupMenu();
    if task.state == TaskState::Pending {
        append_menu(menu, ID_FLOAT_TASK_EDIT, "编辑");
        append_menu(menu, ID_FLOAT_COMPLETE, "完成");
        append_menu(menu, ID_FLOAT_PASS, "Pass");
        append_menu(menu, ID_FLOAT_DELETE, "删除");
    } else if task.state == TaskState::Completed {
        append_menu(menu, ID_FLOAT_COMPLETE, "取消完成");
    } else {
        DestroyMenu(menu);
        return;
    }
    let mut point: POINT = zeroed();
    GetCursorPos(&mut point);
    TrackPopupMenu(
        menu,
        TPM_RIGHTBUTTON,
        point.x,
        point.y,
        0,
        app.floating,
        null(),
    );
    DestroyMenu(menu);
}

unsafe fn exit_application(app: &mut App) {
    app.exiting = true;
    clear_pairing(app);
    clear_sensitive_sync_fields(app);
    save_floating_bounds(app);
    remove_tray_icon(app);
    unregister_hotkeys(app);
    DestroyWindow(app.floating);
    DestroyWindow(app.main);
}

unsafe fn destroy_startup_windows(app: &mut App) {
    remove_tray_icon(app);
    if !app.floating.is_null() && IsWindow(app.floating) != 0 {
        DestroyWindow(app.floating);
    }
    if !app.main.is_null() && IsWindow(app.main) != 0 {
        DestroyWindow(app.main);
    }
}

unsafe fn reconcile_notifications(app: &App) -> Result<(), String> {
    let tasks = app
        .repository
        .fetch_all()
        .map_err(|error| error.to_string())?;
    notifications::reconcile(&tasks).map_err(|error| error.to_string())
}

unsafe fn forward_to_running_instance() {
    let class = wide(MAIN_CLASS);
    let window = FindWindowW(class.as_ptr(), null());
    if window.is_null() {
        return;
    }
    if let Some(uri) = activation_uri_from_args() {
        let bytes = uri.as_bytes();
        let payload = COPYDATASTRUCT {
            dwData: 1,
            cbData: bytes.len() as u32,
            lpData: bytes.as_ptr() as *mut c_void,
        };
        SendMessageW(window, WM_COPYDATA, 0, &payload as *const _ as isize);
    } else {
        PostMessageW(window, WM_APP + 2, 0, 0);
    }
}

unsafe fn handle_activation_args(app: &mut App) {
    if let Some(uri) = activation_uri_from_args() {
        open_activation(app, &uri);
    }
}

unsafe fn open_activation(app: &mut App, uri: &str) {
    let prefix = "wootodo://task-reminder/";
    if let Some(id) = uri.strip_prefix(prefix)
        && let Ok(Some(task)) = app.repository.find(id)
        && task.state == TaskState::Pending
    {
        show_main(app);
        edit_task(app, task, app.main);
        return;
    }
    show_main(app);
}

fn activation_uri_from_args() -> Option<String> {
    std::env::args()
        .skip(1)
        .find(|value| value.starts_with("wootodo://"))
}

unsafe extern "system" fn main_window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        store_app_pointer(hwnd, lparam);
    }
    if !is_main_app_message(message) {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let Some(app) = app_from_window(hwnd) else {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    };
    match message {
        WM_CTLCOLORSTATIC | WM_CTLCOLOREDIT | WM_CTLCOLORBTN | WM_CTLCOLORLISTBOX => {
            paint_main_control(app, message, wparam)
        }
        WM_SIZE => {
            layout_main(app);
            0
        }
        WM_GETMINMAXINFO => {
            set_minimum_track_size(lparam, 860, 620);
            0
        }
        WM_DPICHANGED => {
            apply_suggested_window_rect(hwnd, lparam);
            layout_main(app);
            0
        }
        WM_CLOSE => {
            if app.exiting {
                DestroyWindow(hwnd);
            } else {
                clear_pairing(app);
                clear_sensitive_sync_fields(app);
                ShowWindow(hwnd, SW_HIDE);
            }
            0
        }
        WM_DESTROY => {
            if app.exiting {
                PostQuitMessage(0);
            }
            0
        }
        WM_COMMAND => {
            handle_main_command(app, loword(wparam) as i32, hiword(wparam));
            0
        }
        WM_HSCROLL => {
            if lparam as HWND == app.main_controls.opacity {
                let value =
                    SendMessageW(app.main_controls.opacity, TRACKBAR_GET_POSITION, 0, 0) as i32;
                app.settings.opacity = (value.clamp(20, 100) as f64) / 100.0;
                set_text(app.main_controls.opacity_value, &format!("{}%", value));
                apply_floating_settings(app);
                let _ = app.settings.save();
            }
            0
        }
        WM_NOTIFY => {
            if lparam == 0 {
                return 0;
            }
            let header = &*(lparam as *const NMHDR);
            if header.idFrom == ID_TASKS as usize {
                if header.code == LVN_ITEMCHANGED {
                    handle_main_item_changed(app, &*(lparam as *const NMLISTVIEW));
                }
                update_main_action_state(app);
                if header.code == NM_DBLCLK
                    && let Some(task) = selected_main_task(app)
                {
                    edit_task(app, task, app.main);
                }
            }
            0
        }
        WM_HOTKEY => {
            handle_hotkey(app, wparam as i32);
            0
        }
        WM_TIMER => {
            if wparam == UPDATE_CHECK_TIMER_ID {
                begin_automatic_update_check(app);
            } else if wparam == SYNC_STATUS_TIMER_ID {
                poll_sync_runtime(app);
                poll_sync_ui_events(app);
            } else if wparam == PERIOD_REFRESH_TIMER_ID && today_shanghai() != app.current_date {
                refresh_all(app);
            }
            0
        }
        WM_TIMECHANGE | WM_SETTINGCHANGE => {
            refresh_all(app);
            if let Err(error) = refresh_local_network_host(app) {
                show_tray_warning(app, "局域网同步主机未能刷新", &error);
            }
            app.sync_runtime.request(SyncTrigger::NetworkAvailable);
            0
        }
        WM_ACTIVATEAPP => {
            if wparam != 0 {
                if today_shanghai() != app.current_date {
                    refresh_all(app);
                }
                if let Err(error) = refresh_local_network_host(app) {
                    show_tray_warning(app, "局域网同步主机未能刷新", &error);
                }
                app.sync_runtime.request(SyncTrigger::NetworkAvailable);
                begin_automatic_update_check(app);
            }
            0
        }
        WM_POWERBROADCAST => {
            if matches!(wparam as u32, PBT_APMRESUMEAUTOMATIC | PBT_APMRESUMESUSPEND) {
                refresh_all(app);
                if let Err(error) = refresh_local_network_host(app) {
                    show_tray_warning(app, "局域网同步主机未能恢复", &error);
                }
                app.sync_runtime.request(SyncTrigger::Wake);
                begin_automatic_update_check(app);
            }
            1
        }
        WM_TRAY => {
            match loword(lparam as usize) as u32 {
                WM_LBUTTONDBLCLK | NIN_SELECT => show_main(app),
                WM_CONTEXTMENU | WM_RBUTTONUP => show_tray_menu(app),
                _ => {}
            }
            0
        }
        WM_COPYDATA => {
            if lparam == 0 {
                return 0;
            }
            let payload = &*(lparam as *const COPYDATASTRUCT);
            if payload.dwData == 1 && payload.cbData <= 8192 && !payload.lpData.is_null() {
                let bytes = std::slice::from_raw_parts(
                    payload.lpData as *const u8,
                    payload.cbData as usize,
                );
                if let Ok(uri) = std::str::from_utf8(bytes) {
                    open_activation(app, uri);
                }
            }
            1
        }
        value if value == WM_APP + 2 => {
            show_main(app);
            0
        }
        WM_UPDATE_EVENT => {
            handle_update_events(app);
            0
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

unsafe extern "system" fn float_window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        store_app_pointer(hwnd, lparam);
    }
    if !is_float_app_message(message) {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let Some(app) = app_from_window(hwnd) else {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    };
    match message {
        WM_CTLCOLORSTATIC | WM_CTLCOLOREDIT | WM_CTLCOLORBTN => {
            paint_floating_control(app, message, wparam, lparam)
        }
        WM_SIZE => {
            layout_floating(app);
            0
        }
        WM_GETMINMAXINFO => {
            set_minimum_track_size(lparam, 340, 400);
            0
        }
        WM_DPICHANGED => {
            apply_suggested_window_rect(hwnd, lparam);
            layout_floating(app);
            keep_floating_on_screen(app);
            0
        }
        WM_DISPLAYCHANGE => {
            keep_floating_on_screen(app);
            0
        }
        WM_CLOSE => {
            if app.exiting {
                DestroyWindow(hwnd);
            } else {
                ShowWindow(hwnd, SW_HIDE);
            }
            0
        }
        WM_COMMAND => {
            handle_float_command(app, loword(wparam) as i32);
            0
        }
        WM_NOTIFY => {
            if lparam == 0 {
                return 0;
            }
            let header = &*(lparam as *const NMHDR);
            if header.idFrom == ID_FLOAT_LIST as usize {
                if header.code == LVN_ITEMCHANGED {
                    handle_float_item_changed(app, &*(lparam as *const NMLISTVIEW));
                }
                if header.code == NM_DBLCLK
                    && let Some(task) = selected_float_task(app)
                {
                    edit_task(app, task, app.floating);
                }
            }
            0
        }
        WM_CONTEXTMENU => {
            show_float_menu(app);
            0
        }
        WM_EXITSIZEMOVE => {
            keep_floating_on_screen(app);
            save_floating_bounds(app);
            0
        }
        WM_NCHITTEST => {
            if app.settings.click_through {
                return HTTRANSPARENT as isize;
            }
            let result = DefWindowProcW(hwnd, message, wparam, lparam);
            if result == HTCLIENT as isize {
                let y = ((lparam >> 16) & 0xffff) as i16 as i32;
                let mut rect: RECT = zeroed();
                GetWindowRect(hwnd, &mut rect);
                if y - rect.top < 64 {
                    return HTCAPTION as isize;
                }
            }
            result
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

unsafe extern "system" fn quick_edit_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_KEYDOWN {
        if wparam as u16 == VK_RETURN {
            PostMessageW(
                GetParent(hwnd),
                WM_COMMAND,
                ID_FLOAT_ADD as usize,
                hwnd as isize,
            );
            return 0;
        }
        if wparam as u16 == VK_ESCAPE {
            SetWindowTextW(hwnd, wide("").as_ptr());
            return 0;
        }
    }
    let previous = QUICK_EDIT_PROC.load(Ordering::Acquire);
    CallWindowProcW(
        Some(std::mem::transmute::<
            isize,
            unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT,
        >(previous)),
        hwnd,
        message,
        wparam,
        lparam,
    )
}

unsafe fn show_task_editor(
    owner: HWND,
    secondary: HWND,
    initial_type: TimeType,
    initial_date: NaiveDate,
    existing: Option<TodoTask>,
) -> Option<TaskInput> {
    let mut state = Box::new(EditorState {
        controls: EditorControls::default(),
        input: None,
        initial_type,
        initial_date,
        existing,
    });
    let pointer = (&mut *state) as *mut EditorState;
    let window = create_top_window(
        EDITOR_CLASS,
        if state.existing.is_some() {
            "编辑任务"
        } else {
            "新增任务"
        },
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        WS_EX_DLGMODALFRAME,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        470,
        500,
        pointer.cast(),
    )
    .ok()?;
    SetWindowLongPtrW(window, GWLP_HWNDPARENT, owner as isize);
    if let Err(error) = create_editor_controls(window, &mut state) {
        show_error(owner, "无法打开任务编辑器", &error);
        DestroyWindow(window);
        return None;
    }
    center_window(window, owner);
    let owner_was_enabled = IsWindowEnabled(owner) != 0;
    let secondary_was_enabled = IsWindowEnabled(secondary) != 0;
    EnableWindow(owner, 0);
    EnableWindow(secondary, 0);
    ShowWindow(window, SW_SHOW);
    SetFocus(state.controls.title);
    let mut message: MSG = zeroed();
    while IsWindow(window) != 0 {
        let result = GetMessageW(&mut message, null_mut(), 0, 0);
        if result == 0 {
            PostQuitMessage(message.wParam as i32);
            break;
        }
        if result < 0 {
            break;
        }
        if IsDialogMessageW(window, &message) == 0 {
            let target = message.hwnd;
            if target == window || (!target.is_null() && IsChild(window, target) != 0) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }
    if owner_was_enabled && IsWindow(owner) != 0 {
        EnableWindow(owner, 1);
        SetForegroundWindow(owner);
    }
    if secondary_was_enabled && IsWindow(secondary) != 0 {
        EnableWindow(secondary, 1);
    }
    state.input.take()
}

unsafe fn create_editor_controls(window: HWND, state: &mut EditorState) -> Result<(), String> {
    create_label(window, "任务内容", 22, 20, 420, 20)?;
    state.controls.title = create_child(
        window,
        "EDIT",
        state
            .existing
            .as_ref()
            .map_or("", |task| task.title.as_str()),
        WS_VISIBLE | WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL as u32,
        WS_EX_CLIENTEDGE,
        ID_EDITOR_TITLE,
    )?;
    MoveWindow(state.controls.title, 22, 44, 420, 30, 1);
    create_label(window, "时间范围", 22, 90, 180, 20)?;
    create_label(window, "任务级别", 242, 90, 180, 20)?;
    state.controls.time_type = create_child(
        window,
        "COMBOBOX",
        "",
        WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST as u32,
        0,
        ID_EDITOR_TIME_TYPE,
    )?;
    state.controls.quest = create_child(
        window,
        "COMBOBOX",
        "",
        WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST as u32,
        0,
        ID_EDITOR_QUEST,
    )?;
    MoveWindow(state.controls.time_type, 22, 114, 200, 220, 1);
    MoveWindow(state.controls.quest, 242, 114, 200, 220, 1);
    for kind in [
        TimeType::Day,
        TimeType::Week,
        TimeType::Month,
        TimeType::Someday,
    ] {
        combo_add(state.controls.time_type, time_type_label(kind));
    }
    for line in [QuestLine::Main, QuestLine::Side, QuestLine::Extra] {
        combo_add(state.controls.quest, quest_line_label(line));
    }
    let selected_type = state
        .existing
        .as_ref()
        .map_or(state.initial_type, |task| task.time_type);
    let selected_quest = state
        .existing
        .as_ref()
        .map_or(QuestLine::Main, |task| task.quest_line);
    SendMessageW(
        state.controls.time_type,
        CB_SETCURSEL,
        time_type_index(selected_type) as usize,
        0,
    );
    SendMessageW(
        state.controls.quest,
        CB_SETCURSEL,
        quest_index(selected_quest) as usize,
        0,
    );
    create_label(window, "目标日期", 22, 162, 200, 20)?;
    state.controls.date = create_child(
        window,
        "SysDateTimePick32",
        "",
        WS_VISIBLE | WS_TABSTOP | DTS_SHORTDATEFORMAT,
        0,
        ID_EDITOR_DATE,
    )?;
    MoveWindow(state.controls.date, 22, 186, 200, 30, 1);
    let date = state
        .existing
        .as_ref()
        .and_then(|task| task.period_start)
        .unwrap_or(state.initial_date);
    set_date(state.controls.date, date);
    state.controls.repeats = create_child(
        window,
        "BUTTON",
        "每个所属周期重复",
        WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX as u32,
        0,
        ID_EDITOR_REPEAT,
    )?;
    MoveWindow(state.controls.repeats, 22, 230, 240, 28, 1);
    if state
        .existing
        .as_ref()
        .is_some_and(|task| task.recurrence == Recurrence::Repeat)
    {
        SendMessageW(state.controls.repeats, BM_SETCHECK, BST_CHECKED as usize, 0);
    }

    state.controls.reminder_enabled = create_child(
        window,
        "BUTTON",
        "提醒",
        WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX as u32,
        0,
        ID_EDITOR_REMINDER_ENABLED,
    )?;
    MoveWindow(state.controls.reminder_enabled, 22, 272, 200, 28, 1);
    state.controls.reminder_time = create_child(
        window,
        "SysDateTimePick32",
        "",
        WS_VISIBLE | WS_TABSTOP | DTS_TIMEFORMAT | DTS_UPDOWN,
        0,
        ID_EDITOR_REMINDER_TIME,
    )?;
    MoveWindow(state.controls.reminder_time, 242, 270, 200, 30, 1);
    let reminder = state
        .existing
        .as_ref()
        .and_then(|task| task.reminder_time)
        .unwrap_or(ReminderTime { hour: 9, minute: 0 });
    set_time(state.controls.reminder_time, reminder);
    if state
        .existing
        .as_ref()
        .is_some_and(|task| task.reminder_time.is_some())
    {
        SendMessageW(
            state.controls.reminder_enabled,
            BM_SETCHECK,
            BST_CHECKED as usize,
            0,
        );
    }

    state.controls.deadline_enabled = create_child(
        window,
        "BUTTON",
        "截止日期",
        WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX as u32,
        0,
        ID_EDITOR_DEADLINE_ENABLED,
    )?;
    MoveWindow(state.controls.deadline_enabled, 22, 314, 200, 28, 1);
    state.controls.deadline_date = create_child(
        window,
        "SysDateTimePick32",
        "",
        WS_VISIBLE | WS_TABSTOP | DTS_SHORTDATEFORMAT,
        0,
        ID_EDITOR_DEADLINE_DATE,
    )?;
    MoveWindow(state.controls.deadline_date, 242, 312, 200, 30, 1);
    let deadline = state
        .existing
        .as_ref()
        .and_then(|task| task.deadline_date)
        .unwrap_or(date);
    set_date(state.controls.deadline_date, deadline);
    if state
        .existing
        .as_ref()
        .is_some_and(|task| task.deadline_date.is_some())
    {
        SendMessageW(
            state.controls.deadline_enabled,
            BM_SETCHECK,
            BST_CHECKED as usize,
            0,
        );
    }
    let cancel = button(window, "取消", ID_EDITOR_CANCEL)?;
    let save = create_child(
        window,
        "BUTTON",
        "保存",
        WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
        0,
        ID_EDITOR_SAVE,
    )?;
    MoveWindow(cancel, 278, 410, 76, 32, 1);
    MoveWindow(save, 366, 410, 76, 32, 1);
    update_editor_options(state);
    Ok(())
}

unsafe fn create_label(
    parent: HWND,
    text: &str,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) -> Result<HWND, String> {
    let label = create_child(parent, "STATIC", text, WS_VISIBLE | STATIC_LEFT, 0, 0)?;
    MoveWindow(label, x, y, width, height, 1);
    Ok(label)
}

unsafe fn update_editor_options(state: &EditorState) {
    let index = SendMessageW(state.controls.time_type, CB_GETCURSEL, 0, 0) as i32;
    let someday = index == 3;
    EnableWindow(state.controls.date, (!someday) as i32);
    EnableWindow(state.controls.repeats, (!someday) as i32);
    EnableWindow(state.controls.reminder_enabled, (!someday) as i32);
    if someday {
        SendMessageW(
            state.controls.repeats,
            BM_SETCHECK,
            BST_UNCHECKED as usize,
            0,
        );
        SendMessageW(
            state.controls.reminder_enabled,
            BM_SETCHECK,
            BST_UNCHECKED as usize,
            0,
        );
    }
    let repeats =
        !someday && SendMessageW(state.controls.repeats, BM_GETCHECK, 0, 0) == BST_CHECKED as isize;
    if repeats {
        SendMessageW(
            state.controls.deadline_enabled,
            BM_SETCHECK,
            BST_UNCHECKED as usize,
            0,
        );
    }
    EnableWindow(state.controls.deadline_enabled, (!repeats) as i32);
    let reminder_enabled = !someday
        && SendMessageW(state.controls.reminder_enabled, BM_GETCHECK, 0, 0) == BST_CHECKED as isize;
    EnableWindow(state.controls.reminder_time, reminder_enabled as i32);
    let deadline_enabled = !repeats
        && SendMessageW(state.controls.deadline_enabled, BM_GETCHECK, 0, 0) == BST_CHECKED as isize;
    EnableWindow(state.controls.deadline_date, deadline_enabled as i32);
}

unsafe fn save_editor(state: &mut EditorState) -> Result<(), String> {
    let title = get_text(state.controls.title);
    let type_index = SendMessageW(state.controls.time_type, CB_GETCURSEL, 0, 0) as i32;
    let quest_index = SendMessageW(state.controls.quest, CB_GETCURSEL, 0, 0) as i32;
    let time_type = index_time_type(type_index).ok_or_else(|| "请选择时间范围".to_owned())?;
    let quest_line = index_quest(quest_index).ok_or_else(|| "请选择任务级别".to_owned())?;
    let target_date = if time_type == TimeType::Someday {
        today_shanghai()
    } else {
        get_date(state.controls.date)?
    };
    let repeats = time_type != TimeType::Someday
        && SendMessageW(state.controls.repeats, BM_GETCHECK, 0, 0) == BST_CHECKED as isize;
    let reminder_time = if time_type != TimeType::Someday
        && SendMessageW(state.controls.reminder_enabled, BM_GETCHECK, 0, 0) == BST_CHECKED as isize
    {
        Some(get_time(state.controls.reminder_time)?)
    } else {
        None
    };
    let deadline_date = if !repeats
        && SendMessageW(state.controls.deadline_enabled, BM_GETCHECK, 0, 0) == BST_CHECKED as isize
    {
        Some(get_date(state.controls.deadline_date)?)
    } else {
        None
    };
    woo_todo_core::TodoTask::create(
        &title,
        time_type,
        target_date,
        quest_line,
        repeats,
        0,
        1,
        reminder_time,
        deadline_date,
        None,
    )
    .map_err(|error| error.to_string())?;
    state.input = Some(TaskInput {
        title: title.trim().to_owned(),
        time_type,
        target_date,
        quest_line,
        repeats,
        reminder_time,
        deadline_date,
    });
    Ok(())
}

unsafe extern "system" fn editor_window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        let create = &*(lparam as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
    }
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut EditorState;
    if pointer.is_null() {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let state = &mut *pointer;
    match message {
        WM_COMMAND => {
            let id = loword(wparam) as i32;
            let notification = hiword(wparam);
            if id == ID_EDITOR_TIME_TYPE && notification == CBN_SELCHANGE as u16 {
                update_editor_options(state);
            }
            if matches!(
                id,
                ID_EDITOR_REPEAT | ID_EDITOR_REMINDER_ENABLED | ID_EDITOR_DEADLINE_ENABLED
            ) && notification == BN_CLICKED as u16
            {
                update_editor_options(state);
            }
            if id == ID_EDITOR_SAVE {
                match save_editor(state) {
                    Ok(()) => {
                        DestroyWindow(hwnd);
                    }
                    Err(error) => show_error(hwnd, "无法保存任务", &error),
                }
            }
            if id == ID_EDITOR_CANCEL {
                DestroyWindow(hwnd);
            }
            0
        }
        WM_CLOSE => {
            DestroyWindow(hwnd);
            0
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

unsafe fn center_window(window: HWND, owner: HWND) {
    let mut target: RECT = zeroed();
    let mut source: RECT = zeroed();
    GetWindowRect(window, &mut target);
    GetWindowRect(owner, &mut source);
    let x = source.left + ((source.right - source.left) - (target.right - target.left)) / 2;
    let y = source.top + ((source.bottom - source.top) - (target.bottom - target.top)) / 2;
    SetWindowPos(window, HWND_TOP, x, y, 0, 0, SWP_NOSIZE);
}

unsafe fn combo_add(combo: HWND, text: &str) {
    let text = wide(text);
    SendMessageW(combo, CB_ADDSTRING, 0, text.as_ptr() as isize);
}

unsafe fn set_date(control: HWND, date: NaiveDate) {
    use chrono::Datelike;
    let value = SYSTEMTIME {
        wYear: date.year() as u16,
        wMonth: date.month() as u16,
        wDay: date.day() as u16,
        ..Default::default()
    };
    SendMessageW(
        control,
        DTM_SETSYSTEMTIME,
        GDT_VALID as usize,
        &value as *const _ as isize,
    );
}

unsafe fn set_time(control: HWND, time: ReminderTime) {
    let value = SYSTEMTIME {
        wYear: 2000,
        wMonth: 1,
        wDay: 1,
        wHour: time.hour as u16,
        wMinute: time.minute as u16,
        ..Default::default()
    };
    SendMessageW(
        control,
        DTM_SETSYSTEMTIME,
        GDT_VALID as usize,
        &value as *const _ as isize,
    );
}

unsafe fn get_time(control: HWND) -> Result<ReminderTime, String> {
    let mut value: SYSTEMTIME = zeroed();
    if SendMessageW(control, DTM_GETSYSTEMTIME, 0, &mut value as *mut _ as isize)
        != GDT_VALID as isize
    {
        return Err("请选择提醒时间".to_owned());
    }
    ReminderTime::new(value.wHour as u8, value.wMinute as u8).map_err(|error| error.to_string())
}

unsafe fn get_date(control: HWND) -> Result<NaiveDate, String> {
    let mut value: SYSTEMTIME = zeroed();
    if SendMessageW(control, DTM_GETSYSTEMTIME, 0, &mut value as *mut _ as isize)
        != GDT_VALID as isize
    {
        return Err("请选择目标日期".to_owned());
    }
    NaiveDate::from_ymd_opt(value.wYear as i32, value.wMonth as u32, value.wDay as u32)
        .ok_or_else(|| "目标日期无效".to_owned())
}

fn time_type_index(value: TimeType) -> i32 {
    match value {
        TimeType::Day => 0,
        TimeType::Week => 1,
        TimeType::Month => 2,
        TimeType::Someday => 3,
    }
}
fn index_time_type(value: i32) -> Option<TimeType> {
    [
        TimeType::Day,
        TimeType::Week,
        TimeType::Month,
        TimeType::Someday,
    ]
    .get(value as usize)
    .copied()
}
fn quest_index(value: QuestLine) -> i32 {
    match value {
        QuestLine::Main => 0,
        QuestLine::Side => 1,
        QuestLine::Extra => 2,
    }
}
fn index_quest(value: i32) -> Option<QuestLine> {
    [QuestLine::Main, QuestLine::Side, QuestLine::Extra]
        .get(value as usize)
        .copied()
}

unsafe fn store_app_pointer(hwnd: HWND, lparam: LPARAM) {
    let create = &*(lparam as *const CREATESTRUCTW);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
}

unsafe fn app_from_window(hwnd: HWND) -> Option<&'static mut App> {
    (GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut App).as_mut()
}

unsafe fn set_text(window: HWND, text: &str) {
    SetWindowTextW(window, wide(text).as_ptr());
}

unsafe fn get_text(window: HWND) -> String {
    let length = GetWindowTextLengthW(window);
    let mut buffer = vec![0u16; length as usize + 1];
    GetWindowTextW(window, buffer.as_mut_ptr(), buffer.len() as i32);
    String::from_utf16_lossy(&buffer[..length as usize])
}

unsafe fn show_error(owner: HWND, title: &str, message: &str) {
    let title = wide(title);
    let message = wide(message);
    MessageBoxW(
        owner,
        message.as_ptr(),
        title.as_ptr(),
        MB_OK | MB_ICONERROR,
    );
}

fn data_directory() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
        .join("Woo Todo")
}

fn resource_id(value: u16) -> *const u16 {
    std::ptr::without_provenance(value as usize)
}

fn is_main_app_message(message: u32) -> bool {
    matches!(
        message,
        WM_SIZE
            | WM_CTLCOLORSTATIC
            | WM_CTLCOLOREDIT
            | WM_CTLCOLORBTN
            | WM_CTLCOLORLISTBOX
            | WM_GETMINMAXINFO
            | WM_DPICHANGED
            | WM_CLOSE
            | WM_DESTROY
            | WM_COMMAND
            | WM_HSCROLL
            | WM_NOTIFY
            | WM_HOTKEY
            | WM_TIMER
            | WM_TIMECHANGE
            | WM_SETTINGCHANGE
            | WM_ACTIVATEAPP
            | WM_POWERBROADCAST
            | WM_TRAY
            | WM_COPYDATA
    ) || matches!(message, value if value == WM_APP + 2 || value == WM_UPDATE_EVENT)
}

fn is_float_app_message(message: u32) -> bool {
    matches!(
        message,
        WM_SIZE
            | WM_CTLCOLORSTATIC
            | WM_CTLCOLOREDIT
            | WM_CTLCOLORBTN
            | WM_GETMINMAXINFO
            | WM_DPICHANGED
            | WM_DISPLAYCHANGE
            | WM_CLOSE
            | WM_COMMAND
            | WM_NOTIFY
            | WM_CONTEXTMENU
            | WM_EXITSIZEMOVE
            | WM_NCHITTEST
    )
}

unsafe fn set_minimum_track_size(lparam: LPARAM, width: i32, height: i32) {
    if let Some(info) = (lparam as *mut MINMAXINFO).as_mut() {
        info.ptMinTrackSize.x = width;
        info.ptMinTrackSize.y = height;
    }
}

unsafe fn apply_suggested_window_rect(window: HWND, lparam: LPARAM) {
    let Some(rect) = (lparam as *const RECT).as_ref() else {
        return;
    };
    SetWindowPos(
        window,
        null_mut(),
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        SWP_NOZORDER | SWP_NOACTIVATE,
    );
}

unsafe fn set_control_font(control: HWND, font: HFONT) {
    if !font.is_null() {
        SendMessageW(control, WM_SETFONT, font as usize, 1);
    }
}

unsafe fn set_list_palette(list: HWND, background: COLORREF, text: COLORREF) {
    SendMessageW(list, LVM_SETBKCOLOR, 0, background as isize);
    SendMessageW(list, LVM_SETTEXTBKCOLOR, 0, background as isize);
    SendMessageW(list, LVM_SETTEXTCOLOR, 0, text as isize);
}

unsafe fn apply_dark_control_theme(control: HWND) {
    let theme = wide("DarkMode_Explorer");
    SetWindowTheme(control, theme.as_ptr(), null());
}

unsafe fn paint_main_control(app: &App, message: u32, wparam: WPARAM) -> LRESULT {
    let context = wparam as HDC;
    SetTextColor(context, TEXT_ON_LIGHT);
    SetBkColor(context, PAPER_BRIGHT);
    if message == WM_CTLCOLORSTATIC {
        SetBkMode(context, TRANSPARENT as i32);
    }
    app.theme.paper_brush as LRESULT
}

unsafe fn paint_floating_control(
    app: &App,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let context = wparam as HDC;
    let control = lparam as HWND;
    if message == WM_CTLCOLOREDIT {
        SetTextColor(context, TEXT_ON_LIGHT);
        SetBkColor(context, PAPER_BRIGHT);
        return app.theme.paper_brush as LRESULT;
    }
    let text = if control == app.float_controls.date || control == app.float_controls.progress {
        MUTED_ON_DARK
    } else if control == app.float_controls.heading {
        TEXT_ON_DARK
    } else {
        PURPLE_LIGHT
    };
    SetTextColor(context, text);
    SetBkColor(context, INK);
    if message == WM_CTLCOLORSTATIC {
        SetBkMode(context, TRANSPARENT as i32);
        app.theme.ink_brush as LRESULT
    } else {
        app.theme.ink_soft_brush as LRESULT
    }
}

const fn rgb(red: u8, green: u8, blue: u8) -> COLORREF {
    red as COLORREF | ((green as COLORREF) << 8) | ((blue as COLORREF) << 16)
}

fn now_millis() -> i64 {
    Utc::now().timestamp_millis()
}

fn smoke_trace(message: &str) {
    let Some(path) = std::env::var_os("WOO_TODO_SMOKE_TRACE") else {
        return;
    };
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{} {message}", Utc::now().to_rfc3339());
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn copy_wide<const N: usize>(target: &mut [u16; N], value: &str) {
    let source: Vec<u16> = value.encode_utf16().take(N.saturating_sub(1)).collect();
    target.fill(0);
    target[..source.len()].copy_from_slice(&source);
}

fn loword(value: usize) -> u16 {
    (value & 0xffff) as u16
}
fn hiword(value: usize) -> u16 {
    ((value >> 16) & 0xffff) as u16
}

fn last_error(context: &str) -> String {
    format!("{context}：{}", std::io::Error::last_os_error())
}
