# Olico 设计文档

- 日期：2026-11-10
- 状态：待评审
- 版本：1.0
- 范围：第一期（MVP）

## 1. 背景与目标

Olico 是一款跨平台效率启动器，对标 Raycast 的“随时呼出、键盘优先”体验，并内置剪贴板历史与窗口管理。产品形态为常驻菜单栏/托盘的桌面应用。

目标：

1. 全局热键随时呼出，从按键到可输入不超过 100ms。
2. 核心逻辑只实现一次：Rust 核心同时被 macOS 与 Windows 原生壳调用。
3. 可重复构建：CI 产出 macOS Apple Silicon、macOS Intel、Windows x64 三份产物。

## 2. 范围

### 2.1 第一期功能

- **启动器**：应用搜索与启动、文件搜索、计算器、网页搜索、内置命令、基于使用频率的排序。
- **剪贴板历史**：记录文本/图片/文件，支持搜索、置顶、删除、回贴。
- **窗口管理**：左半屏、右半屏、最大化、居中。
- **设置**：全局热键、剪贴板策略、排除应用、网页搜索引擎。
- **构建发布**：本地构建脚本与 GitHub Actions 发布流水线。

### 2.2 第二期功能

Snipaste 类能力：区域截图、截图标注、贴图置顶、取色。该部分单独出具设计文档，不在本设计范围内。

### 2.3 非目标（第一期明确不做）

- 插件/扩展生态
- AI 能力
- 账号体系与云同步
- 自动更新
- Windows ARM64、Linux
- 图形安装器（使用 dmg / zip 分发）
- 文本片段（Snippets）与翻译工具

## 3. 技术决策

| 决策点 | 选择 | 理由 |
|---|---|---|
| 代码复用 | Rust 共享核心 + 双端原生 UI | 逻辑一份、原生体验不打折、天然支持多架构 |
| macOS UI | SwiftUI + AppKit 混合 | SwiftUI 做界面，AppKit 提供 NSPanel、状态栏等能力 |
| Windows UI | WinUI 3（Windows App SDK）+ .NET 8 | 原生控件与亚克力背景，接近 Raycast 观感 |
| 核心边界 | C ABI + JSON 协议 | Swift/C# 绑定成本低，新增能力不改函数签名 |
| 本地存储 | SQLite（rusqlite，bundled） | 剪贴板历史需要查询、去重、保留策略 |
| 模糊排序 | nucleo 匹配器 | 高性能、支持 Unicode 与中文 |
| 构建 | GitHub Actions | mac 双架构与 Windows 构建无法在单机完成 |
| 最低系统 | macOS 13 / Windows 10 1809 | 覆盖 NSPanel 与 Windows App SDK 的稳定能力 |

## 4. 总体架构

### 4.1 进程模型

单进程应用：Rust 核心以静态库形式链接进 macOS App，以动态库形式由 Windows 壳通过 P/Invoke 调用。不引入后台守护进程，不引入 IPC。

```
┌─────────────────────────────┐      ┌─────────────────────────────┐
│   Olico.app (SwiftUI)       │      │   Olico.exe (WinUI 3)       │
│   平台能力：热键/枚举/窗口/剪贴板 │      │   平台能力：热键/枚举/窗口/剪贴板 │
└──────────────┬──────────────┘      └──────────────┬──────────────┘
               │ C ABI + JSON                        │ P/Invoke + JSON
               ▼                                     ▼
        ┌──────────────────────────────────────────────────┐
        │  olico-core (Rust)：搜索排序 / 索引 / 配置 / 剪贴板 │
        └──────────────────────────────────────────────────┘
```

### 4.2 目录结构

```
Olico/
├── VERSION                       # 版本号唯一来源
├── rust-toolchain.toml
├── Cargo.toml                    # workspace
├── crates/
│   ├── olico-core/               # 领域逻辑、SQLite、排序
│   └── olico-ffi/                # C ABI 导出（staticlib + cdylib）
├── apps/
│   ├── macos/                    # XcodeGen 工程 + Swift 源码
│   └── windows/                  # Olico.sln + WinUI 3 项目
├── shared/
│   ├── protocol.md               # JSON 请求/响应 schema
│   └── design-tokens.json        # 两端共用视觉参数
├── scripts/
│   ├── version-sync.sh           # 同步版本号到各构建文件
│   └── build-macos.sh            # 双架构静态库 + lipo + 打包
├── docs/
│   └── superpowers/specs/        # 设计文档
└── .github/workflows/            # ci.yml / release.yml
```

### 4.3 线程模型

- 所有 FFI 调用必须离开主线程执行（macOS 用全局并发队列，Windows 用 `Task.Run`）。
- 核心句柄内部持锁，可被多线程调用，但实际调用串行化。
- UI 更新统一回到主线程。
- 启动器输入防抖 40ms；剪贴板轮询间隔 500ms；索引 TTL 5 分钟。

## 5. 核心层（olico-core）

### 5.1 数据模型

```rust
enum ItemKind { Application, File, BuiltinCommand, WindowAction }

struct Item {
    id: String,          // 应用=BunId/可执行路径，文件=绝对路径，命令="cmd:xxx"
    kind: ItemKind,
    title: String,
    subtitle: String,
    keywords: Vec<String>,
    icon_ref: String,    // 平台据此加载图标（应用路径/文件路径/命令图标名）
    action: Action,      // 执行描述，由平台层解释
    source: String,      // mac_scan / win_start_menu / spotlight / win_search / builtin
}

enum Action {
    OpenApp { path: String },
    OpenPath { path: String },
    RunBuiltin { name: String },   // clipboard_history / settings / quit / web_search / calculator_copy
    WindowAction { name: String }, // left / right / maximize / center
}

struct Query {
    text: String,
    scope: Scope,        // All / Apps / Files / Commands（剪贴板走 clipboard_list）
    limit: u32,
    extras: Vec<Item>,   // 平台层即时提供的候选（文件搜索结果），与索引一起排序
}

struct Result { item: Item, score: f32, match_ranges: Vec<(u32, u32)> }
```

### 5.2 模块职责

| 模块 | 职责 | 实现要点 |
|---|---|---|
| `search` | 模糊匹配与排序 | 字段权重 title 1.0 / keywords 0.8 / subtitle 0.4；frecency = 使用次数 × 时间衰减；空查询按 frecency 返回常用应用；排序结果确定可复现 |
| `index` | 应用索引 | 仅存元数据；接收平台推送；按 `source` 清理失效条目 |
| `commands` | 内置命令 | 计算器、网页搜索（执行时对查询做 URL 编码）、剪贴板入口、设置、退出、窗口动作 |
| `calculator` | 表达式求值 | 自写解析器，支持 `+ - * / % ^`、括号、百分比；禁止 eval；整数/小数混合运算 |
| `config` | 配置读写 | 原子写入；缺失字段用默认值补齐；配置版本字段支持未来迁移 |
| `clipboard` | 剪贴板历史 | 文本入库、图片落盘只存路径、hash 去重、置顶不参与清理、按条数与天数双重上限清理 |

### 5.3 FFI 接口

```c
typedef struct OlicoHandle OlicoHandle;

OlicoHandle* olico_core_new(const char* config_dir);
void         olico_core_free(OlicoHandle* handle);
char*        olico_dispatch(OlicoHandle* handle, const char* request_json);
void         olico_string_free(char* ptr);
```

- `olico-ffi` 的 crate-type 为 `["staticlib", "cdylib"]`：macOS 链接静态库，Windows 使用 DLL。
- 单入口 `olico_dispatch`，请求与响应均为 UTF-8 JSON。
- 所有导出函数包裹 `catch_unwind`，panic 不跨 FFI。
- 返回的字符串由调用方通过 `olico_string_free` 释放。
- 头文件由 cbindgen 生成，Swift 通过 bridging header、C# 通过 `DllImport` 使用。

请求/响应格式：

```json
{"v":1,"op":"search","payload":{"text":"code","scope":"all","limit":20,"extras":[]}}
{"v":1,"ok":true,"data":[{"item":{...},"score":0.93,"match_ranges":[[0,4]]}]}
{"v":1,"ok":false,"error":{"code":"invalid_payload","message":"..."}}
```

操作清单：

| op | payload | 说明 |
|---|---|---|
| `search` | `text, scope, limit, extras` | 排序并返回结果 |
| `index_upsert_items` | `items[]` | 平台推送应用条目 |
| `index_remove_stale` | `source, valid_ids[]` | 清理已卸载应用 |
| `clipboard_add` | `kind, text?, file_path?, source_app?` | 写入并去重 |
| `clipboard_list` | `query, kind?, limit` | 查询历史 |
| `clipboard_delete` | `id` | 删除单条 |
| `clipboard_pin` | `id, pinned` | 置顶/取消置顶 |
| `clipboard_clear` | `{}` | 清空非置顶记录 |
| `config_get` | `{}` | 返回完整配置 |
| `config_set` | `config` | 校验后原子写入 |
| `usage_record` | `item_id` | 更新 frecency |

### 5.4 配置结构

```json
{
  "version": 1,
  "hotkey": {"mac": "alt+space", "windows": "alt+space", "windows_fallback": "ctrl+alt+space"},
  "search": {
    "file_search": true,
    "max_results": 20,
    "web_engines": [
      {"keyword": "g", "name": "Google", "url": "https://www.google.com/search?q={query}"},
      {"keyword": "bd", "name": "百度", "url": "https://www.baidu.com/s?wd={query}"}
    ]
  },
  "clipboard": {
    "enabled": true,
    "max_items": 500,
    "retention_days": 30,
    "excluded_apps": [],
    "ignore_concealed": true
  }
}
```

### 5.5 存储位置与日志

- macOS：`~/Library/Application Support/Olico/`（`config.json`、`olico.db`、`images/`、`logs/`）
- Windows：`%LOCALAPPDATA%\Olico\`（同上）
- 日志滚动：单文件 5MB，保留 3 份。日志不记录剪贴板内容明文。

## 6. macOS 壳

| 关注点 | 实现 |
|---|---|
| 应用形态 | `LSUIElement = true` 无 Dock 图标，拥有菜单栏状态项 |
| 浮层 | `NSPanel`（borderless、nonactivating），level `.floating`，`canJoinAllSpaces + fullScreenAuxiliary`；`NSVisualEffectView`（hudWindow 材质）做毛玻璃；失焦隐藏 |
| 定位 | 尺寸 680×460，显示在鼠标所在屏幕居中偏上 |
| 全局热键 | Carbon `RegisterEventHotKey`（默认 `⌥Space`），无需额外权限；注册失败时提示改键 |
| 应用枚举 | 扫描 `/Applications`、`/System/Applications`、`/Applications/Utilities`、`~/Applications`；`NSWorkspace.icon(forFile:)` 取图标；5 分钟 TTL + `FSEvents` 监听应用目录变化 |
| 应用启动 | 已运行用 `NSRunningApplication.activate`，否则 `NSWorkspace.openApplication(at:configuration:)` |
| 文件搜索 | `NSMetadataQuery`（Spotlight）在用户主目录内按文件名匹配，结果经 `extras` 交给核心排序；仅在查询长度 ≥2 且配置开启时执行 |
| 窗口管理 | 首次使用弹引导申请辅助功能（`AXIsProcessTrustedWithOptions`）；取系统焦点窗口（`kAXFocusedWindowAttribute`），按 `NSScreen.visibleFrame` 设置 `kAXPositionAttribute` / `kAXSizeAttribute` |
| 剪贴板 | 500ms 轮询 `NSPasteboard.changeCount`；支持文本、图片（PNG/TIFF）、文件 URL；图片写入 `images/` 后只传路径；跳过 `org.nspasteboard.ConcealedType` / `TransientType` |
| 回贴 | 将选中记录写回 `NSPasteboard`，若辅助功能已授权则 `CGEvent` 模拟 `⌘V`，否则仅复制并提示 |
| 单实例 | `NSApplication` 单实例 + 二次启动聚焦已有实例 |
| 设置窗口 | SwiftUI `Settings` 场景：热键录制、剪贴板选项、排除应用、搜索引擎 |

## 7. Windows 壳

| 关注点 | 实现 |
|---|---|
| 应用形态 | WinUI 3 unpackaged，自包含部署；主窗口隐藏，托盘菜单提供打开/设置/退出 |
| 浮层 | 无边框 `Window`，`DesktopAcrylicBackdrop`，置顶、居中、失焦隐藏；尺寸 680×460 |
| 定位 | 显示在鼠标所在显示器工作区居中偏上（DPI 感知） |
| 全局热键 | 创建 message-only 窗口并固定 `WndProc` 委托，`RegisterHotKey` 默认 `Alt+Space`；被占用时自动回退 `Ctrl+Alt+Space` 并在设置中提示 |
| 应用枚举 | 扫描公共与用户开始菜单 `.lnk`，`IShellLink` 解析目标；`shell:AppsFolder` 枚举 UWP 应用；`IShellItemImageFactory` 取图标；5 分钟 TTL + `FileSystemWatcher` |
| 应用启动 | 普通程序 `Process.Start`/`ShellExecuteEx`；UWP 通过 `explorer.exe shell:AppsFolder\{AUMID}` |
| 文件搜索 | 优先 Windows Search（OLE DB `SystemIndex`，按 `System.FileName` 匹配）；服务不可用时降级为扫描桌面/文档/下载目录（深度 ≤4，5 分钟 TTL）；结果经 `extras` 交给核心排序 |
| 窗口管理 | `GetForegroundWindow` → `DwmGetWindowAttribute(EXTENDED_FRAME_BOUNDS)` → `MonitorFromWindow` + `GetMonitorInfo` 算工作区 → `SetWindowPos` |
| 剪贴板 | `AddClipboardFormatListener` + `WM_CLIPBOARDUPDATE`；读取 `CF_UNICODETEXT`、`CF_HDROP`、DIB/PNG；跳过 `Clipboard Viewer Ignore` 标记格式；图片落盘 |
| 回贴 | 写回剪贴板后 `SendInput` 模拟 `Ctrl+V`；因 UIPI 限制，无法注入管理员权限窗口时降级为仅复制并提示 |
| 托盘/单实例 | `H.NotifyIcon.WinUI` 实现托盘；命名 Mutex 保证单实例 |
| 设置窗口 | WinUI 设置页：热键、剪贴板、排除应用、搜索引擎 |

## 8. 关键流程

### 8.1 呼出与搜索

1. 全局热键触发，平台层显示并聚焦浮层。
2. 输入变化防抖 40ms 后发起 `search`；查询长度 ≥2 且开启文件搜索时，平台层并行获取文件候选作为 `extras`。
3. 核心合并索引与 extras 排序，返回扁平结果；浮层按 `kind` 分组展示，组内保持核心给出的顺序。
4. 键盘上下选择；回车执行 `Action`，记录 `usage_record`，隐藏浮层。
5. 空查询返回 frecency 最高的应用与常用命令。

### 8.2 应用索引

启动时全量枚举并 `index_upsert_items`；每次呼出检查 TTL，过期则后台刷新并 `index_remove_stale` 清理不存在的条目。索引刷新不阻塞呼出。

### 8.3 剪贴板

平台层监听/轮询系统剪贴板 → 生成 hash 去重 → 图片落盘 → `clipboard_add`。用户通过“剪贴板历史”命令进入专用列表，支持搜索、置顶、删除，回车回贴。

### 8.4 窗口动作

执行前检查权限（macOS 辅助功能）。未授权时显示引导卡片并打开系统设置对应页面，授权后命令立即可用。目标区域基于窗口所在显示器的工作区计算。

### 8.5 错误与降级

- FFI 返回错误：浮层内 toast 提示，同时写日志。
- 索引为空：自动触发全量重扫。
- 权限缺失：仅相关命令置灰并给出引导，不影响启动器本身。
- 热键注册失败：保留应用可用，提示用户改键。

## 9. 构建与发布

### 9.1 产物矩阵

| 平台 | Rust target | 链接方式 | 产物 | 最低系统 |
|---|---|---|---|---|
| macOS Apple Silicon | `aarch64-apple-darwin` | staticlib + lipo | `Olico-<ver>-macos-universal.dmg` | macOS 13 |
| macOS Intel | `x86_64-apple-darwin` | staticlib + lipo | 同上 | macOS 13 |
| Windows x64 | `x86_64-pc-windows-msvc` | cdylib（DLL + P/Invoke） | `Olico-<ver>-windows-x64.zip` | Windows 10 1809 |

### 9.2 本地构建

- macOS：`scripts/build-macos.sh` 构建双架构静态库 → `lipo` 合并 → XcodeGen 生成工程 → `xcodebuild ARCHS="arm64 x86_64"` → 签名 → `create-dmg`。
- Windows：`cargo build --release --target x86_64-pc-windows-msvc` + `dotnet publish -r win-x64 --self-contained true /p:WindowsPackageType=None /p:WindowsAppSDKSelfContained=true` → 打包 zip。
- WinUI 3 不支持从 macOS 交叉编译，Windows 端必须在 Windows 机器/VM/CI 上构建与验证。

### 9.3 CI 流水线

- `ci.yml`（PR 与主分支）：Rust `fmt`、`clippy -D warnings`、`test`；Windows `dotnet build`；macOS `xcodebuild build`（不签名）。
- `release.yml`（tag `v*`）：
  - `macos-14`：双架构 Rust → lipo → XcodeGen → xcodebuild → 签名/公证 → dmg。
  - `windows-2022`：Rust msvc → dotnet publish → zip。
  - 缓存：`Swatinem/rust-cache`、NuGet cache；产物上传 Artifact，并挂到 GitHub Release。
- 版本号由根 `VERSION` 经 `scripts/version-sync.sh` 同步到 `Cargo.toml`、`project.yml`、`Directory.Build.props`。

### 9.4 签名策略

| 阶段 | macOS | Windows | 用户体验 |
|---|---|---|---|
| MVP/自用 | 固定自签名证书 `Olico Dev` + hardened runtime | 不签名 | 首次需右键打开或执行 `xattr -dr com.apple.quarantine`；SmartScreen 提示“仍要运行” |
| 正式分发 | Apple Developer ID（$99/年）+ `notarytool` 公证 + staple | Authenticode 证书或 Azure Trusted Signing | 双击直接安装 |

macOS 辅助功能授权（TCC）按代码签名绑定：开发期必须使用固定自签名证书，避免每次重编译导致权限重置。

## 10. 测试策略

### 10.1 自动化

- Rust 单元测试：排序金标用例（中英文混合、字段权重、frecency 衰减）、计算器、配置迁移、剪贴板去重与保留策略、索引清理。
- 金标数据：`crates/olico-core/tests/fixtures/ranking/*.json`，输入与期望输出固定。
- FFI 契约：macOS 用 C harness 链接静态库冒烟；Windows 用 P/Invoke 冒烟，校验 JSON 协议一致。
- macOS：ViewModel XCTest + 核心集成测试。
- Windows：ViewModel xUnit。
- CI 门禁：`cargo fmt --check`、`cargo clippy -D warnings`、`cargo test`、`dotnet build`。

### 10.2 手工验收清单

macOS：

- 热键在任意应用、全屏 Space 下可呼出
- 中文输入法组合期间不误触发回车/方向键
- 多显示器下浮层与窗口动作定位正确
- 辅助功能授权前后窗口动作行为正确，重新构建后权限不丢失
- 剪贴板：文本/图片/文件记录、去重、置顶、排除应用、密码管理器内容不记录
- 应用搜索/启动正确，卸载应用后索引清理

Windows：

- `Alt+Space` 被占用时回退注册成功且设置中可见
- UWP 应用可搜索并启动
- 150%/200% DPI 下浮层尺寸与定位正确
- 多显示器窗口动作正确
- 剪贴板监听与回贴正常

## 11. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| WinUI 3 unpackaged 部署与托盘库兼容性 | Windows 端无法启动/无托盘 | 优先验证自包含发布；托盘使用成熟库；保留 WPF 作为退路 |
| Windows 全局热键被系统或其他软件占用 | 无法呼出 | 注册失败自动回退并在设置中可改 |
| macOS TCC 授权与签名绑定 | 每次构建权限重置 | 固定自签名证书；正式版用 Developer ID |
| 多显示器与全屏 Space 行为差异 | 浮层不显示/位置错误 | 使用 nonactivating panel + canJoinAllSpaces；手工清单覆盖 |
| 剪贴板敏感数据 | 隐私泄露 | 跳过 concealed/ignore 类型；支持排除应用；数据仅本地存储 |
| 无 Windows 开发机 | 迭代依赖 CI，反馈慢 | 使用 Windows VM 或 CI 构建验证；先完成 macOS 端 |
| 中文输入法与快捷键冲突 | 无法输入或误执行 | 组合输入期间不处理导航键；热键可配置 |

## 12. 验收标准

1. 热键呼出到可输入 ≤100ms；失焦自动隐藏。
2. 空查询展示 frecency 最高的应用；输入可搜索并启动应用。
3. 文件搜索在 macOS（Spotlight）与 Windows（Windows Search/降级扫描）返回可打开结果。
4. 计算器输入表达式回车后复制结果；网页搜索按配置引擎打开默认浏览器。
5. 剪贴板历史保留文本/图片/文件，支持搜索、去重、置顶、删除、回贴。
6. 窗口左/右/最大化/居中在单屏与多屏下正确执行。
7. 重启应用后配置、索引与剪贴板历史保留。
8. CI 在 tag 上产出 macOS universal dmg 与 Windows x64 zip，且两端均可安装运行。

## 13. 二期预告

截图/贴图/取色子系统将单独设计：macOS 使用 ScreenCaptureKit 与 CGDisplay 取色，Windows 使用 Windows Graphics Capture；标注画布与贴图窗口在各平台原生实现，仅共享配置与图形数据 schema。
