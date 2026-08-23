use std::sync::mpsc;
use std::thread::{self, JoinHandle};

use crate::shortcut::{ShortcutCommand, ShortcutConfiguration};

const HOTKEY_BASE_ID: i32 = 0x5200;

#[derive(Debug)]
pub enum HotkeyEvent {
    Triggered(ShortcutCommand),
    RegistrationFailed(String),
}

pub struct HotkeyManager {
    thread_id: u32,
    worker: Option<JoinHandle<()>>,
}

impl HotkeyManager {
    pub fn start<F>(configuration: ShortcutConfiguration, callback: F) -> Self
    where
        F: Fn(HotkeyEvent) + Send + 'static,
    {
        let (thread_id_sender, thread_id_receiver) = mpsc::sync_channel(1);
        let worker = thread::spawn(move || run(configuration, callback, thread_id_sender));
        let thread_id = thread_id_receiver
            .recv()
            .expect("快捷键线程未能初始化消息队列");
        Self {
            thread_id,
            worker: Some(worker),
        }
    }
}

impl Drop for HotkeyManager {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::UI::WindowsAndMessaging::PostThreadMessageW(
                self.thread_id,
                windows_sys::Win32::UI::WindowsAndMessaging::WM_QUIT,
                0,
                0,
            );
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn run<F>(
    configuration: ShortcutConfiguration,
    callback: F,
    thread_id_sender: mpsc::SyncSender<u32>,
) where
    F: Fn(HotkeyEvent),
{
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::GetLastError;
    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::System::Threading::GetCurrentThreadId;
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        MOD_NOREPEAT, RegisterHotKey, UnregisterHotKey,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CS_HREDRAW, CS_VREDRAW, CreateWindowExW, DestroyWindow, DispatchMessageW, GetMessageW,
        HWND_MESSAGE, MSG, PM_NOREMOVE, PeekMessageW, RegisterClassW, WM_HOTKEY, WNDCLASSW,
    };

    // Creating a message queue before publishing the thread id makes shutdown reliable even if
    // the Tauri event loop drops the manager immediately after setup.
    let thread_id = unsafe { GetCurrentThreadId() };
    let mut queue_probe = MSG::default();
    unsafe {
        PeekMessageW(&mut queue_probe, null_mut(), 0, 0, PM_NOREMOVE);
    }
    let _ = thread_id_sender.send(thread_id);

    let class_name = wide("WooTodoHotkeyWindow");
    let instance = unsafe { GetModuleHandleW(null()) };
    let window_class = WNDCLASSW {
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(hotkey_window_proc),
        hInstance: instance,
        lpszClassName: class_name.as_ptr(),
        ..Default::default()
    };
    let _ = unsafe { RegisterClassW(&window_class) };
    let window = unsafe {
        CreateWindowExW(
            0,
            class_name.as_ptr(),
            class_name.as_ptr(),
            0,
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            null_mut(),
            instance,
            null(),
        )
    };
    if window.is_null() {
        callback(HotkeyEvent::RegistrationFailed(format!(
            "无法创建快捷键窗口（错误 {}）",
            unsafe { GetLastError() }
        )));
        return;
    }

    let mut registered = Vec::new();
    for command in ShortcutCommand::ALL {
        let Some(binding) = configuration.binding(command) else {
            callback(HotkeyEvent::RegistrationFailed(format!(
                "快捷键配置缺少 {}",
                crate::shortcut::command_label(command)
            )));
            unsafe { DestroyWindow(window) };
            return;
        };
        let id = hotkey_id(command);
        if unsafe {
            RegisterHotKey(
                window,
                id,
                binding.modifiers.bits() | MOD_NOREPEAT,
                binding.virtual_key,
            )
        } == 0
        {
            for registered_id in registered {
                unsafe { UnregisterHotKey(window, registered_id) };
            }
            callback(HotkeyEvent::RegistrationFailed(format!(
                "{}（{}）注册失败，可能已被其他应用占用",
                crate::shortcut::command_label(command),
                crate::shortcut::format_shortcut_binding(binding)
            )));
            unsafe { DestroyWindow(window) };
            return;
        }
        registered.push(id);
    }

    let mut message = MSG::default();
    loop {
        let result = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        if result <= 0 {
            break;
        }
        if message.message == WM_HOTKEY {
            if let Some(command) = command_for_id(message.wParam as i32) {
                callback(HotkeyEvent::Triggered(command));
            }
        } else {
            unsafe { DispatchMessageW(&message) };
        }
    }
    for id in registered {
        unsafe { UnregisterHotKey(window, id) };
    }
    unsafe { DestroyWindow(window) };
}

unsafe extern "system" fn hotkey_window_proc(
    window: windows_sys::Win32::Foundation::HWND,
    message: u32,
    wparam: windows_sys::Win32::Foundation::WPARAM,
    lparam: windows_sys::Win32::Foundation::LPARAM,
) -> windows_sys::Win32::Foundation::LRESULT {
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::DefWindowProcW(window, message, wparam, lparam)
    }
}

fn hotkey_id(command: ShortcutCommand) -> i32 {
    HOTKEY_BASE_ID
        + ShortcutCommand::ALL
            .iter()
            .position(|value| *value == command)
            .unwrap_or(0) as i32
}

fn command_for_id(id: i32) -> Option<ShortcutCommand> {
    let index = usize::try_from(id - HOTKEY_BASE_ID).ok()?;
    ShortcutCommand::ALL.get(index).copied()
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
