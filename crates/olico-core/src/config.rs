use std::fs;
use std::io::Write;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};

pub const CONFIG_VERSION: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Modifier {
    Cmd,
    Opt,
    Ctrl,
    Shift,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Hotkey {
    pub key_code: u32,
    pub modifiers: Vec<Modifier>,
}

impl Hotkey {
    pub fn new(key_code: u32, modifiers: &[Modifier]) -> Self {
        Self {
            key_code,
            modifiers: modifiers.to_vec(),
        }
    }

    pub fn canonical(&self) -> String {
        let mut modifiers = self.modifiers.clone();
        modifiers.sort();
        modifiers.dedup();
        format!("{}:{:?}", self.key_code, modifiers)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct HotkeySet {
    pub screenshot: Hotkey,
    pub clipboard: Hotkey,
    pub color_picker: Hotkey,
    pub toggle_pins: Hotkey,
}

impl Default for HotkeySet {
    fn default() -> Self {
        Self {
            screenshot: Hotkey::new(1, &[Modifier::Opt, Modifier::Shift]),
            clipboard: Hotkey::new(9, &[Modifier::Cmd, Modifier::Shift]),
            color_picker: Hotkey::new(8, &[Modifier::Opt, Modifier::Shift]),
            toggle_pins: Hotkey::new(4, &[Modifier::Opt, Modifier::Shift]),
        }
    }
}

impl HotkeySet {
    pub fn all(&self) -> [&Hotkey; 4] {
        [
            &self.screenshot,
            &self.clipboard,
            &self.color_picker,
            &self.toggle_pins,
        ]
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AppShortcut {
    pub target: String,
    pub path: String,
    pub key_code: u32,
    pub modifiers: Vec<Modifier>,
    pub enabled: bool,
}

impl Default for AppShortcut {
    fn default() -> Self {
        Self {
            target: String::new(),
            path: String::new(),
            key_code: 0,
            modifiers: Vec::new(),
            enabled: true,
        }
    }
}

impl AppShortcut {
    fn canonical(&self) -> String {
        Hotkey {
            key_code: self.key_code,
            modifiers: self.modifiers.clone(),
        }
        .canonical()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LinkShortcut {
    pub id: String,
    pub title: String,
    pub url: String,
    pub key_code: u32,
    pub modifiers: Vec<Modifier>,
    pub enabled: bool,
}

impl Default for LinkShortcut {
    fn default() -> Self {
        Self {
            id: String::new(),
            title: String::new(),
            url: String::new(),
            key_code: 0,
            modifiers: Vec::new(),
            enabled: true,
        }
    }
}

impl LinkShortcut {
    fn canonical(&self) -> String {
        Hotkey {
            key_code: self.key_code,
            modifiers: self.modifiers.clone(),
        }
        .canonical()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ColorFormat {
    Hex,
    Rgb,
    Hsl,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ClipboardConfig {
    pub enabled: bool,
    pub max_items: u32,
    pub retention_days: u32,
    pub max_image_mb: u64,
    pub max_text_kb: u64,
    pub excluded_apps: Vec<String>,
}

impl Default for ClipboardConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            max_items: 500,
            retention_days: 30,
            max_image_mb: 50,
            max_text_kb: 512,
            excluded_apps: vec![
                "com.agilebits.onepassword7".into(),
                "com.bitwarden.desktop".into(),
                "com.apple.keychainaccess".into(),
            ],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ScreenshotConfig {
    pub save_dir: String,
    pub color_format: ColorFormat,
    pub restore_pins: bool,
}

impl Default for ScreenshotConfig {
    fn default() -> Self {
        Self {
            save_dir: "~/Pictures/Olico".into(),
            color_format: ColorFormat::Hex,
            restore_pins: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ResidencyConfig {
    pub launch_at_login: bool,
}

impl Default for ResidencyConfig {
    fn default() -> Self {
        Self {
            launch_at_login: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub version: u32,
    pub hotkeys: HotkeySet,
    pub shortcuts: Vec<AppShortcut>,
    pub links: Vec<LinkShortcut>,
    pub clipboard: ClipboardConfig,
    pub screenshot: ScreenshotConfig,
    pub residency: ResidencyConfig,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            version: CONFIG_VERSION,
            hotkeys: HotkeySet::default(),
            shortcuts: Vec::new(),
            links: Vec::new(),
            clipboard: ClipboardConfig::default(),
            screenshot: ScreenshotConfig::default(),
            residency: ResidencyConfig::default(),
        }
    }
}

impl Config {
    pub fn load(dir: &Path) -> Result<Self> {
        let path = dir.join("config.json");
        if !path.exists() {
            let cfg = Config::default();
            cfg.save(dir)?;
            return Ok(cfg);
        }
        let value: serde_json::Value = serde_json::from_str(&fs::read_to_string(&path)?)?;
        let version = value.get("version").and_then(|v| v.as_u64()).unwrap_or(1) as u32;
        let migrated = version < CONFIG_VERSION;
        let cfg = match version {
            1 => Self::migrate_v1(value)?,
            v if v == CONFIG_VERSION => serde_json::from_value(value)?,
            v if v > CONFIG_VERSION => {
                return Err(CoreError::Config(format!(
                    "config version {v} is newer than supported {CONFIG_VERSION}"
                )));
            }
            v => return Err(CoreError::Config(format!("unsupported config version {v}"))),
        };
        cfg.validate()?;
        if migrated {
            cfg.save(dir)?;
        }
        Ok(cfg)
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        self.validate()?;
        fs::create_dir_all(dir)?;
        let tmp = dir.join("config.json.tmp");
        let final_path = dir.join("config.json");
        let bytes = serde_json::to_vec_pretty(self)?;
        let mut file = fs::File::create(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, &final_path)?;
        Ok(())
    }

    fn migrate_v1(value: serde_json::Value) -> Result<Self> {
        let mut cfg = Config::default();
        if let Some(clip) = value.get("clipboard") {
            if let Some(v) = clip.get("enabled").and_then(|v| v.as_bool()) {
                cfg.clipboard.enabled = v;
            }
            if let Some(v) = clip.get("max_items").and_then(|v| v.as_u64()) {
                cfg.clipboard.max_items = v as u32;
            }
            if let Some(v) = clip.get("retention_days").and_then(|v| v.as_u64()) {
                cfg.clipboard.retention_days = v as u32;
            }
            if let Some(apps) = clip.get("excluded_apps").and_then(|v| v.as_array()) {
                cfg.clipboard.excluded_apps = apps
                    .iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect();
            }
        }
        Ok(cfg)
    }

    pub fn validate(&self) -> Result<()> {
        if self.version != CONFIG_VERSION {
            return Err(CoreError::Config(format!(
                "unsupported config version {}, expected {CONFIG_VERSION}",
                self.version
            )));
        }
        if !(1..=10_000).contains(&self.clipboard.max_items) {
            return Err(CoreError::Config(
                "clipboard.max_items must be 1..=10000".into(),
            ));
        }
        if !(1..=3_650).contains(&self.clipboard.retention_days) {
            return Err(CoreError::Config(
                "clipboard.retention_days must be 1..=3650".into(),
            ));
        }
        if !(1..=1_024).contains(&self.clipboard.max_image_mb) {
            return Err(CoreError::Config(
                "clipboard.max_image_mb must be 1..=1024".into(),
            ));
        }
        if !(1..=10_240).contains(&self.clipboard.max_text_kb) {
            return Err(CoreError::Config(
                "clipboard.max_text_kb must be 1..=10240".into(),
            ));
        }
        if self.screenshot.save_dir.trim().is_empty() {
            return Err(CoreError::Config(
                "screenshot.save_dir must not be empty".into(),
            ));
        }

        let mut builtin = Vec::new();
        for hotkey in self.hotkeys.all() {
            let canonical = hotkey.canonical();
            if builtin.contains(&canonical) {
                return Err(CoreError::Config(format!(
                    "duplicate builtin hotkey {canonical}"
                )));
            }
            builtin.push(canonical);
        }

        let mut targets = Vec::new();
        let mut app_hotkeys = Vec::new();
        for shortcut in &self.shortcuts {
            if shortcut.target.trim().is_empty() {
                return Err(CoreError::Config(
                    "shortcut target must not be empty".into(),
                ));
            }
            if targets.contains(&shortcut.target) {
                return Err(CoreError::Config(format!(
                    "duplicate shortcut target {}",
                    shortcut.target
                )));
            }
            targets.push(shortcut.target.clone());
            if shortcut.enabled {
                let canonical = shortcut.canonical();
                if builtin.contains(&canonical) {
                    return Err(CoreError::Config(format!(
                        "shortcut {} conflicts with builtin hotkey {canonical}",
                        shortcut.target
                    )));
                }
                if app_hotkeys.contains(&canonical) {
                    return Err(CoreError::Config(format!(
                        "duplicate shortcut hotkey {canonical}"
                    )));
                }
                app_hotkeys.push(canonical);
            }
        }

        let mut link_ids = Vec::new();
        let mut link_hotkeys = Vec::new();
        for link in &self.links {
            if link.id.trim().is_empty() {
                return Err(CoreError::Config("link id must not be empty".into()));
            }
            if link_ids.contains(&link.id) {
                return Err(CoreError::Config(format!("duplicate link id {}", link.id)));
            }
            link_ids.push(link.id.clone());
            if link.title.trim().is_empty() {
                return Err(CoreError::Config(format!(
                    "link {} title must not be empty",
                    link.id
                )));
            }
            if !(link.url.starts_with("http://") || link.url.starts_with("https://")) {
                return Err(CoreError::Config(format!(
                    "link {} url must start with http(s)://",
                    link.id
                )));
            }
            if link.enabled {
                let canonical = link.canonical();
                if builtin.contains(&canonical) {
                    return Err(CoreError::Config(format!(
                        "link {} conflicts with builtin hotkey {canonical}",
                        link.id
                    )));
                }
                if app_hotkeys.contains(&canonical) {
                    return Err(CoreError::Config(format!(
                        "link {} conflicts with app shortcut hotkey {canonical}",
                        link.id
                    )));
                }
                if link_hotkeys.contains(&canonical) {
                    return Err(CoreError::Config(format!(
                        "duplicate link hotkey {canonical}"
                    )));
                }
                link_hotkeys.push(canonical);
            }
        }

        let mut excluded = self.clipboard.excluded_apps.clone();
        excluded.sort();
        excluded.dedup();
        if excluded.len() != self.clipboard.excluded_apps.len() {
            return Err(CoreError::Config(
                "clipboard.excluded_apps contains duplicates".into(),
            ));
        }

        Ok(())
    }
}
