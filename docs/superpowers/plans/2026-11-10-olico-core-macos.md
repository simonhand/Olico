# Olico — Rust 核心与 macOS MVP 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付可在 macOS 13+（Apple Silicon 与 Intel）运行、可打包成 universal dmg 的 Olico 启动器，包含应用/文件搜索、计算器、网页搜索、剪贴板历史与窗口管理，核心逻辑位于可复用的 Rust crate。

**Architecture:** Rust workspace 提供 `olico-core`（模型、搜索排序、配置、SQLite、命令）与 `olico-ffi`（C ABI + JSON 单入口），SwiftUI/AppKit 壳通过 bridging header 调用；平台能力（热键、应用枚举、窗口、剪贴板）保留在 Swift 层。

**Tech Stack:** Rust 1.85（serde / nucleo / rusqlite / thiserror / uuid / sha2）、Swift 5.9 + SwiftUI + AppKit、Carbon HotKey、ApplicationServices（AX）、Spotlight（NSMetadataQuery）、XcodeGen、Xcode 15+、GitHub Actions。

**Spec:** `docs/superpowers/specs/2026-11-10-olico-design.md`

## Global Constraints

- 最低系统：macOS 13.0；Swift 5.9；Rust 1.85.0；Xcode 15+。
- 浮层尺寸 680×460；输入防抖 40ms；剪贴板轮询 500ms；索引 TTL 5 分钟。
- 剪贴板默认上限 500 条、保留 30 天；置顶条目不参与清理；日志单文件 5MB、保留 3 份；日志不得包含剪贴板明文。
- FFI 协议版本固定为 `1`，单入口 `olico_dispatch`，请求/响应均为 UTF-8 JSON；panic 不得跨 FFI。
- `olico-ffi` crate-type 为 `["staticlib", "cdylib"]`。
- 版本号唯一来源为仓库根 `VERSION`（初始 `0.1.0`）。
- 全局热键默认 `alt+space`；窗口动作仅 `left` / `right` / `maximize` / `center`。
- 数据结构字段名与 JSON 形态必须与 spec 第 5 节一致；Swift/C# 端按 `snake_case` 解码。
- 本计划不包含 Windows 壳与 Windows CI；它们属于第二份计划。

---

## 文件结构（本计划结束时）

```
Olico/
├── VERSION
├── Cargo.toml
├── rust-toolchain.toml
├── rustfmt.toml
├── .gitignore
├── crates/
│   ├── olico-core/
│   │   ├── Cargo.toml
│   │   ├── src/
│   │   │   ├── lib.rs
│   │   │   ├── model.rs
│   │   │   ├── protocol.rs
│   │   │   ├── config.rs
│   │   │   ├── calculator.rs
│   │   │   ├── commands.rs
│   │   │   ├── dispatch.rs
│   │   │   ├── search/mod.rs
│   │   │   └── store/{mod.rs,items.rs,clipboard.rs}
│   │   └── tests/{protocol.rs,config.rs,calculator.rs,search.rs,store.rs,dispatch.rs,fixtures/ranking/basic.json}
│   └── olico-ffi/
│       ├── Cargo.toml
│       ├── build.rs
│       ├── cbindgen.toml
│       ├── src/lib.rs
│       ├── include/olico.h        # cbindgen 生成
│       └── tests/{ffi.rs,smoke.c}
├── apps/macos/
│   ├── project.yml
│   ├── Info.plist
│   ├── Vendor/libolico_ffi.a      # 构建产物，git 忽略
│   ├── Sources/
│   │   ├── OlicoApp.swift
│   │   ├── AppDelegate.swift
│   │   ├── Bridge/{RustBridge.swift,Olico-Bridging-Header.h}
│   │   ├── Models/Models.swift
│   │   ├── UI/{LauncherPanel.swift,LauncherView.swift,LauncherViewModel.swift,SearchField.swift,ClipboardPanel.swift,ClipboardView.swift,ClipboardViewModel.swift,SettingsView.swift,SettingsViewModel.swift,HotkeyRecorder.swift,ToastView.swift}
│   │   ├── Platform/{HotkeyManager.swift,AppIndexer.swift,AppLauncher.swift,FileSearchService.swift,ClipboardMonitor.swift,PasteService.swift,WindowManager.swift,ActionExecutor.swift}
│   │   └── Support/{FileLogger.swift,Paths.swift}
│   └── Tests/{HotkeyParserTests.swift,RustBridgeTests.swift,LauncherViewModelTests.swift,AppScannerTests.swift,WindowFramesTests.swift,ClipboardTests.swift,SettingsViewModelTests.swift,FileLoggerTests.swift}
├── scripts/{version-sync.sh,build-ffi.sh,build-macos.sh,create-dev-cert.sh,ffi-smoke.sh}
├── shared/design-tokens.json
├── docs/qa/macos-mvp-checklist.md
└── .github/workflows/{ci.yml,release-macos.yml}
```

---

## Task 1: Workspace 骨架与 JSON 协议

**Files:**
- Create: `VERSION`, `Cargo.toml`, `rust-toolchain.toml`, `rustfmt.toml`, `.gitignore`
- Create: `crates/olico-core/Cargo.toml`, `crates/olico-core/src/lib.rs`, `crates/olico-core/src/protocol.rs`
- Test: `crates/olico-core/tests/protocol.rs`

**Interfaces:**
- Consumes: 无
- Produces:
  - `olico_core::protocol::{Request, ApiError, parse_request, ok, err}`
  - `Request { v: u32, op: String, payload: serde_json::Value }`
  - `parse_request(&str) -> Result<Request, ApiError>`
  - `ok(serde_json::Value) -> String`，`err(ApiError) -> String`

- [ ] **Step 1: 写失败测试**

`crates/olico-core/tests/protocol.rs`：

```rust
use olico_core::protocol::{ok, parse_request};
use serde_json::json;

#[test]
fn parses_search_request() {
    let req = parse_request(r#"{"v":1,"op":"search","payload":{"text":"code"}}"#).unwrap();
    assert_eq!(req.op, "search");
    assert_eq!(req.payload["text"], "code");
}

#[test]
fn rejects_unsupported_version() {
    let err = parse_request(r#"{"v":2,"op":"search","payload":{}}"#).unwrap_err();
    assert_eq!(err.code, "unsupported_version");
}

#[test]
fn success_response_has_ok_true_and_no_error() {
    let raw = ok(json!({"n": 1}));
    let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(v["v"], 1);
    assert_eq!(v["ok"], true);
    assert_eq!(v["data"]["n"], 1);
    assert!(v.get("error").is_none());
}
```

- [ ] **Step 2: 建最小骨架并运行，确认失败**

```bash
cat > VERSION <<'EOF'
0.1.0
EOF
cat > rust-toolchain.toml <<'EOF'
[toolchain]
channel = "1.85.0"
components = ["rustfmt", "clippy"]
EOF
cat > rustfmt.toml <<'EOF'
edition = "2021"
max_width = 100
EOF
cat > .gitignore <<'EOF'
/target
/apps/macos/Vendor/
/apps/macos/Olico.xcodeproj/
/apps/macos/build/
/dist/
.DS_Store
EOF
cat > Cargo.toml <<'EOF'
[workspace]
members = ["crates/olico-core", "crates/olico-ffi"]
resolver = "2"

[workspace.package]
version = "0.1.0"
edition = "2021"
rust-version = "1.85"
EOF
mkdir -p crates/olico-core/src crates/olico-core/tests
cat > crates/olico-core/Cargo.toml <<'EOF'
[package]
name = "olico-core"
version.workspace = true
edition.workspace = true

[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
thiserror = "2"
nucleo = "0.5"
rusqlite = { version = "0.32", features = ["bundled"] }
uuid = { version = "1", features = ["v4"] }
sha2 = "0.10"
percent-encoding = "2"
chrono = "0.4"

[dev-dependencies]
tempfile = "3"
EOF
printf 'pub mod protocol;\n' > crates/olico-core/src/lib.rs
printf '// placeholder\n' > crates/olico-core/src/protocol.rs
```

Run: `cargo test -p olico-core --test protocol`
Expected: 编译失败（`parse_request` / `ok` 不存在）。

- [ ] **Step 3: 实现协议模块**

```rust
// crates/olico-core/src/protocol.rs
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug, Deserialize)]
pub struct Request {
    pub v: u32,
    pub op: String,
    #[serde(default)]
    pub payload: Value,
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct ApiError {
    pub code: String,
    pub message: String,
}

pub fn api_error(code: &str, message: impl Into<String>) -> ApiError {
    ApiError { code: code.to_string(), message: message.into() }
}

pub fn parse_request(raw: &str) -> Result<Request, ApiError> {
    let req: Request = serde_json::from_str(raw)
        .map_err(|e| api_error("invalid_json", e.to_string()))?;
    if req.v != 1 {
        return Err(api_error("unsupported_version", format!("v={}", req.v)));
    }
    Ok(req)
}

pub fn ok(data: Value) -> String {
    json!({"v": 1, "ok": true, "data": data}).to_string()
}

pub fn err(error: ApiError) -> String {
    json!({"v": 1, "ok": false, "error": error}).to_string()
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test protocol`
Expected: 3 passed。

- [ ] **Step 5: 提交**

```bash
git add VERSION Cargo.toml rust-toolchain.toml rustfmt.toml .gitignore crates/olico-core
git commit -m "chore: scaffold rust workspace and json protocol"
```

---

## Task 2: 配置模块

**Files:**
- Create: `crates/olico-core/src/config.rs`
- Modify: `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/config.rs`

**Interfaces:**
- Consumes: 无
- Produces:
  - `AppConfig { version: u32, hotkey: HotkeyConfig, search: SearchConfig, clipboard: ClipboardConfig }`
  - `HotkeyConfig { mac, windows, windows_fallback }`
  - `SearchConfig { file_search: bool, max_results: usize, web_engines: Vec<WebEngine> }`
  - `WebEngine { keyword, name, url }`
  - `ClipboardConfig { enabled, max_items, retention_days, excluded_apps, ignore_concealed }`
  - `AppConfig::default()`, `AppConfig::load(&Path)`, `AppConfig::save(&self, &Path)`, `AppConfig::file_path(&Path) -> PathBuf`

- [ ] **Step 1: 写失败测试**

`crates/olico-core/tests/config.rs`：

```rust
use olico_core::config::AppConfig;
use tempfile::tempdir;

#[test]
fn defaults_match_spec() {
    let c = AppConfig::default();
    assert_eq!(c.hotkey.mac, "alt+space");
    assert_eq!(c.search.max_results, 20);
    assert_eq!(c.clipboard.max_items, 500);
    assert_eq!(c.clipboard.retention_days, 30);
    assert_eq!(c.search.web_engines[0].keyword, "g");
}

#[test]
fn save_then_load_roundtrips() {
    let dir = tempdir().unwrap();
    let mut c = AppConfig::default();
    c.hotkey.mac = "ctrl+space".into();
    c.save(dir.path()).unwrap();
    let loaded = AppConfig::load(dir.path()).unwrap();
    assert_eq!(loaded.hotkey.mac, "ctrl+space");
}

#[test]
fn missing_file_returns_default() {
    let dir = tempdir().unwrap();
    let loaded = AppConfig::load(dir.path()).unwrap();
    assert_eq!(loaded.version, 1);
}

#[test]
fn partial_file_is_filled_with_defaults() {
    let dir = tempdir().unwrap();
    std::fs::write(dir.path().join("config.json"), r#"{"clipboard":{"max_items":10}}"#).unwrap();
    let loaded = AppConfig::load(dir.path()).unwrap();
    assert_eq!(loaded.clipboard.max_items, 10);
    assert_eq!(loaded.hotkey.mac, "alt+space");
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cargo test -p olico-core --test config`
Expected: 编译失败（`olico_core::config` 不存在）。

- [ ] **Step 3: 实现配置模块**

```rust
// crates/olico-core/src/config.rs
use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct AppConfig {
    pub version: u32,
    pub hotkey: HotkeyConfig,
    pub search: SearchConfig,
    pub clipboard: ClipboardConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct HotkeyConfig {
    pub mac: String,
    pub windows: String,
    pub windows_fallback: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct SearchConfig {
    pub file_search: bool,
    pub max_results: usize,
    pub web_engines: Vec<WebEngine>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WebEngine {
    pub keyword: String,
    pub name: String,
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct ClipboardConfig {
    pub enabled: bool,
    pub max_items: i64,
    pub retention_days: i64,
    pub excluded_apps: Vec<String>,
    pub ignore_concealed: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            version: 1,
            hotkey: HotkeyConfig::default(),
            search: SearchConfig::default(),
            clipboard: ClipboardConfig::default(),
        }
    }
}

impl Default for HotkeyConfig {
    fn default() -> Self {
        Self {
            mac: "alt+space".into(),
            windows: "alt+space".into(),
            windows_fallback: "ctrl+alt+space".into(),
        }
    }
}

impl Default for SearchConfig {
    fn default() -> Self {
        Self {
            file_search: true,
            max_results: 20,
            web_engines: vec![
                WebEngine {
                    keyword: "g".into(),
                    name: "Google".into(),
                    url: "https://www.google.com/search?q={query}".into(),
                },
                WebEngine {
                    keyword: "bd".into(),
                    name: "百度".into(),
                    url: "https://www.baidu.com/s?wd={query}".into(),
                },
            ],
        }
    }
}

impl Default for ClipboardConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            max_items: 500,
            retention_days: 30,
            excluded_apps: vec![],
            ignore_concealed: true,
        }
    }
}

impl AppConfig {
    pub fn file_path(dir: &Path) -> PathBuf {
        dir.join("config.json")
    }

    pub fn load(dir: &Path) -> Result<Self, ConfigError> {
        let path = Self::file_path(dir);
        if !path.exists() {
            return Ok(Self::default());
        }
        Ok(serde_json::from_slice(&fs::read(path)?)?)
    }

    pub fn save(&self, dir: &Path) -> Result<(), ConfigError> {
        fs::create_dir_all(dir)?;
        let path = Self::file_path(dir);
        let tmp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(self)?;
        {
            let mut file = File::create(&tmp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        fs::rename(tmp, path)?;
        Ok(())
    }
}
```

在 `crates/olico-core/src/lib.rs` 增加：

```rust
pub mod config;
pub mod protocol;
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test config`
Expected: 4 passed。

- [ ] **Step 5: 提交**

```bash
git add crates/olico-core
git commit -m "feat(core): add config with defaults and atomic save"
```

---

## Task 3: 计算器

**Files:**
- Create: `crates/olico-core/src/calculator.rs`
- Modify: `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/calculator.rs`

**Interfaces:**
- Consumes: 无
- Produces:
  - `olico_core::calculator::evaluate(&str) -> Result<f64, CalcError>`
  - `CalcError` 实现 `Display`

- [ ] **Step 1: 写失败测试**

`crates/olico-core/tests/calculator.rs`：

```rust
use olico_core::calculator::evaluate;

#[test]
fn respects_precedence() {
    assert_eq!(evaluate("1+2*3").unwrap(), 7.0);
    assert_eq!(evaluate("(1+2)*3").unwrap(), 9.0);
}

#[test]
fn supports_power_and_percent() {
    assert_eq!(evaluate("2^10").unwrap(), 1024.0);
    assert_eq!(evaluate("2^3^2").unwrap(), 512.0);
    assert_eq!(evaluate("50%").unwrap(), 0.5);
    assert_eq!(evaluate("200 * 5%").unwrap(), 10.0);
}

#[test]
fn handles_unary_minus() {
    assert_eq!(evaluate("-3 + 5").unwrap(), 2.0);
}

#[test]
fn rejects_invalid_input() {
    assert!(evaluate("").is_err());
    assert!(evaluate("1+").is_err());
    assert!(evaluate("1/0").is_err());
    assert!(evaluate("abc").is_err());
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cargo test -p olico-core --test calculator`
Expected: 编译失败（模块不存在）。

- [ ] **Step 3: 实现计算器**

```rust
// crates/olico-core/src/calculator.rs
use std::fmt;

#[derive(Debug, PartialEq)]
pub struct CalcError(pub String);

impl fmt::Display for CalcError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}
impl std::error::Error for CalcError {}

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Num(f64),
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Caret,
    LParen,
    RParen,
}

fn tokenize(input: &str) -> Result<Vec<Tok>, CalcError> {
    let mut out = Vec::new();
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match c {
            ' ' | '\t' => i += 1,
            '+' => { out.push(Tok::Plus); i += 1; }
            '-' => { out.push(Tok::Minus); i += 1; }
            '*' => { out.push(Tok::Star); i += 1; }
            '/' => { out.push(Tok::Slash); i += 1; }
            '%' => { out.push(Tok::Percent); i += 1; }
            '^' => { out.push(Tok::Caret); i += 1; }
            '(' => { out.push(Tok::LParen); i += 1; }
            ')' => { out.push(Tok::RParen); i += 1; }
            c if c.is_ascii_digit() || c == '.' => {
                let start = i;
                while i < chars.len() && (chars[i].is_ascii_digit() || chars[i] == '.') {
                    i += 1;
                }
                let text: String = chars[start..i].iter().collect();
                let value = text
                    .parse::<f64>()
                    .map_err(|_| CalcError(format!("invalid number: {text}")))?;
                out.push(Tok::Num(value));
            }
            other => return Err(CalcError(format!("unexpected character: {other}"))),
        }
    }
    Ok(out)
}

struct Parser {
    tokens: Vec<Tok>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.tokens.get(self.pos)
    }
    fn bump(&mut self) -> Option<Tok> {
        let tok = self.tokens.get(self.pos).cloned();
        self.pos += 1;
        tok
    }

    fn expr(&mut self) -> Result<f64, CalcError> {
        let mut value = self.term()?;
        loop {
            match self.peek() {
                Some(Tok::Plus) => { self.bump(); value += self.term()?; }
                Some(Tok::Minus) => { self.bump(); value -= self.term()?; }
                _ => return Ok(value),
            }
        }
    }

    fn term(&mut self) -> Result<f64, CalcError> {
        let mut value = self.power()?;
        loop {
            match self.peek() {
                Some(Tok::Star) => { self.bump(); value *= self.power()?; }
                Some(Tok::Slash) => {
                    self.bump();
                    let rhs = self.power()?;
                    if rhs == 0.0 {
                        return Err(CalcError("division by zero".into()));
                    }
                    value /= rhs;
                }
                _ => return Ok(value),
            }
        }
    }

    fn power(&mut self) -> Result<f64, CalcError> {
        let base = self.unary()?;
        if matches!(self.peek(), Some(Tok::Caret)) {
            self.bump();
            let exp = self.power()?;
            Ok(base.powf(exp))
        } else {
            Ok(base)
        }
    }

    fn unary(&mut self) -> Result<f64, CalcError> {
        match self.peek() {
            Some(Tok::Minus) => { self.bump(); Ok(-self.unary()?) }
            Some(Tok::Plus) => { self.bump(); self.unary() }
            _ => self.postfix(),
        }
    }

    fn postfix(&mut self) -> Result<f64, CalcError> {
        let mut value = self.primary()?;
        while matches!(self.peek(), Some(Tok::Percent)) {
            self.bump();
            value /= 100.0;
        }
        Ok(value)
    }

    fn primary(&mut self) -> Result<f64, CalcError> {
        match self.bump() {
            Some(Tok::Num(v)) => Ok(v),
            Some(Tok::LParen) => {
                let v = self.expr()?;
                match self.bump() {
                    Some(Tok::RParen) => Ok(v),
                    _ => Err(CalcError("missing closing parenthesis".into())),
                }
            }
            Some(_) => Err(CalcError("unexpected token".into())),
            None => Err(CalcError("unexpected end of expression".into())),
        }
    }
}

pub fn evaluate(input: &str) -> Result<f64, CalcError> {
    let tokens = tokenize(input)?;
    if tokens.is_empty() {
        return Err(CalcError("empty expression".into()));
    }
    let mut parser = Parser { tokens, pos: 0 };
    let value = parser.expr()?;
    if parser.pos != parser.tokens.len() {
        return Err(CalcError("unexpected trailing token".into()));
    }
    if !value.is_finite() {
        return Err(CalcError("result is not finite".into()));
    }
    Ok(value)
}
```

在 `lib.rs` 增加 `pub mod calculator;` 并保证 `Tok` 派生 `Clone`（上面已加）。

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test calculator`
Expected: 4 passed。

- [ ] **Step 5: 提交**

```bash
git add crates/olico-core
git commit -m "feat(core): add safe calculator parser"
```

---

## Task 4: 数据模型、模糊搜索与 frecency

**Files:**
- Create: `crates/olico-core/src/model.rs`
- Create: `crates/olico-core/src/search/mod.rs`
- Modify: `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/search.rs`
- Test fixture: `crates/olico-core/tests/fixtures/ranking/basic.json`

**Interfaces:**
- Consumes: 无
- Produces:
  - `model::{Item, ItemKind, Action, Scope, SearchHit, ClipboardKind, ClipboardItem}`
  - `Action` 的 JSON 形态为 `{"type":"open_app","path":"..."}` 等（`#[serde(tag="type", rename_all="snake_case")]`）
  - `search::Usage { count: u32, last_used: i64 }`
  - `search::frecency(&Usage, now: i64) -> f64`
  - `search::search(cands: &[Item], usage: &HashMap<String, Usage>, query: &str, scope: Scope, limit: usize, now: i64) -> Vec<SearchHit>`

- [ ] **Step 1: 写失败测试与金标数据**

`crates/olico-core/tests/fixtures/ranking/basic.json`：

```json
{
  "query": "code",
  "now": 1735689600,
  "items": [
    {"id":"app:com.apple.Safari","kind":"application","title":"Safari","subtitle":"/Applications/Safari.app","keywords":["browser"],"icon_ref":"/Applications/Safari.app","action":{"type":"open_app","path":"/Applications/Safari.app"},"source":"mac_scan"},
    {"id":"app:com.microsoft.VSCode","kind":"application","title":"Visual Studio Code","subtitle":"/Applications/Visual Studio Code.app","keywords":["vscode","editor"],"icon_ref":"/Applications/Visual Studio Code.app","action":{"type":"open_app","path":"/Applications/Visual Studio Code.app"},"source":"mac_scan"},
    {"id":"app:com.apple.dt.Xcode","kind":"application","title":"Xcode","subtitle":"/Applications/Xcode.app","keywords":["ide","apple"],"icon_ref":"/Applications/Xcode.app","action":{"type":"open_app","path":"/Applications/Xcode.app"},"source":"mac_scan"}
  ],
  "usage": {
    "app:com.apple.dt.Xcode": {"count": 8, "last_used": 1735603200},
    "app:com.microsoft.VSCode": {"count": 2, "last_used": 1735603200}
  },
  "expected_ids": ["app:com.apple.dt.Xcode", "app:com.microsoft.VSCode"]
}
```

`crates/olico-core/tests/search.rs`：

```rust
use olico_core::model::{Action, Item, ItemKind, Scope};
use olico_core::search::{frecency, search, Usage};
use serde_json::Value;
use std::collections::HashMap;

fn item(id: &str, title: &str, kind: ItemKind, subtitle: &str) -> Item {
    Item {
        id: id.into(),
        kind,
        title: title.into(),
        subtitle: subtitle.into(),
        keywords: vec![],
        icon_ref: String::new(),
        action: Action::OpenPath { path: "/tmp".into() },
        source: "test".into(),
    }
}

#[test]
fn golden_ranking_fixture() {
    let raw = std::fs::read_to_string("tests/fixtures/ranking/basic.json").unwrap();
    let v: Value = serde_json::from_str(&raw).unwrap();
    let items: Vec<Item> = serde_json::from_value(v["items"].clone()).unwrap();
    let usage: HashMap<String, Usage> = serde_json::from_value(v["usage"].clone()).unwrap();
    let now = v["now"].as_i64().unwrap();
    let expected: Vec<String> = serde_json::from_value(v["expected_ids"].clone()).unwrap();

    let hits = search(&items, &usage, "code", Scope::All, 10, now);
    let ids: Vec<String> = hits.into_iter().map(|h| h.item.id).collect();
    assert_eq!(ids, expected);
}

#[test]
fn chinese_title_matches() {
    let items = vec![item("app:wechat", "微信", ItemKind::Application, "")];
    let hits = search(&items, &HashMap::new(), "微信", Scope::All, 10, 100);
    assert_eq!(hits.len(), 1);
    assert!(!hits[0].match_ranges.is_empty());
}

#[test]
fn empty_query_sorts_by_frecency() {
    let items = vec![
        item("a", "Alpha", ItemKind::Application, ""),
        item("b", "Beta", ItemKind::Application, ""),
    ];
    let usage = HashMap::from([
        ("a".to_string(), Usage { count: 1, last_used: 0 }),
        ("b".to_string(), Usage { count: 5, last_used: 0 }),
    ]);
    let hits = search(&items, &usage, "", Scope::All, 10, 86_400);
    assert_eq!(hits[0].item.id, "b");
}

#[test]
fn scope_filters_commands() {
    let items = vec![
        item("app", "Code", ItemKind::Application, ""),
        item("cmd", "Code Settings", ItemKind::BuiltinCommand, ""),
    ];
    let hits = search(&items, &HashMap::new(), "code", Scope::Commands, 10, 0);
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].item.id, "cmd");
}

#[test]
fn frecency_decays_over_time() {
    let fresh = frecency(&Usage { count: 3, last_used: 0 }, 0);
    let old = frecency(&Usage { count: 3, last_used: 0 }, 90 * 86_400);
    assert!(fresh > old);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cargo test -p olico-core --test search`
Expected: 编译失败（`model` / `search` 不存在）。

- [ ] **Step 3: 实现模型**

```rust
// crates/olico-core/src/model.rs
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemKind {
    Application,
    File,
    BuiltinCommand,
    WindowAction,
}

impl ItemKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Application => "application",
            Self::File => "file",
            Self::BuiltinCommand => "builtin_command",
            Self::WindowAction => "window_action",
        }
    }
    pub fn from_str(value: &str) -> Self {
        match value {
            "file" => Self::File,
            "builtin_command" => Self::BuiltinCommand,
            "window_action" => Self::WindowAction,
            _ => Self::Application,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Action {
    OpenApp { path: String },
    OpenPath { path: String },
    OpenUrl { url: String },
    CopyText { text: String },
    RunBuiltin { name: String },
    WindowAction { name: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    pub kind: ItemKind,
    pub title: String,
    pub subtitle: String,
    pub keywords: Vec<String>,
    pub icon_ref: String,
    pub action: Action,
    pub source: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    #[default]
    All,
    Apps,
    Files,
    Commands,
}

impl Scope {
    pub fn matches(&self, item: &Item) -> bool {
        match self {
            Self::All => true,
            Self::Apps => item.kind == ItemKind::Application,
            Self::Files => item.kind == ItemKind::File,
            Self::Commands => matches!(item.kind, ItemKind::BuiltinCommand | ItemKind::WindowAction),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SearchHit {
    pub item: Item,
    pub score: f64,
    pub match_ranges: Vec<(u32, u32)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardKind {
    Text,
    Image,
    File,
}

impl ClipboardKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Image => "image",
            Self::File => "file",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipboardItem {
    pub id: String,
    pub kind: ClipboardKind,
    pub text: Option<String>,
    pub file_path: Option<String>,
    pub hash: String,
    pub source_app: Option<String>,
    pub created_at: i64,
    pub pinned: bool,
    pub use_count: u32,
}
```

- [ ] **Step 4: 实现搜索与排序**

```rust
// crates/olico-core/src/search/mod.rs
use crate::model::{Item, Scope, SearchHit};
use nucleo::pattern::{CaseMatching, Normalization, Pattern};
use nucleo::{Config, Matcher, Utf32Str};
use serde::Deserialize;
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
pub struct Usage {
    pub count: u32,
    pub last_used: i64,
}

pub fn frecency(usage: &Usage, now: i64) -> f64 {
    let days = ((now - usage.last_used).max(0) as f64) / 86_400.0;
    (1.0 + usage.count as f64).ln() * 0.5_f64.powf(days / 30.0)
}

fn indices_to_ranges(indices: Vec<u32>) -> Vec<(u32, u32)> {
    let mut ranges: Vec<(u32, u32)> = Vec::new();
    for index in indices {
        match ranges.last_mut() {
            Some((_, end)) if *end + 1 == index => *end = index,
            _ => ranges.push((index, index)),
        }
    }
    ranges
}

pub fn search(
    candidates: &[Item],
    usage: &HashMap<String, Usage>,
    query: &str,
    scope: Scope,
    limit: usize,
    now: i64,
) -> Vec<SearchHit> {
    let trimmed = query.trim();
    let usage_of = |item: &Item| usage.get(&item.id).map(|u| frecency(u, now)).unwrap_or(0.0);

    if trimmed.is_empty() {
        let mut hits: Vec<SearchHit> = candidates
            .iter()
            .filter(|item| scope.matches(item))
            .map(|item| SearchHit { item: item.clone(), score: usage_of(item), match_ranges: vec![] })
            .collect();
        hits.sort_by(|a, b| {
            b.score.partial_cmp(&a.score).unwrap().then_with(|| a.item.title.cmp(&b.item.title))
        });
        hits.truncate(limit);
        return hits;
    }

    let pattern = Pattern::parse(trimmed, CaseMatching::Ignore, Normalization::Smart);
    let mut matcher = Matcher::new(Config::DEFAULT);
    let mut hits = Vec::new();

    for item in candidates.iter().filter(|item| scope.matches(item)) {
        let keywords = item.keywords.join(" ");
        let fields = [
            (item.title.as_str(), 1.0_f64),
            (keywords.as_str(), 0.8_f64),
            (item.subtitle.as_str(), 0.4_f64),
        ];
        let mut best: Option<(u32, f64, Vec<(u32, u32)>)> = None;
        for (field, weight) in fields {
            let mut buf = Vec::new();
            let haystack = Utf32Str::new(field, &mut buf);
            if let Some(indices) = pattern.indices(haystack, &mut buf, &mut matcher) {
                let score = pattern.score(haystack, &mut matcher).unwrap_or(0) as f64 * weight;
                if best.as_ref().map(|(_, s, _)| score > *s).unwrap_or(true) {
                    best = Some((0, score, indices_to_ranges(indices)));
                }
            }
        }
        if let Some((_, match_score, ranges)) = best {
            hits.push(SearchHit {
                item: item.clone(),
                score: match_score + usage_of(item) * 100.0,
                match_ranges: ranges,
            });
        }
    }

    hits.sort_by(|a, b| {
        b.score.partial_cmp(&a.score).unwrap().then_with(|| a.item.title.cmp(&b.item.title))
    });
    hits.truncate(limit);
    hits
}
```

> 若 `nucleo 0.5` 的 `Pattern::indices` 签名与上述不同，以编译错误为准调整调用顺序；对外函数签名保持不变。

在 `lib.rs` 增加：

```rust
pub mod model;
pub mod search;
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cargo test -p olico-core --test search`
Expected: 5 passed。

- [ ] **Step 6: 提交**

```bash
git add crates/olico-core
git commit -m "feat(core): add item model and fuzzy ranking with frecency"
```

---

## Task 5: SQLite 存储 — 应用索引与使用记录

**Files:**
- Create: `crates/olico-core/src/store/mod.rs`
- Create: `crates/olico-core/src/store/items.rs`
- Modify: `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/store.rs`

**Interfaces:**
- Consumes: `model::{Item, ItemKind}`, `search::Usage`
- Produces:
  - `Store::open(&Path)`, `Store::open_in_memory()`
  - `Store::upsert_items(&mut self, &[Item])`
  - `Store::remove_stale(&mut self, source: &str, valid_ids: &[String]) -> usize`
  - `Store::items(&self) -> Vec<Item>`
  - `Store::record_usage(&mut self, item_id: &str, now: i64)`
  - `Store::usage(&self) -> HashMap<String, Usage>`

- [ ] **Step 1: 写失败测试**

`crates/olico-core/tests/store.rs`：

```rust
use olico_core::model::{Action, Item, ItemKind};
use olico_core::store::Store;

fn app(id: &str, title: &str) -> Item {
    Item {
        id: id.into(),
        kind: ItemKind::Application,
        title: title.into(),
        subtitle: "/Applications/Test.app".into(),
        keywords: vec!["test".into()],
        icon_ref: "/Applications/Test.app".into(),
        action: Action::OpenApp { path: "/Applications/Test.app".into() },
        source: "mac_scan".into(),
    }
}

#[test]
fn upsert_and_list_items() {
    let mut store = Store::open_in_memory().unwrap();
    store.upsert_items(&[app("a", "Alpha")]).unwrap();
    store.upsert_items(&[app("a", "Alpha Renamed"), app("b", "Beta")]).unwrap();
    let items = store.items().unwrap();
    assert_eq!(items.len(), 2);
    assert!(items.iter().any(|i| i.title == "Alpha Renamed"));
}

#[test]
fn remove_stale_only_touches_source() {
    let mut store = Store::open_in_memory().unwrap();
    store.upsert_items(&[app("a", "Alpha"), app("b", "Beta")]).unwrap();
    let removed = store.remove_stale("mac_scan", &["a".to_string()]).unwrap();
    assert_eq!(removed, 1);
    assert_eq!(store.items().unwrap().len(), 1);
}

#[test]
fn usage_accumulates() {
    let mut store = Store::open_in_memory().unwrap();
    store.record_usage("a", 100).unwrap();
    store.record_usage("a", 200).unwrap();
    let usage = store.usage().unwrap();
    assert_eq!(usage["a"].count, 2);
    assert_eq!(usage["a"].last_used, 200);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cargo test -p olico-core --test store`
Expected: 编译失败（`store` 不存在）。

- [ ] **Step 3: 实现 Store 打开与迁移**

```rust
// crates/olico-core/src/store/mod.rs
mod clipboard;
mod items;

use rusqlite::Connection;
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("not found: {0}")]
    NotFound(String),
}

pub struct Store {
    pub(crate) conn: Connection,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        Self::migrate(&conn)?;
        Ok(Self { conn })
    }

    pub fn open_in_memory() -> Result<Self, StoreError> {
        let conn = Connection::open_in_memory()?;
        Self::migrate(&conn)?;
        Ok(Self { conn })
    }

    fn migrate(conn: &Connection) -> Result<(), StoreError> {
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                subtitle TEXT NOT NULL,
                keywords TEXT NOT NULL,
                icon_ref TEXT NOT NULL,
                action TEXT NOT NULL,
                source TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS usage (
                item_id TEXT PRIMARY KEY,
                count INTEGER NOT NULL DEFAULT 0,
                last_used INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS clipboard (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                text TEXT,
                file_path TEXT,
                hash TEXT NOT NULL UNIQUE,
                source_app TEXT,
                created_at INTEGER NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                use_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_clipboard_order
                ON clipboard(pinned DESC, created_at DESC);
            PRAGMA user_version = 1;
            "#,
        )?;
        Ok(())
    }
}
```

- [ ] **Step 4: 实现索引与使用记录**

```rust
// crates/olico-core/src/store/items.rs
use super::{Store, StoreError};
use crate::model::{Item, ItemKind};
use crate::search::Usage;
use rusqlite::params;
use std::collections::{HashMap, HashSet};

impl Store {
    pub fn upsert_items(&mut self, items: &[Item]) -> Result<(), StoreError> {
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO items (id, kind, title, subtitle, keywords, icon_ref, action, source)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(id) DO UPDATE SET
                   kind=excluded.kind, title=excluded.title, subtitle=excluded.subtitle,
                   keywords=excluded.keywords, icon_ref=excluded.icon_ref,
                   action=excluded.action, source=excluded.source",
            )?;
            for item in items {
                stmt.execute(params![
                    item.id,
                    item.kind.as_str(),
                    item.title,
                    item.subtitle,
                    serde_json::to_string(&item.keywords)?,
                    item.icon_ref,
                    serde_json::to_string(&item.action)?,
                    item.source,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn remove_stale(&mut self, source: &str, valid_ids: &[String]) -> Result<usize, StoreError> {
        let valid: HashSet<&str> = valid_ids.iter().map(String::as_str).collect();
        let mut stmt = self.conn.prepare("SELECT id FROM items WHERE source = ?1")?;
        let existing: Vec<String> =
            stmt.query_map([source], |row| row.get::<_, String>(0))?.collect::<Result<_, _>>()?;
        let mut removed = 0;
        for id in existing {
            if !valid.contains(id.as_str()) {
                removed += self.conn.execute("DELETE FROM items WHERE id = ?1", [&id])?;
            }
        }
        Ok(removed)
    }

    pub fn items(&self) -> Result<Vec<Item>, StoreError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, kind, title, subtitle, keywords, icon_ref, action, source FROM items",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, String>(7)?,
            ))
        })?;
        let mut items = Vec::new();
        for row in rows {
            let (id, kind, title, subtitle, keywords, icon_ref, action, source) = row?;
            items.push(Item {
                id,
                kind: ItemKind::from_str(&kind),
                title,
                subtitle,
                keywords: serde_json::from_str(&keywords)?,
                icon_ref,
                action: serde_json::from_str(&action)?,
                source,
            });
        }
        Ok(items)
    }

    pub fn record_usage(&mut self, item_id: &str, now: i64) -> Result<(), StoreError> {
        self.conn.execute(
            "INSERT INTO usage (item_id, count, last_used) VALUES (?1, 1, ?2)
             ON CONFLICT(item_id) DO UPDATE SET count = count + 1, last_used = excluded.last_used",
            params![item_id, now],
        )?;
        Ok(())
    }

    pub fn usage(&self) -> Result<HashMap<String, Usage>, StoreError> {
        let mut stmt = self.conn.prepare("SELECT item_id, count, last_used FROM usage")?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, Usage { count: row.get(1)?, last_used: row.get(2)? }))
        })?;
        let mut usage = HashMap::new();
        for row in rows {
            let (id, value) = row?;
            usage.insert(id, value);
        }
        Ok(usage)
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cargo test -p olico-core --test store`
Expected: 3 passed。

- [ ] **Step 6: 提交**

```bash
git add crates/olico-core
git commit -m "feat(core): persist app index and usage in sqlite"
```

---

## Task 6: 剪贴板存储

**Files:**
- Create: `crates/olico-core/src/store/clipboard.rs`
- Modify: `crates/olico-core/tests/store.rs`
- Test: `crates/olico-core/tests/store.rs`（追加用例）

**Interfaces:**
- Consumes: `model::{ClipboardItem, ClipboardKind}`
- Produces:
  - `Store::clipboard_add(kind, text: Option<&str>, file_path: Option<&str>, hash: &str, source_app: Option<&str>, now: i64) -> ClipboardItem`
  - `Store::clipboard_list(query: &str, kind: Option<ClipboardKind>, limit: usize) -> Vec<ClipboardItem>`
  - `Store::clipboard_delete(id)`, `clipboard_pin(id, pinned)`, `clipboard_clear()`
  - `Store::clipboard_prune(now, max_items, retention_days) -> usize`

- [ ] **Step 1: 写失败测试（追加）**

```rust
// 追加到 crates/olico-core/tests/store.rs
use olico_core::model::ClipboardKind;

#[test]
fn clipboard_dedupes_by_hash() {
    let mut store = Store::open_in_memory().unwrap();
    store.clipboard_add(ClipboardKind::Text, Some("hello"), None, "h1", None, 100).unwrap();
    let second = store.clipboard_add(ClipboardKind::Text, Some("hello"), None, "h1", None, 200).unwrap();
    let items = store.clipboard_list("", None, 10).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(second.created_at, 200);
    assert_eq!(items[0].use_count, 1);
}

#[test]
fn clipboard_orders_pinned_first() {
    let mut store = Store::open_in_memory().unwrap();
    let a = store.clipboard_add(ClipboardKind::Text, Some("a"), None, "ha", None, 100).unwrap();
    store.clipboard_add(ClipboardKind::Text, Some("b"), None, "hb", None, 200).unwrap();
    store.clipboard_pin(&a.id, true).unwrap();
    let items = store.clipboard_list("", None, 10).unwrap();
    assert_eq!(items[0].id, a.id);
}

#[test]
fn clipboard_prune_respects_pins_and_limits() {
    let mut store = Store::open_in_memory().unwrap();
    for i in 0..5 {
        store
            .clipboard_add(ClipboardKind::Text, Some(&format!("v{i}")), None, &format!("h{i}"), None, i as i64)
            .unwrap();
    }
    let pinned = store.clipboard_list("", None, 1).unwrap()[0].id.clone();
    store.clipboard_pin(&pinned, true).unwrap();
    store.clipboard_prune(10, 2, 30).unwrap();
    let items = store.clipboard_list("", None, 10).unwrap();
    assert!(items.len() <= 3);
    assert!(items.iter().any(|i| i.id == pinned));
}

#[test]
fn clipboard_query_matches_text() {
    let mut store = Store::open_in_memory().unwrap();
    store.clipboard_add(ClipboardKind::Text, Some("hello world"), None, "h1", None, 1).unwrap();
    store.clipboard_add(ClipboardKind::Text, Some("goodbye"), None, "h2", None, 2).unwrap();
    let items = store.clipboard_list("hello", None, 10).unwrap();
    assert_eq!(items.len(), 1);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cargo test -p olico-core --test store`
Expected: 编译失败（`clipboard_add` 等方法不存在）。

- [ ] **Step 3: 实现剪贴板存储**

```rust
// crates/olico-core/src/store/clipboard.rs
use super::{Store, StoreError};
use crate::model::{ClipboardItem, ClipboardKind};
use rusqlite::{params, OptionalExtension, Row};

fn row_to_item(row: &Row<'_>) -> rusqlite::Result<ClipboardItem> {
    let kind: String = row.get(1)?;
    Ok(ClipboardItem {
        id: row.get(0)?,
        kind: match kind.as_str() {
            "image" => ClipboardKind::Image,
            "file" => ClipboardKind::File,
            _ => ClipboardKind::Text,
        },
        text: row.get(2)?,
        file_path: row.get(3)?,
        hash: row.get(4)?,
        source_app: row.get(5)?,
        created_at: row.get(6)?,
        pinned: row.get::<_, i64>(7)? != 0,
        use_count: row.get(8)?,
    })
}

const SELECT: &str =
    "SELECT id, kind, text, file_path, hash, source_app, created_at, pinned, use_count FROM clipboard";

impl Store {
    pub fn clipboard_add(
        &mut self,
        kind: ClipboardKind,
        text: Option<&str>,
        file_path: Option<&str>,
        hash: &str,
        source_app: Option<&str>,
        now: i64,
    ) -> Result<ClipboardItem, StoreError> {
        let id = uuid::Uuid::new_v4().to_string();
        self.conn.execute(
            "INSERT INTO clipboard (id, kind, text, file_path, hash, source_app, created_at, pinned, use_count)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, 0)
             ON CONFLICT(hash) DO UPDATE SET
               created_at = excluded.created_at,
               use_count = use_count + 1",
            params![id, kind.as_str(), text, file_path, hash, source_app, now],
        )?;
        self.clipboard_by_hash(hash)
    }

    fn clipboard_by_hash(&self, hash: &str) -> Result<ClipboardItem, StoreError> {
        let sql = format!("{SELECT} WHERE hash = ?1");
        self.conn
            .query_row(&sql, [hash], row_to_item)
            .optional()?
            .ok_or_else(|| StoreError::NotFound(hash.to_string()))
    }

    pub fn clipboard_list(
        &self,
        query: &str,
        kind: Option<ClipboardKind>,
        limit: usize,
    ) -> Result<Vec<ClipboardItem>, StoreError> {
        let pattern = format!("%{}%", query);
        let kind_filter = kind.map(|k| k.as_str()).unwrap_or("");
        let sql = format!(
            "{SELECT}
             WHERE (?1 = '' OR text LIKE ?1 OR file_path LIKE ?1)
               AND (?2 = '' OR kind = ?2)
             ORDER BY pinned DESC, created_at DESC
             LIMIT ?3"
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![pattern, kind_filter, limit as i64], row_to_item)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn clipboard_delete(&mut self, id: &str) -> Result<(), StoreError> {
        self.conn.execute("DELETE FROM clipboard WHERE id = ?1", [id])?;
        Ok(())
    }

    pub fn clipboard_pin(&mut self, id: &str, pinned: bool) -> Result<(), StoreError> {
        self.conn.execute("UPDATE clipboard SET pinned = ?1 WHERE id = ?2", params![pinned as i64, id])?;
        Ok(())
    }

    pub fn clipboard_clear(&mut self) -> Result<usize, StoreError> {
        Ok(self.conn.execute("DELETE FROM clipboard WHERE pinned = 0", [])?)
    }

    pub fn clipboard_prune(
        &mut self,
        now: i64,
        max_items: i64,
        retention_days: i64,
    ) -> Result<usize, StoreError> {
        let cutoff = now - retention_days * 86_400;
        let mut removed =
            self.conn.execute("DELETE FROM clipboard WHERE pinned = 0 AND created_at < ?1", [cutoff])?;
        removed += self.conn.execute(
            "DELETE FROM clipboard WHERE pinned = 0 AND id NOT IN (
                SELECT id FROM clipboard WHERE pinned = 0 ORDER BY created_at DESC LIMIT ?1
             )",
            [max_items.max(1)],
        )?;
        Ok(removed)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test store`
Expected: 7 passed。

- [ ] **Step 5: 提交**

```bash
git add crates/olico-core
git commit -m "feat(core): add clipboard history store"
```

---

## Task 7: 内置命令与上下文命令

**Files:**
- Create: `crates/olico-core/src/commands.rs`
- Modify: `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/commands.rs`

**Interfaces:**
- Consumes: `model::{Item, ItemKind, Action}`, `config::AppConfig`, `calculator::evaluate`
- Produces:
  - `commands::builtin_items() -> Vec<Item>`（固定 6 条：剪贴板、设置、退出、左/右/最大化/居中 4 个窗口动作中至少 left/right/maximize/center 与 clipboard/settings/quit，共 7 条）
  - `commands::contextual_items(query: &str, config: &AppConfig) -> Vec<Item>`

- [ ] **Step 1: 写失败测试**

`crates/olico-core/tests/commands.rs`：

```rust
use olico_core::commands::{builtin_items, contextual_items};
use olico_core::config::AppConfig;
use olico_core::model::Action;

#[test]
fn builtin_items_have_stable_ids() {
    let ids: Vec<String> = builtin_items().into_iter().map(|i| i.id).collect();
    assert!(ids.contains(&"cmd:clipboard".to_string()));
    assert!(ids.contains(&"cmd:settings".to_string()));
    assert!(ids.contains(&"cmd:quit".to_string()));
    assert!(ids.contains(&"cmd:win:left".to_string()));
}

#[test]
fn calculator_command_appears_for_expression() {
    let items = contextual_items("2+2", &AppConfig::default());
    let calc = items.iter().find(|i| i.id == "cmd:calc").unwrap();
    assert!(matches!(&calc.action, Action::CopyText { text } if text == "4"));
}

#[test]
fn web_search_command_uses_engine_template() {
    let items = contextual_items("g rust lang", &AppConfig::default());
    let web = items.iter().find(|i| i.id == "cmd:web:g").unwrap();
    match &web.action {
        Action::OpenUrl { url } => {
            assert!(url.starts_with("https://www.google.com/search?q="));
            assert!(url.contains("rust%20lang"));
        }
        other => panic!("unexpected action: {other:?}"),
    }
}

#[test]
fn no_contextual_items_for_plain_text() {
    assert!(contextual_items("hello", &AppConfig::default()).is_empty());
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cargo test -p olico-core --test commands`
Expected: 编译失败（模块不存在）。

- [ ] **Step 3: 实现命令模块**

```rust
// crates/olico-core/src/commands.rs
use crate::calculator::evaluate;
use crate::config::AppConfig;
use crate::model::{Action, Item, ItemKind};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};

fn item(
    id: &str,
    title: &str,
    subtitle: &str,
    keywords: &[&str],
    icon_ref: &str,
    kind: ItemKind,
    action: Action,
) -> Item {
    Item {
        id: id.into(),
        kind,
        title: title.into(),
        subtitle: subtitle.into(),
        keywords: keywords.iter().map(|s| s.to_string()).collect(),
        icon_ref: icon_ref.into(),
        action,
        source: "builtin".into(),
    }
}

pub fn builtin_items() -> Vec<Item> {
    vec![
        item(
            "cmd:clipboard",
            "剪贴板历史",
            "浏览并粘贴复制记录",
            &["clipboard", "paste", "剪贴板", "粘贴"],
            "doc.on.clipboard",
            ItemKind::BuiltinCommand,
            Action::RunBuiltin { name: "clipboard_history".into() },
        ),
        item(
            "cmd:settings",
            "打开设置",
            "热键、剪贴板与搜索引擎",
            &["settings", "preferences", "设置", "偏好"],
            "gearshape",
            ItemKind::BuiltinCommand,
            Action::RunBuiltin { name: "settings".into() },
        ),
        item(
            "cmd:quit",
            "退出 Olico",
            "关闭应用",
            &["quit", "exit", "退出"],
            "power",
            ItemKind::BuiltinCommand,
            Action::RunBuiltin { name: "quit".into() },
        ),
        item(
            "cmd:win:left",
            "窗口：左半屏",
            "将当前窗口放到左侧",
            &["left", "window", "左半屏", "分屏"],
            "rectangle.lefthalf.filled",
            ItemKind::WindowAction,
            Action::WindowAction { name: "left".into() },
        ),
        item(
            "cmd:win:right",
            "窗口：右半屏",
            "将当前窗口放到右侧",
            &["right", "window", "右半屏", "分屏"],
            "rectangle.righthalf.filled",
            ItemKind::WindowAction,
            Action::WindowAction { name: "right".into() },
        ),
        item(
            "cmd:win:maximize",
            "窗口：最大化",
            "铺满当前屏幕",
            &["maximize", "window", "最大化", "全屏"],
            "rectangle.inset.filled",
            ItemKind::WindowAction,
            Action::WindowAction { name: "maximize".into() },
        ),
        item(
            "cmd:win:center",
            "窗口：居中",
            "将窗口移到屏幕中央",
            &["center", "window", "居中"],
            "rectangle.center.inset.filled",
            ItemKind::WindowAction,
            Action::WindowAction { name: "center".into() },
        ),
    ]
}

fn format_number(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        let raw = format!("{value:.10}");
        raw.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

pub fn contextual_items(query: &str, config: &AppConfig) -> Vec<Item> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return vec![];
    }
    let mut items = Vec::new();

    if let Ok(value) = evaluate(trimmed) {
        let text = format_number(value);
        items.push(item(
            "cmd:calc",
            &format!("计算：{text}"),
            "回车复制结果",
            &["calculator", "计算器", "计算"],
            "function",
            ItemKind::BuiltinCommand,
            Action::CopyText { text },
        ));
    }

    for engine in &config.search.web_engines {
        let prefix = format!("{} ", engine.keyword);
        if let Some(rest) = trimmed.strip_prefix(&prefix) {
            let rest = rest.trim();
            if rest.is_empty() {
                continue;
            }
            let encoded = utf8_percent_encode(rest, NON_ALPHANUMERIC).to_string();
            let url = engine.url.replace("{query}", &encoded);
            items.push(item(
                &format!("cmd:web:{}", engine.keyword),
                &format!("用 {} 搜索“{rest}”", engine.name),
                &engine.name,
                &[engine.keyword.as_str(), "web", "搜索"],
                "magnifyingglass",
                ItemKind::BuiltinCommand,
                Action::OpenUrl { url },
            ));
        }
    }

    items
}
```

在 `lib.rs` 增加 `pub mod commands;`。

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test commands`
Expected: 4 passed。

- [ ] **Step 5: 提交**

```bash
git add crates/olico-core
git commit -m "feat(core): add builtin and contextual commands"
```

---

## Task 8: Core 调度层（全部 op）

**Files:**
- Create: `crates/olico-core/src/dispatch.rs`
- Modify: `crates/olico-core/src/lib.rs`
- Test: `crates/olico-core/tests/dispatch.rs`

**Interfaces:**
- Consumes: 前述全部模块
- Produces:
  - `dispatch::Core { dir: PathBuf }`
  - `Core::open(&Path) -> Result<Core, CoreError>`
  - `Core::dispatch_json(&mut self, raw: &str) -> String`
  - 支持的 op：`search`、`index_upsert_items`、`index_remove_stale`、`clipboard_add`、`clipboard_list`、`clipboard_delete`、`clipboard_pin`、`clipboard_clear`、`config_get`、`config_set`、`usage_record`

- [ ] **Step 1: 写失败测试**

`crates/olico-core/tests/dispatch.rs`：

```rust
use olico_core::dispatch::Core;
use serde_json::{json, Value};
use tempfile::tempdir;

fn call(core: &mut Core, op: &str, payload: Value) -> Value {
    let raw = json!({"v": 1, "op": op, "payload": payload}).to_string();
    serde_json::from_str(&core.dispatch_json(&raw)).unwrap()
}

fn app(id: &str, title: &str) -> Value {
    json!({
        "id": id, "kind": "application", "title": title, "subtitle": "/Applications/T.app",
        "keywords": ["test"], "icon_ref": "/Applications/T.app",
        "action": {"type": "open_app", "path": "/Applications/T.app"},
        "source": "mac_scan"
    })
}

#[test]
fn end_to_end_search_and_usage() {
    let dir = tempdir().unwrap();
    let mut core = Core::open(dir.path()).unwrap();

    let res = call(&mut core, "index_upsert_items", json!({"items": [app("a", "Alpha"), app("b", "Beta")]}));
    assert_eq!(res["ok"], true);

    let res = call(&mut core, "usage_record", json!({"item_id": "b"}));
    assert_eq!(res["ok"], true);

    let res = call(&mut core, "search", json!({"text": "", "scope": "apps", "limit": 10}));
    assert_eq!(res["data"][0]["item"]["id"], "b");
}

#[test]
fn unknown_op_returns_error() {
    let dir = tempdir().unwrap();
    let mut core = Core::open(dir.path()).unwrap();
    let res = call(&mut core, "nope", json!({}));
    assert_eq!(res["ok"], false);
    assert_eq!(res["error"]["code"], "unknown_op");
}

#[test]
fn config_roundtrip_through_dispatch() {
    let dir = tempdir().unwrap();
    let mut core = Core::open(dir.path()).unwrap();
    let mut config = call(&mut core, "config_get", json!({}))["data"].clone();
    config["clipboard"]["max_items"] = json!(42);
    let res = call(&mut core, "config_set", config);
    assert_eq!(res["ok"], true);
    let loaded = call(&mut core, "config_get", json!({}));
    assert_eq!(loaded["data"]["clipboard"]["max_items"], 42);
}

#[test]
fn clipboard_add_list_and_pin() {
    let dir = tempdir().unwrap();
    let mut core = Core::open(dir.path()).unwrap();
    let res = call(&mut core, "clipboard_add", json!({"kind": "text", "text": "hello"}));
    assert_eq!(res["ok"], true);
    let id = res["data"]["id"].as_str().unwrap().to_string();

    let listed = call(&mut core, "clipboard_list", json!({"query": "hell", "limit": 10}));
    assert_eq!(listed["data"].as_array().unwrap().len(), 1);

    let pinned = call(&mut core, "clipboard_pin", json!({"id": id, "pinned": true}));
    assert_eq!(pinned["ok"], true);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cargo test -p olico-core --test dispatch`
Expected: 编译失败（`dispatch` 不存在）。

- [ ] **Step 3: 实现 Core 与 op 分发**

```rust
// crates/olico-core/src/dispatch.rs
use crate::commands;
use crate::config::AppConfig;
use crate::model::{ClipboardKind, Item, Scope};
use crate::protocol::{api_error, err, ok, parse_request, ApiError};
use crate::search;
use crate::store::Store;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("config: {0}")]
    Config(#[from] crate::config::ConfigError),
    #[error("store: {0}")]
    Store(#[from] crate::store::StoreError),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

pub struct Core {
    pub dir: PathBuf,
    config: AppConfig,
    store: Store,
}

#[derive(Debug, Deserialize)]
struct SearchPayload {
    #[serde(default)]
    text: String,
    #[serde(default)]
    scope: Scope,
    #[serde(default = "default_limit")]
    limit: usize,
    #[serde(default)]
    extras: Vec<Item>,
}

fn default_limit() -> usize {
    20
}

#[derive(Debug, Deserialize)]
struct ItemsPayload {
    items: Vec<Item>,
}

#[derive(Debug, Deserialize)]
struct StalePayload {
    source: String,
    valid_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct ClipboardAddPayload {
    kind: ClipboardKind,
    text: Option<String>,
    file_path: Option<String>,
    source_app: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(default)]
struct ClipboardListPayload {
    query: String,
    kind: Option<ClipboardKind>,
    limit: usize,
}

impl Default for ClipboardListPayload {
    fn default() -> Self {
        Self { query: String::new(), kind: None, limit: 100 }
    }
}

#[derive(Debug, Deserialize)]
struct IdPayload {
    id: String,
}

#[derive(Debug, Deserialize)]
struct PinPayload {
    id: String,
    pinned: bool,
}

#[derive(Debug, Deserialize)]
struct UsagePayload {
    item_id: String,
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn internal(error: impl std::fmt::Display) -> ApiError {
    api_error("internal", error.to_string())
}

impl Core {
    pub fn open(dir: &Path) -> Result<Self, CoreError> {
        std::fs::create_dir_all(dir)?;
        let config = AppConfig::load(dir)?;
        let store = Store::open(&dir.join("olico.db"))?;
        Ok(Self { dir: dir.to_path_buf(), config, store })
    }

    pub fn dispatch_json(&mut self, raw: &str) -> String {
        let request = match parse_request(raw) {
            Ok(request) => request,
            Err(error) => return err(error),
        };
        match self.handle(&request.op, request.payload) {
            Ok(data) => ok(data),
            Err(error) => err(error),
        }
    }

    fn handle(&mut self, op: &str, payload: Value) -> Result<Value, ApiError> {
        match op {
            "search" => self.search(payload),
            "index_upsert_items" => {
                let p: ItemsPayload =
                    serde_json::from_value(payload).map_err(|e| api_error("invalid_payload", e.to_string()))?;
                self.store.upsert_items(&p.items).map_err(internal)?;
                Ok(json!({"upserted": p.items.len()}))
            }
            "index_remove_stale" => {
                let p: StalePayload =
                    serde_json::from_value(payload).map_err(|e| api_error("invalid_payload", e.to_string()))?;
                let removed = self.store.remove_stale(&p.source, &p.valid_ids).map_err(internal)?;
                Ok(json!({"removed": removed}))
            }
            "clipboard_add" => self.clipboard_add(payload),
            "clipboard_list" => {
                let p: ClipboardListPayload =
                    serde_json::from_value(payload).map_err(|e| api_error("invalid_payload", e.to_string()))?;
                let items = self.store.clipboard_list(&p.query, p.kind, p.limit).map_err(internal)?;
                Ok(serde_json::to_value(items).map_err(internal)?)
            }
            "clipboard_delete" => {
                let p: IdPayload =
                    serde_json::from_value(payload).map_err(|e| api_error("invalid_payload", e.to_string()))?;
                self.store.clipboard_delete(&p.id).map_err(internal)?;
                Ok(json!({}))
            }
            "clipboard_pin" => {
                let p: PinPayload =
                    serde_json::from_value(payload).map_err(|e| api_error("invalid_payload", e.to_string()))?;
                self.store.clipboard_pin(&p.id, p.pinned).map_err(internal)?;
                Ok(json!({}))
            }
            "clipboard_clear" => {
                let removed = self.store.clipboard_clear().map_err(internal)?;
                Ok(json!({"removed": removed}))
            }
            "config_get" => Ok(serde_json::to_value(&self.config).map_err(internal)?),
            "config_set" => {
                let config: AppConfig =
                    serde_json::from_value(payload).map_err(|e| api_error("invalid_payload", e.to_string()))?;
                if config.hotkey.mac.trim().is_empty() || config.clipboard.max_items < 1 {
                    return Err(api_error("invalid_payload", "hotkey and max_items must be valid"));
                }
                config.save(&self.dir).map_err(internal)?;
                self.config = config;
                Ok(json!({}))
            }
            "usage_record" => {
                let p: UsagePayload =
                    serde_json::from_value(payload).map_err(|e| api_error("invalid_payload", e.to_string()))?;
                self.store.record_usage(&p.item_id, chrono::Utc::now().timestamp()).map_err(internal)?;
                Ok(json!({}))
            }
            other => Err(api_error("unknown_op", format!("unknown op: {other}"))),
        }
    }

    fn search(&mut self, payload: Value) -> Result<Value, ApiError> {
        let p: SearchPayload =
            serde_json::from_value(payload).map_err(|e| api_error("invalid_payload", e.to_string()))?;
        let usage = self.store.usage().map_err(internal)?;
        let mut candidates = self.store.items().map_err(internal)?;
        candidates.extend(commands::builtin_items());
        candidates.extend(commands::contextual_items(&p.text, &self.config));
        candidates.extend(p.extras);

        let hits = search::search(
            &candidates,
            &usage,
            &p.text,
            p.scope,
            p.limit.min(200),
            chrono::Utc::now().timestamp(),
        );
        Ok(serde_json::to_value(hits).map_err(internal)?)
    }

    fn clipboard_add(&mut self, payload: Value) -> Result<Value, ApiError> {
        let p: ClipboardAddPayload =
            serde_json::from_value(payload).map_err(|e| api_error("invalid_payload", e.to_string()))?;
        let hash = match (&p.text, &p.file_path) {
            (Some(text), _) => sha256_hex(text.as_bytes()),
            (None, Some(path)) => {
                let bytes = std::fs::read(path).map_err(|e| api_error("invalid_payload", e.to_string()))?;
                sha256_hex(&bytes)
            }
            _ => return Err(api_error("invalid_payload", "text or file_path is required")),
        };
        let now = chrono::Utc::now().timestamp();
        let item = self
            .store
            .clipboard_add(p.kind, p.text.as_deref(), p.file_path.as_deref(), &hash, p.source_app.as_deref(), now)
            .map_err(internal)?;
        self.store
            .clipboard_prune(now, self.config.clipboard.max_items, self.config.clipboard.retention_days)
            .map_err(internal)?;
        Ok(serde_json::to_value(item).map_err(internal)?)
    }
}

#[allow(dead_code)]
fn _usage_type_check(_: HashMap<String, search::Usage>) {}
```

在 `lib.rs` 增加 `pub mod dispatch;`。

- [ ] **Step 4: 运行测试确认通过**

Run: `cargo test -p olico-core --test dispatch`
Expected: 4 passed。

- [ ] **Step 5: 运行全部核心测试与静态检查**

Run: `cargo fmt && cargo clippy -p olico-core --all-targets -- -D warnings && cargo test -p olico-core`
Expected: 全部通过；无 clippy 警告。

- [ ] **Step 6: 提交**

```bash
git add crates/olico-core
git commit -m "feat(core): add dispatch layer for all protocol ops"
```

---

## Task 9: FFI crate、C 头文件与冒烟测试

**Files:**
- Create: `crates/olico-ffi/Cargo.toml`, `crates/olico-ffi/build.rs`, `cbindgen.toml`, `src/lib.rs`
- Create: `crates/olico-ffi/tests/ffi.rs`, `crates/olico-ffi/tests/smoke.c`
- Create: `scripts/ffi-smoke.sh`
- Test: `crates/olico-ffi/tests/ffi.rs`、C 冒烟脚本

**Interfaces:**
- Consumes: `olico_core::dispatch::Core`
- Produces:
  - `olico_core_new(config_dir: *const c_char) -> *mut OlicoHandle`
  - `olico_core_free(*mut OlicoHandle)`
  - `olico_dispatch(*mut OlicoHandle, *const c_char) -> *mut c_char`
  - `olico_string_free(*mut c_char)`
  - `crates/olico-ffi/include/olico.h`

- [ ] **Step 1: 写失败测试**

`crates/olico-ffi/tests/ffi.rs`：

```rust
use olico_ffi::{olico_core_free, olico_core_new, olico_dispatch, olico_string_free};
use std::ffi::{CStr, CString};
use tempfile::tempdir;

#[test]
fn dispatch_through_c_abi() {
    let dir = tempdir().unwrap();
    let dir_c = CString::new(dir.path().to_str().unwrap()).unwrap();
    let handle = unsafe { olico_core_new(dir_c.as_ptr()) };
    assert!(!handle.is_null());

    let request = CString::new(r#"{"v":1,"op":"config_get","payload":{}}"#).unwrap();
    let response = unsafe { olico_dispatch(handle, request.as_ptr()) };
    assert!(!response.is_null());
    let text = unsafe { CStr::from_ptr(response) }.to_str().unwrap().to_string();
    unsafe { olico_string_free(response) };
    assert!(text.contains("\"ok\":true"));
    assert!(text.contains("\"mac\":\"alt+space\""));

    unsafe { olico_core_free(handle) };
}
```

- [ ] **Step 2: 创建 crate 并运行，确认失败**

```bash
mkdir -p crates/olico-ffi/src crates/olico-ffi/tests crates/olico-ffi/include
cat > crates/olico-ffi/Cargo.toml <<'EOF'
[package]
name = "olico-ffi"
version.workspace = true
edition.workspace = true

[lib]
crate-type = ["staticlib", "cdylib"]

[dependencies]
olico-core = { path = "../olico-core" }
serde_json = "1"

[dev-dependencies]
tempfile = "3"
EOF
printf '// placeholder\n' > crates/olico-ffi/src/lib.rs
```

Run: `cargo test -p olico-ffi`
Expected: 编译失败（导出函数不存在）。

- [ ] **Step 3: 实现 FFI 层**

```rust
// crates/olico-ffi/src/lib.rs
use olico_core::dispatch::Core;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::Mutex;

pub struct OlicoHandle {
    core: Mutex<Core>,
}

fn panic_response() -> String {
    serde_json::json!({
        "v": 1,
        "ok": false,
        "error": {"code": "panic", "message": "rust core panicked"}
    })
    .to_string()
}

fn to_c_string(text: String) -> *mut c_char {
    match CString::new(text) {
        Ok(value) => value.into_raw(),
        Err(_) => CString::new(panic_response()).unwrap().into_raw(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn olico_core_new(config_dir: *const c_char) -> *mut OlicoHandle {
    if config_dir.is_null() {
        return std::ptr::null_mut();
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let raw = CStr::from_ptr(config_dir).to_str().ok()?;
        let core = Core::open(&PathBuf::from(raw)).ok()?;
        Some(Box::into_raw(Box::new(OlicoHandle { core: Mutex::new(core) })))
    }));
    match result {
        Ok(Some(handle)) => handle,
        _ => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn olico_core_free(handle: *mut OlicoHandle) {
    if handle.is_null() {
        return;
    }
    drop(Box::from_raw(handle));
}

#[no_mangle]
pub unsafe extern "C" fn olico_dispatch(
    handle: *mut OlicoHandle,
    request_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() || request_json.is_null() {
        return to_c_string(panic_response());
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let raw = match CStr::from_ptr(request_json).to_str() {
            Ok(raw) => raw.to_string(),
            Err(_) => return to_c_string(panic_response()),
        };
        let handle = &*handle;
        let mut core = match handle.core.lock() {
            Ok(core) => core,
            Err(_) => return to_c_string(panic_response()),
        };
        to_c_string(core.dispatch_json(&raw))
    }));
    match result {
        Ok(pointer) => pointer,
        Err(_) => to_c_string(panic_response()),
    }
}

#[no_mangle]
pub unsafe extern "C" fn olico_string_free(pointer: *mut c_char) {
    if pointer.is_null() {
        return;
    }
    drop(CString::from_raw(pointer));
}
```

```toml
# crates/olico-ffi/cbindgen.toml
language = "C"
include_guard = "OLICO_FFI_H"
```

```rust
// crates/olico-ffi/build.rs
fn main() {
    println!("cargo:rerun-if-changed=src/lib.rs");
}
```

- [ ] **Step 4: 运行 Rust 测试确认通过**

Run: `cargo test -p olico-ffi`
Expected: 1 passed。

- [ ] **Step 5: 生成头文件并编译 C 冒烟**

`crates/olico-ffi/tests/smoke.c`：

```c
#include <stdio.h>
#include <string.h>
#include "olico.h"

int main(void) {
    OlicoHandle *handle = olico_core_new("/tmp/olico-smoke");
    if (handle == NULL) {
        fprintf(stderr, "olico_core_new failed\n");
        return 1;
    }
    char *response = olico_dispatch(handle, "{\"v\":1,\"op\":\"config_get\",\"payload\":{}}");
    if (response == NULL) {
        fprintf(stderr, "olico_dispatch returned null\n");
        olico_core_free(handle);
        return 1;
    }
    int ok = strstr(response, "\"ok\":true") != NULL;
    olico_string_free(response);
    olico_core_free(handle);
    return ok ? 0 : 1;
}
```

`scripts/ffi-smoke.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! command -v cbindgen >/dev/null 2>&1; then
  echo "cbindgen not found: cargo install cbindgen --version 0.27.0" >&2
  exit 1
fi
cbindgen --config crates/olico-ffi/cbindgen.toml \
  --crate olico-ffi \
  --output crates/olico-ffi/include/olico.h
cargo build -p olico-ffi --release
cc crates/olico-ffi/tests/smoke.c \
  -I crates/olico-ffi/include \
  -L target/release -lolico_ffi \
  -o /tmp/olico-ffi-smoke
DYLD_LIBRARY_PATH="$ROOT/target/release" /tmp/olico-ffi-smoke
echo "ffi smoke ok"
```

```bash
chmod +x scripts/ffi-smoke.sh
```

Run:
```bash
cargo install cbindgen --version 0.27.0 --locked
./scripts/ffi-smoke.sh
```
Expected: 输出 `ffi smoke ok`。

- [ ] **Step 6: 提交**

```bash
git add crates/olico-ffi scripts/ffi-smoke.sh
git commit -m "feat(ffi): expose core over c abi with smoke test"
```

---

<!-- PART2 -->
