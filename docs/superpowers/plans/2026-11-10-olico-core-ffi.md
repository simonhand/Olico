# Olico Core + FFI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 实现 Olico 的 Rust 核心与 C ABI：配置、剪贴板历史、分类板、模糊搜索、SQLite 持久化，并通过 JSON 协议暴露给 macOS 壳。

**Architecture:** `olico-core` 是纯 Rust 领域库，不依赖任何 macOS API；`olico-ffi` 只做 C ABI 包装（句柄、字符串所有权、panic 隔离）。平台层通过 `olico_dispatch` 发 JSON 请求，核心返回 JSON。本计划是 macOS MVP 的第一阶段，完成后可在终端中用 JSON 协议完整验证剪贴板能力。

**Tech Stack:** Rust 2021、rusqlite（bundled SQLite）、serde/serde_json、sha2、uuid、nucleo-matcher、thiserror、tempfile。

**Spec:** `docs/superpowers/specs/2026-11-10-olico-design.md`

## Global Constraints

- 最低 macOS 14；Rust stable，edition 2021。
- `olico-core` 不得引用 AppKit/Objective-C 或任何平台 API。
- JSON 协议版本固定为 `v: 1`；配置版本为 `2`；数据库 `PRAGMA user_version = 1`。
- 默认数据目录由调用方传入（macOS 为 `~/Library/Application Support/Olico/`）。
- 剪贴板默认上限：500 条、30 天、单图 50MB、文本 512KB；置顶与分类板内条目不受自动清理影响。
- 日志/错误信息不得包含剪贴板正文、文件名或图片内容。
- 内置热键默认值：截图 `⌥⇧S`（key_code 1）、剪贴板 `⌘⇧V`（key_code 9）、取色 `⌥⇧C`（key_code 8）、隐藏贴图 `⌥⇧H`（key_code 4），modifiers 使用字符串 `cmd/opt/ctrl/shift`。
- 分类板保留 ID `__pinned` 作为“已置顶”虚拟板；真实分类板 ID 为 UUID。
- 只允许向前迁移；无法识别的新版本配置必须返回错误，不得覆盖。
- 提交策略：仅在用户明确授权后执行 `git commit`；未授权时保留工作区改动。

---

## 文件结构

```
Cargo.toml                         # workspace
rust-toolchain.toml
VERSION
.gitignore
crates/olico-core/Cargo.toml
crates/olico-core/src/lib.rs
crates/olico-core/src/error.rs
crates/olico-core/src/model.rs
crates/olico-core/src/config.rs
crates/olico-core/src/hash.rs
crates/olico-core/src/db.rs
crates/olico-core/src/clipboard.rs
crates/olico-core/src/pinboard.rs
crates/olico-core/src/search.rs
crates/olico-core/src/dispatch.rs
crates/olico-core/tests/config.rs
crates/olico-core/tests/clipboard.rs
crates/olico-core/tests/pinboard.rs
crates/olico-core/tests/search.rs
crates/olico-core/tests/dispatch.rs
crates/olico-ffi/Cargo.toml
crates/olico-ffi/src/lib.rs
crates/olico-ffi/include/olico.h
crates/olico-ffi/tests/ffi_smoke.rs
shared/protocol.md
.github/workflows/ci.yml
```

职责：

- `model`：对外 JSON 类型，全部 `serde`。
- `config`：配置默认值、加载、原子保存、校验、v1→v2 迁移。
- `db`：连接、PRAGMA、schema 迁移、所有 SQL。
- `clipboard`：去重、排序、清理、文件回收。
- `pinboard`：分类板 CRUD 与关联。
- `search`：nucleo 模糊排序。
- `dispatch`：JSON op 路由。
- `ffi`：C ABI 与所有权。

---

### Task 1: Workspace 骨架与核心模型

**Files:**
- Create: `Cargo.toml`, `rust-toolchain.toml`, `VERSION`, `.gitignore`
- Create: `crates/olico-core/Cargo.toml`, `crates/olico-core/src/lib.rs`, `src/error.rs`, `src/model.rs`
- Test: `crates/olico-core/tests/model.rs`

**Interfaces:**
- Produces: `ClipboardKind`, `ClipboardItem`, `ClipboardQuery`（`normalized()`）、`NewClipboardItem`、`Pinboard`、`CoreError`、`Result<T>`。

- [x] **Step 1: 创建 workspace 与 core crate**

`Cargo.toml`：

```toml
[workspace]
resolver = "2"
members = ["crates/olico-core", "crates/olico-ffi"]

[workspace.package]
version = "0.1.0"
edition = "2021"
license = "MIT"
rust-version = "1.80"

[workspace.dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
rusqlite = { version = "0.32", features = ["bundled"] }
sha2 = "0.10"
nucleo-matcher = "0.3"
uuid = { version = "1", features = ["v4"] }
thiserror = "2"
tempfile = "3"
```

`rust-toolchain.toml`：

```toml
[toolchain]
channel = "stable"
components = ["rustfmt", "clippy"]
```

`VERSION`：`0.1.0`

`.gitignore`：

```
/target
**/*.rs.bk
.DS_Store
/build
```

`crates/olico-core/Cargo.toml`：

```toml
[package]
name = "olico-core"
version.workspace = true
edition.workspace = true
license.workspace = true
rust-version.workspace = true

[dependencies]
serde.workspace = true
serde_json.workspace = true
rusqlite.workspace = true
sha2.workspace = true
nucleo-matcher.workspace = true
uuid.workspace = true
thiserror.workspace = true

[dev-dependencies]
tempfile.workspace = true
```

- [x] **Step 2: 写失败测试**

`crates/olico-core/tests/model.rs`：

```rust
use olico_core::model::{ClipboardItem, ClipboardKind, ClipboardQuery};

#[test]
fn kind_serializes_snake_case() {
    assert_eq!(serde_json::to_string(&ClipboardKind::Text).unwrap(), "\"text\"");
    assert_eq!(serde_json::to_string(&ClipboardKind::Image).unwrap(), "\"image\"");
    assert_eq!(serde_json::to_string(&ClipboardKind::File).unwrap(), "\"file\"");
}

#[test]
fn query_defaults_to_100_and_zero_offset() {
    let q: ClipboardQuery = serde_json::from_str("{}").unwrap();
    assert_eq!(q.limit, 100);
    assert_eq!(q.offset, 0);
    assert!(q.text.is_empty());
}

#[test]
fn query_limit_is_clamped() {
    let high = ClipboardQuery { limit: 9999, ..Default::default() }.normalized();
    let zero = ClipboardQuery { limit: 0, ..Default::default() }.normalized();
    assert_eq!(high.limit, 500);
    assert_eq!(zero.limit, 1);
}

#[test]
fn item_roundtrips_with_optional_fields_absent() {
    let json = r#"{
        "id":"a","kind":"text","hash":"h","created_at":1
    }"#;
    let item: ClipboardItem = serde_json::from_str(json).unwrap();
    assert!(item.file_paths.is_empty());
    assert!(item.text.is_none());
    assert!(!item.pinned);
}
```

- [x] **Step 3: 运行测试确认失败**

Run: `cargo test -p olico-core --test model`
Expected: 编译失败，`olico_core::model` 不存在。

- [x] **Step 4: 实现 error 与 model**

`src/error.rs`：

```rust
#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("invalid payload: {0}")]
    InvalidPayload(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("config: {0}")]
    Config(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("db: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, CoreError>;

impl CoreError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidPayload(_) => "invalid_payload",
            Self::NotFound(_) => "not_found",
            Self::Config(_) => "config_error",
            Self::Io(_) => "io_error",
            Self::Db(_) => "db_error",
            Self::Json(_) => "invalid_payload",
        }
    }
}
```

`src/model.rs`：

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardKind {
    Text,
    Image,
    File,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipboardItem {
    pub id: String,
    pub kind: ClipboardKind,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub file_paths: Vec<String>,
    #[serde(default)]
    pub image_path: Option<String>,
    #[serde(default)]
    pub thumb_path: Option<String>,
    pub hash: String,
    #[serde(default)]
    pub source_bundle: Option<String>,
    #[serde(default)]
    pub source_name: Option<String>,
    #[serde(default)]
    pub byte_size: i64,
    pub created_at: i64,
    #[serde(default)]
    pub pinned: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewClipboardItem {
    pub kind: ClipboardKind,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub file_paths: Vec<String>,
    #[serde(default)]
    pub image_path: Option<String>,
    #[serde(default)]
    pub thumb_path: Option<String>,
    #[serde(default)]
    pub source_bundle: Option<String>,
    #[serde(default)]
    pub source_name: Option<String>,
    #[serde(default)]
    pub byte_size: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ClipboardQuery {
    pub text: String,
    pub board_id: Option<String>,
    pub kind: Option<ClipboardKind>,
    pub limit: u32,
    pub offset: u32,
}

impl Default for ClipboardQuery {
    fn default() -> Self {
        Self { text: String::new(), board_id: None, kind: None, limit: 100, offset: 0 }
    }
}

impl ClipboardQuery {
    pub fn normalized(self) -> Self {
        Self { limit: self.limit.clamp(1, 500), ..self }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Pinboard {
    pub id: String,
    pub name: String,
    pub color: String,
    pub sort_order: i32,
    pub created_at: i64,
    pub item_count: u32,
}
```

`src/lib.rs`：

```rust
pub mod error;
pub mod model;

pub use error::{CoreError, Result};
```

- [x] **Step 5: 运行测试确认通过**

Run: `cargo test -p olico-core --test model`
Expected: 4 passed.

- [x] **Step 6: 提交（需用户授权）**

```bash
git add Cargo.toml rust-toolchain.toml VERSION .gitignore crates/olico-core
git commit -m "feat(core): scaffold workspace and clipboard models"
```

---

### Task 2: 配置默认值、原子保存、校验与迁移

**Files:**
- Create: `crates/olico-core/src/config.rs`
- Modify: `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/config.rs`

**Interfaces:**
- Produces: `Config`（含 `load(dir)`、`save(dir)`、`validate()`）、`Hotkey`、`Modifier`、`AppShortcut`、`ClipboardConfig`、`ScreenshotConfig`、`ResidencyConfig`、`ColorFormat`。
- `Config::load` 对缺失文件写入默认配置；v1 配置迁移为 v2 并回写；版本高于 2 返回 `CoreError::Config`。

- [x] **Step 1: 写失败测试**

`crates/olico-core/tests/config.rs`：

```rust
use std::fs;
use olico_core::config::{AppShortcut, Config, Hotkey, Modifier};
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
    cfg.shortcuts = vec![shortcut.clone(), AppShortcut { key_code: 3, ..shortcut }];
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
    cfg.hotkeys.clipboard = Hotkey { key_code: 9, modifiers: vec![Modifier::Shift, Modifier::Cmd] };
    assert_eq!(cfg.validate().unwrap_err().code(), "config_error");
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `cargo test -p olico-core --test config`
Expected: 编译失败，`olico_core::config` 不存在。

- [x] **Step 3: 实现配置模块**

要点：

```rust
pub const CONFIG_VERSION: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Modifier { Cmd, Opt, Ctrl, Shift }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Hotkey { pub key_code: u32, pub modifiers: Vec<Modifier> }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct HotkeySet {
    pub screenshot: Hotkey,
    pub clipboard: Hotkey,
    pub color_picker: Hotkey,
    pub toggle_pins: Hotkey,
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

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ColorFormat { Hex, Rgb, Hsl }

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

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ScreenshotConfig {
    pub save_dir: String,
    pub color_format: ColorFormat,
    pub restore_pins: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ResidencyConfig { pub launch_at_login: bool }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub version: u32,
    pub hotkeys: HotkeySet,
    pub shortcuts: Vec<AppShortcut>,
    pub clipboard: ClipboardConfig,
    pub screenshot: ScreenshotConfig,
    pub residency: ResidencyConfig,
}
```

`Default` 必须给出全局约束中的默认值。`Modifier` 的 `Ord` 顺序即 `Cmd < Opt < Ctrl < Shift`，用于规范化。

`Hotkey::canonical()` 返回 `format!("{}:{:?}", key_code, sorted_modifiers)`（把 modifiers 排序去重）。

`Config::validate()` 规则：

```rust
if self.version != CONFIG_VERSION { return Err(CoreError::Config("unsupported config version".into())); }
if !(1..=10_000).contains(&self.clipboard.max_items) { ... }
if !(1..=3_650).contains(&self.clipboard.retention_days) { ... }
if !(1..=1_024).contains(&self.clipboard.max_image_mb) { ... }
if !(1..=10_240).contains(&self.clipboard.max_text_kb) { ... }
if self.screenshot.save_dir.trim().is_empty() { ... }
// 内置热键互相重复
// enabled 的应用热键互相重复，且不得与内置热键重复
// shortcuts.target 非空且不重复
// excluded_apps 去重后数量不变
```

`Config::save`：

```rust
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
```

`Config::load`：

```rust
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
    1 => Config::migrate_v1(value)?,
    v if v == CONFIG_VERSION => serde_json::from_value(value)?,
    v if v > CONFIG_VERSION => return Err(CoreError::Config(format!("config version {v} is newer than supported {CONFIG_VERSION}"))),
    v => return Err(CoreError::Config(format!("unsupported config version {v}"))),
};
cfg.validate()?;
if migrated { cfg.save(dir)?; }
Ok(cfg)
```

`migrate_v1` 保留 `clipboard.enabled/max_items/retention_days/excluded_apps`，其他字段使用默认值。

- [x] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test config`
Expected: 8 passed.

- [x] **Step 5: 提交（需用户授权）**

```bash
git add crates/olico-core/src/config.rs crates/olico-core/src/lib.rs crates/olico-core/tests/config.rs
git commit -m "feat(core): add versioned config with validation and migration"
```

---

### Task 3: SQLite schema 与迁移

**Files:**
- Create: `crates/olico-core/src/db.rs`
- Modify: `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/db.rs`

**Interfaces:**
- Produces: `Store::open(dir: &Path) -> Result<Store>`、`Store::schema_version(&self) -> Result<u32>`、`Store::journal_mode(&self) -> Result<String>`。
- 连接启用 `foreign_keys=ON`、WAL、2 秒 busy timeout。

- [x] **Step 1: 写失败测试**

`crates/olico-core/tests/db.rs`：

```rust
use olico_core::db::Store;
use tempfile::tempdir;

#[test]
fn open_creates_database_and_migrates() {
    let dir = tempdir().unwrap();
    let store = Store::open(dir.path()).unwrap();
    assert_eq!(store.schema_version().unwrap(), 1);
    assert!(dir.path().join("olico.db").exists());
}

#[test]
fn open_is_idempotent() {
    let dir = tempdir().unwrap();
    {
        let store = Store::open(dir.path()).unwrap();
        assert_eq!(store.schema_version().unwrap(), 1);
    }
    let store = Store::open(dir.path()).unwrap();
    assert_eq!(store.schema_version().unwrap(), 1);
}

#[test]
fn journal_mode_is_wal() {
    let dir = tempdir().unwrap();
    let store = Store::open(dir.path()).unwrap();
    assert_eq!(store.journal_mode().unwrap().to_lowercase(), "wal");
}

#[test]
fn foreign_keys_are_enabled() {
    let dir = tempdir().unwrap();
    let mut store = Store::open(dir.path()).unwrap();
    let err = store
        .execute_for_test(
            "INSERT INTO pinboard_items (board_id, item_id, added_at) VALUES ('missing', 'missing', 1)",
        )
        .unwrap_err();
    assert_eq!(err.code(), "db_error");
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `cargo test -p olico-core --test db`
Expected: 编译失败，`olico_core::db` 不存在。

- [x] **Step 3: 实现 Store**

`db.rs` 要点：

```rust
pub struct Store { conn: Connection }

impl Store {
    pub fn open(dir: &Path) -> Result<Self> {
        fs::create_dir_all(dir)?;
        let conn = Connection::open(dir.join("olico.db"))?;
        conn.busy_timeout(Duration::from_secs(2))?;
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<()> {
        let version: u32 = self.conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version < 1 {
            self.conn.execute_batch(SCHEMA_V1)?;
            self.conn.pragma_update(None, "user_version", 1)?;
        }
        Ok(())
    }

    pub fn schema_version(&self) -> Result<u32> { ... }
    pub fn journal_mode(&self) -> Result<String> { ... }
    pub fn execute_for_test(&mut self, sql: &str) -> Result<()> { self.conn.execute_batch(sql)?; Ok(()) }
}
```

`SCHEMA_V1` 使用 spec 5.6 的三张表与两个索引，全部 `IF NOT EXISTS`。

- [x] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test db`
Expected: 4 passed.

- [x] **Step 5: 提交（需用户授权）**

```bash
git add crates/olico-core/src/db.rs crates/olico-core/src/lib.rs crates/olico-core/tests/db.rs
git commit -m "feat(core): add sqlite store with schema migration"
```

---

### Task 4: 剪贴板写入、去重与查询

**Files:**
- Create: `crates/olico-core/src/hash.rs`, `crates/olico-core/src/clipboard.rs`, `crates/olico-core/src/search.rs`（先提供空排序占位）
- Modify: `crates/olico-core/src/db.rs`, `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/clipboard.rs`

**Interfaces:**
- Produces: `hash_text`, `hash_file`, `hash_files`；`Service::open(dir)`、`Service::clipboard_add(input, now)`、`Service::clipboard_list(query)`、`Service::clipboard_delete(id)`、`Service::clipboard_pin(id, pinned)`、`Service::clipboard_clear()`、`Service::now_ms()`。
- `Store` 新增：`insert_clipboard(&mut self, &ClipboardItem)`、`find_clipboard_by_hash(&self, &str)`、`touch_clipboard(&mut self, &str, i64)`、`list_clipboard_candidates(&self, Option<&str>, Option<ClipboardKind>)`、`delete_clipboard(&mut self, &str) -> Result<Option<ClipboardItem>>`、`set_pinned`、`clear_clipboard`、`referenced_files`。

- [x] **Step 1: 写失败测试**

`crates/olico-core/tests/clipboard.rs`：

```rust
use olico_core::clipboard::Service;
use olico_core::model::{ClipboardItem, ClipboardKind, ClipboardQuery, NewClipboardItem};
use tempfile::tempdir;

fn text_item(text: &str) -> NewClipboardItem {
    NewClipboardItem {
        kind: ClipboardKind::Text,
        text: Some(text.into()),
        file_paths: vec![],
        image_path: None,
        thumb_path: None,
        source_bundle: Some("com.example.editor".into()),
        source_name: Some("Editor".into()),
        byte_size: 0,
    }
}

fn add_text(service: &mut Service, text: &str, now: i64) -> ClipboardItem {
    service.clipboard_add(text_item(text), now).unwrap()
}

#[test]
fn text_is_stored_with_computed_hash_and_size() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let item = add_text(&mut service, "hello", 1_000);
    assert_eq!(item.kind, ClipboardKind::Text);
    assert_eq!(item.hash.len(), 64);
    assert_eq!(item.byte_size, 5);
    assert_eq!(item.created_at, 1_000);
    assert!(!item.pinned);
}

#[test]
fn identical_text_is_deduped_and_moves_to_top() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let first = add_text(&mut service, "same", 1_000);
    let second = add_text(&mut service, "same", 2_000);
    assert_eq!(first.id, second.id);
    assert_eq!(second.created_at, 2_000);
    let items = service.clipboard_list(ClipboardQuery::default()).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].created_at, 2_000);
}

#[test]
fn dedupe_preserves_pin() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let item = add_text(&mut service, "pinned", 1_000);
    service.clipboard_pin(&item.id, true).unwrap();
    let again = add_text(&mut service, "pinned", 2_000);
    assert!(again.pinned);
}

#[test]
fn list_orders_pinned_first_then_newest() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let a = add_text(&mut service, "a", 1_000);
    add_text(&mut service, "b", 2_000);
    add_text(&mut service, "c", 3_000);
    service.clipboard_pin(&a.id, true).unwrap();
    let items = service.clipboard_list(ClipboardQuery::default()).unwrap();
    let texts: Vec<_> = items.iter().map(|i| i.text.clone().unwrap()).collect();
    assert_eq!(texts, vec!["a", "c", "b"]);
}

#[test]
fn file_kind_hashes_sorted_paths() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let mut input = text_item("");
    input.kind = ClipboardKind::File;
    input.text = None;
    input.file_paths = vec!["/tmp/b".into(), "/tmp/a".into()];
    let first = service.clipboard_add(input.clone(), 1_000).unwrap();
    input.file_paths = vec!["/tmp/a".into(), "/tmp/b".into()];
    let second = service.clipboard_add(input, 2_000).unwrap();
    assert_eq!(first.hash, second.hash);
    assert_eq!(first.id, second.id);
}

#[test]
fn image_hash_uses_file_bytes() {
    let dir = tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("images")).unwrap();
    let image = dir.path().join("images/pic.png");
    std::fs::write(&image, b"PNGDATA").unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let input = NewClipboardItem {
        kind: ClipboardKind::Image,
        text: None,
        file_paths: vec![],
        image_path: Some(image.to_string_lossy().to_string()),
        thumb_path: None,
        source_bundle: None,
        source_name: None,
        byte_size: 0,
    };
    let item = service.clipboard_add(input, 1_000).unwrap();
    assert_eq!(item.byte_size, 7);
    assert_eq!(item.hash.len(), 64);
}

#[test]
fn delete_removes_item_and_files() {
    let dir = tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("images")).unwrap();
    let image = dir.path().join("images/pic.png");
    std::fs::write(&image, b"PNGDATA").unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let input = NewClipboardItem {
        kind: ClipboardKind::Image,
        text: None,
        file_paths: vec![],
        image_path: Some(image.to_string_lossy().to_string()),
        thumb_path: None,
        source_bundle: None,
        source_name: None,
        byte_size: 0,
    };
    let item = service.clipboard_add(input, 1_000).unwrap();
    service.clipboard_delete(&item.id).unwrap();
    assert!(!image.exists());
    assert!(service.clipboard_list(ClipboardQuery::default()).unwrap().is_empty());
}

#[test]
fn list_filters_by_kind_and_offset() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    add_text(&mut service, "a", 1_000);
    add_text(&mut service, "b", 2_000);
    let mut file_input = text_item("");
    file_input.kind = ClipboardKind::File;
    file_input.text = None;
    file_input.file_paths = vec!["/tmp/x".into()];
    service.clipboard_add(file_input, 3_000).unwrap();

    let files = service.clipboard_list(ClipboardQuery { kind: Some(ClipboardKind::File), ..Default::default() }).unwrap();
    assert_eq!(files.len(), 1);

    let paged = service.clipboard_list(ClipboardQuery { offset: 1, limit: 1, ..Default::default() }).unwrap();
    assert_eq!(paged.len(), 1);
    assert_eq!(paged[0].text.as_deref(), Some("b"));
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `cargo test -p olico-core --test clipboard`
Expected: 编译失败，`olico_core::clipboard` 不存在。

- [x] **Step 3: 实现 hash 与 Store 查询**

`hash.rs`：

```rust
pub fn hash_bytes(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

pub fn normalize_text(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

pub fn hash_text(text: &str) -> String { hash_bytes(normalize_text(text).as_bytes()) }

pub fn hash_file(path: &Path) -> Result<(String, i64)> {
    let bytes = std::fs::read(path)?;
    Ok((hash_bytes(&bytes), bytes.len() as i64))
}

pub fn hash_files(paths: &[String]) -> Result<String> {
    let mut sorted = paths.to_vec();
    sorted.sort();
    sorted.dedup();
    Ok(hash_bytes(&serde_json::to_vec(&sorted)?))
}
```

`Store` 实现：

- `row_to_item`：解析 `file_paths_json`（空字符串或 `NULL` 视为空数组），`kind` 从 `text` 映射。
- `insert_clipboard`：`INSERT INTO clipboard_items (...)`，参数顺序与 schema 一致。
- `find_clipboard_by_hash`：`... WHERE hash = ?1` + `OptionalExtension`。
- `touch_clipboard`：`UPDATE clipboard_items SET created_at = ?2 WHERE id = ?1`。
- `list_clipboard_candidates`：动态 WHERE：
  - `board_id == Some("__pinned")` → `pinned = 1`
  - 其他 board → `EXISTS (SELECT 1 FROM pinboard_items pi WHERE pi.item_id = clipboard_items.id AND pi.board_id = ?)`
  - `kind` → `kind = ?`
  - `ORDER BY created_at DESC`
- `set_pinned`、`delete_clipboard`（先 `get` 再 `DELETE` 并返回条目）、`clear_clipboard`（先收集全部条目再删除）、`referenced_files`（`SELECT image_path, thumb_path FROM clipboard_items`）。

- [x] **Step 4: 实现 Service 的写入/查询**

`Service` 字段：`data_dir: PathBuf`、`config: Config`、`store: Store`。

```rust
impl Service {
    pub fn open(dir: &Path) -> Result<Self> {
        let store = Store::open(dir)?;
        let config = Config::load(dir)?;
        let mut service = Self { data_dir: dir.to_path_buf(), config, store };
        service.cleanup_orphans()?;
        service.prune_at(Self::now_ms())?;
        Ok(service)
    }

    pub fn clipboard_add(&mut self, input: NewClipboardItem, now: i64) -> Result<ClipboardItem> { ... }
    pub fn clipboard_list(&self, query: ClipboardQuery) -> Result<Vec<ClipboardItem>> { ... }
    pub fn clipboard_delete(&mut self, id: &str) -> Result<()> { ... }
    pub fn clipboard_pin(&mut self, id: &str, pinned: bool) -> Result<()> { ... }
    pub fn clipboard_clear(&mut self) -> Result<()> { ... }
    pub fn now_ms() -> i64 { ... }
}
```

`clipboard_add`：

1. 按 kind 计算 hash 与推断 `byte_size`（文本用字节数；图片读文件字节数；文件保留传入值）。
2. `find_clipboard_by_hash` 命中 → `touch_clipboard` → 返回更新了 `created_at` 的既有条目（保留 pinned）。
3. 未命中 → 构造 `ClipboardItem`（`id = Uuid::new_v4()`、`pinned = false`），插入。
4. 调用 `self.prune_at(now)`。
5. 返回条目。

`clipboard_list`：

```rust
let q = query.normalized();
let items = self.store.list_clipboard_candidates(q.board_id.as_deref(), q.kind)?;
let ordered = if q.text.trim().is_empty() {
    let mut items = items;
    items.sort_by(|a, b| b.pinned.cmp(&a.pinned).then_with(|| b.created_at.cmp(&a.created_at)));
    items
} else {
    search::rank(items, q.text.trim())
};
Ok(ordered.into_iter().skip(q.offset as usize).take(q.limit as usize).collect())
```

Task 4 的 `search::rank` 先实现为“按 `text` 是否包含关键字过滤 + 时间倒序”，Task 7 替换为 nucleo。

- [x] **Step 5: 运行测试确认通过**

Run: `cargo test -p olico-core --test clipboard`
Expected: 8 passed.

- [x] **Step 6: 提交（需用户授权）**

```bash
git add crates/olico-core
git commit -m "feat(core): add clipboard service with dedupe and query"
```

---

### Task 5: 保留策略、置顶保护与孤儿文件回收

**Files:**
- Modify: `crates/olico-core/src/db.rs`, `crates/olico-core/src/clipboard.rs`
- Test: `crates/olico-core/tests/clipboard.rs`（追加）

**Interfaces:**
- Produces: `Store::prune(&mut self, cfg: &ClipboardConfig, now: i64) -> Result<Vec<ClipboardFiles>>`、`Store::all_files(&self) -> Result<Vec<ClipboardFiles>>`、`Service::cleanup_orphans()`。
- `ClipboardFiles { image_path: Option<String>, thumb_path: Option<String> }`。

- [x] **Step 1: 追加失败测试**

```rust
#[test]
fn max_items_keeps_newest_and_removes_files() {
    let dir = tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("images")).unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    service.config_mut_for_test().clipboard.max_items = 3;
    let mut paths = Vec::new();
    for (i, text) in ["a", "b", "c", "d", "e"].iter().enumerate() {
        let image = dir.path().join(format!("images/{i}.png"));
        std::fs::write(&image, format!("img{i}")).unwrap();
        paths.push(image);
        let input = NewClipboardItem {
            kind: ClipboardKind::Image,
            text: Some(text.to_string()),
            file_paths: vec![],
            image_path: Some(image.to_string_lossy().to_string()),
            thumb_path: None,
            source_bundle: None,
            source_name: None,
            byte_size: 0,
        };
        service.clipboard_add(input, 1_000 + i as i64).unwrap();
    }
    let items = service.clipboard_list(ClipboardQuery::default()).unwrap();
    assert_eq!(items.len(), 3);
    assert_eq!(items[0].text.as_deref(), Some("e"));
    assert!(!paths[0].exists());
    assert!(!paths[1].exists());
    assert!(paths[4].exists());
}

#[test]
fn retention_days_removes_old_items() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    add_text(&mut service, "old", 1_000);
    add_text(&mut service, "new", 1_000 + 31 * 86_400_000);
    service.prune_at_for_test(1_000 + 31 * 86_400_000).unwrap();
    let items = service.clipboard_list(ClipboardQuery::default()).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].text.as_deref(), Some("new"));
}

#[test]
fn pinned_and_boarded_items_survive_max_items() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    service.config_mut_for_test().clipboard.max_items = 1;
    let pinned = add_text(&mut service, "pinned", 1_000);
    service.clipboard_pin(&pinned.id, true).unwrap();
    let boarded = add_text(&mut service, "boarded", 2_000);
    let board = service.pinboard_create("Keep", "#0A84FF").unwrap();
    service.pinboard_add_item(&board.id, &boarded.id).unwrap();
    add_text(&mut service, "newest", 3_000);
    add_text(&mut service, "newer", 4_000);
    let items = service.clipboard_list(ClipboardQuery::default()).unwrap();
    let texts: Vec<_> = items.iter().map(|i| i.text.clone().unwrap()).collect();
    assert!(texts.contains(&"pinned".to_string()));
    assert!(texts.contains(&"boarded".to_string()));
    assert!(texts.contains(&"newer".to_string()));
    assert!(!texts.contains(&"newest".to_string()));
}

#[test]
fn orphan_files_are_cleaned_on_open() {
    let dir = tempdir().unwrap();
    {
        let mut service = Service::open(dir.path()).unwrap();
        std::fs::create_dir_all(dir.path().join("images")).unwrap();
        std::fs::create_dir_all(dir.path().join("thumbnails")).unwrap();
        let image = dir.path().join("images/keep.png");
        std::fs::write(&image, b"keep").unwrap();
        let input = NewClipboardItem {
            kind: ClipboardKind::Image,
            text: None,
            file_paths: vec![],
            image_path: Some(image.to_string_lossy().to_string()),
            thumb_path: None,
            source_bundle: None,
            source_name: None,
            byte_size: 0,
        };
        service.clipboard_add(input, 1_000).unwrap();
        std::fs::write(dir.path().join("images/orphan.png"), b"orphan").unwrap();
        std::fs::write(dir.path().join("thumbnails/orphan.png"), b"orphan").unwrap();
    }
    let _service = Service::open(dir.path()).unwrap();
    assert!(dir.path().join("images/keep.png").exists());
    assert!(!dir.path().join("images/orphan.png").exists());
    assert!(!dir.path().join("thumbnails/orphan.png").exists());
}
```

为测试暴露：

```rust
impl Service {
    pub fn config_mut_for_test(&mut self) -> &mut Config { &mut self.config }
    pub fn prune_at_for_test(&mut self, now: i64) -> Result<()> { self.prune_at(now) }
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `cargo test -p olico-core --test clipboard`
Expected: 编译失败或断言失败（清理未实现）。

- [x] **Step 3: 实现 prune 与孤儿回收**

`Store::prune` 在一个事务中：

1. 过期：`created_at < cutoff AND pinned = 0 AND id NOT IN (SELECT item_id FROM pinboard_items)`。
2. 超额：非保护条目按 `created_at DESC` 取第 `max_items` 条之后的所有条目。
3. 合并 ID 集合，先查 `image_path/thumb_path`，再 `DELETE`。
4. 返回文件路径。

`Service::prune_at` 删除文件。`remove_files` 只删除 `data_dir` 下的路径：

```rust
fn remove_files(&self, files: &[ClipboardFiles]) {
    for file in files {
        for path in [&file.image_path, &file.thumb_path].into_iter().flatten() {
            let path = PathBuf::from(path);
            if path.starts_with(&self.data_dir) {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}
```

`cleanup_orphans` 对比 `store.referenced_files()` 的文件名集合与 `images/`、`thumbnails/` 下的文件，删除未引用文件；目录不存在时跳过。

- [x] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test clipboard`
Expected: 12 passed.

- [x] **Step 5: 提交（需用户授权）**

```bash
git add crates/olico-core
git commit -m "feat(core): enforce clipboard retention and reclaim files"
```

---

### Task 6: 分类板 CRUD

**Files:**
- Create: `crates/olico-core/src/pinboard.rs`
- Modify: `crates/olico-core/src/clipboard.rs`, `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/pinboard.rs`

**Interfaces:**
- Produces: `Service::pinboard_create(name, color) -> Result<Pinboard>`、`pinboard_rename(id, name)`、`pinboard_delete(id)`、`pinboard_list() -> Result<Vec<Pinboard>>`、`pinboard_add_item(board_id, item_id)`、`pinboard_remove_item(board_id, item_id)`。
- 名称去首尾空白且不可为空；颜色为空时使用 `#0A84FF`。

- [x] **Step 1: 写失败测试**

```rust
use olico_core::clipboard::Service;
use olico_core::model::{ClipboardKind, ClipboardQuery, NewClipboardItem};
use tempfile::tempdir;

fn add(service: &mut Service, text: &str, now: i64) -> String {
    service.clipboard_add(NewClipboardItem {
        kind: ClipboardKind::Text,
        text: Some(text.into()),
        file_paths: vec![], image_path: None, thumb_path: None,
        source_bundle: None, source_name: None, byte_size: 0,
    }, now).unwrap().id
}

#[test]
fn create_list_and_count() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let board = service.pinboard_create(" 工作 ", "").unwrap();
    assert_eq!(board.name, "工作");
    assert_eq!(board.color, "#0A84FF");
    let item = add(&mut service, "x", 1);
    service.pinboard_add_item(&board.id, &item).unwrap();
    let boards = service.pinboard_list().unwrap();
    assert_eq!(boards.len(), 1);
    assert_eq!(boards[0].item_count, 1);
}

#[test]
fn add_and_remove_item() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let board = service.pinboard_create("B", "#FF0000").unwrap();
    let item = add(&mut service, "x", 1);
    service.pinboard_add_item(&board.id, &item).unwrap();
    let filtered = service.clipboard_list(ClipboardQuery { board_id: Some(board.id.clone()), ..Default::default() }).unwrap();
    assert_eq!(filtered.len(), 1);
    service.pinboard_remove_item(&board.id, &item).unwrap();
    let filtered = service.clipboard_list(ClipboardQuery { board_id: Some(board.id.clone()), ..Default::default() }).unwrap();
    assert!(filtered.is_empty());
}

#[test]
fn deleting_board_keeps_items() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let board = service.pinboard_create("B", "#FF0000").unwrap();
    let item = add(&mut service, "x", 1);
    service.pinboard_add_item(&board.id, &item).unwrap();
    service.pinboard_delete(&board.id).unwrap();
    assert!(service.pinboard_list().unwrap().is_empty());
    assert_eq!(service.clipboard_list(ClipboardQuery::default()).unwrap().len(), 1);
}

#[test]
fn rename_rejects_empty() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let board = service.pinboard_create("B", "#FF0000").unwrap();
    assert_eq!(service.pinboard_rename(&board.id, "   ").unwrap_err().code(), "invalid_payload");
}

#[test]
fn missing_item_or_board_is_not_found() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let board = service.pinboard_create("B", "#FF0000").unwrap();
    assert_eq!(service.pinboard_add_item(&board.id, "missing").unwrap_err().code(), "not_found");
    assert_eq!(service.pinboard_add_item("missing", "missing").unwrap_err().code(), "not_found");
}

#[test]
fn pinned_virtual_board_returns_only_pinned() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let a = add(&mut service, "a", 1);
    add(&mut service, "b", 2);
    service.clipboard_pin(&a, true).unwrap();
    let items = service.clipboard_list(ClipboardQuery { board_id: Some("__pinned".into()), ..Default::default() }).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].text.as_deref(), Some("a"));
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `cargo test -p olico-core --test pinboard`
Expected: 编译失败或 `not implemented`。

- [x] **Step 3: 实现 pinboard 模块**

`Store` 新增方法（全部 `&mut self` 除 `list_pinboards`）：

- `insert_pinboard`：`sort_order = COALESCE(MAX(sort_order), 0) + 1`。
- `rename_pinboard`：返回受影响行数，0 → `NotFound`。
- `delete_pinboard`：依赖 FK 级联删除关联；0 行 → `NotFound`。
- `list_pinboards`：`LEFT JOIN pinboard_items` 聚合 `COUNT`，按 `sort_order, created_at` 排序。
- `board_exists`、`item_exists`。
- `add_pinboard_item`：先校验 board 与 item 存在 → `INSERT OR IGNORE`。
- `remove_pinboard_item`：删除关联；不存在时仍返回 `Ok(())`（幂等）。

`Service` 方法负责名称/颜色清洗与错误映射。

- [x] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test pinboard`
Expected: 6 passed.

- [x] **Step 5: 提交（需用户授权）**

```bash
git add crates/olico-core
git commit -m "feat(core): add pinboards and item associations"
```

---

### Task 7: nucleo 模糊搜索

**Files:**
- Modify: `crates/olico-core/src/search.rs`
- Test: `crates/olico-core/tests/search.rs`

**Interfaces:**
- Produces: `search::rank(items: Vec<ClipboardItem>, query: &str) -> Vec<ClipboardItem>`。
- 字段权重：`text` 1.0、`file_paths` 0.8、`source_name` 0.4；同分按 `created_at` 倒序。

- [x] **Step 1: 写失败测试**

```rust
use olico_core::model::{ClipboardItem, ClipboardKind};
use olico_core::search::rank;

fn item(id: &str, text: &str, files: &[&str], source: &str, created_at: i64) -> ClipboardItem {
    ClipboardItem {
        id: id.into(),
        kind: ClipboardKind::Text,
        text: Some(text.into()),
        file_paths: files.iter().map(|s| s.to_string()).collect(),
        image_path: None,
        thumb_path: None,
        hash: id.into(),
        source_bundle: None,
        source_name: Some(source.into()),
        byte_size: 0,
        created_at,
        pinned: false,
    }
}

#[test]
fn text_match_outranks_source_match() {
    let items = vec![
        item("text", "quarterly report", &[], "Safari", 1),
        item("source", "hello", &[], "Reportly", 2),
    ];
    let ranked = rank(items, "report");
    assert_eq!(ranked[0].id, "text");
    assert_eq!(ranked.len(), 2);
}

#[test]
fn file_path_is_searchable() {
    let items = vec![
        item("file", "", &["/Users/me/Documents/report.pdf"], "Finder", 1),
        item("other", "notes", &[], "Editor", 2),
    ];
    let ranked = rank(items, "report");
    assert_eq!(ranked.len(), 1);
    assert_eq!(ranked[0].id, "file");
}

#[test]
fn chinese_query_matches() {
    let items = vec![
        item("cn", "季度报告 2026", &[], "Pages", 1),
        item("en", "quarterly report", &[], "Pages", 2),
    ];
    let ranked = rank(items, "报告");
    assert_eq!(ranked.len(), 1);
    assert_eq!(ranked[0].id, "cn");
}

#[test]
fn no_match_returns_empty() {
    let items = vec![item("a", "hello", &[], "Safari", 1)];
    assert!(rank(items, "zzzzz").is_empty());
}

#[test]
fn ties_follow_created_at_desc() {
    let items = vec![
        item("old", "needle", &[], "Safari", 1),
        item("new", "needle", &[], "Safari", 2),
    ];
    let ranked = rank(items, "needle");
    assert_eq!(ranked[0].id, "new");
}

#[test]
fn case_insensitive_match() {
    let items = vec![item("a", "Hello World", &[], "Safari", 1)];
    assert_eq!(rank(items, "hello").len(), 1);
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `cargo test -p olico-core --test search`
Expected: 失败（当前占位实现只做包含匹配，中文与路径用例失败）。

- [x] **Step 3: 实现 nucleo 排序**

```rust
use nucleo_matcher::{Config, Matcher};

pub fn rank(items: Vec<ClipboardItem>, query: &str) -> Vec<ClipboardItem> {
    let mut matcher = Matcher::new(Config::DEFAULT);
    let needle = query.to_lowercase();
    let mut scored: Vec<(f64, i64, usize, ClipboardItem)> = Vec::new();
    for (index, item) in items.into_iter().enumerate() {
        let mut score = 0.0f64;
        if let Some(text) = &item.text {
            if let Some(s) = matcher.fuzzy_match(&text.to_lowercase(), &needle) {
                score += s as f64;
            }
        }
        let files = item.file_paths.join("\n").to_lowercase();
        if !files.is_empty() {
            if let Some(s) = matcher.fuzzy_match(&files, &needle) {
                score += s as f64 * 0.8;
            }
        }
        if let Some(source) = &item.source_name {
            if let Some(s) = matcher.fuzzy_match(&source.to_lowercase(), &needle) {
                score += s as f64 * 0.4;
            }
        }
        if score > 0.0 {
            scored.push((score, item.created_at, index, item));
        }
    }
    scored.sort_by(|a, b| {
        b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.1.cmp(&a.1))
            .then_with(|| a.2.cmp(&b.2))
    });
    scored.into_iter().map(|(_, _, _, item)| item).collect()
}
```

若 `nucleo_matcher` 的 `fuzzy_match` 需要 `Utf32Str`，改用：

```rust
matcher.fuzzy_match(Utf32Str::new(&haystack, &mut buf), Utf32Str::new(&needle, &mut buf2))
```

实现时以编译结果为准，语义不变。

- [x] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test search`
Expected: 6 passed.

- [x] **Step 5: 提交（需用户授权）**

```bash
git add crates/olico-core
git commit -m "feat(core): rank clipboard with nucleo fuzzy matching"
```

---

### Task 8: JSON 调度层

**Files:**
- Create: `crates/olico-core/src/dispatch.rs`
- Modify: `crates/olico-core/src/clipboard.rs`, `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/dispatch.rs`

**Interfaces:**
- Produces: `olico_core::dispatch::dispatch(&mut Service, &str) -> String`；成功 `{"v":1,"ok":true,"data":...}`；失败 `{"v":1,"ok":false,"error":{"code","message"}}`。
- `Service` 新增 `config() -> &Config`、`set_config(Config) -> Result<()>`。

- [x] **Step 1: 写失败测试**

```rust
use olico_core::clipboard::Service;
use olico_core::dispatch::dispatch;
use serde_json::Value;
use tempfile::tempdir;

fn call(service: &mut Service, body: &str) -> Value {
    serde_json::from_str(&dispatch(service, body)).unwrap()
}

#[test]
fn config_get_returns_defaults() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let res = call(&mut service, r#"{"v":1,"op":"config_get","payload":{}}"#);
    assert_eq!(res["ok"], true);
    assert_eq!(res["data"]["version"], 2);
    assert_eq!(res["data"]["hotkeys"]["clipboard"]["key_code"], 9);
}

#[test]
fn clipboard_add_then_list() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let add = call(&mut service, r#"{"v":1,"op":"clipboard_add","payload":{"kind":"text","text":"hello"}}"#);
    assert_eq!(add["ok"], true);
    let list = call(&mut service, r#"{"v":1,"op":"clipboard_list","payload":{}}"#);
    assert_eq!(list["data"][0]["text"], "hello");
}

#[test]
fn unknown_op_returns_error() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let res = call(&mut service, r#"{"v":1,"op":"nope","payload":{}}"#);
    assert_eq!(res["ok"], false);
    assert_eq!(res["error"]["code"], "unknown_op");
}

#[test]
fn invalid_json_returns_error() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let res = call(&mut service, "not json");
    assert_eq!(res["error"]["code"], "invalid_payload");
}

#[test]
fn unsupported_protocol_version_is_rejected() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let res = call(&mut service, r#"{"v":2,"op":"config_get","payload":{}}"#);
    assert_eq!(res["error"]["code"], "invalid_payload");
}

#[test]
fn config_set_persists() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let mut config: Value = call(&mut service, r#"{"v":1,"op":"config_get","payload":{}}"#)["data"].clone();
    config["clipboard"]["max_items"] = 11.into();
    let body = serde_json::json!({"v":1,"op":"config_set","payload":{"config":config}}).to_string();
    let res = call(&mut service, &body);
    assert_eq!(res["ok"], true);
    let raw = std::fs::read_to_string(dir.path().join("config.json")).unwrap();
    assert!(raw.contains("\"max_items\": 11"));
}

#[test]
fn pinboard_ops_roundtrip() {
    let dir = tempdir().unwrap();
    let mut service = Service::open(dir.path()).unwrap();
    let created = call(&mut service, r#"{"v":1,"op":"pinboard_create","payload":{"name":"Work","color":"#FF0000"}}"#);
    let board_id = created["data"]["id"].as_str().unwrap().to_string();
    let list = call(&mut service, r#"{"v":1,"op":"pinboard_list","payload":{}}"#);
    assert_eq!(list["data"][0]["name"], "Work");
    let renamed = call(&mut service, &serde_json::json!({"v":1,"op":"pinboard_rename","payload":{"id":board_id,"name":"Job"}}).to_string());
    assert_eq!(renamed["ok"], true);
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `cargo test -p olico-core --test dispatch`
Expected: 编译失败，`dispatch` 不存在。

- [x] **Step 3: 实现 dispatch**

```rust
#[derive(serde::Deserialize)]
struct Request {
    #[serde(default = "protocol_version")]
    v: u32,
    op: String,
    #[serde(default)]
    payload: serde_json::Value,
}
fn protocol_version() -> u32 { 1 }

pub fn dispatch(service: &mut Service, raw: &str) -> String {
    match handle(service, raw) {
        Ok(data) => serde_json::json!({"v":1,"ok":true,"data":data}).to_string(),
        Err(err) => serde_json::json!({
            "v":1,"ok":false,
            "error":{"code":err.code(),"message":err.to_string()}
        }).to_string(),
    }
}

fn handle(service: &mut Service, raw: &str) -> Result<serde_json::Value> {
    let request: Request = serde_json::from_str(raw)?;
    if request.v != 1 { return Err(CoreError::InvalidPayload(format!("unsupported protocol version {}", request.v))); }
    match request.op.as_str() {
        "clipboard_add" => {
            let input: NewClipboardItem = serde_json::from_value(request.payload)?;
            Ok(serde_json::to_value(service.clipboard_add(input, Service::now_ms())?)?)
        }
        "clipboard_list" => {
            let query: ClipboardQuery = serde_json::from_value(request.payload)?;
            Ok(serde_json::to_value(service.clipboard_list(query)?)?)
        }
        "clipboard_delete" => { let p: IdPayload = ...; service.clipboard_delete(&p.id)?; Ok(serde_json::json!({})) }
        "clipboard_pin" => { ... }
        "clipboard_clear" => { ... }
        "maintenance_prune" => { service.prune()?; Ok(serde_json::json!({})) }
        "pinboard_create" => { ... }
        "pinboard_rename" => { ... }
        "pinboard_delete" => { ... }
        "pinboard_list" => { ... }
        "pinboard_add_item" => { ... }
        "pinboard_remove_item" => { ... }
        "config_get" => Ok(serde_json::to_value(service.config())?),
        "config_set" => {
            #[derive(serde::Deserialize)] struct P { config: Config }
            let p: P = serde_json::from_value(request.payload)?;
            service.set_config(p.config)?;
            Ok(serde_json::json!({}))
        }
        other => Err(CoreError::InvalidPayload(format!("unknown op {other}"))),
    }
}
```

`unknown_op` 需要独立错误码：在 `CoreError` 增加 `UnknownOp(String)` 映射到 `"unknown_op"`，或 dispatch 直接构造错误响应。实现时在 `CoreError` 添加该变体。

- [x] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test dispatch`
Expected: 7 passed.

- [x] **Step 5: 提交（需用户授权）**

```bash
git add crates/olico-core
git commit -m "feat(core): expose json dispatch protocol"
```

---

### Task 9: FFI crate、头文件与协议文档

**Files:**
- Create: `crates/olico-ffi/Cargo.toml`, `crates/olico-ffi/src/lib.rs`, `crates/olico-ffi/include/olico.h`, `crates/olico-ffi/tests/ffi_smoke.rs`, `shared/protocol.md`

**Interfaces:**
- 导出四个 C 函数：`olico_core_new`、`olico_core_free`、`olico_dispatch`、`olico_string_free`。
- 句柄 `*mut OlicoHandle` 内部 `Mutex<Service>`；所有入口 `catch_unwind`；空指针与非法 UTF-8 返回错误 JSON。

- [x] **Step 1: 写失败测试**

`crates/olico-ffi/tests/ffi_smoke.rs`：

```rust
use std::ffi::{CStr, CString};
use olico_ffi::{olico_core_free, olico_core_new, olico_dispatch, olico_string_free};
use tempfile::tempdir;

unsafe fn take_string(ptr: *mut std::ffi::c_char) -> String {
    assert!(!ptr.is_null());
    let text = CStr::from_ptr(ptr).to_string_lossy().into_owned();
    olico_string_free(ptr);
    text
}

#[test]
fn config_get_via_ffi() {
    let dir = tempdir().unwrap();
    let path = CString::new(dir.path().to_str().unwrap()).unwrap();
    unsafe {
        let handle = olico_core_new(path.as_ptr());
        assert!(!handle.is_null());
        let request = CString::new(r#"{"v":1,"op":"config_get","payload":{}}"#).unwrap();
        let response = take_string(olico_dispatch(handle, request.as_ptr()));
        assert!(response.contains("\"ok\":true"));
        olico_core_free(handle);
    }
}

#[test]
fn clipboard_roundtrip_via_ffi() {
    let dir = tempdir().unwrap();
    let path = CString::new(dir.path().to_str().unwrap()).unwrap();
    unsafe {
        let handle = olico_core_new(path.as_ptr());
        let add = CString::new(r#"{"v":1,"op":"clipboard_add","payload":{"kind":"text","text":"ffi"}}"#).unwrap();
        let response = take_string(olico_dispatch(handle, add.as_ptr()));
        assert!(response.contains("\"ok\":true"));
        let list = CString::new(r#"{"v":1,"op":"clipboard_list","payload":{}}"#).unwrap();
        let response = take_string(olico_dispatch(handle, list.as_ptr()));
        assert!(response.contains("\"text\":\"ffi\""));
        olico_core_free(handle);
    }
}

#[test]
fn invalid_json_returns_error_json() {
    let dir = tempdir().unwrap();
    let path = CString::new(dir.path().to_str().unwrap()).unwrap();
    unsafe {
        let handle = olico_core_new(path.as_ptr());
        let request = CString::new("not json").unwrap();
        let response = take_string(olico_dispatch(handle, request.as_ptr()));
        assert!(response.contains("\"ok\":false"));
        assert!(response.contains("invalid_payload"));
        olico_core_free(handle);
    }
}

#[test]
fn null_handle_returns_error_json() {
    unsafe {
        let request = CString::new(r#"{"v":1,"op":"config_get","payload":{}}"#).unwrap();
        let response = take_string(olico_dispatch(std::ptr::null_mut(), request.as_ptr()));
        assert!(response.contains("\"ok\":false"));
    }
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `cargo test -p olico-ffi`
Expected: 编译失败，crate 不存在。

- [x] **Step 3: 实现 FFI**

`crates/olico-ffi/Cargo.toml`：

```toml
[package]
name = "olico-ffi"
version.workspace = true
edition.workspace = true
license.workspace = true
rust-version.workspace = true

[lib]
crate-type = ["staticlib", "rlib"]

[dependencies]
olico-core = { path = "../olico-core" }

[dev-dependencies]
tempfile.workspace = true
```

`src/lib.rs` 要点：

```rust
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::Mutex;

pub struct OlicoHandle { service: Mutex<Service> }

fn json_error(code: &str, message: &str) -> *mut c_char {
    let body = serde_json::json!({"v":1,"ok":false,"error":{"code":code,"message":message}}).to_string();
    CString::new(body).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn olico_core_new(data_dir: *const c_char) -> *mut OlicoHandle {
    if data_dir.is_null() { return std::ptr::null_mut(); }
    catch_unwind(|| {
        let Ok(dir) = CStr::from_ptr(data_dir).to_str() else { return std::ptr::null_mut() };
        match Service::open(Path::new(dir)) {
            Ok(service) => Box::into_raw(Box::new(OlicoHandle { service: Mutex::new(service) })),
            Err(_) => std::ptr::null_mut(),
        }
    }).unwrap_or(std::ptr::null_mut())
}
```

`olico_dispatch`：

```rust
if handle.is_null() || request.is_null() { return json_error("invalid_handle", "null handle or request"); }
catch_unwind(AssertUnwindSafe(|| {
    let Ok(raw) = CStr::from_ptr(request).to_str() else { return json_error("invalid_payload", "request is not valid utf-8") };
    let handle = &*handle;
    let mut service = match handle.service.lock() { Ok(s) => s, Err(_) => return json_error("internal_error", "lock poisoned") };
    let response = olico_core::dispatch::dispatch(&mut service, raw);
    CString::new(response).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
})).unwrap_or_else(|_| json_error("internal_error", "panic"))
```

`olico_string_free`：

```rust
#[no_mangle]
pub unsafe extern "C" fn olico_string_free(ptr: *mut c_char) {
    if !ptr.is_null() { drop(CString::from_raw(ptr)); }
}
```

`include/olico.h`：

```c
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OlicoHandle OlicoHandle;

OlicoHandle *olico_core_new(const char *data_dir);
void olico_core_free(OlicoHandle *handle);
char *olico_dispatch(OlicoHandle *handle, const char *request_json);
void olico_string_free(char *ptr);

#ifdef __cplusplus
}
#endif
```

- [x] **Step 4: 写协议文档**

`shared/protocol.md`：记录四个 C 函数、请求/响应示例、全部 op 的 payload、`__pinned` 虚拟分类板、配置 v2 关键字段、字符串所有权规则。内容与 spec 5.3、5.4 一致。

- [x] **Step 5: 运行测试确认通过**

Run: `cargo test -p olico-ffi`
Expected: 4 passed.

Run: `cargo build --release -p olico-ffi --target aarch64-apple-darwin`
Expected: 生成 `target/aarch64-apple-darwin/release/libolico_ffi.a`（若该 target 未安装，先 `rustup target add aarch64-apple-darwin`）。

- [x] **Step 6: 提交（需用户授权）**

```bash
git add crates/olico-ffi shared/protocol.md
git commit -m "feat(ffi): expose core over c abi"
```

---

### Task 10: CI 与全量门禁

**Files:**
- Create: `.github/workflows/ci.yml`

- [x] **Step 1: 添加 CI**

```yaml
name: ci
on:
  push:
  pull_request:

jobs:
  rust:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy
      - uses: Swatinem/rust-cache@v2
      - run: cargo fmt --all --check
      - run: cargo clippy --workspace --all-targets -- -D warnings
      - run: cargo test --workspace
```

- [x] **Step 2: 本地跑全量门禁**

Run:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

Expected: 全部通过。

- [x] **Step 3: 提交（需用户授权）**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run rust checks and tests on macos"
```

---

## 自审记录

- **Spec 覆盖**：配置（5.4）、数据模型（5.1）、FFI（5.3）、存储与清理（5.5/5.6）、剪贴板（7.1/7.2/7.4）、分类板（7.3）、常驻中与核心相关的启动清理（9.3/11.5）均已覆盖。应用热键、截图、贴图、取色、LaunchAgent、SwiftUI 属于后续计划。
- **占位符**：无 TBD/TODO；唯一“以编译结果为准”是 nucleo API 形态说明，语义已固定。
- **类型一致性**：`ClipboardItem`、`ClipboardQuery`、`NewClipboardItem`、`Pinboard`、`Config`、`Service` 方法与后续 Swift 计划使用的字段名一致；`__pinned` 在搜索、列表、测试三处一致。
- **风险**：`rusqlite`/`nucleo-matcher` 版本解析以 Cargo.lock 为准；若 API 变化，按测试语义调整实现，不改接口。
