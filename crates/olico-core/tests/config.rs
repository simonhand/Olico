use olico_core::config::{AppShortcut, Config, Hotkey, Modifier};
use std::fs;
use tempfile::tempdir;

#[test]
fn missing_config_is_created_with_defaults() {
    let dir = tempdir().unwrap();
    let cfg = Config::load(dir.path()).unwrap();
    assert_eq!(cfg.version, 2);
    assert_eq!(cfg.hotkeys.clipboard.key_code, 9);
    assert!(dir.path().join("config.json").exists());
    assert!(!dir.path().join("config.json.tmp").exists());
}

#[test]
fn save_then_load_roundtrips() {
    let dir = tempdir().unwrap();
    let mut cfg = Config::default();
    cfg.clipboard.max_items = 42;
    cfg.save(dir.path()).unwrap();
    let loaded = Config::load(dir.path()).unwrap();
    assert_eq!(loaded.clipboard.max_items, 42);
}

#[test]
fn v1_config_is_migrated_and_rewritten() {
    let dir = tempdir().unwrap();
    let v1 = r#"{
      "version": 1,
      "hotkey": {"mac": "alt+space", "windows": "alt+space"},
      "clipboard": {"enabled": true, "max_items": 77, "retention_days": 7,
                    "excluded_apps": ["com.example.secret"], "ignore_concealed": true}
    }"#;
    fs::write(dir.path().join("config.json"), v1).unwrap();
    let cfg = Config::load(dir.path()).unwrap();
    assert_eq!(cfg.version, 2);
    assert_eq!(cfg.clipboard.max_items, 77);
    assert_eq!(cfg.clipboard.retention_days, 7);
    assert_eq!(cfg.clipboard.excluded_apps, vec!["com.example.secret"]);
    let raw = fs::read_to_string(dir.path().join("config.json")).unwrap();
    assert!(raw.contains("\"version\": 2"));
}

#[test]
fn newer_config_version_is_rejected() {
    let dir = tempdir().unwrap();
    fs::write(dir.path().join("config.json"), r#"{"version": 99}"#).unwrap();
    let err = Config::load(dir.path()).unwrap_err();
    assert_eq!(err.code(), "config_error");
}

#[test]
fn duplicate_builtin_hotkey_is_rejected() {
    let mut cfg = Config::default();
    cfg.hotkeys.color_picker = cfg.hotkeys.screenshot.clone();
    assert_eq!(cfg.validate().unwrap_err().code(), "config_error");
}

#[test]
fn duplicate_target_is_rejected() {
    let mut cfg = Config::default();
    let shortcut = AppShortcut {
        target: "com.example.app".into(),
        path: "/Applications/Example.app".into(),
        key_code: 2,
        modifiers: vec![Modifier::Cmd],
        enabled: true,
    };
    cfg.shortcuts = vec![
        shortcut.clone(),
        AppShortcut {
            key_code: 3,
            ..shortcut
        },
    ];
    assert_eq!(cfg.validate().unwrap_err().code(), "config_error");
}

#[test]
fn invalid_limits_are_rejected() {
    let mut cfg = Config::default();
    cfg.clipboard.max_items = 0;
    assert_eq!(cfg.validate().unwrap_err().code(), "config_error");

    let mut cfg = Config::default();
    cfg.clipboard.max_image_mb = 0;
    assert_eq!(cfg.validate().unwrap_err().code(), "config_error");
}

#[test]
fn modifier_order_does_not_affect_duplicate_detection() {
    let mut cfg = Config::default();
    cfg.hotkeys.color_picker = Hotkey {
        key_code: 9,
        modifiers: vec![Modifier::Shift, Modifier::Cmd],
    };
    assert_eq!(cfg.validate().unwrap_err().code(), "config_error");
}
