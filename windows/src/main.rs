#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(any(windows, test))]
mod settings;
#[cfg(any(windows, test))]
mod ui_text;

#[cfg(windows)]
mod integration;
#[cfg(windows)]
mod native;
#[cfg(windows)]
mod notifications;
#[cfg(any(windows, test))]
mod update;

#[cfg(windows)]
fn main() {
    if let Some(result) = update::run_helper_from_args() {
        if let Err(error) = result {
            native::show_fatal_error(&error);
            std::process::exit(1);
        }
        return;
    }
    if let Err(error) = native::run() {
        native::show_fatal_error(&error);
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("Woo Todo Windows 客户端只能在 Windows 10/11 上运行");
}
