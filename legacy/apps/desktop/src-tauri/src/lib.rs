use serde::Serialize;
use tauri::{Emitter, Manager, PhysicalPosition, WebviewWindow};

#[derive(Serialize, Clone)]
struct WindowState {
    always_on_top: bool,
    penetrate: bool,
}

#[tauri::command]
async fn toggle_always_on_top(window: WebviewWindow) -> Result<bool, String> {
    let is_on_top = window.is_always_on_top().map_err(|e| e.to_string())?;
    let next = !is_on_top;
    window.set_always_on_top(next).map_err(|e| e.to_string())?;
    let _ = window.emit("window-state", WindowState {
        always_on_top: next,
        penetrate: window.is_cursor_passthrough().unwrap_or(false),
    });
    Ok(next)
}

#[tauri::command]
async fn toggle_penetrate(window: WebviewWindow) -> Result<bool, String> {
    let currently = window.is_cursor_passthrough().map_err(|e| e.to_string())?;
    let next = !currently;
    // 开启穿透时关闭交互
    window.set_ignore_cursor_events(next).map_err(|e| e.to_string())?;
    let _ = window.emit("window-state", WindowState {
        always_on_top: window.is_always_on_top().unwrap_or(false),
        penetrate: next,
    });
    Ok(next)
}

#[tauri::command]
async fn get_window_state(window: WebviewWindow) -> Result<WindowState, String> {
    Ok(WindowState {
        always_on_top: window.is_always_on_top().unwrap_or(false),
        penetrate: window.is_cursor_passthrough().unwrap_or(false),
    })
}

#[tauri::command]
async fn move_window(window: WebviewWindow, dx: f64, dy: f64) -> Result<(), String> {
    let pos: PhysicalPosition<f64> = window.outer_position().map_err(|e| e.to_string())?.into();
    window
        .set_position(PhysicalPosition::new(pos.x + dx, pos.y + dy))
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            toggle_always_on_top,
            toggle_penetrate,
            get_window_state,
            move_window
        ])
        .setup(|app| {
            // 系统托盘菜单
            use tauri::menu::{Menu, MenuItem};
            use tauri::tray::TrayIconBuilder;

            let toggle_top = MenuItem::with_id(app, "toggle-top", "切换置顶", true, None::<&str>)?;
            let toggle_penetrate = MenuItem::with_id(app, "toggle-penetrate", "切换穿透", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&toggle_top, &toggle_penetrate, &quit])?;

            let _tray = TrayIconBuilder::with_id("main")
                .menu(&menu)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "toggle-top" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = toggle_always_on_top(w);
                        }
                    }
                    "toggle-penetrate" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = toggle_penetrate(w);
                        }
                    }
                    "quit" => {
                        app.exit(0);
                    }
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
