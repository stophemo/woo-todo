use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::display::DisplayConfiguration;
use crate::shortcut::ShortcutConfiguration;

const DEFAULT_LEFT: f64 = 80.0;
const DEFAULT_TOP: f64 = 80.0;
const DEFAULT_WIDTH: f64 = 380.0;
const DEFAULT_HEIGHT: f64 = 540.0;
const DEFAULT_OPACITY: f64 = 0.92;

#[derive(Debug, Clone)]
pub struct AppSettings {
    path: PathBuf,
    pub board_left: f64,
    pub board_top: f64,
    pub board_width: f64,
    pub board_height: f64,
    pub opacity: f64,
    pub topmost: bool,
    pub click_through: bool,
    pub display: DisplayConfiguration,
    pub shortcuts: ShortcutConfiguration,
    /// 当前 Windows 设备是否负责承载“同一网络同步”服务。
    ///
    /// 同步密钥仍只保存在 Credential Manager；这里仅保存非敏感的主机角色，
    /// 使应用重启、休眠唤醒和网络变化后能够恢复监听。
    pub local_network_host: bool,
    pub last_update_successful_check_at: i64,
    pub last_update_attempt_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
struct PersistedSettings {
    board_left: f64,
    board_top: f64,
    board_width: f64,
    board_height: f64,
    opacity: f64,
    topmost: bool,
    click_through: bool,
    display: Value,
    shortcuts: Value,
    local_network_host: bool,
    last_update_successful_check_at: i64,
    last_update_attempt_at: i64,
}

impl Default for PersistedSettings {
    fn default() -> Self {
        Self {
            board_left: DEFAULT_LEFT,
            board_top: DEFAULT_TOP,
            board_width: DEFAULT_WIDTH,
            board_height: DEFAULT_HEIGHT,
            opacity: DEFAULT_OPACITY,
            topmost: true,
            click_through: false,
            display: serde_json::to_value(DisplayConfiguration::default()).unwrap_or(Value::Null),
            shortcuts: serde_json::to_value(ShortcutConfiguration::default())
                .unwrap_or(Value::Null),
            local_network_host: false,
            last_update_successful_check_at: 0,
            last_update_attempt_at: 0,
        }
    }
}

impl AppSettings {
    pub fn load(directory: &Path) -> Self {
        let _ = fs::create_dir_all(directory);
        let path = directory.join("settings.json");
        let loaded = fs::read_to_string(&path)
            .ok()
            .and_then(|source| serde_json::from_str::<PersistedSettings>(&source).ok())
            .unwrap_or_default();
        let display = serde_json::from_value::<DisplayConfiguration>(loaded.display)
            .ok()
            .filter(|configuration| configuration.validate().is_ok())
            .unwrap_or_default();
        let shortcuts = serde_json::from_value::<ShortcutConfiguration>(loaded.shortcuts)
            .ok()
            .filter(|configuration| configuration.validate().is_ok())
            .unwrap_or_default();
        Self {
            path,
            board_left: loaded.board_left,
            board_top: loaded.board_top,
            board_width: loaded.board_width.max(320.0),
            board_height: loaded.board_height.max(360.0),
            opacity: loaded.opacity.clamp(0.20, 1.0),
            topmost: loaded.topmost,
            click_through: loaded.click_through,
            display,
            shortcuts,
            local_network_host: loaded.local_network_host,
            last_update_successful_check_at: loaded.last_update_successful_check_at,
            last_update_attempt_at: loaded.last_update_attempt_at,
        }
    }

    pub fn save(&self) -> Result<(), String> {
        self.display
            .validate()
            .map_err(|_| "显示设置不合法".to_string())?;
        self.shortcuts
            .validate()
            .map_err(|_| "快捷键设置不合法".to_string())?;
        let display = serde_json::to_value(&self.display)
            .map_err(|error| format!("无法编码显示设置：{error}"))?;
        let shortcuts = serde_json::to_value(&self.shortcuts)
            .map_err(|error| format!("无法编码快捷键设置：{error}"))?;
        let value = PersistedSettings {
            board_left: self.board_left,
            board_top: self.board_top,
            board_width: self.board_width,
            board_height: self.board_height,
            opacity: self.opacity,
            topmost: self.topmost,
            click_through: self.click_through,
            display,
            shortcuts,
            local_network_host: self.local_network_host,
            last_update_successful_check_at: self.last_update_successful_check_at,
            last_update_attempt_at: self.last_update_attempt_at,
        };
        let source = serde_json::to_string_pretty(&value)
            .map_err(|error| format!("无法编码设置：{error}"))?;
        let temporary = self.path.with_extension("json.tmp");
        fs::write(&temporary, source).map_err(|error| format!("无法写入设置：{error}"))?;
        if self.path.exists() {
            fs::remove_file(&self.path).map_err(|error| format!("无法替换旧设置：{error}"))?;
        }
        fs::rename(&temporary, &self.path).map_err(|error| format!("无法保存设置：{error}"))
    }

    pub fn opacity_percent(&self) -> u8 {
        (self.opacity * 100.0).round().clamp(20.0, 100.0) as u8
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_preserves_existing_pascal_case_settings_and_clamps_geometry() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(
            directory.path().join("settings.json"),
            r#"{
  "BoardLeft": 12,
  "BoardTop": 34,
  "BoardWidth": 100,
  "BoardHeight": 200,
  "Opacity": 0.1,
  "Topmost": false,
  "ClickThrough": true
}"#,
        )
        .unwrap();

        let settings = AppSettings::load(directory.path());

        assert_eq!(settings.board_left, 12.0);
        assert_eq!(settings.board_top, 34.0);
        assert_eq!(settings.board_width, 320.0);
        assert_eq!(settings.board_height, 360.0);
        assert_eq!(settings.opacity, 0.20);
        assert!(!settings.topmost);
        assert!(settings.click_through);
        assert_eq!(settings.last_update_successful_check_at, 0);
        assert_eq!(settings.last_update_attempt_at, 0);
        assert_eq!(settings.display, DisplayConfiguration::default());
        assert_eq!(settings.shortcuts, ShortcutConfiguration::default());
    }

    #[test]
    fn opacity_and_click_through_are_persisted_independently() {
        let directory = tempfile::tempdir().unwrap();
        let mut settings = AppSettings::load(directory.path());
        settings.opacity = 0.73;
        settings.click_through = true;
        settings.last_update_successful_check_at = 123_000;
        settings.last_update_attempt_at = 124_000;
        settings.save().unwrap();

        let restored = AppSettings::load(directory.path());
        assert_eq!(restored.opacity_percent(), 73);
        assert!(restored.click_through);
        assert_eq!(restored.last_update_successful_check_at, 123_000);
        assert_eq!(restored.last_update_attempt_at, 124_000);
    }

    #[test]
    fn display_and_shortcuts_round_trip_with_independent_counter_dates() {
        use chrono::NaiveDate;

        use crate::shortcut::{ShortcutBinding, ShortcutCommand, ShortcutModifiers};

        let directory = tempfile::tempdir().unwrap();
        let mut settings = AppSettings::load(directory.path());
        settings.display.header_template = "{dateLong} · 今日任务".to_string();
        settings.display.subtitle_template =
            "第 {elapsedDays:2026-07-01} 天 · {deadlineDays:2026-12-31}".to_string();
        settings.display.start_date = NaiveDate::from_ymd_opt(2020, 1, 1).unwrap();
        settings.display.deadline_date = NaiveDate::from_ymd_opt(2030, 1, 1).unwrap();
        settings.shortcuts.bindings.insert(
            ShortcutCommand::QuickAdd,
            ShortcutBinding::new(ShortcutModifiers::CONTROL | ShortcutModifiers::SHIFT, 0x51),
        );
        settings.save().unwrap();

        let restored = AppSettings::load(directory.path());
        assert_eq!(restored.display, settings.display);
        assert_eq!(restored.shortcuts, settings.shortcuts);
        assert_eq!(
            restored
                .display
                .render_subtitle(NaiveDate::from_ymd_opt(2026, 7, 3).unwrap())
                .as_deref(),
            Some("第 3 天 · 181")
        );
    }

    #[test]
    fn invalid_nested_configuration_does_not_discard_legacy_settings() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(
            directory.path().join("settings.json"),
            r#"{
  "BoardLeft": 18,
  "BoardTop": 26,
  "BoardWidth": 640,
  "BoardHeight": 720,
  "Opacity": 0.42,
  "Topmost": false,
  "ClickThrough": true,
  "Display": {
    "HeaderTemplate": "第一行\n第二行",
    "SubtitleTemplate": "",
    "StartDate": "2026-07-01",
    "DeadlineDate": "2026-12-31"
  },
  "Shortcuts": {
    "Bindings": {
      "QuickAdd": { "Modifiers": 3, "VirtualKey": 49 }
    }
  }
}"#,
        )
        .unwrap();

        let settings = AppSettings::load(directory.path());

        assert_eq!(settings.board_left, 18.0);
        assert_eq!(settings.board_top, 26.0);
        assert_eq!(settings.board_width, 640.0);
        assert_eq!(settings.board_height, 720.0);
        assert_eq!(settings.opacity_percent(), 42);
        assert!(!settings.topmost);
        assert!(settings.click_through);
        assert_eq!(settings.display, DisplayConfiguration::default());
        assert_eq!(settings.shortcuts, ShortcutConfiguration::default());
    }

    #[test]
    fn opacity_percent_has_twenty_percent_floor() {
        let directory = tempfile::tempdir().unwrap();
        let mut settings = AppSettings::load(directory.path());
        settings.opacity = 0.01;

        assert_eq!(settings.opacity_percent(), 20);
    }
}
