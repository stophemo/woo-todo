#![allow(unsafe_op_in_unsafe_fn)]

use std::cmp::Reverse;
use std::ffi::c_void;
use std::mem::{size_of, zeroed};
use std::path::PathBuf;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicIsize, Ordering};

use chrono::{Days, NaiveDate, Utc};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Graphics::Gdi::*;
use windows_sys::Win32::System::Com::*;
use windows_sys::Win32::System::DataExchange::COPYDATASTRUCT;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Threading::*;
use windows_sys::Win32::UI::Controls::*;
use windows_sys::Win32::UI::HiDpi::*;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
use windows_sys::Win32::UI::Shell::*;
use windows_sys::Win32::UI::WindowsAndMessaging::*;
use woo_todo_core::{
    QuestLine, Recurrence, ReminderTime, TaskRepository, TaskState, TimeType, TodoTask,
    calculate_statistics, today_shanghai,
};

use crate::notifications;
use crate::settings::AppSettings;
use crate::ui_text::{period_label, quest_line_label, state_label, time_type_label};

const APP_ID: &str = "stophemo.WooTodo";
const MAIN_CLASS: &str = "WooTodo.Native.Main.v1";
const FLOAT_CLASS: &str = "WooTodo.Native.Float.v1";
const EDITOR_CLASS: &str = "WooTodo.Native.Editor.v1";
const MUTEX_NAME: &str = "Local\\WooTodo.WindowsApp";
const WM_TRAY: u32 = WM_APP + 1;
const STATIC_LEFT: u32 = 0;
const STATIC_RIGHT: u32 = 2;
const TRACKBAR_GET_POSITION: u32 = WM_USER;

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
const ID_EDITOR_SAVE: i32 = IDOK;
const ID_EDITOR_CANCEL: i32 = IDCANCEL;

const ID_TRAY_SHOW_MAIN: i32 = 400;
const ID_TRAY_TOGGLE_BOARD: i32 = 401;
const ID_TRAY_QUICK_ADD: i32 = 402;
const ID_TRAY_TOPMOST: i32 = 403;
const ID_TRAY_RESTORE: i32 = 404;
const ID_TRAY_EXIT: i32 = 405;

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
}

#[derive(Default)]
struct FloatControls {
    heading: HWND,
    date: HWND,
    tasks: HWND,
    quick_edit: HWND,
    add: HWND,
    open: HWND,
}

struct App {
    instance: HINSTANCE,
    main: HWND,
    floating: HWND,
    main_controls: MainControls,
    float_controls: FloatControls,
    repository: TaskRepository,
    settings: AppSettings,
    section: Section,
    visible_tasks: Vec<TodoTask>,
    floating_tasks: Vec<TodoTask>,
    populating_main_tasks: bool,
    populating_float_tasks: bool,
    exiting: bool,
    tray_added: bool,
    mutex: HANDLE,
}

#[derive(Debug, Clone)]
struct TaskInput {
    title: String,
    time_type: TimeType,
    target_date: NaiveDate,
    quest_line: QuestLine,
    repeats: bool,
    reminder_time: Option<ReminderTime>,
}

#[derive(Default)]
struct EditorControls {
    title: HWND,
    time_type: HWND,
    quest: HWND,
    date: HWND,
    repeats: HWND,
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
        register_window_class(
            instance,
            MAIN_CLASS,
            Some(main_window_proc),
            (COLOR_WINDOW + 1) as u32,
        )?;
        register_window_class(
            instance,
            FLOAT_CLASS,
            Some(float_window_proc),
            (COLOR_WINDOW + 1) as u32,
        )?;
        register_window_class(
            instance,
            EDITOR_CLASS,
            Some(editor_window_proc),
            (COLOR_WINDOW + 1) as u32,
        )?;

        let data_directory = data_directory();
        let database = data_directory.join("woo-todo.sqlite3");
        let mut repository = TaskRepository::open(&database)
            .map_err(|error| format!("无法打开本地任务库：{error}"))?;
        repository
            .settle_expired(today_shanghai(), now_millis())
            .map_err(|error| format!("无法结算已结束周期：{error}"))?;

        let settings = AppSettings::load(&data_directory);
        let mut app = Box::new(App {
            instance,
            main: null_mut(),
            floating: null_mut(),
            main_controls: MainControls::default(),
            float_controls: FloatControls::default(),
            repository,
            settings,
            section: Section::Today,
            visible_tasks: Vec::new(),
            floating_tasks: Vec::new(),
            populating_main_tasks: false,
            populating_float_tasks: false,
            exiting: false,
            tray_added: false,
            mutex,
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
        register_hotkeys(&app);
        refresh_all(&mut app);

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
    background: u32,
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
        hbrBackground: background as usize as HBRUSH,
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
        visible | WS_BORDER | WS_VSCROLL | LBS_NOTIFY as u32,
        WS_EX_CLIENTEDGE,
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
        visible | WS_BORDER | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS,
        WS_EX_CLIENTEDGE,
        ID_TASKS,
    )?;
    SendMessageW(
        app.main_controls.tasks,
        LVM_SETEXTENDEDLISTVIEWSTYLE,
        0,
        (LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES | LVS_EX_DOUBLEBUFFER | LVS_EX_CHECKBOXES)
            as isize,
    );
    add_list_column(app.main_controls.tasks, 0, "状态", 80);
    add_list_column(app.main_controls.tasks, 1, "任务", 390);
    add_list_column(app.main_controls.tasks, 2, "周期", 130);
    add_list_column(app.main_controls.tasks, 3, "级别", 90);
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
    SendMessageW(app.main_controls.opacity, TBM_SETRANGEMIN, 1, 35);
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
        "鼠标穿透（Ctrl+Alt+4 恢复）",
        BS_AUTOCHECKBOX as u32,
        0,
        ID_CLICK_THROUGH,
    )?;

    layout_main(app);
    Ok(())
}

unsafe fn create_float_controls(app: &mut App) -> Result<(), String> {
    let parent = app.floating;
    let visible = WS_VISIBLE;
    app.float_controls.heading =
        create_child(parent, "STATIC", "今日任务", visible | STATIC_LEFT, 0, 0)?;
    app.float_controls.date = create_child(parent, "STATIC", "", visible | STATIC_LEFT, 0, 0)?;
    app.float_controls.tasks = create_child(
        parent,
        "SysListView32",
        "",
        visible | WS_BORDER | LVS_REPORT | LVS_SINGLESEL | LVS_NOCOLUMNHEADER | LVS_SHOWSELALWAYS,
        WS_EX_CLIENTEDGE,
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
    MoveWindow(
        app.main_controls.opacity_label,
        nav_width + 30,
        110,
        110,
        24,
        1,
    );
    MoveWindow(app.main_controls.opacity, nav_width + 145, 102, 300, 40, 1);
    MoveWindow(
        app.main_controls.opacity_value,
        nav_width + 455,
        110,
        60,
        24,
        1,
    );
    MoveWindow(app.main_controls.topmost, nav_width + 30, 166, 260, 28, 1);
    MoveWindow(
        app.main_controls.click_through,
        nav_width + 30,
        208,
        330,
        28,
        1,
    );
}

unsafe fn layout_floating(app: &App) {
    let mut area: RECT = zeroed();
    GetClientRect(app.floating, &mut area);
    let width = area.right.max(320);
    let height = area.bottom.max(360);
    MoveWindow(app.float_controls.heading, 18, 14, width - 110, 26, 1);
    MoveWindow(app.float_controls.date, 18, 42, width - 100, 22, 1);
    MoveWindow(app.float_controls.open, width - 82, 16, 64, 28, 1);
    MoveWindow(
        app.float_controls.tasks,
        18,
        74,
        width - 36,
        height - 132,
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
        width - 112,
        28,
        1,
    );
    MoveWindow(app.float_controls.add, width - 86, height - 46, 68, 28, 1);
}

unsafe fn refresh_all(app: &mut App) {
    refresh_main(app);
    refresh_floating(app);
    if let Err(error) = reconcile_notifications(app) {
        show_tray_warning(app, "任务提醒未能更新", &error);
    }
}

unsafe fn refresh_main(app: &mut App) {
    let today = today_shanghai();
    let _ = app.repository.settle_expired(today, now_millis());
    hide_settings(app);
    match app.section {
        Section::Statistics => show_statistics(app, today),
        Section::Settings => show_settings(app),
        section => show_tasks(app, section, today),
    }
}

unsafe fn show_tasks(app: &mut App, section: Section, today: NaiveDate) {
    let (title, subtitle, result) = match section {
        Section::Today => (
            "今日",
            today.format("%Y年%m月%d日").to_string(),
            app.repository.fetch_scope(TimeType::Day, today, false),
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
    populate_task_list(app.main_controls.tasks, &app.visible_tasks);
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
        "周期履约率  {}    完成 {} · Pass {}\r\n主线履约率  {}    完成 {} · Pass {}\r\n\r\n按时间范围\r\n",
        rate(
            snapshot.ended_periods.completed,
            snapshot.ended_periods.pass
        ),
        snapshot.ended_periods.completed,
        snapshot.ended_periods.pass,
        rate(
            snapshot.main_ended_periods.completed,
            snapshot.main_ended_periods.pass
        ),
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
    text.push_str("\r\n最近 7 天\r\n");
    for bucket in snapshot.daily_trend {
        text.push_str(&format!(
            "{}    完成 {}    Pass {}\r\n",
            bucket.start, bucket.completed, bucket.pass
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
    for control in [
        app.main_controls.opacity_label,
        app.main_controls.opacity,
        app.main_controls.opacity_value,
        app.main_controls.topmost,
        app.main_controls.click_through,
    ] {
        ShowWindow(control, SW_SHOW);
    }
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

unsafe fn hide_settings(app: &App) {
    for control in [
        app.main_controls.opacity_label,
        app.main_controls.opacity,
        app.main_controls.opacity_value,
        app.main_controls.topmost,
        app.main_controls.click_through,
    ] {
        ShowWindow(control, SW_HIDE);
    }
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
    set_text(
        app.float_controls.date,
        &today.format("%Y年%m月%d日").to_string(),
    );
    app.floating_tasks = app
        .repository
        .fetch_scope(TimeType::Day, today, false)
        .unwrap_or_default();
    app.populating_float_tasks = true;
    SendMessageW(app.float_controls.tasks, LVM_DELETEALLITEMS, 0, 0);
    if app.floating_tasks.is_empty() {
        insert_list_item(app.float_controls.tasks, 0, 0, "今日暂无任务");
        set_list_state_image(app.float_controls.tasks, 0, 0);
        EnableWindow(app.float_controls.tasks, 0);
    } else {
        EnableWindow(app.float_controls.tasks, 1);
        for (index, task) in app.floating_tasks.iter().enumerate() {
            insert_list_item(
                app.float_controls.tasks,
                index as i32,
                0,
                &format!("{}  · {}", task.title, quest_line_label(task.quest_line)),
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

unsafe fn populate_task_list(list: HWND, tasks: &[TodoTask]) {
    SendMessageW(list, LVM_DELETEALLITEMS, 0, 0);
    for (index, task) in tasks.iter().enumerate() {
        insert_list_item(list, index as i32, 0, state_label(task.state));
        set_list_subitem(list, index as i32, 1, &task.title);
        set_list_subitem(list, index as i32, 2, &period_label(task));
        set_list_subitem(list, index as i32, 3, quest_line_label(task.quest_line));
        set_list_checked(list, index as i32, task.state == TaskState::Completed);
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
        Ok(_) => refresh_all(app),
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
        })
    } else {
        show_task_editor(app.main, app.floating, default_type, default_date, None)
    };
    let Some(input) = input else { return };
    match app.repository.create(
        &input.title,
        input.time_type,
        input.target_date,
        input.quest_line,
        input.repeats,
        input.reminder_time,
        now_millis(),
    ) {
        Ok(_) => refresh_all(app),
        Err(error) => show_error(app.main, "无法新增任务", &error.to_string()),
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
        now_millis(),
    ) {
        Ok(_) => refresh_all(app),
        Err(error) => show_error(app.main, "无法更新任务", &error.to_string()),
    }
}

unsafe fn handle_main_command(app: &mut App, id: i32, notification: u16) {
    match id {
        ID_NAV if notification == LBN_SELCHANGE as u16 => {
            let index = SendMessageW(app.main_controls.nav, LB_GETCURSEL, 0, 0) as i32;
            app.section = Section::from_index(index);
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
        ID_TRAY_EXIT => exit_application(app),
        _ => {}
    }
}

unsafe fn handle_float_command(app: &mut App, id: i32) {
    match id {
        ID_FLOAT_ADD => {
            let title = get_text(app.float_controls.quick_edit);
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
    let alpha = (app.settings.opacity.clamp(0.35, 1.0) * 255.0).round() as u8;
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
    let modifiers = MOD_CONTROL | MOD_ALT | MOD_NOREPEAT;
    let entries = [
        (HOTKEY_QUICK_ADD, 0x31, "Ctrl+Alt+1"),
        (HOTKEY_TOGGLE_BOARD, 0x32, "Ctrl+Alt+2"),
        (HOTKEY_TOPMOST, 0x33, "Ctrl+Alt+3"),
        (HOTKEY_CLICK_THROUGH, 0x34, "Ctrl+Alt+4"),
    ];
    let failures: Vec<&str> = entries
        .into_iter()
        .filter_map(|(id, key, label)| {
            (RegisterHotKey(app.main, id, modifiers, key) == 0).then_some(label)
        })
        .collect();
    if !failures.is_empty() {
        show_tray_warning(
            app,
            "全局快捷键不可用",
            &format!("{} 无法注册，可能已被其他应用占用。", failures.join("、")),
        );
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
                app.settings.opacity = (value.clamp(35, 100) as f64) / 100.0;
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
        400,
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
    MoveWindow(state.controls.repeats, 22, 236, 240, 28, 1);
    if state
        .existing
        .as_ref()
        .is_some_and(|task| task.recurrence == Recurrence::Repeat)
    {
        SendMessageW(state.controls.repeats, BM_SETCHECK, BST_CHECKED as usize, 0);
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
    MoveWindow(cancel, 278, 318, 76, 32, 1);
    MoveWindow(save, 366, 318, 76, 32, 1);
    update_editor_someday(state);
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

unsafe fn update_editor_someday(state: &EditorState) {
    let index = SendMessageW(state.controls.time_type, CB_GETCURSEL, 0, 0) as i32;
    let someday = index == 3;
    EnableWindow(state.controls.date, (!someday) as i32);
    EnableWindow(state.controls.repeats, (!someday) as i32);
    if someday {
        SendMessageW(
            state.controls.repeats,
            BM_SETCHECK,
            BST_UNCHECKED as usize,
            0,
        );
    }
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
    let reminder_time = state.existing.as_ref().and_then(|task| task.reminder_time);
    woo_todo_core::TodoTask::create(
        &title,
        time_type,
        target_date,
        quest_line,
        repeats,
        0,
        1,
        reminder_time,
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
                update_editor_someday(state);
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
            | WM_GETMINMAXINFO
            | WM_DPICHANGED
            | WM_CLOSE
            | WM_DESTROY
            | WM_COMMAND
            | WM_HSCROLL
            | WM_NOTIFY
            | WM_HOTKEY
            | WM_TRAY
            | WM_COPYDATA
    ) || message == WM_APP + 2
}

fn is_float_app_message(message: u32) -> bool {
    matches!(
        message,
        WM_SIZE
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

fn now_millis() -> i64 {
    Utc::now().timestamp_millis()
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
