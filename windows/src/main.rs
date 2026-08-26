#![cfg_attr(windows, windows_subsystem = "windows")]

#[allow(dead_code)]
#[cfg(any(windows, test))]
mod credentials;
#[allow(dead_code)]
#[cfg(any(windows, test))]
mod display;
#[cfg(any(windows, test))]
mod http;
#[cfg(any(windows, test))]
mod local_server;
#[cfg(any(windows, test))]
mod local_sync_host;
#[cfg(any(windows, test))]
mod lunar;
#[cfg(any(windows, test))]
mod settings;
#[allow(dead_code)]
#[cfg(any(windows, test))]
mod shortcut;
#[allow(dead_code)]
#[cfg(any(windows, test))]
mod sync_runtime;
#[allow(dead_code)]
#[cfg(any(windows, test))]
mod ui_text;

#[cfg(windows)]
mod hotkeys;
#[cfg(windows)]
mod integration;
#[cfg(windows)]
mod notifications;
#[cfg(windows)]
mod tauri_app;
#[allow(dead_code)]
#[cfg(any(windows, test))]
mod update;
#[allow(dead_code)]
#[cfg(any(windows, test))]
mod webdav;
#[allow(dead_code)]
#[cfg(any(windows, test))]
mod worker;

#[cfg(windows)]
fn main() {
    install_panic_log();
    if let Some(result) = update::run_helper_from_args() {
        if let Err(error) = result {
            show_fatal_error(&error);
            std::process::exit(1);
        }
        return;
    }
    if let Err(error) = tauri_app::run() {
        show_fatal_error(&error);
    }
}

#[cfg(windows)]
fn show_fatal_error(message: &str) {
    use std::ptr::null_mut;
    use windows_sys::Win32::UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW};

    let title = "Woo Todo 启动失败"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let message = message
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    unsafe {
        MessageBoxW(
            null_mut(),
            message.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

/// GUI 程序没有控制台，panic 信息默认不可见；
/// 写入 `%LOCALAPPDATA%\Woo Todo\panic.log` 便于排查启动问题。
#[cfg(windows)]
fn install_panic_log() {
    use std::io::Write;
    use std::path::PathBuf;

    let Some(directory) = std::env::var_os("LOCALAPPDATA") else {
        return;
    };
    let log_directory = PathBuf::from(directory).join("Woo Todo");
    if std::fs::create_dir_all(&log_directory).is_err() {
        return;
    }
    let log_path = log_directory.join("panic.log");
    let Ok(file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
    else {
        return;
    };
    let file = std::sync::Mutex::new(file);
    std::panic::set_hook(Box::new(move |info| {
        let timestamp = chrono::Local::now().format("%Y-%m-%d %H:%M:%S");
        if let Ok(mut file) = file.lock() {
            let _ = writeln!(file, "[{timestamp}] {info}");
        }
    }));
}

#[cfg(not(windows))]
fn main() {
    eprintln!("Woo Todo Windows 客户端只能在 Windows 10/11 上运行");
}
