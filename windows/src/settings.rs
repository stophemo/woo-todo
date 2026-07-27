use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

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
        Self {
            path,
            board_left: loaded.board_left,
            board_top: loaded.board_top,
            board_width: loaded.board_width.max(320.0),
            board_height: loaded.board_height.max(360.0),
            opacity: loaded.opacity.clamp(0.35, 1.0),
            topmost: loaded.topmost,
            click_through: loaded.click_through,
        }
    }

    pub fn save(&self) -> Result<(), String> {
        let value = PersistedSettings {
            board_left: self.board_left,
            board_top: self.board_top,
            board_width: self.board_width,
            board_height: self.board_height,
            opacity: self.opacity,
            topmost: self.topmost,
            click_through: self.click_through,
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
        (self.opacity * 100.0).round().clamp(35.0, 100.0) as u8
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
        assert_eq!(settings.opacity, 0.35);
        assert!(!settings.topmost);
        assert!(settings.click_through);
    }

    #[test]
    fn opacity_and_click_through_are_persisted_independently() {
        let directory = tempfile::tempdir().unwrap();
        let mut settings = AppSettings::load(directory.path());
        settings.opacity = 0.73;
        settings.click_through = true;
        settings.save().unwrap();

        let restored = AppSettings::load(directory.path());
        assert_eq!(restored.opacity_percent(), 73);
        assert!(restored.click_through);
    }
}
