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
- `olico-ffi` 发布链接使用 `["staticlib", "cdylib"]`；为支持 Rust 集成测试，crate-type 额外包含 `"rlib"`（rlib 不参与分发）。
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
/apps/macos/Sources/Bridge/OlicoFFI.h
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
    pub fn from_db(value: &str) -> Self {
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
  - `Store::open(&Path) -> Result<Store, StoreError>`、`Store::open_in_memory() -> Result<Store, StoreError>`
  - `Store::upsert_items(&mut self, &[Item]) -> Result<(), StoreError>`
  - `Store::remove_stale(&mut self, source: &str, valid_ids: &[String]) -> Result<usize, StoreError>`
  - `Store::items(&self) -> Result<Vec<Item>, StoreError>`
  - `Store::record_usage(&mut self, item_id: &str, now: i64) -> Result<(), StoreError>`
  - `Store::usage(&self) -> Result<HashMap<String, Usage>, StoreError>`

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
                kind: ItemKind::from_db(&kind),
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
  - `Store::clipboard_add(kind, text: Option<&str>, file_path: Option<&str>, hash: &str, source_app: Option<&str>, now: i64) -> Result<ClipboardItem, StoreError>`
  - `Store::clipboard_list(query: &str, kind: Option<ClipboardKind>, limit: usize) -> Result<Vec<ClipboardItem>, StoreError>`
  - `Store::clipboard_delete(id) -> Result<(), StoreError>`、`clipboard_pin(id, pinned) -> Result<(), StoreError>`、`clipboard_clear() -> Result<usize, StoreError>`
  - `Store::clipboard_prune(now, max_items, retention_days) -> Result<usize, StoreError>`

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
  - `commands::builtin_items() -> Vec<Item>`（7 条：clipboard、settings、quit 与 left/right/maximize/center）
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
        let hash = match p.kind {
            ClipboardKind::Text => p
                .text
                .as_deref()
                .map(|text| sha256_hex(text.as_bytes()))
                .ok_or_else(|| api_error("invalid_payload", "text is required"))?,
            ClipboardKind::File => p
                .file_path
                .as_deref()
                .map(|path| sha256_hex(path.as_bytes()))
                .ok_or_else(|| api_error("invalid_payload", "file_path is required"))?,
            ClipboardKind::Image => {
                let path = p
                    .file_path
                    .as_deref()
                    .ok_or_else(|| api_error("invalid_payload", "file_path is required"))?;
                let bytes =
                    std::fs::read(path).map_err(|e| api_error("invalid_payload", e.to_string()))?;
                sha256_hex(&bytes)
            }
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
- Create: `crates/olico-ffi/Cargo.toml`, `cbindgen.toml`, `src/lib.rs`
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
crate-type = ["staticlib", "cdylib", "rlib"]

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

## Task 10: macOS 工程骨架与 RustBridge

**Files:**
- Create: `apps/macos/project.yml`
- Create: `apps/macos/Sources/OlicoApp.swift`, `Sources/AppDelegate.swift`
- Create: `apps/macos/Sources/Bridge/RustBridge.swift`, `Sources/Bridge/Olico-Bridging-Header.h`
- Create: `apps/macos/Sources/Support/Paths.swift`
- Create: `scripts/build-ffi.sh`
- Test: `apps/macos/Tests/RustBridgeTests.swift`

**Interfaces:**
- Consumes: `olico_core_new` / `olico_dispatch` / `olico_string_free` / `olico_core_free`
- Produces:
  - `protocol CoreClient: AnyObject { func dispatch(op: String, payload: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) }`
  - `final class RustBridge: CoreClient`（init 抛错，completion 回主线程）
  - `enum Paths { static var configDir/imagesDir/logsDir: URL }`
  - Xcode 工程 `Olico.xcodeproj`（由 XcodeGen 生成）与测试 target `OlicoTests`

- [ ] **Step 1: 写失败测试**

`apps/macos/Tests/RustBridgeTests.swift`：

```swift
import XCTest
@testable import Olico

final class RustBridgeTests: XCTestCase {
    func testConfigGetReturnsDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olico-test-\(UUID().uuidString)")
        let bridge = try RustBridge(configDir: dir)
        let done = expectation(description: "config_get")

        bridge.dispatch(op: "config_get", payload: [:]) { result in
            switch result {
            case .success(let data):
                let config = data as? [String: Any]
                let hotkey = config?["hotkey"] as? [String: Any]
                XCTAssertEqual(hotkey?["mac"] as? String, "alt+space")
            case .failure(let error):
                XCTFail("unexpected error: \(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
}
```

- [ ] **Step 2: 创建工程文件与最小 App，运行确认测试无法编译**

`apps/macos/project.yml`：

```yaml
name: Olico
options:
  bundleIdPrefix: com.olico
  deploymentTarget:
    macOS: "13.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.9"
    MACOSX_DEPLOYMENT_TARGET: "13.0"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
targets:
  Olico:
    type: application
    platform: macOS
    sources:
      - path: Sources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.olico.app
        SWIFT_OBJC_BRIDGING_HEADER: Sources/Bridge/Olico-Bridging-Header.h
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
        ENABLE_HARDENED_RUNTIME: YES
        OTHER_LDFLAGS:
          - "-framework"
          - "Carbon"
          - "-framework"
          - "ApplicationServices"
          - "$(SRCROOT)/Vendor/libolico_ffi.a"
    info:
      path: Info.plist
      properties:
        LSUIElement: true
        LSMinimumSystemVersion: "13.0"
        CFBundleDisplayName: Olico
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
  OlicoTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests
    dependencies:
      - target: Olico
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.olico.app.tests
schemes:
  Olico:
    build:
      targets:
        Olico: all
        OlicoTests: [test]
    test:
      targets: [OlicoTests]
```

`apps/macos/Sources/Bridge/Olico-Bridging-Header.h`：

```c
#import "OlicoFFI.h"
```

`apps/macos/Sources/Support/Paths.swift`：

```swift
import Foundation

enum Paths {
    static var configDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olico", isDirectory: true)
    }
    static var imagesDir: URL { configDir.appendingPathComponent("images", isDirectory: true) }
    static var logsDir: URL { configDir.appendingPathComponent("logs", isDirectory: true) }

    static func prepare() throws {
        for dir in [configDir, imagesDir, logsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
```

`apps/macos/Sources/Bridge/RustBridge.swift`（本步骤先放桩，Step 3 再补全）：

```swift
import Foundation

enum BridgeError: LocalizedError {
    case createFailed
    case callFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .createFailed: return "无法初始化 Olico 核心"
        case .callFailed(let message): return message
        case .decodeFailed(let message): return "响应解析失败：\(message)"
        }
    }
}

protocol CoreClient: AnyObject {
    func dispatch(op: String, payload: [String: Any], completion: @escaping (Result<Any, Error>) -> Void)
}

final class RustBridge: CoreClient {
    init(configDir: URL) throws {
        throw BridgeError.createFailed
    }

    func dispatch(op: String, payload: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        completion(.failure(BridgeError.callFailed("not implemented")))
    }
}
```

`apps/macos/Sources/OlicoApp.swift`：

```swift
import SwiftUI

@main
struct OlicoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
```

`apps/macos/Sources/AppDelegate.swift`：

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var bridge: RustBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? Paths.prepare()
        bridge = try? RustBridge(configDir: Paths.configDir)
        setupStatusItem()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Olico")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "退出 Olico", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}
```

`scripts/build-ffi.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v cbindgen >/dev/null 2>&1; then
  echo "cbindgen not found: cargo install cbindgen --version 0.27.0" >&2
  exit 1
fi

rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build -p olico-ffi --release --target "$target"
done

mkdir -p apps/macos/Vendor apps/macos/Sources/Bridge
lipo -create \
  target/aarch64-apple-darwin/release/libolico_ffi.a \
  target/x86_64-apple-darwin/release/libolico_ffi.a \
  -output apps/macos/Vendor/libolico_ffi.a

cbindgen --config crates/olico-ffi/cbindgen.toml \
  --crate olico-ffi \
  --output apps/macos/Sources/Bridge/OlicoFFI.h
```

Run:
```bash
chmod +x scripts/build-ffi.sh
./scripts/build-ffi.sh
xcodegen generate --spec apps/macos/project.yml
xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
```
Expected: `RustBridgeTests` 失败（桩在初始化时抛出 `createFailed`），确认测试先红。

- [ ] **Step 3: 补全 RustBridge 并运行测试确认通过**

用以下实现替换 `RustBridge` 桩（`BridgeError` 与 `CoreClient` 保持不变）：

```swift
final class RustBridge: CoreClient {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "com.olico.rust", qos: .userInitiated)

    init(configDir: URL) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        guard let created = configDir.path.withCString({ olico_core_new($0) }) else {
            throw BridgeError.createFailed
        }
        handle = created
    }

    deinit {
        olico_core_free(handle)
    }

    func dispatch(op: String, payload: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        queue.async {
            do {
                let request: [String: Any] = ["v": 1, "op": op, "payload": payload]
                let encoded = try JSONSerialization.data(withJSONObject: request)
                let raw = String(decoding: encoded, as: UTF8.self)
                guard let pointer = raw.withCString({ olico_dispatch(self.handle, $0) }) else {
                    throw BridgeError.callFailed("核心返回空指针")
                }
                defer { olico_string_free(pointer) }
                let responseRaw = String(cString: pointer)
                guard
                    let response = try JSONSerialization.jsonObject(with: Data(responseRaw.utf8)) as? [String: Any]
                else {
                    throw BridgeError.decodeFailed(responseRaw)
                }
                if response["ok"] as? Bool != true {
                    let message = ((response["error"] as? [String: Any])?["message"] as? String) ?? "未知错误"
                    throw BridgeError.callFailed(message)
                }
                let data = response["data"] ?? NSNull()
                DispatchQueue.main.async { completion(.success(data)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
```

```bash
xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
```
Expected: `RustBridgeTests.testConfigGetReturnsDefaults` PASS。

- [ ] **Step 4: 手动验证 App 启动**

```bash
open apps/macos/build/Build/Products/Debug/Olico.app
```
（若未使用 `-derivedDataPath`，用 Xcode 产物路径；）预期：菜单栏出现 command 图标，无 Dock 图标。单实例由 LaunchServices 保证：同一 `.app` 再次双击只会激活已有进程，无需额外代码。

- [ ] **Step 5: 提交**

```bash
git add apps/macos scripts/build-ffi.sh
git commit -m "feat(macos): scaffold app and rust bridge"
```

---

## Task 11: 全局热键与浮层显隐

**Files:**
- Create: `apps/macos/Sources/Platform/HotkeyManager.swift`
- Create: `apps/macos/Sources/UI/LauncherPanel.swift`
- Modify: `apps/macos/Sources/AppDelegate.swift`
- Test: `apps/macos/Tests/HotkeyParserTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `HotkeyParser.parse(String) -> HotkeyParser.Combo?`（`Combo { keyCode, modifiers, canonical }`）
  - `HotkeyParser.canonical(from: NSEvent) -> String?`
  - `HotkeyManager.register(_ combo: String) -> Bool`、`unregister()`、`onTrigger`
  - `class LauncherPanel: NSPanel`（`init(rootView: AnyView)`、`toggle()`、`showCentered()`）

- [ ] **Step 1: 写失败测试**

`apps/macos/Tests/HotkeyParserTests.swift`：

```swift
import XCTest
import Carbon
@testable import Olico

final class HotkeyParserTests: XCTestCase {
    func testParsesAltSpace() {
        let combo = HotkeyParser.parse("alt+space")
        XCTAssertEqual(combo?.keyCode, 49)
        XCTAssertEqual(combo?.modifiers, UInt32(optionKey))
        XCTAssertEqual(combo?.canonical, "alt+space")
    }

    func testParsesModifierOrder() {
        let combo = HotkeyParser.parse("ctrl+alt+space")
        XCTAssertEqual(combo?.modifiers, UInt32(controlKey) | UInt32(optionKey))
        XCTAssertEqual(combo?.canonical, "ctrl+alt+space")
    }

    func testRejectsUnknownKey() {
        XCTAssertNil(HotkeyParser.parse("alt+notakey"))
        XCTAssertNil(HotkeyParser.parse("space"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Expected: 编译失败（`HotkeyParser` 不存在）。

- [ ] **Step 3: 实现热键解析与注册**

```swift
// apps/macos/Sources/Platform/HotkeyManager.swift
import AppKit
import Carbon

enum HotkeyParser {
    struct Combo: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        let canonical: String
    }

    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
        "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32,
        "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
    ]

    static let keyNames: [UInt32: String] = Dictionary(uniqueKeysWithValues: keyCodes.map { ($1, $0) })

    static func parse(_ text: String) -> Combo? {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        var modifiers: UInt32 = 0
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "alt", "option", "opt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: key = part
            }
        }
        guard let key, let code = keyCodes[key], modifiers != 0 else { return nil }
        return Combo(keyCode: code, modifiers: modifiers, canonical: canonicalString(modifiers: modifiers, key: key))
    }

    static func canonicalString(modifiers: UInt32, key: String) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("alt") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    static func canonical(from event: NSEvent) -> String? {
        guard let key = keyNames[UInt32(event.keyCode)] else { return nil }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0 else { return nil }
        return canonicalString(modifiers: modifiers, key: key)
    }
}

final class HotkeyManager {
    var onTrigger: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(_ combo: String) -> Bool {
        unregister()
        guard let parsed = HotkeyParser.parse(combo) else { return false }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onTrigger?() }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )

        var hotKeyID = EventHotKeyID(signature: OSType(0x4F4C4956), id: 1)
        let status = RegisterEventHotKey(
            parsed.keyCode,
            parsed.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit { unregister() }
}
```

- [ ] **Step 4: 实现浮层与显隐**

```swift
// apps/macos/Sources/UI/LauncherPanel.swift
import AppKit
import SwiftUI

class LauncherPanel: NSPanel {
    init(rootView: AnyView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: rootView)
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        orderOut(nil)
    }

    func showCentered() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2 + visible.height * 0.08
        )
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            showCentered()
        }
    }
}
```

在 `AppDelegate` 中增加：

```swift
private var panel: LauncherPanel?
private var hotkey: HotkeyManager?

// 在 applicationDidFinishLaunching 中 setupStatusItem() 之前：
panel = LauncherPanel(rootView: AnyView(Text("Olico").frame(width: 680, height: 460)))
hotkey = HotkeyManager()
hotkey?.onTrigger = { [weak self] in self?.panel?.toggle() }
if hotkey?.register("alt+space") != true {
    let alert = NSAlert()
    alert.messageText = "全局热键注册失败"
    alert.informativeText = "Option+Space 可能已被其他应用占用，请在设置中更换热键。"
    alert.runModal()
}
```

- [ ] **Step 5: 运行测试并手动验证**

```bash
xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
open apps/macos/Olico.xcodeproj
```
Expected: 测试通过；运行 App 后按 `Option+Space` 显示/隐藏浮层，`Esc` 关闭。

- [ ] **Step 6: 提交**

```bash
git add apps/macos
git commit -m "feat(macos): global hotkey and floating launcher panel"
```

---

## Task 12: 启动器 UI、ViewModel 与动作执行

**Files:**
- Create: `apps/macos/Sources/Models/Models.swift`
- Create: `apps/macos/Sources/UI/LauncherViewModel.swift`, `LauncherView.swift`, `SearchField.swift`, `ToastView.swift`
- Create: `apps/macos/Sources/Platform/ActionExecutor.swift`
- Modify: `apps/macos/Sources/AppDelegate.swift`
- Test: `apps/macos/Tests/LauncherViewModelTests.swift`

**Interfaces:**
- Consumes: `CoreClient`、`olico_dispatch` 的 `search` / `usage_record`
- Produces:
  - `OlicoItem`、`OlicoAction`、`SearchHit`（Codable）
  - `protocol ActionExecuting { func execute(_ action: OlicoAction, completion: @escaping (Error?) -> Void) }`
  - `protocol WindowActionPerforming { func perform(_ name: String, completion: @escaping (Error?) -> Void) }`（窗口动作的窄接口，Task 15 提供实现）
  - `@MainActor final class LauncherViewModel`：`queryChanged`、`move`、`executeSelected`、`reset`、`sections`、`selectedHitID`、`toast`、`onHide`、`fileSearch`、`fileSearchEnabled`
  - `struct SearchField: NSViewRepresentable`（处理 ↑/↓/Enter/Esc，输入法组合期间不拦截）

- [ ] **Step 1: 写失败测试**

`apps/macos/Tests/LauncherViewModelTests.swift`：

```swift
import XCTest
@testable import Olico

final class FakeClient: CoreClient {
    var lastOp: String?
    var lastPayload: [String: Any] = [:]
    var searchResponse: [[String: Any]] = []

    func dispatch(op: String, payload: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        lastOp = op
        lastPayload = payload
        DispatchQueue.main.async {
            if op == "search" {
                completion(.success(self.searchResponse))
            } else {
                completion(.success([:]))
            }
        }
    }
}

final class FakeExecutor: ActionExecuting {
    var executed: [OlicoAction] = []
    func execute(_ action: OlicoAction, completion: @escaping (Error?) -> Void) {
        executed.append(action)
        completion(nil)
    }
}

@MainActor
final class LauncherViewModelTests: XCTestCase {
    private func hit(id: String, title: String, kind: String = "application") -> [String: Any] {
        [
            "item": [
                "id": id, "kind": kind, "title": title, "subtitle": "",
                "keywords": [], "icon_ref": "", "source": "test",
                "action": ["type": "open_app", "path": "/Applications/\(title).app"],
            ],
            "score": 1.0,
            "match_ranges": [[0, 1]],
        ]
    }

    func testSearchUpdatesHits() {
        let client = FakeClient()
        client.searchResponse = [hit(id: "a", title: "Alpha")]
        let viewModel = LauncherViewModel(client: client, executor: FakeExecutor(), debounceInterval: 0.01)
        let done = expectation(description: "search")

        viewModel.queryChanged("alp")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(client.lastOp, "search")
            XCTAssertEqual(client.lastPayload["text"] as? String, "alp")
            XCTAssertEqual(viewModel.hits.first?.item.id, "a")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testMoveClampsSelection() {
        let client = FakeClient()
        client.searchResponse = [hit(id: "a", title: "Alpha"), hit(id: "b", title: "Beta")]
        let viewModel = LauncherViewModel(client: client, executor: FakeExecutor(), debounceInterval: 0)
        viewModel.hits = [SearchHit(item: OlicoItem(id: "a", kind: "application", title: "Alpha", subtitle: "", keywords: [], iconRef: "", action: OlicoAction(type: "open_app", path: nil, url: nil, text: nil, name: nil), source: "test"), score: 1, matchRanges: [])]
        viewModel.move(5)
        XCTAssertEqual(viewModel.selectedIndex, 0)
        viewModel.move(-5)
        XCTAssertEqual(viewModel.selectedIndex, 0)
    }

    func testExecuteCallsUsageAndHides() {
        let client = FakeClient()
        let executor = FakeExecutor()
        let viewModel = LauncherViewModel(client: client, executor: executor, debounceInterval: 0)
        viewModel.hits = [
            SearchHit(
                item: OlicoItem(
                    id: "a",
                    kind: "application",
                    title: "Alpha",
                    subtitle: "",
                    keywords: [],
                    iconRef: "",
                    action: OlicoAction(type: "open_app", path: "/Applications/Alpha.app", url: nil, text: nil, name: nil),
                    source: "test"
                ),
                score: 1,
                matchRanges: []
            )
        ]
        var hidden = false
        viewModel.onHide = { hidden = true }
        viewModel.executeSelected()
        XCTAssertEqual(executor.executed.first?.type, "open_app")
        XCTAssertEqual(client.lastOp, "usage_record")
        XCTAssertTrue(hidden)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Expected: 编译失败（`LauncherViewModel` 等不存在）。

- [ ] **Step 3: 实现模型与 ViewModel**

```swift
// apps/macos/Sources/Models/Models.swift
import Foundation

struct OlicoAction: Codable, Equatable {
    let type: String
    let path: String?
    let url: String?
    let text: String?
    let name: String?
}

struct OlicoItem: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String
    let keywords: [String]
    let iconRef: String
    let action: OlicoAction
    let source: String

    enum CodingKeys: String, CodingKey {
        case id, kind, title, subtitle, keywords, action, source
        case iconRef = "icon_ref"
    }
}

struct SearchHit: Codable, Identifiable, Equatable {
    let item: OlicoItem
    let score: Double
    let matchRanges: [[UInt32]]

    var id: String { item.id }

    enum CodingKeys: String, CodingKey {
        case item, score
        case matchRanges = "match_ranges"
    }
}

protocol FileSearching: AnyObject {
    func search(_ query: String, completion: @escaping ([[String: Any]]) -> Void)
}
```

```swift
// apps/macos/Sources/UI/LauncherViewModel.swift
import Foundation

struct ResultSection: Identifiable {
    let title: String
    let hits: [SearchHit]
    var id: String { title }
}

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var query = ""
    @Published var hits: [SearchHit] = []
    @Published var selectedIndex = 0
    @Published var toast: String?

    var onHide: (() -> Void)?
    weak var fileSearch: FileSearching?
    var fileSearchEnabled = true

    private let client: CoreClient
    private let executor: ActionExecuting
    private let debounceInterval: TimeInterval
    private var debounceWork: DispatchWorkItem?

    init(client: CoreClient, executor: ActionExecuting, debounceInterval: TimeInterval = 0.04) {
        self.client = client
        self.executor = executor
        self.debounceInterval = debounceInterval
    }

    var selectedHit: SearchHit? {
        hits.indices.contains(selectedIndex) ? hits[selectedIndex] : nil
    }

    var selectedHitID: String? { selectedHit?.id }

    var sections: [ResultSection] {
        var order: [String] = []
        var grouped: [String: [SearchHit]] = [:]
        for hit in hits {
            if grouped[hit.item.kind] == nil {
                order.append(hit.item.kind)
                grouped[hit.item.kind] = []
            }
            grouped[hit.item.kind]?.append(hit)
        }
        let titles = [
            "application": "应用",
            "file": "文件",
            "builtin_command": "命令",
            "window_action": "窗口",
        ]
        return order.map { ResultSection(title: titles[$0] ?? $0, hits: grouped[$0] ?? []) }
    }

    func reset() {
        query = ""
        hits = []
        selectedIndex = 0
        toast = nil
        debounceWork?.cancel()
        performSearch()
    }

    func queryChanged(_ text: String) {
        query = text
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performSearch() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func performSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var extras: [[String: Any]] = []
        let group = DispatchGroup()
        if fileSearchEnabled, text.count >= 2, let fileSearch {
            group.enter()
            fileSearch.search(text) { items in
                extras = items
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let payload: [String: Any] = ["text": text, "scope": "all", "limit": 20, "extras": extras]
            self.client.dispatch(op: "search", payload: payload) { result in
                switch result {
                case .success(let data):
                    do {
                        let raw = try JSONSerialization.data(withJSONObject: data)
                        self.hits = try JSONDecoder().decode([SearchHit].self, from: raw)
                        self.selectedIndex = 0
                    } catch {
                        self.showToast("搜索结果解析失败")
                    }
                case .failure(let error):
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selectedIndex = max(0, min(hits.count - 1, selectedIndex + delta))
    }

    func select(_ id: String) {
        guard let index = hits.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    func executeSelected() {
        guard let hit = selectedHit else { return }
        executor.execute(hit.item.action) { [weak self] error in
            guard let self else { return }
            if let error {
                self.showToast(error.localizedDescription)
                return
            }
            self.client.dispatch(op: "usage_record", payload: ["item_id": hit.id]) { _ in }
            self.onHide?()
        }
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}
```

- [ ] **Step 4: 实现 UI 与动作执行**

`SearchField.swift`：

```swift
import AppKit
import SwiftUI

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22)
        field.placeholderString = "搜索应用、文件或输入命令…"
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
```

`ToastView.swift`：

```swift
import SwiftUI

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(radius: 8)
    }
}
```

`LauncherView.swift`：

```swift
import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        VStack(spacing: 0) {
            SearchField(
                text: Binding(get: { viewModel.query }, set: { viewModel.queryChanged($0) }),
                onMove: { viewModel.move($0) },
                onSubmit: { viewModel.executeSelected() },
                onCancel: { viewModel.onHide?() }
            )
            .frame(height: 52)
            .padding(.horizontal, 16)

            Divider().opacity(0.15)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.sections) { section in
                            Text(section.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                            ForEach(section.hits) { hit in
                                ResultRow(hit: hit, selected: hit.id == viewModel.selectedHitID)
                                    .id(hit.id)
                                    .onTapGesture {
                                        viewModel.select(hit.id)
                                        viewModel.executeSelected()
                                    }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: viewModel.selectedIndex) { _ in
                    if let id = viewModel.selectedHitID {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }

            HStack {
                Text("↑↓ 选择    ↵ 执行    esc 关闭")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 680, height: 460)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toast {
                ToastView(text: toast).padding(.bottom, 40)
            }
        }
    }
}

struct ResultRow: View {
    let hit: SearchHit
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.item.title).lineLimit(1)
                if !hit.item.subtitle.isEmpty {
                    Text(hit.item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var icon: some View {
        if hit.item.kind == "application" || hit.item.kind == "file" {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.item.iconRef))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: hit.item.iconRef.isEmpty ? "terminal" : hit.item.iconRef)
                .font(.system(size: 18))
        }
    }
}
```

`ActionExecutor.swift`：

```swift
import AppKit

protocol WindowActionPerforming: AnyObject {
    func perform(_ name: String, completion: @escaping (Error?) -> Void)
}

final class ActionExecutor: ActionExecuting {
    var onBuiltin: ((String) -> Void)?
    var windowActions: WindowActionPerforming?

    func execute(_ action: OlicoAction, completion: @escaping (Error?) -> Void) {
        switch action.type {
        case "open_app":
            if let path = action.path { AppLauncher.open(path: path) }
            completion(nil)
        case "open_path":
            if let path = action.path {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            completion(nil)
        case "open_url":
            if let url = action.url.flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
            }
            completion(nil)
        case "copy_text":
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(action.text ?? "", forType: .string)
            completion(nil)
        case "run_builtin":
            onBuiltin?(action.name ?? "")
            completion(nil)
        case "window_action":
            guard let windowActions else {
                completion(nil)
                return
            }
            windowActions.perform(action.name ?? "", completion: completion)
        default:
            completion(BridgeError.callFailed("未知动作：\(action.type)"))
        }
    }
}

enum AppLauncher {
    static func open(path: String) {
        let url = URL(fileURLWithPath: path)
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == url.standardizedFileURL
        }
        if let running {
            running.activate(options: [.activateIgnoringOtherApps])
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
    }
}
```

在 `AppDelegate` 中增加 `private var launcherViewModel: LauncherViewModel?`，并替换浮层初始化：

```swift
let executor = ActionExecutor()
executor.onBuiltin = { name in
    if name == "quit" { NSApp.terminate(nil) }
}
let viewModel = LauncherViewModel(client: bridge!, executor: executor)
launcherViewModel = viewModel
let panel = LauncherPanel(rootView: AnyView(LauncherView(viewModel: viewModel)))
viewModel.onHide = { [weak panel] in panel?.orderOut(nil) }
hotkey?.onTrigger = { [weak panel, weak viewModel] in
    if panel?.isVisible == true {
        panel?.orderOut(nil)
    } else {
        viewModel?.reset()
        panel?.showCentered()
    }
}
self.panel = panel
```

- [ ] **Step 5: 运行测试确认通过**

Run: `xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Expected: ViewModel 三个用例 PASS。

- [ ] **Step 6: 提交**

```bash
git add apps/macos
git commit -m "feat(macos): launcher ui and view model"
```

---

## Task 13: 应用索引、文件搜索与启动

**Files:**
- Create: `apps/macos/Sources/Platform/AppIndexer.swift`
- Create: `apps/macos/Sources/Platform/FileSearchService.swift`
- Modify: `apps/macos/Sources/AppDelegate.swift`
- Test: `apps/macos/Tests/AppScannerTests.swift`

**Interfaces:**
- Consumes: `CoreClient`、`olico_dispatch` 的 `index_upsert_items` / `index_remove_stale`
- Produces:
  - `AppScanner.scan(dirs: [URL]) -> [[String: Any]]`（Item JSON 字典）
  - `AppIndexer.refreshIfNeeded(force: Bool)`
  - `final class FileSearchService: FileSearching`

- [ ] **Step 1: 写失败测试**

`apps/macos/Tests/AppScannerTests.swift`：

```swift
import XCTest
@testable import Olico

final class AppScannerTests: XCTestCase {
    func testScanFindsAppBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apps-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let items = AppScanner.scan(dirs: [root])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["kind"] as? String, "application")
        XCTAssertEqual(items[0]["title"] as? String, "Demo")
        let action = items[0]["action"] as? [String: Any]
        XCTAssertEqual(action?["type"] as? String, "open_app")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Expected: 编译失败（`AppScanner` 不存在）。

- [ ] **Step 3: 实现应用扫描与索引**

```swift
// apps/macos/Sources/Platform/AppIndexer.swift
import AppKit
import CoreServices
import Foundation

struct AppScanner {
    static var defaultDirs: [URL] {
        var dirs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
        ]
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        if FileManager.default.fileExists(atPath: userApps.path) {
            dirs.append(userApps)
        }
        return dirs
    }

    static func scan(dirs: [URL]) -> [[String: Any]] {
        var seen = Set<String>()
        var items: [[String: Any]] = []
        for dir in dirs {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in children where url.pathExtension == "app" {
                let path = url.path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                let name = url.deletingPathExtension().lastPathComponent
                let bundleID = Bundle(url: url)?.bundleIdentifier ?? path
                items.append([
                    "id": bundleID,
                    "kind": "application",
                    "title": name,
                    "subtitle": path,
                    "keywords": [name],
                    "icon_ref": path,
                    "action": ["type": "open_app", "path": path],
                    "source": "mac_scan",
                ])
            }
        }
        return items
    }
}

final class AppIndexer {
    private let client: CoreClient
    private let dirs: [URL]
    private var lastRefresh: Date?
    private let ttl: TimeInterval
    private var stream: FSEventStreamRef?

    init(client: CoreClient, dirs: [URL] = AppScanner.defaultDirs, ttl: TimeInterval = 300) {
        self.client = client
        self.dirs = dirs
        self.ttl = ttl
    }

    func refreshIfNeeded(force: Bool = false) {
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < ttl {
            return
        }
        let items = AppScanner.scan(dirs: dirs)
        lastRefresh = Date()
        client.dispatch(op: "index_upsert_items", payload: ["items": items]) { _ in }
        let ids = items.compactMap { $0["id"] as? String }
        client.dispatch(op: "index_remove_stale", payload: ["source": "mac_scan", "valid_ids": ids]) { _ in }
    }

    func startWatching() {
        guard stream == nil else { return }
        let paths = dirs.map(\.path) as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let indexer = Unmanaged<AppIndexer>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { indexer.refreshIfNeeded(force: true) }
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
    }

    func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stopWatching() }
}
```

`FileSearchService.swift`：

```swift
import Foundation

final class FileSearchService: FileSearching {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    func search(_ text: String, completion: @escaping ([[String: Any]]) -> Void) {
        cancel()
        guard text.count >= 2 else {
            completion([])
            return
        }
        let md = NSMetadataQuery()
        md.searchScopes = [FileManager.default.homeDirectoryForCurrentUser]
        md.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(text)*")
        query = md
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: md,
            queue: .main
        ) { [weak self] _ in
            guard let self, let md = self.query else { return }
            md.disableUpdates()
            let results: [[String: Any]] = md.results.prefix(20).compactMap { element in
                guard
                    let item = element as? NSMetadataItem,
                    let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
                else { return nil }
                return [
                    "id": path,
                    "kind": "file",
                    "title": (path as NSString).lastPathComponent,
                    "subtitle": path,
                    "keywords": [] as [String],
                    "icon_ref": path,
                    "action": ["type": "open_path", "path": path],
                    "source": "spotlight",
                ]
            }
            md.stop()
            self.query = nil
            completion(results)
        }
        md.start()
    }

    func cancel() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        query?.stop()
        query = nil
    }

    deinit { cancel() }
}
```

在 `AppDelegate` 中接线：

```swift
private var indexer: AppIndexer?
private var fileSearch: FileSearchService?

// applicationDidFinishLaunching 中创建 bridge 后：
indexer = AppIndexer(client: bridge!)
indexer?.refreshIfNeeded(force: true)
indexer?.startWatching()
fileSearch = FileSearchService()
launcherViewModel?.fileSearch = fileSearch
bridge?.dispatch(op: "config_get", payload: [:]) { result in
    let config = result as? [String: Any]
    let search = config?["search"] as? [String: Any]
    launcherViewModel?.fileSearchEnabled = search?["file_search"] as? Bool ?? true
}
// 每次呼出时刷新索引：
hotkey?.onTrigger = { [weak self] in
    self?.indexer?.refreshIfNeeded()
    ...
}
```

- [ ] **Step 4: 运行测试并手动验证**

```bash
xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
```
Expected: `AppScannerTests` PASS；运行 App 后可搜索本机应用，前 2 个字符搜索到主目录文件。

- [ ] **Step 5: 提交**

```bash
git add apps/macos
git commit -m "feat(macos): index applications and search files with spotlight"
```

---

## Task 14: 剪贴板监控、历史面板与回贴

**Files:**
- Create: `apps/macos/Sources/Platform/ClipboardMonitor.swift`, `PasteService.swift`
- Create: `apps/macos/Sources/UI/ClipboardViewModel.swift`, `ClipboardView.swift`, `ClipboardPanel.swift`
- Modify: `apps/macos/Sources/AppDelegate.swift`
- Test: `apps/macos/Tests/ClipboardTests.swift`

**Interfaces:**
- Consumes: `CoreClient` 的 `clipboard_add` / `clipboard_list` / `clipboard_pin` / `clipboard_delete`
- Produces:
  - `ClipboardPolicy.shouldIgnore(types: [String], frontmost: String?, excluded: Set<String>, ignoreConcealed: Bool) -> Bool`
  - `ClipboardMonitor.start()/stop()`、`isEnabled`、`excludedApps`、`ignoreConcealed`
  - `ClipboardEntry`、`@MainActor final class ClipboardViewModel`
  - `protocol Pasting { func paste(_ entry: ClipboardEntry) -> Bool }`

- [ ] **Step 1: 写失败测试**

`apps/macos/Tests/ClipboardTests.swift`：

```swift
import XCTest
@testable import Olico

final class ClipboardPolicyTests: XCTestCase {
    func testIgnoresConcealedTypes() {
        XCTAssertTrue(ClipboardPolicy.shouldIgnore(
            types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
            frontmost: "com.apple.Safari",
            excluded: [],
            ignoreConcealed: true
        ))
    }

    func testIgnoresExcludedApp() {
        XCTAssertTrue(ClipboardPolicy.shouldIgnore(
            types: ["public.utf8-plain-text"],
            frontmost: "com.1password.1password",
            excluded: ["com.1password.1password"],
            ignoreConcealed: false
        ))
    }

    func testAllowsNormalText() {
        XCTAssertFalse(ClipboardPolicy.shouldIgnore(
            types: ["public.utf8-plain-text"],
            frontmost: "com.apple.Safari",
            excluded: [],
            ignoreConcealed: true
        ))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Expected: 编译失败（`ClipboardPolicy` 不存在）。

- [ ] **Step 3: 实现监控与回贴**

```swift
// apps/macos/Sources/Platform/ClipboardMonitor.swift
import AppKit
import CryptoKit
import Foundation

enum ClipboardPolicy {
    static func shouldIgnore(
        types: [String],
        frontmost: String?,
        excluded: Set<String>,
        ignoreConcealed: Bool
    ) -> Bool {
        if let frontmost, excluded.contains(frontmost) { return true }
        guard ignoreConcealed else { return false }
        return types.contains { type in
            type.contains("Concealed") || type.contains("Transient")
        }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

final class ClipboardMonitor {
    var isEnabled = true
    var excludedApps: Set<String> = []
    var ignoreConcealed = true

    private let client: CoreClient
    private var timer: Timer?
    private var lastChangeCount = -1

    init(client: CoreClient) {
        self.client = client
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard isEnabled else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let types = (pasteboard.types ?? []).map(\.rawValue)
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !ClipboardPolicy.shouldIgnore(
            types: types,
            frontmost: frontmost,
            excluded: excludedApps,
            ignoreConcealed: ignoreConcealed
        ) else { return }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first {
            client.dispatch(op: "clipboard_add", payload: [
                "kind": "file", "file_path": first.path, "source_app": frontmost ?? "",
            ]) { _ in }
            return
        }

        if let image = NSImage(pasteboard: pasteboard), let png = image.pngData() {
            let hash = sha256Hex(png)
            let path = Paths.imagesDir.appendingPathComponent("\(hash).png")
            if !FileManager.default.fileExists(atPath: path.path) {
                try? png.write(to: path)
            }
            client.dispatch(op: "clipboard_add", payload: [
                "kind": "image", "file_path": path.path, "source_app": frontmost ?? "",
            ]) { _ in }
            return
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            client.dispatch(op: "clipboard_add", payload: [
                "kind": "text", "text": text, "source_app": frontmost ?? "",
            ]) { _ in }
        }
    }
}
```

```swift
// apps/macos/Sources/Platform/PasteService.swift
import AppKit
import ApplicationServices

protocol Pasting: AnyObject {
    func paste(_ entry: ClipboardEntry) -> Bool
}

final class PasteService: Pasting {
    func paste(_ entry: ClipboardEntry) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.kind {
        case "text":
            pasteboard.setString(entry.text ?? "", forType: .string)
        case "image":
            if let path = entry.filePath, let image = NSImage(contentsOfFile: path) {
                pasteboard.writeObjects([image])
            }
        case "file":
            if let path = entry.filePath {
                pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
            }
        default:
            break
        }
        guard AXIsProcessTrusted() else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
        return true
    }
}
```

- [ ] **Step 4: 实现剪贴板 ViewModel 与面板**

```swift
// apps/macos/Sources/UI/ClipboardViewModel.swift
import Foundation

struct ClipboardEntry: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let text: String?
    let filePath: String?
    let hash: String
    let sourceApp: String?
    let createdAt: Int64
    let pinned: Bool
    let useCount: UInt32

    enum CodingKeys: String, CodingKey {
        case id, kind, text, hash, pinned
        case filePath = "file_path"
        case sourceApp = "source_app"
        case createdAt = "created_at"
        case useCount = "use_count"
    }
}

@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var query = ""
    @Published var entries: [ClipboardEntry] = []
    @Published var selectedIndex = 0
    @Published var toast: String?

    var onHide: (() -> Void)?

    private let client: CoreClient
    private let paster: Pasting

    init(client: CoreClient, paster: Pasting) {
        self.client = client
        self.paster = paster
    }

    func reload() {
        client.dispatch(op: "clipboard_list", payload: ["query": query, "limit": 100]) { result in
            guard case .success(let data) = result else { return }
            do {
                let raw = try JSONSerialization.data(withJSONObject: data)
                self.entries = try JSONDecoder().decode([ClipboardEntry].self, from: raw)
                self.selectedIndex = min(self.selectedIndex, max(0, self.entries.count - 1))
            } catch {
                self.showToast("剪贴板数据解析失败")
            }
        }
    }

    func queryChanged(_ text: String) {
        query = text
        reload()
    }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = max(0, min(entries.count - 1, selectedIndex + delta))
    }

    func select(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    func pasteSelected() {
        guard entries.indices.contains(selectedIndex) else { return }
        let autoPasted = paster.paste(entries[selectedIndex])
        if !autoPasted { showToast("已复制，粘贴需要辅助功能权限") }
        onHide?()
    }

    func togglePin(_ entry: ClipboardEntry) {
        client.dispatch(op: "clipboard_pin", payload: ["id": entry.id, "pinned": !entry.pinned]) { _ in
            self.reload()
        }
    }

    func delete(_ entry: ClipboardEntry) {
        client.dispatch(op: "clipboard_delete", payload: ["id": entry.id]) { _ in
            self.reload()
        }
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}
```

`ClipboardView.swift`：

```swift
import SwiftUI

struct ClipboardView: View {
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            SearchField(
                text: Binding(get: { viewModel.query }, set: { viewModel.queryChanged($0) }),
                onMove: { viewModel.move($0) },
                onSubmit: { viewModel.pasteSelected() },
                onCancel: { viewModel.onHide?() }
            )
            .frame(height: 52)
            .padding(.horizontal, 16)

            Divider().opacity(0.15)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.entries) { entry in
                        ClipboardRow(
                            entry: entry,
                            selected: entry.id == viewModel.entries[safe: viewModel.selectedIndex]?.id,
                            onPin: { viewModel.togglePin(entry) },
                            onDelete: { viewModel.delete(entry) }
                        )
                        .onTapGesture {
                            viewModel.select(entry.id)
                            viewModel.pasteSelected()
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            HStack {
                Text("↑↓ 选择    ↵ 粘贴    图钉置顶    垃圾桶删除    esc 关闭")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 680, height: 460)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toast {
                ToastView(text: toast).padding(.bottom, 40)
            }
        }
    }
}

struct ClipboardRow: View {
    let entry: ClipboardEntry
    let selected: Bool
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind == "text" ? "text.alignleft" : entry.kind == "image" ? "photo" : "doc")
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text ?? entry.filePath ?? "（空）")
                    .lineLimit(1)
                if let source = entry.sourceApp, !source.isEmpty {
                    Text(source).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onPin) {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

`ClipboardPanel.swift`：

```swift
import SwiftUI

final class ClipboardPanel: LauncherPanel {
    init(viewModel: ClipboardViewModel) {
        super.init(rootView: AnyView(ClipboardView(viewModel: viewModel)))
    }
}
```

在 `AppDelegate` 中接线：

```swift
private var clipboardMonitor: ClipboardMonitor?
private var clipboardViewModel: ClipboardViewModel?
private var clipboardPanel: LauncherPanel?

// 创建 bridge 后：
let monitor = ClipboardMonitor(client: bridge!)
monitor.start()
clipboardMonitor = monitor
let paster = PasteService()
let clipboardVM = ClipboardViewModel(client: bridge!, paster: paster)
clipboardVM.onHide = { [weak self] in self?.clipboardPanel?.orderOut(nil) }
clipboardViewModel = clipboardVM
clipboardPanel = ClipboardPanel(viewModel: clipboardVM)

// executor.onBuiltin 增加：
case "clipboard_history":
    clipboardVM.reload()
    clipboardPanel?.showCentered()
```

- [ ] **Step 5: 运行测试并手动验证**

```bash
xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
```
Expected: `ClipboardPolicyTests` 3 个用例 PASS；运行 App 复制几段文本/图片，呼出“剪贴板历史”可检索、置顶、删除、回车粘贴。

- [ ] **Step 6: 提交**

```bash
git add apps/macos
git commit -m "feat(macos): clipboard monitor, history panel and paste back"
```

---

## Task 15: 窗口管理

**Files:**
- Create: `apps/macos/Sources/Platform/WindowManager.swift`
- Test: `apps/macos/Tests/WindowFramesTests.swift`

**Interfaces:**
- Consumes: `AXIsProcessTrusted`、`AXUIElement`、`NSScreen`
- Produces:
  - `WindowFrames.target(action: String, screen: CGRect, window: CGRect) -> CGRect?`
  - `WindowFrames.toAX(_ cocoa: CGRect, mainScreenHeight: CGFloat) -> CGRect`
  - `final class WindowActionService: WindowActionPerforming { func perform(_ name: String, completion: @escaping (Error?) -> Void) }`
  - `enum WindowError { permission, noWindow, unsupported }`

- [ ] **Step 1: 写失败测试**

`apps/macos/Tests/WindowFramesTests.swift`：

```swift
import XCTest
@testable import Olico

final class WindowFramesTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let window = CGRect(x: 100, y: 100, width: 400, height: 300)

    func testLeftRightMaximize() {
        XCTAssertEqual(WindowFrames.target(action: "left", screen: screen, window: window),
                       CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(WindowFrames.target(action: "right", screen: screen, window: window),
                       CGRect(x: 500, y: 0, width: 500, height: 800))
        XCTAssertEqual(WindowFrames.target(action: "maximize", screen: screen, window: window), screen)
    }

    func testCenterKeepsSize() {
        XCTAssertEqual(WindowFrames.target(action: "center", screen: screen, window: window),
                       CGRect(x: 300, y: 250, width: 400, height: 300))
    }

    func testCocoaToAXFlipsY() {
        let cocoa = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(WindowFrames.toAX(cocoa, mainScreenHeight: 800), cocoa)
        let upper = CGRect(x: 0, y: 400, width: 500, height: 400)
        XCTAssertEqual(WindowFrames.toAX(upper, mainScreenHeight: 800),
                       CGRect(x: 0, y: 0, width: 500, height: 400))
    }

    func testUnknownActionReturnsNil() {
        XCTAssertNil(WindowFrames.target(action: "diagonal", screen: screen, window: window))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Expected: 编译失败（`WindowFrames` 不存在）。

- [ ] **Step 3: 实现窗口动作**

```swift
// apps/macos/Sources/Platform/WindowManager.swift
import AppKit
import ApplicationServices

enum WindowError: LocalizedError {
    case permission
    case noWindow
    case unsupported

    var errorDescription: String? {
        switch self {
        case .permission: return "需要辅助功能权限才能移动窗口"
        case .noWindow: return "没有找到当前窗口"
        case .unsupported: return "不支持的窗口动作"
        }
    }
}

enum WindowFrames {
    static func target(action: String, screen: CGRect, window: CGRect) -> CGRect? {
        switch action {
        case "left":
            return CGRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case "right":
            return CGRect(x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case "maximize":
            return screen
        case "center":
            let size = CGSize(width: min(window.width, screen.width), height: min(window.height, screen.height))
            return CGRect(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        default:
            return nil
        }
    }

    static func toAX(_ cocoa: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: cocoa.minX,
            y: mainScreenHeight - cocoa.maxY,
            width: cocoa.width,
            height: cocoa.height
        )
    }
}

final class WindowActionService: WindowActionPerforming {
    func perform(_ name: String, completion: @escaping (Error?) -> Void) {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "需要辅助功能权限"
                alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”中勾选 Olico。"
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    )
                }
                completion(WindowError.permission)
            }
            return
        }

        guard let window = Self.focusedWindow(), let current = Self.frame(of: window) else {
            completion(WindowError.noWindow)
            return
        }
        let center = CGPoint(x: current.midX, y: current.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame,
              let target = WindowFrames.target(action: name, screen: visible, window: current) else {
            completion(WindowError.unsupported)
            return
        }
        let axFrame = WindowFrames.toAX(target, mainScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        Self.setFrame(axFrame, window: window)
        completion(nil)
    }

    private static func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedWindowAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as! AXUIElement
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        // AX 坐标系以主屏左上角为原点，转换成 NSScreen 的底部原点坐标系。
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: point.x, y: mainHeight - point.y - size.height, width: size.width, height: size.height)
    }

    private static func setFrame(_ frame: CGRect, window: AXUIElement) {
        var point = CGPoint(x: frame.minX, y: frame.minY)
        var size = CGSize(width: frame.width, height: frame.height)
        if let position = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let dimensions = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        }
    }
}
```

在 `AppDelegate` 中为 executor 注入：

```swift
let executor = ActionExecutor()
executor.windowActions = WindowActionService()
```

- [ ] **Step 4: 运行测试并手动验证**

```bash
xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
```
Expected: `WindowFramesTests` 4 个用例 PASS；首次执行窗口命令弹出权限引导，授权后左/右/最大化/居中生效（多屏分别验证）。

- [ ] **Step 5: 提交**

```bash
git add apps/macos
git commit -m "feat(macos): window management with accessibility permission"
```

---

## Task 16: 设置窗口与配置联动

**Files:**
- Create: `apps/macos/Sources/UI/SettingsView.swift`, `SettingsViewModel.swift`, `HotkeyRecorder.swift`
- Modify: `apps/macos/Sources/AppDelegate.swift`
- Test: `apps/macos/Tests/SettingsViewModelTests.swift`

**Interfaces:**
- Consumes: `CoreClient` 的 `config_get` / `config_set`、`HotkeyParser.canonical(from:)`
- Produces:
  - `struct SettingsSnapshot { hotkey: String; fileSearch: Bool; clipboardEnabled: Bool; excludedApps: [String]; maxItems: Int; retentionDays: Int }`
  - `@MainActor final class SettingsViewModel`：`load()`、`save()`、`onSaved: ((SettingsSnapshot) -> Void)?`
  - `struct HotkeyRecorder: NSViewRepresentable`

- [ ] **Step 1: 写失败测试**

`apps/macos/Tests/SettingsViewModelTests.swift`：

```swift
import XCTest
@testable import Olico

final class SettingsFakeClient: CoreClient {
    var saved: [String: Any]?
    func dispatch(op: String, payload: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        DispatchQueue.main.async {
            switch op {
            case "config_get":
                completion(.success([
                    "version": 1,
                    "hotkey": ["mac": "alt+space", "windows": "alt+space", "windows_fallback": "ctrl+alt+space"],
                    "search": [
                        "file_search": true,
                        "max_results": 20,
                        "web_engines": [["keyword": "g", "name": "Google", "url": "https://www.google.com/search?q={query}"]],
                    ],
                    "clipboard": [
                        "enabled": true, "max_items": 500, "retention_days": 30,
                        "excluded_apps": [], "ignore_concealed": true,
                    ],
                ]))
            case "config_set":
                self.saved = payload
                completion(.success([:]))
            default:
                completion(.success([:]))
            }
        }
    }
}

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testLoadAndSaveRoundtrip() {
        let client = SettingsFakeClient()
        let viewModel = SettingsViewModel(client: client)
        let loaded = expectation(description: "load")
        viewModel.load { loaded.fulfill() }
        wait(for: [loaded], timeout: 2)

        XCTAssertEqual(viewModel.hotkey, "alt+space")
        XCTAssertEqual(viewModel.maxItems, 500)

        viewModel.hotkey = "ctrl+space"
        viewModel.maxItems = 120
        viewModel.fileSearch = false
        var snapshot: SettingsSnapshot?
        viewModel.onSaved = { snapshot = $0 }
        let saved = expectation(description: "save")
        viewModel.save { saved.fulfill() }
        wait(for: [saved], timeout: 2)

        let clipboard = client.saved?["clipboard"] as? [String: Any]
        XCTAssertEqual(clipboard?["max_items"] as? Int, 120)
        let search = client.saved?["search"] as? [String: Any]
        XCTAssertEqual(search?["file_search"] as? Bool, false)
        XCTAssertEqual(snapshot?.hotkey, "ctrl+space")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Expected: 编译失败（`SettingsViewModel` 不存在）。

- [ ] **Step 3: 实现 SettingsViewModel**

```swift
// apps/macos/Sources/UI/SettingsViewModel.swift
import Foundation

struct WebEngineDraft: Identifiable, Equatable {
    let id = UUID()
    var keyword: String
    var name: String
    var url: String
}

struct SettingsSnapshot {
    let hotkey: String
    let fileSearch: Bool
    let clipboardEnabled: Bool
    let excludedApps: [String]
    let maxItems: Int
    let retentionDays: Int
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var hotkey = "alt+space"
    @Published var fileSearch = true
    @Published var maxResults = 20
    @Published var clipboardEnabled = true
    @Published var maxItems = 500
    @Published var retentionDays = 30
    @Published var excludedApps = ""
    @Published var webEngines: [WebEngineDraft] = []
    @Published var errorMessage: String?

    var onSaved: ((SettingsSnapshot) -> Void)?

    private let client: CoreClient
    private var rawConfig: [String: Any] = [:]

    init(client: CoreClient) {
        self.client = client
    }

    func load(completion: (() -> Void)? = nil) {
        client.dispatch(op: "config_get", payload: [:]) { result in
            defer { completion?() }
            guard case .success(let data) = result, let config = data as? [String: Any] else {
                self.errorMessage = "读取配置失败"
                return
            }
            self.rawConfig = config
            let hotkey = config["hotkey"] as? [String: Any]
            self.hotkey = hotkey?["mac"] as? String ?? "alt+space"
            let search = config["search"] as? [String: Any]
            self.fileSearch = search?["file_search"] as? Bool ?? true
            self.maxResults = search?["max_results"] as? Int ?? 20
            self.webEngines = (search?["web_engines"] as? [[String: Any]] ?? []).map {
                WebEngineDraft(
                    keyword: $0["keyword"] as? String ?? "",
                    name: $0["name"] as? String ?? "",
                    url: $0["url"] as? String ?? ""
                )
            }
            let clipboard = config["clipboard"] as? [String: Any]
            self.clipboardEnabled = clipboard?["enabled"] as? Bool ?? true
            self.maxItems = clipboard?["max_items"] as? Int ?? 500
            self.retentionDays = clipboard?["retention_days"] as? Int ?? 30
            self.excludedApps = (clipboard?["excluded_apps"] as? [String] ?? []).joined(separator: "\n")
        }
    }

    func save(completion: (() -> Void)? = nil) {
        var config = rawConfig
        var hotkeyConfig = config["hotkey"] as? [String: Any] ?? [:]
        hotkeyConfig["mac"] = hotkey
        config["hotkey"] = hotkeyConfig

        var search = config["search"] as? [String: Any] ?? [:]
        search["file_search"] = fileSearch
        search["max_results"] = maxResults
        search["web_engines"] = webEngines.map {
            ["keyword": $0.keyword, "name": $0.name, "url": $0.url]
        }
        config["search"] = search

        var clipboard = config["clipboard"] as? [String: Any] ?? [:]
        clipboard["enabled"] = clipboardEnabled
        clipboard["max_items"] = maxItems
        clipboard["retention_days"] = retentionDays
        clipboard["excluded_apps"] = excludedApps
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        clipboard["ignore_concealed"] = true
        config["clipboard"] = clipboard

        let snapshot = SettingsSnapshot(
            hotkey: hotkey,
            fileSearch: fileSearch,
            clipboardEnabled: clipboardEnabled,
            excludedApps: clipboard["excluded_apps"] as? [String] ?? [],
            maxItems: maxItems,
            retentionDays: retentionDays
        )

        client.dispatch(op: "config_set", payload: config) { result in
            defer { completion?() }
            switch result {
            case .success:
                self.rawConfig = config
                self.onSaved?(snapshot)
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 4: 实现设置界面与热键录制**

`HotkeyRecorder.swift`：

```swift
import AppKit
import SwiftUI

struct HotkeyRecorder: NSViewRepresentable {
    @Binding var combo: String

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.stringValue = combo
        field.onCapture = { combo = $0 }
        return field
    }

    func updateNSView(_ nsView: RecorderField, context: Context) {
        if nsView.stringValue != combo { nsView.stringValue = combo }
    }

    final class RecorderField: NSTextField {
        var onCapture: ((String) -> Void)?

        override func keyDown(with event: NSEvent) {
            if let value = HotkeyParser.canonical(from: event) {
                stringValue = value
                onCapture?(value)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
```

`SettingsView.swift`：

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("通用") {
                LabeledContent("全局热键") {
                    HotkeyRecorder(combo: $viewModel.hotkey)
                        .frame(width: 180)
                }
                Toggle("启用文件搜索", isOn: $viewModel.fileSearch)
                Stepper("最大结果数：\(viewModel.maxResults)", value: $viewModel.maxResults, in: 5...100, step: 5)
            }

            Section("剪贴板") {
                Toggle("记录剪贴板历史", isOn: $viewModel.clipboardEnabled)
                Stepper("最多保留：\(viewModel.maxItems) 条", value: $viewModel.maxItems, in: 50...5000, step: 50)
                Stepper("保留天数：\(viewModel.retentionDays) 天", value: $viewModel.retentionDays, in: 1...365)
                TextEditor(text: $viewModel.excludedApps)
                    .frame(height: 60)
                    .font(.body.monospaced())
                Text("排除的应用 Bundle ID，每行一个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("网页搜索") {
                ForEach($viewModel.webEngines) { $engine in
                    HStack {
                        TextField("关键词", text: $engine.keyword).frame(width: 70)
                        TextField("名称", text: $engine.name).frame(width: 100)
                        TextField("URL 模板（用 {query} 占位）", text: $engine.url)
                    }
                }
                Button("添加搜索引擎") {
                    viewModel.webEngines.append(
                        WebEngineDraft(keyword: "", name: "", url: "https://example.com/search?q={query}")
                    )
                }
            }

            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("保存") { viewModel.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 540, height: 560)
    }
}
```

在 `AppDelegate` 中增加设置窗口：

```swift
private var settingsWindow: NSWindow?
private var settingsViewModel: SettingsViewModel?

private func showSettings() {
    if settingsWindow == nil {
        let viewModel = SettingsViewModel(client: bridge!)
        viewModel.onSaved = { [weak self] snapshot in
            guard let self else { return }
            self.hotkey?.register(snapshot.hotkey)
            self.launcherViewModel?.fileSearchEnabled = snapshot.fileSearch
            self.clipboardMonitor?.isEnabled = snapshot.clipboardEnabled
            self.clipboardMonitor?.excludedApps = Set(snapshot.excludedApps)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Olico 设置"
        window.contentView = NSHostingView(rootView: SettingsView(viewModel: viewModel))
        window.center()
        settingsWindow = window
        settingsViewModel = viewModel
        viewModel.load()
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}
```

把 `executor.onBuiltin` 中的 `settings` 分支指向 `showSettings()`，并在 `AppDelegate` 保存 `launcherViewModel` 引用。

- [ ] **Step 5: 运行测试并手动验证**

```bash
xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
```
Expected: `SettingsViewModelTests` PASS；修改热键后立即生效，重启后配置保留。

- [ ] **Step 6: 提交**

```bash
git add apps/macos
git commit -m "feat(macos): settings window with hotkey recorder and config sync"
```

---

## Task 17: 文件日志与错误提示

**Files:**
- Create: `apps/macos/Sources/Support/FileLogger.swift`
- Modify: `apps/macos/Sources/Bridge/RustBridge.swift`, `AppDelegate.swift`
- Test: `apps/macos/Tests/FileLoggerTests.swift`

**Interfaces:**
- Consumes: `Paths.logsDir`
- Produces:
  - `final class FileLogger`：`init(directory:maxBytes:maxFiles:)`、`log(level:message:)`
  - `FileLogger.shared`（5MB × 3）

- [ ] **Step 1: 写失败测试**

`apps/macos/Tests/FileLoggerTests.swift`：

```swift
import XCTest
@testable import Olico

final class FileLoggerTests: XCTestCase {
    func testRotationKeepsMaxFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        let logger = FileLogger(directory: dir, maxBytes: 200, maxFiles: 3)
        for index in 0..<20 {
            logger.log(level: "info", message: "line \(index) " + String(repeating: "x", count: 60))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("olico.log") }
        XCTAssertLessThanOrEqual(files.count, 3)
        XCTAssertFalse(files.isEmpty)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Expected: 编译失败（`FileLogger` 不存在）。

- [ ] **Step 3: 实现日志**

```swift
// apps/macos/Sources/Support/FileLogger.swift
import Foundation

final class FileLogger {
    static let shared = FileLogger(
        directory: Paths.logsDir,
        maxBytes: 5 * 1024 * 1024,
        maxFiles: 3
    )

    private let directory: URL
    private let maxBytes: Int
    private let maxFiles: Int
    private let queue = DispatchQueue(label: "com.olico.logger")

    private var currentFile: URL { directory.appendingPathComponent("olico.log") }

    init(directory: URL, maxBytes: Int, maxFiles: Int) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func log(level: String, message: String) {
        queue.sync {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: currentFile.path) {
                FileManager.default.createFile(atPath: currentFile.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: currentFile) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    private func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: currentFile.path)[.size] as? Int) ?? 0
        guard size >= maxBytes else { return }
        let oldest = directory.appendingPathComponent("olico.log.\(maxFiles - 1)")
        try? FileManager.default.removeItem(at: oldest)
        for index in stride(from: maxFiles - 2, through: 1, by: -1) {
            let source = directory.appendingPathComponent("olico.log.\(index)")
            let destination = directory.appendingPathComponent("olico.log.\(index + 1)")
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: destination)
            }
        }
        try? FileManager.default.moveItem(at: currentFile, to: directory.appendingPathComponent("olico.log.1"))
    }
}
```

在 `AppDelegate` 启动失败与热键失败分支调用：

```swift
FileLogger.shared.log(level: "error", message: "hotkey registration failed: alt+space")
```

在 `RustBridge` 的 catch 分支：

```swift
FileLogger.shared.log(level: "error", message: "dispatch \(op) failed: \(error.localizedDescription)")
```

> 日志禁止写入剪贴板内容或文件内容明文；仅记录操作名、错误与时间。

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild test -project apps/macos/Olico.xcodeproj -scheme Olico -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
Expected: `FileLoggerTests` PASS。

- [ ] **Step 5: 提交**

```bash
git add apps/macos
git commit -m "feat(macos): file logger with rotation and error toasts"
```

---

## Task 18: 版本同步、签名证书与 universal dmg 构建

**Files:**
- Create: `scripts/version-sync.sh`, `scripts/build-macos.sh`, `scripts/create-dev-cert.sh`
- Modify: `apps/macos/project.yml`（`MARKETING_VERSION` 由脚本同步）
- Verify: `dist/Olico-<ver>-macos-universal.dmg`

**Interfaces:**
- Consumes: `scripts/build-ffi.sh`、`VERSION`
- Produces: 可双击安装的 universal dmg；签名身份 `Olico Dev`

- [ ] **Step 1: 实现版本同步与构建脚本**

`scripts/version-sync.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
perl -pi -e "s/^version = .*/version = \"$VERSION\"/" "$ROOT/Cargo.toml"
perl -pi -e "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VERSION\"/" "$ROOT/apps/macos/project.yml"
echo "synced version $VERSION"
```

`scripts/build-macos.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
"$ROOT/scripts/version-sync.sh"
"$ROOT/scripts/build-ffi.sh"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate --spec apps/macos/project.yml

DERIVED="$ROOT/apps/macos/build"
IDENTITY="${CODESIGN_IDENTITY:--}"
xcodebuild \
  -project apps/macos/Olico.xcodeproj \
  -scheme Olico \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  build

APP="$DERIVED/Build/Products/Release/Olico.app"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"

mkdir -p dist
rm -f "dist/Olico-$VERSION-macos-universal.dmg"
hdiutil create \
  -volname "Olico" \
  -srcfolder "$APP" \
  -ov \
  -format UDZO \
  "dist/Olico-$VERSION-macos-universal.dmg"

echo "built dist/Olico-$VERSION-macos-universal.dmg"
```

`scripts/create-dev-cert.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
CERT_NAME="${1:-Olico Dev}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$CERT_NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

openssl pkcs12 -export \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:

security import "$WORK/identity.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "" -T /usr/bin/codesign

security add-trusted-cert -d -r trustRoot \
  -k "$HOME/Library/Keychains/login.keychain-db" "$WORK/cert.pem"

echo "Created signing identity: $CERT_NAME"
echo "If codesign prompts for keychain access, choose \"Always Allow\"."
```

> 说明：`security add-trusted-cert -d` 写入登录钥匙串；如系统要求管理员权限，使用 `-k /Library/Keychains/System.keychain` 并输入密码。证书固定后，macOS 辅助功能授权不会因重编译而丢失。

- [ ] **Step 2: 创建开发签名证书并验证**

```bash
chmod +x scripts/version-sync.sh scripts/build-macos.sh scripts/create-dev-cert.sh
./scripts/version-sync.sh
./scripts/create-dev-cert.sh
security find-identity -v -p codesigning | grep "Olico Dev"
```
Expected: 输出包含 `"Olico Dev"`。

- [ ] **Step 3: 构建 universal dmg**

```bash
CODESIGN_IDENTITY="Olico Dev" ./scripts/build-macos.sh
```
Expected: 产出 `dist/Olico-0.1.0-macos-universal.dmg`。

- [ ] **Step 4: 验证产物架构与启动**

```bash
lipo -info apps/macos/build/Build/Products/Release/Olico.app/Contents/MacOS/Olico
hdiutil attach dist/Olico-0.1.0-macos-universal.dmg
codesign -dv --verbose=2 /Volumes/Olico/Olico.app
open /Volumes/Olico/Olico.app
hdiutil detach /Volumes/Olico
```
Expected: `lipo` 显示 `x86_64 arm64`；codesign 显示 `Authority=Olico Dev`；应用可启动。

- [ ] **Step 5: 提交**

```bash
git add scripts apps/macos/project.yml
git commit -m "build(macos): universal dmg pipeline with dev signing identity"
```

---

## Task 19: macOS CI 与发布流水线

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release-macos.yml`

**Interfaces:**
- Consumes: `scripts/build-ffi.sh`、`scripts/build-macos.sh`、`VERSION`
- Produces: PR 质量门禁；tag `v*` 触发的 dmg Release 产物

- [ ] **Step 1: 编写 CI 工作流**

```yaml
# .github/workflows/ci.yml
name: ci

on:
  push:
    branches: [main]
  pull_request:

jobs:
  rust:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy
      - uses: Swatinem/rust-cache@v2
      - run: cargo fmt --check
      - run: cargo clippy --all-targets -- -D warnings
      - run: cargo test --workspace

  macos:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: aarch64-apple-darwin,x86_64-apple-darwin
      - uses: Swatinem/rust-cache@v2
      - run: brew install xcodegen
      - run: cargo install cbindgen --version 0.27.0 --locked
      - run: ./scripts/build-ffi.sh
      - run: xcodegen generate --spec apps/macos/project.yml
      - run: |
          xcodebuild test \
            -project apps/macos/Olico.xcodeproj \
            -scheme Olico \
            -destination 'platform=macOS' \
            CODE_SIGN_IDENTITY=-
```

- [ ] **Step 2: 编写发布工作流**

```yaml
# .github/workflows/release-macos.yml
name: release-macos

on:
  push:
    tags: ["v*"]

permissions:
  contents: write

jobs:
  dmg:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: aarch64-apple-darwin,x86_64-apple-darwin
      - uses: Swatinem/rust-cache@v2
      - run: brew install xcodegen
      - run: cargo install cbindgen --version 0.27.0 --locked
      - run: ./scripts/version-sync.sh
      - run: CODESIGN_IDENTITY="-" ./scripts/build-macos.sh
      - uses: softprops/action-gh-release@v2
        with:
          files: dist/Olico-*-macos-universal.dmg
```

- [ ] **Step 3: 本地校验工作流语法**

```bash
git add .github/workflows
git commit -m "ci: add rust and macos build workflows"
```
（可选）如已安装 `actionlint`：`actionlint .github/workflows/*.yml`，预期无输出。

- [ ] **Step 4: 触发验证**

推送到远端后确认 `ci` 两个 job 通过；打 tag 后 `release-macos` 产出 dmg 并挂到 Release。

---

## Task 20: macOS 手工验收清单

**Files:**
- Create: `docs/qa/macos-mvp-checklist.md`

**Interfaces:**
- Consumes: 已构建的 Olico.app
- Produces: 验收结果记录（勾选 + 备注）

- [ ] **Step 1: 写验收清单**

```markdown
# Olico macOS MVP 验收清单

日期：
版本：
签名身份：

## 启动器
- [ ] Option+Space 在 Finder、Safari、全屏 Space 中均可呼出
- [ ] 呼出到可输入 ≤ 100ms（主观 + 录屏计时）
- [ ] 失焦自动隐藏，Esc 隐藏
- [ ] 空查询展示常用应用（使用过的高频应用靠前）
- [ ] 输入中文应用名可命中，中文输入法组合期间不误触发
- [ ] 应用可启动；已运行应用被激活而不是新开实例
- [ ] 文件搜索在输入 ≥2 字符时返回结果并可打开
- [ ] 计算器：`1+2*3` 显示 7，回车复制
- [ ] 网页搜索：`g rust` 用默认浏览器打开 Google
- [ ] 多显示器下浮层出现在鼠标所在屏幕

## 剪贴板历史
- [ ] 复制文本/图片/文件后可在历史中找到
- [ ] 重复内容不产生重复记录
- [ ] 置顶记录排在最前且重启后仍保留
- [ ] 删除、清空（保留置顶）正常
- [ ] 排除应用（如 1Password）的内容不被记录
- [ ] 回车回贴到前一个应用；未授权辅助功能时提示仅复制
- [ ] 超过 500 条或 30 天后旧记录被清理

## 窗口管理
- [ ] 未授权时弹出辅助功能引导，跳转系统设置正确
- [ ] 左半屏/右半屏/最大化/居中在单屏正确
- [ ] 多显示器下按窗口所在屏幕计算
- [ ] 重新构建后辅助功能授权不丢失（使用固定签名证书）

## 设置与持久化
- [ ] 修改热键立即生效，重启后保留
- [ ] 关闭文件搜索后不再查询 Spotlight
- [ ] 修改剪贴板条数/天数后按新策略清理
- [ ] 搜索引擎增删改后立即生效
- [ ] 重启后配置、索引、剪贴板历史均保留

## 稳定性
- [ ] 连续快速呼出/隐藏 20 次无崩溃
- [ ] 索引刷新期间呼出不卡顿
- [ ] 日志目录存在且滚动不超过 3 份，无剪贴板明文
- [ ] universal dmg 在 Intel Mac（或 Rosetta 环境）可启动
```

- [ ] **Step 2: 逐项执行并记录结果**

运行 `dist/Olico-0.1.0-macos-universal.dmg` 安装后的 App，按清单逐项验证；失败项记录复现步骤，回到对应任务修复。

- [ ] **Step 3: 提交验收结果**

```bash
git add docs/qa/macos-mvp-checklist.md
git commit -m "docs(qa): add macos mvp acceptance checklist and results"
```

---

## 后续计划（不在本计划范围）

Windows 壳（WinUI 3 + .NET 8）与 Windows CI 是独立的第二份实施计划，依赖本计划产出的 `olico.h` 与 JSON 协议。启动 Windows 工作的前置条件：本计划 Task 20 全部勾选通过、`olico.h` 稳定、JSON 协议不再变动。