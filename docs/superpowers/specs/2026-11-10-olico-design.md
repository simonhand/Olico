# Olico 设计文档

- 日期：2026-11-10
- 状态：待评审
- 版本：2.0
- 范围：第一期（macOS MVP，四项刚需）

## 变更记录

| 版本 | 变更 |
|---|---|
| 1.0 | 跨平台启动器 + 剪贴板 + 窗口管理；截图为二期 |
| 2.0 | 收敛为 macOS 单端；截图为“完整 Snipaste 核心全套”并进入一期；剪贴板升级到 Paste 级；新增应用自定义热键与常驻可靠性设计；启动器搜索、文件搜索、计算器、网页搜索、窗口管理、Windows 端全部延后 |

v1.0 的实现计划（`docs/superpowers/plans/2026-11-10-olico-core-macos.md`）已与本期范围不一致，将在本 spec 通过后重新生成。

## 1. 背景与目标

Olico 是一款 macOS 常驻效率工具。第一期只解决四个真实刚需：

1. **应用热键**：为任意已安装应用设置自定义组合键，按一下启动或切换到该应用。
2. **剪贴板历史**：Paste 级体验——卡片时间线、图文预览、搜索、置顶、分类板、数字键快贴、回贴到原应用。
3. **截图**：Snipaste 核心全套——区域/窗口/全屏、窗口与控件识别、放大镜取色、标注、复制/保存、贴图置顶、独立取色器。
4. **常驻可靠**：菜单栏常驻、登录自启、崩溃自动拉起、睡眠唤醒后自动恢复，长期后台不掉。

目标：

- 热键按下到应用切换/浮层出现 ≤ 100ms（不含目标应用自身启动时间）。
- 截图热键到取景层可操作 ≤ 150ms。
- 连续后台运行 7×24 小时不出现热键失灵、轮询停止、内存持续增长。
- 数据全部本地存储，不联网、不记录敏感内容。

## 2. 范围

### 2.1 第一期（macOS）

| 模块 | 内容 |
|---|---|
| 应用热键 | 自定义组合键启动/切换应用；设置页枚举本机应用、搜索、录制按键、冲突检测、清除 |
| 剪贴板 | 卡片时间线、文本/图片/文件、搜索、置顶、分类板、⌘1–9 快贴、回贴、排除应用、暂停记录、自动清理 |
| 截图 | 区域/窗口/全屏、窗口与控件识别、放大镜坐标与取色、标注（矩形/椭圆/箭头/画笔/文字/马赛克/橡皮/撤销重做）、复制/保存、贴图置顶、取色器 |
| 常驻 | 无 Dock 图标、菜单栏常驻、登录自启、崩溃自动拉起、唤醒/显示器变化恢复、健康自检、单实例 |

### 2.2 延后（明确不做于本期）

- 启动器搜索、文件搜索、计算器、网页搜索、窗口管理（v1.0 原一期功能）。
- Windows 端（后续可能适配，本期只保留边界，不写实现）。
- Linux、云同步、账号体系、插件、AI、自动更新、图形安装器、滚动长截图、录屏、OCR、富文本保真。

### 2.3 非目标

- 不做多进程架构（后台 daemon + UI 分离）。
- 不做截图标注的二次拖拽编辑（一期只有撤销/重做与橡皮删除）。
- 不做剪贴板内容上传或分析。

## 3. 技术决策

| 决策点 | 选择 | 理由 |
|---|---|---|
| 代码复用 | Rust 共享核心 + macOS 原生壳 | 数据、搜索、配置、剪贴板存储只写一次，为未来 Windows 复用 |
| macOS UI | SwiftUI + AppKit 混合 | SwiftUI 做面板，AppKit 提供 NSPanel、状态栏、取景浮层、贴图窗口 |
| 最低系统 | macOS 14 | 使用 `SCScreenshotManager` 单帧截图；更低版本需绕 SCStream 取帧，不值得 |
| 截图采集 | ScreenCaptureKit | 原生、支持多显示器与 Retina、比废弃 API 稳定 |
| 取景/标注 | 自绘 AppKit + CoreGraphics | 才能实现放大镜、像素坐标、控件识别与 Snipaste 式交互 |
| 全局热键 | Carbon `RegisterEventHotKey` | 无需辅助功能权限，应用不在前台也能触发，支持多热键 |
| 本地存储 | SQLite（rusqlite，bundled）+ 文件 | 剪贴板查询、去重、分类板、保留策略都需要关系查询 |
| 模糊排序 | nucleo | 高性能，支持 Unicode 与中文 |
| 常驻守护 | `LaunchAgent`（`RunAtLoad` + `KeepAlive.SuccessfulExit=false`） | 一次配置同时解决登录自启与崩溃拉起；正常退出不复活 |
| 单实例 | 文件锁 + 运行中实例检测 | 防止 launchd 与手动启动产生双实例 |
| 签名 | 固定自签名证书 `Olico Dev` + hardened runtime | TCC 授权与签名绑定，避免每次重编译丢权限 |
| 构建 | XcodeGen + xcodebuild + create-dmg | 工程文件可复现，无需手改 Xcode 工程 |

## 4. 架构

### 4.1 进程与模块边界

单进程应用：Rust 核心以静态库链接进 `Olico.app`，Swift 壳负责所有 macOS 平台能力，两者只通过 C ABI + JSON 通信。

```
┌──────────────────────────────────────────────────────┐
│ Olico.app (LSUIElement, 单进程)                       │
│                                                      │
│  Swift 壳                                            │
│  ├── AppDelegate / StatusItem    生命周期、菜单栏      │
│  ├── ShortcutCenter              Carbon 多热键、录制   │
│  ├── ClipboardMonitor            粘贴板轮询、去重判重   │
│  ├── ClipboardPanel              Paste 式面板/分类板   │
│  ├── ScreenshotCenter            取景、标注、输出       │
│  ├── PinWindowManager            贴图窗口、持久化       │
│  ├── ColorPicker                 放大镜取色            │
│  ├── Residency                   登录项、守护、恢复     │
│  └── SettingsWindow              应用/剪贴板/截图/通用  │
│                                                      │
│  olico-core (Rust, staticlib)                        │
│  ├── config      配置读写、校验、迁移                  │
│  ├── clipboard   记录、去重、保留策略、分类板           │
│  ├── search      剪贴板模糊搜索与排序                  │
│  └── db          SQLite schema 与迁移                 │
└──────────────────────────────────────────────────────┘
```

边界原则：

- 核心层不依赖任何 macOS API，也不处理 UI、截图、剪贴板系统监听、热键注册。
- 平台层只做“取数据、发指令、渲染”，不实现排序与清理规则。
- 新增能力若需要 Swift 与核心协作，只扩展 JSON op，不改 C 函数签名。

### 4.2 目录结构（一期）

```
Olico/
├── VERSION
├── rust-toolchain.toml
├── Cargo.toml                    # workspace
├── crates/
│   ├── olico-core/               # 配置、剪贴板、搜索、SQLite
│   └── olico-ffi/                # C ABI（staticlib）
├── apps/
│   └── macos/                    # XcodeGen 工程 + Swift 源码
├── shared/
│   ├── protocol.md               # FFI JSON、配置 schema、标注 schema
│   └── design-tokens.json        # 面板视觉参数
├── scripts/
│   ├── version-sync.sh
│   └── build-macos.sh
├── docs/superpowers/specs/
└── .github/workflows/ci.yml
```

`apps/windows/` 在二期立项时新增，本期不创建空目录。

### 4.3 线程模型

- 所有 FFI 调用在全局并发队列执行，禁止在主线程同步调用。
- 核心句柄内部持锁，串行化写入；读操作可在同一队列内执行。
- UI 更新统一回主线程。
- 定时器：剪贴板轮询 500ms、面板搜索防抖 150ms、健康自检 30s、应用列表缓存 5 分钟。
- 截图管线：后台抓帧 → 主线程创建浮层 → 主线程交互与渲染；保存/编码在后台完成后回主线程提示。

### 4.4 权限

| 权限 | 用途 | 未授权时 |
|---|---|---|
| 屏幕录制 | 截图、取色 | 截图/取色不可用，显示引导卡片；其余功能正常 |
| 辅助功能 | 控件级识别、模拟 `⌘V` 回贴 | 识别降级为窗口级；回贴只复制并提示 |

设置页“通用”展示两项权限的实时状态与跳转按钮。授权状态变化后刷新；系统要求重启时明确提示。

### 4.5 跨端预留（本期不实现）

为保证后续 Windows 适配不被锁死，以下边界保持平台无关：

| 边界 | 内容 |
|---|---|
| 核心库 | Rust 纯逻辑，不引用 AppKit；未来 Windows 通过 cdylib/P/Invoke 复用 |
| JSON 协议 | 请求/响应格式稳定，新增 op 向后兼容 |
| 配置与数据库 | 字段语义一致，仅存储目录不同 |
| 标注数据 | 矢量元素 JSON，未来 Windows 用同一模型、不同渲染器 |
| 图片格式 | 一律输出 PNG，不依赖平台专有格式 |

平台能力映射（二期参考，本期不写代码）：热键 `RegisterHotKey`、剪贴板 `AddClipboardFormatListener`、截图 Windows Graphics Capture、UI WinUI 3、常驻改为登录项 + 守护任务。二期单独出设计文档。

## 5. 核心层（olico-core）

### 5.1 数据模型

```rust
enum ClipboardKind { Text, Image, File }

struct ClipboardItem {
    id: String,
    kind: ClipboardKind,
    text: Option<String>,          // 文本正文
    file_paths: Vec<String>,       // 文件列表
    image_path: Option<String>,    // 原图 PNG 路径
    thumb_path: Option<String>,    // 缩略图路径
    hash: String,                  // 去重键
    source_bundle: Option<String>,
    source_name: Option<String>,
    byte_size: i64,
    created_at: i64,
    pinned: bool,
}

struct ClipboardQuery {
    text: String,
    board_id: Option<String>,
    kind: Option<ClipboardKind>,
    limit: u32,
    offset: u32,
}

struct Pinboard {
    id: String,
    name: String,
    color: String,
    sort_order: i32,
    created_at: i64,
    item_count: u32,
}

struct AppShortcut {
    target: String,                // Bundle ID 优先
    path: String,                  // 兜底路径，仅用于展示与缺失提示
    key_code: u32,                 // Carbon 虚拟键码
    modifiers: Vec<String>,        // cmd / opt / ctrl / shift
    enabled: bool,
}
```

### 5.2 模块职责

| 模块 | 职责 | 要点 |
|---|---|---|
| `config` | 配置读写与校验 | 原子写入；缺失字段补默认；版本迁移；重复热键与非法组合拒绝写入 |
| `clipboard` | 剪贴板记录 | 去重命中只刷新时间；置顶与分类板保护；条数/天数双上限；事务内删除并回收文件 |
| `search` | 剪贴板搜索 | 模糊匹配正文、文件名、来源应用名；空查询按“置顶优先 + 时间倒序”；结果确定可复现 |
| `db` | SQLite | WAL、`foreign_keys=ON`、`user_version` 迁移、孤儿文件清理 |

### 5.3 FFI 接口

```c
typedef struct OlicoHandle OlicoHandle;

OlicoHandle* olico_core_new(const char* data_dir);
void         olico_core_free(OlicoHandle* handle);
char*        olico_dispatch(OlicoHandle* handle, const char* request_json);
void         olico_string_free(char* ptr);
```

- `olico-ffi` 的 crate-type 为 `["staticlib"]`（macOS 静态链接）。
- 单入口 `olico_dispatch`，UTF-8 JSON；所有导出函数包裹 `catch_unwind`。
- 返回字符串由调用方 `olico_string_free` 释放；头文件由 cbindgen 生成。

请求/响应：

```json
{"v":1,"op":"clipboard_list","payload":{"text":"api","limit":50,"offset":0}}
{"v":1,"ok":true,"data":[{"item":{"id":"..."}}]}
{"v":1,"ok":false,"error":{"code":"invalid_payload","message":"..."}}
```

操作清单：

| op | payload | 说明 |
|---|---|---|
| `clipboard_add` | `kind, text?, file_paths?, image_path?, thumb_path?, source_bundle?, source_name?, byte_size` | 写入并去重，返回最终条目 |
| `clipboard_list` | `text, board_id?, kind?, limit, offset` | 查询历史 |
| `clipboard_delete` | `id` | 删除单条并回收文件 |
| `clipboard_pin` | `id, pinned` | 置顶/取消置顶 |
| `clipboard_clear` | `{}` | 清空全部记录（含置顶，需二次确认） |
| `maintenance_prune` | `{}` | 执行保留策略与孤儿文件回收 |
| `pinboard_create` | `name, color` | 新建分类板 |
| `pinboard_rename` | `id, name` | 重命名 |
| `pinboard_delete` | `id` | 删除分类板（不删条目） |
| `pinboard_list` | `{}` | 分类板与条目数 |
| `pinboard_add_item` | `board_id, item_id` | 加入分类板 |
| `pinboard_remove_item` | `board_id, item_id` | 移出分类板 |
| `config_get` | `{}` | 返回完整配置 |
| `config_set` | `config` | 校验后原子写入 |

### 5.4 配置（v2）

```json
{
  "version": 2,
  "hotkeys": {
    "screenshot": {"key_code": 1, "modifiers": ["opt", "shift"]},
    "clipboard": {"key_code": 9, "modifiers": ["cmd", "shift"]},
    "color_picker": {"key_code": 8, "modifiers": ["opt", "shift"]},
    "toggle_pins": {"key_code": 4, "modifiers": ["opt", "shift"]}
  },
  "shortcuts": [
    {
      "target": "com.google.Chrome",
      "path": "/Applications/Google Chrome.app",
      "key_code": 1,
      "modifiers": ["opt", "shift"],
      "enabled": true
    }
  ],
  "clipboard": {
    "enabled": true,
    "max_items": 500,
    "retention_days": 30,
    "max_image_mb": 50,
    "max_text_kb": 512,
    "excluded_apps": [
      "com.agilebits.onepassword7",
      "com.bitwarden.desktop",
      "com.apple.keychainaccess"
    ]
  },
  "screenshot": {
    "save_dir": "~/Pictures/Olico",
    "color_format": "hex",
    "restore_pins": true
  },
  "residency": {
    "launch_at_login": true
  }
}
```

默认快捷键：

| 功能 | 默认 | 说明 |
|---|---|---|
| 截图 | `⌥⇧S` | 避开系统截图与微信 `⌘⇧A` |
| 剪贴板面板 | `⌘⇧V` | 会全局拦截“粘贴并匹配样式”，设置页提示 |
| 取色 | `⌥⇧C` | |
| 隐藏/显示全部贴图 | `⌥⇧H` | 隐藏不关闭 |

`key_code` 为 Carbon 虚拟键码，显示字符按当前键盘布局换算，配置里不存显示文本。

### 5.5 存储布局

macOS：`~/Library/Application Support/Olico/`

```
config.json
olico.db
images/           # 原图 <hash>.png
thumbnails/       # 256px 缩略图
pins/             # 贴图图片 + pins.json
color_history.json
logs/             # 滚动日志：单文件 5MB，保留 3 份
```

### 5.6 数据库与一致性

```sql
CREATE TABLE clipboard_items (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  text TEXT,
  file_paths_json TEXT,
  image_path TEXT,
  thumb_path TEXT,
  hash TEXT NOT NULL UNIQUE,
  source_bundle TEXT,
  source_name TEXT,
  byte_size INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  pinned INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_items_created ON clipboard_items(created_at DESC);
CREATE INDEX idx_items_pinned ON clipboard_items(pinned, created_at DESC);

CREATE TABLE pinboards (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  color TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE pinboard_items (
  board_id TEXT NOT NULL REFERENCES pinboards(id) ON DELETE CASCADE,
  item_id TEXT NOT NULL REFERENCES clipboard_items(id) ON DELETE CASCADE,
  added_at INTEGER NOT NULL,
  PRIMARY KEY (board_id, item_id)
);
```

- 去重键 `hash`：文本按 UTF-8 归一化后 SHA-256；图片按 PNG 字节；文件按排序后的路径列表。命中时只更新 `created_at`，保留 `pinned` 与分类板归属。
- 保留策略：`max_items` 与 `retention_days` 先到先清；`pinned = 1` 或存在于任意分类板的记录不自动清理。
- 启动时与每次写入后执行清理；事务提交后删除对应图片/缩略图；启动时扫描目录回收数据库无引用的孤儿文件。
- 数据库损坏：重命名为 `olico.db.corrupt.<时间戳>` 后重建空库，并提示用户历史已不可用。
- 迁移统一使用 `PRAGMA user_version`，只允许向前迁移。

## 6. 应用热键

### 6.1 数据与注册

- 快捷键存 `config.json` 的 `shortcuts[]`；`target` 为 Bundle ID，`path` 仅作展示与兜底。
- 使用 Carbon `RegisterEventHotKey` 注册全部热键，一个事件处理器 + `hotKeyID → shortcut` 映射。
- 启动时先读取配置并注册，再显示菜单栏图标，确保热键早于 UI 可用。
- 配置变化时整体注销并重建；重建失败的热键逐条标记。

### 6.2 执行语义

- 已运行：按 Bundle ID 找到 `NSRunningApplication`，激活并提升其全部窗口。
- 未运行：`NSWorkspace.openApplication` 启动。
- 应用已卸载/移动：不注册热键，设置页标灰“未找到”，不弹窗。
- 启动失败：菜单栏图标旁 toast 提示，写日志。

### 6.3 设置页

- 打开时扫描 `/Applications`、`/System/Applications`、`/Applications/Utilities`、`~/Applications`，深度 ≤ 3，按 Bundle ID 去重；读取名称与图标；提供刷新按钮；结果缓存 5 分钟。
- 列表项：图标、名称、Bundle ID（次要）、当前快捷键、录制/清除按钮。
- 顶部搜索框；开关“仅显示已设置”。
- 顶部固定“已设置的快捷键”概览区，一眼核对全部绑定。
- 录制：模态按键捕获视图，`Esc` 取消，录制期间吞掉按键；保存前试注册，冲突当场提示。

### 6.4 冲突与限制

- 三重校验：与四个内置热键重复、应用热键彼此重复、组合过于简单（无修饰键且非功能键）。
- 注册失败（被系统或其他应用占用）在设置页标红并给出原因；不影响其他热键。
- 媒体键、系统保留组合（`⌘⇧3/4/5` 等）无法注册，录制时直接拒绝并说明。

## 7. 剪贴板

### 7.1 采集

- 500ms 轮询 `NSPasteboard.general.changeCount`；应用自身回贴引起的变更用 changeCount 基线跳过。
- 读取优先级：文件 URL → 图片（PNG/TIFF）→ 文本。
- 来源应用取采集时前台应用的 Bundle ID 与名称，用于卡片角标。
- 图片写入 `images/<hash>.png`，同时生成 256px 缩略图；文件只存路径列表。
- 单图上限 50MB、文本上限 512KB，超限跳过并记日志（不记内容）。
- 一期类型边界：纯文本、图片、文件列表；富文本降级为纯文本保存。

### 7.2 去重与清理

按 5.6 执行。用户手动删除分类板不删除条目；删除条目会同时从所有分类板移除。

### 7.3 面板

- `NSPanel` 720×520，浮于所有窗口之上，显示在鼠标所在屏幕居中偏上，失焦隐藏。
- 结构：搜索框 → 分类板标签（全部 / 已置顶 / 自定义板）→ 按“今天 / 昨天 / 更早”分组的横向卡片行；置顶区固定在顶部。
- 卡片：160×120 预览（文本摘要 / 图片缩略图 / 最多 4 个文件图标）+ 来源应用图标 + 时间 + 置顶标记；悬停显示置顶、删除、加入分类板。
- 键盘：方向键导航、`Enter` 回贴、`⌘1–9` 快贴当前可见前 9 条、`⌘P` 置顶、`Delete` 删除、空格大图/长文预览、`Esc` 关闭。
- 删除后底部 toast 5 秒内可撤销。
- 分类板：新建/重命名/删除；卡片拖到标签即加入；内置“全部”“已置顶”不可删。
- 视觉：深色半透明材质、12px 圆角卡片、统一间距，参数放 `shared/design-tokens.json`。

### 7.4 搜索

- 输入防抖 150ms → `clipboard_list`；模糊匹配正文、文件名、来源应用名。
- 空查询：置顶优先，其余按时间倒序。
- 列表上限 100 条，滚动加载更多。

### 7.5 回贴

1. 显示面板前记录前台应用。
2. 用户确认后把条目写回原始类型：文本 / 图片（PNG + TIFF）/ 文件 URL 列表。
3. 隐藏面板、重新激活原应用。
4. 辅助功能已授权且未处于安全输入模式：80ms 后 `CGEvent` 发送 `⌘V`。
5. 未授权或 `IsSecureEventInputEnabled()` 为真：只复制，提示“已复制，按 ⌘V 粘贴”。

### 7.6 隐私

- 跳过 `ConcealedType`、`TransientType` 与密码管理器标记。
- 默认排除 1Password、Bitwarden、钥匙串访问；支持自定义排除应用。
- 菜单栏“暂停记录”立即生效，不缓存暂停期间内容。
- 日志不记录剪贴板正文、文件名或图片内容。

### 7.7 性能

- 卡片只加载缩略图；原图仅在预览与回贴时读取。
- 缩略图内存缓存上限 64MB，超出按最近最少使用淘汰。
- 500 条历史下打开面板 ≤ 200ms，搜索响应 ≤ 100ms。

## 8. 截图

### 8.1 触发与权限

- 热键（默认 `⌥⇧S`）→ 检查屏幕录制权限。
- 未授权：显示引导卡片，跳转系统设置；授权后按系统要求提示重启应用。
- 控件级识别与模拟粘贴需要辅助功能；未授权只影响控件识别与自动粘贴。

### 8.2 取景

1. `SCShareableContent` 获取显示器与窗口列表。
2. 每个显示器用 `SCScreenshotManager` 抓原生像素静态帧。
3. 每个显示器铺一层无边框浮层窗口（高于普通窗口，跟随所有 Space 与全屏应用），背景为冻结帧。
4. 鼠标交互：十字线、8× 放大镜（像素网格、坐标、HEX/RGB）、当前窗口边界高亮；辅助功能可用时高亮按钮/文字等控件。
5. 选择：拖拽 = 区域，单击 = 窗口，双击空白 = 当前显示器整屏，`Esc`/右键 = 取消；选区限定在单个显示器内。
6. 选区上浮工具栏，贴近屏幕边缘自动翻转。

### 8.3 标注

- 工具：矩形、椭圆、箭头、画笔、文字、马赛克、橡皮、撤销、重做。
- 样式：8 色色板、线宽 1/2/4/8、文字字号、马赛克粒度。
- 数据模型为矢量元素列表（见 8.9），撤销/重做回退列表，栈上限 50。
- 文字使用原生文本视图，支持中文输入法组合；`Enter` 提交、`Esc` 取消。
- 马赛克对底图区域做像素化，粒度可调。
- 橡皮为“划过即删除命中的标注元素”；一期不支持像素级擦除与标注二次拖拽编辑。

### 8.4 输出

- 按 Retina 原生像素渲染，复制时同时写 PNG + TIFF，`Enter`/双击选区 = 复制。
- 保存默认 `~/Pictures/Olico/`，文件名 `Olico_YYYY-MM-DD_HH-mm-ss.png`，`⌘S` 触发；成功后提示并支持“在 Finder 中显示”。
- 保存失败时保留剪贴板复制结果并提示。

### 8.5 贴图

- 每张贴图为独立无边框 `NSPanel`：置顶、跟随所有 Space、不抢焦点、`sharingType = .none`（不进入截图）。
- 操作：拖动移动、滚轮缩放（10%–500% 保持比例）、双击关闭、右键菜单（复制/保存/旋转 90°/透明度/关闭）。
- 多张贴图共存；`⌥⇧H` 隐藏/恢复全部，隐藏不等于关闭。
- 持久化：图片与元数据（位置、缩放、旋转、透明度、屏幕）存 `pins/`，重启恢复；上限 20 张。
- 恢复时若原屏幕不存在，夹回主屏可见区域。

### 8.6 取色器

- 热键（默认 `⌥⇧C`）→ 冻结画面 + 十字线/放大镜 → 单击复制颜色。
- 格式 HEX / RGB / HSL 可选，即时提示。
- 最近 10 个颜色存 `color_history.json`，下次取色以侧边色条展示，点击即复制。

### 8.7 多显示器与 Retina

- 所有几何计算统一使用像素坐标；选择框、标注、输出尺寸都按 `backingScaleFactor` 换算。
- 浮层每屏一个，选区不跨屏；坐标显示为真实像素坐标。
- 显示器插拔时关闭当前取景并提示，重新触发即可。

### 8.8 边界

不做滚动长截图、录屏、OCR、贴图云同步、贴图跨设备。

### 8.9 标注数据格式（平台无关）

```json
{
  "version": 1,
  "canvas": {"width_px": 1440, "height_px": 900},
  "elements": [
    {"type": "rect", "x": 10, "y": 10, "w": 120, "h": 80, "color": "#FF3B30", "stroke": 2},
    {"type": "ellipse", "x": 40, "y": 40, "w": 100, "h": 60, "color": "#FFCC00", "stroke": 2},
    {"type": "arrow", "x1": 0, "y1": 0, "x2": 80, "y2": 60, "color": "#34C759", "stroke": 4},
    {"type": "pen", "points": [[0, 0], [8, 12]], "color": "#0A84FF", "stroke": 2},
    {"type": "text", "x": 20, "y": 20, "text": "示例", "font_size": 16, "color": "#FFFFFF"},
    {"type": "mosaic", "points": [[30, 30]], "brush": 24, "block": 8}
  ]
}
```

本期只作为内部模型与测试契约，不导出；未来 Windows 端复用同一模型、重写渲染器。

## 9. 常驻与稳定性

### 9.1 形态与单实例

- `LSUIElement = true`，无 Dock 图标；菜单栏状态项提供：剪贴板、截图、取色、隐藏贴图、设置、暂停记录、退出。
- 单实例：文件锁 + 运行中实例检测；二次启动激活已有实例后立即 `exit(0)`。

### 9.2 登录自启与崩溃拉起

使用 `~/Library/LaunchAgents/com.olico.app.plist`：

```xml
<key>Label</key><string>com.olico.app</string>
<key>ProgramArguments</key>
<array><string>/Applications/Olico.app/Contents/MacOS/Olico</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key>
<dict><key>SuccessfulExit</key><false/></dict>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>ProcessType</key><string>Interactive</string>
```

- 一次配置同时解决登录自启与崩溃拉起；正常退出（`exit(0)`）不会被复活。
- 首次开启：写 plist → `launchctl bootstrap gui/$UID` → 原实例释放单实例锁并 `exit(0)` → launchd 拉起的实例在 ≤2 秒内拿到锁接管。设置页显示“守护已生效/未生效”。
- 关闭开关：`launchctl bootout gui/$UID/com.olico.app` 并删除 plist。
- 交接失败或系统策略拦截：回退为普通启动 + 登录项，并在设置页明确提示“崩溃不会被自动拉起”。

### 9.3 唤醒与显示器变化

- 监听 `NSWorkspace.didWakeNotification`：重新注册全部 Carbon 热键、重置粘贴板 `changeCount` 基线、重启轮询定时器、重建贴图窗口、刷新显示器列表。
- 监听 `NSApplication.didChangeScreenParametersNotification`：贴图位置夹回可见区域，关闭失效的取景层。
- 快速用户切换返回后执行同一套恢复流程。

### 9.4 健康自检

每 30 秒检查一次：已注册热键数 == 配置数、SQLite 可读写、轮询定时器存活、菜单栏图标存在。异常只写日志并尝试修复，不打断用户。

### 9.5 资源上限

- 剪贴板：500 条 / 30 天；图片 50MB、文本 512KB 单条上限。
- 缩略图缓存 64MB；贴图上限 20 张；标注撤销栈 50。
- 日志单文件 5MB、保留 3 份。
- 空闲内存目标：常驻 < 150MB；打开面板/截图后回落到基线附近。

### 9.6 崩溃与日志

- 安装未捕获异常处理器与信号处理，写 `logs/crash-<时间戳>.log` 后退出，由 launchd 拉起。
- 日志只记录事件、错误码、耗时，不记录内容。
- 连续崩溃由 launchd 节流（约 10 秒间隔）；设置页提供“打开日志目录”。

### 9.7 TCC 稳定性

- 固定自签名证书 `Olico Dev`，Bundle ID 固定；重编译、覆盖安装不丢屏幕录制/辅助功能授权。
- 升级时直接替换 app 包；若签名变化，设置页主动提示重新授权。

## 10. 设置窗口

| 标签 | 内容 |
|---|---|
| 应用 | 应用列表、搜索、录制快捷键、冲突提示、已设置概览、刷新 |
| 剪贴板 | 启用开关、条数/天数上限、排除应用、暂停记录、清空历史（二次确认） |
| 截图 | 保存目录、颜色格式、贴图恢复开关 |
| 通用 | 登录自启、守护状态、屏幕录制/辅助功能权限状态与跳转、日志目录、版本号 |

## 11. 关键流程

### 11.1 启动

1. 单实例检查 → 读取配置 → 初始化 SQLite → 执行清理 → 注册全部热键。
2. 恢复贴图（配置开启时）→ 创建菜单栏图标 → 启动剪贴板轮询与健康自检。
3. 任一环节失败不阻塞启动：记录日志、菜单栏图标带感叹号角标、设置页展示原因。

### 11.2 应用热键

热键事件 → 映射到 Bundle ID → 已运行则激活全部窗口，未运行则启动 → 写日志（仅应用 ID 与耗时）。

### 11.3 剪贴板

轮询发现变化 → 判断类型与排除规则 → 计算 hash → 图片落盘与缩略图 → `clipboard_add` → 通知面板刷新（若可见）。
回贴：记录前台应用 → 写粘贴板 → 隐藏面板 → 激活原应用 → 模拟 `⌘V` 或提示手动粘贴。

### 11.4 截图

热键 → 权限检查 → 抓帧 → 浮层 → 选择 → 标注 → 复制/保存/贴图。贴图创建后立即写元数据，关闭或变更时更新。

### 11.5 崩溃恢复

launchd 拉起 → 单实例检查 → 读取配置与数据库 → 注册热键 → 恢复贴图 → 恢复菜单栏。剪贴板历史来自 SQLite，不丢数据。

### 11.6 错误降级

| 场景 | 行为 |
|---|---|
| 屏幕录制被拒 | 截图/取色显示引导卡片，其余功能正常 |
| 辅助功能被拒 | 控件识别降级为窗口级；回贴只复制并提示 |
| 热键注册失败 | 设置页标红并说明；其他热键正常 |
| 安全输入模式 | 回贴只复制，不模拟按键 |
| 截到受保护内容黑帧 | 提示可能受 DRM/受保护窗口影响 |
| 数据库损坏 | 备份损坏文件、重建空库并提示 |
| 图片/缩略图写盘失败 | 剪贴板复制与面板仍可用，记录错误 |
| 贴图恢复失败 | 跳过该张，继续恢复其余，日志记录 |
| launchd 交接失败 | 回退普通启动 + 登录项，设置页提示守护未生效 |

## 12. 构建与发布

### 12.1 产物

- `Olico-<ver>-macos-universal.dmg`，包含 arm64 + x86_64，最低 macOS 14。
- 本阶段只做 macOS；Windows 产物在二期引入。

### 12.2 本地构建

1. `scripts/build-macos.sh`：分别构建 `aarch64-apple-darwin` 与 `x86_64-apple-darwin` 静态库 → `lipo` 合并。
2. XcodeGen 生成工程 → `xcodebuild ARCHS="arm64 x86_64"`。
3. 签名（固定自签名证书）→ `create-dmg`。

### 12.3 CI

- `ci.yml`（PR 与主分支，`macos-14`）：`cargo fmt --check`、`cargo clippy -D warnings`、`cargo test`、`xcodebuild build`（不签名）。
- 发布流水线在需要对外分发时再增加；本期自用可本地出包。
- 缓存 Rust 与 DerivedData。

### 12.4 版本号

根 `VERSION` 经 `scripts/version-sync.sh` 同步到 `Cargo.toml`、`project.yml`、`Info.plist`。

## 13. 测试

### 13.1 自动化

- Rust 单元测试：去重键与时间刷新、置顶/分类板保护、保留策略边界、分类板 CRUD、搜索排序金标、配置校验与迁移、孤儿文件清理。
- Swift 单元测试：标注元素几何与渲染快照（固定输入 PNG 对比）、贴图变换数学、热键组合校验、文件名生成、剪贴板类型映射。
- FFI 契约：C harness 链接静态库跑一组 op，校验 JSON 结构。
- CI 门禁：`fmt`、`clippy -D warnings`、`cargo test`、`xcodebuild build`。

### 13.2 手工验收

应用热键：

- 三个应用分别绑定热键，冷启动与已运行两种状态都能正确切换。
- 与内置热键/其他应用冲突时设置页标红且不生效。
- 卸载一个已绑定应用后，设置页标灰、不报错。

剪贴板：

- 文本、图片、多个文件分别复制后正确入库与展示。
- 连续复制同一内容只保留一条并置顶到最前。
- 分类板增删改、拖拽加入、删除条目同步移出。
- 密码管理器内容与暂停记录期间内容不入库。
- 超过条数/天数后自动清理，置顶项保留。
- 回贴到浏览器、编辑器、Finder 均正确；关闭辅助功能后只复制。

截图：

- 多显示器 + Retina 下区域尺寸与像素准确。
- 窗口识别、控件识别（授权/未授权两种）表现正确。
- 七个标注工具、撤销重做、中文文字输入。
- 复制到其他应用、保存到目录、贴图缩放旋转、隐藏全部贴图。
- 贴图重启后恢复；受保护视频窗口黑帧有提示。
- 取色三种格式与历史色条。

常驻：

- 登录后自动出现菜单栏图标。
- `kill -9` 后 10 秒内被拉起，剪贴板历史与贴图恢复。
- 正常退出后不被拉起；再次手动启动只有一个实例。
- 合盖唤醒、切换用户返回后热键与剪贴板监听正常。
- 拔插外接显示器后贴图位置合理。

## 14. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| TCC 授权与签名绑定 | 重编译后权限丢失 | 固定自签名证书；设置页展示权限状态；覆盖安装不换签名 |
| 全局热键冲突（尤其 `⌘⇧V`） | 用户肌肉记忆被改变或热键无法注册 | 试注册 + 明确提示 + 全部可改 |
| LaunchAgent 受管交接失败或被策略拦截 | 崩溃不自动拉起 | 回退登录项并在设置页显示“守护未生效”；提供文档 |
| launchd 崩溃节流 | 连续崩溃时恢复变慢 | 崩溃日志定位；健康自检降低故障面 |
| ScreenCaptureKit 对 DRM/受保护窗口黑帧 | 截图内容为空 | 检测黑帧并提示；不承诺绕过 |
| 安全输入模式下无法模拟粘贴 | 回贴失败 | 检测 `IsSecureEventInputEnabled`，降级为仅复制 |
| 剪贴板图片导致磁盘/内存膨胀 | 磁盘占满、卡顿 | 单条上限、条数/天数上限、缩略图缓存、孤儿文件回收 |
| 多显示器坐标换算错误 | 选区/贴图位置错 | 统一像素坐标；手工清单覆盖 |
| 中文输入法与快捷键/文字工具冲突 | 误触发或无法输入 | 输入法组合期间不处理导航键；文字工具用原生文本视图 |
| 设置页枚举大量应用耗时 | 打开卡顿 | 后台扫描 + 缓存 + 刷新按钮 |

## 15. 验收标准

1. 设置页能列出本机应用并搜索；为应用录键后，任意前台应用下按热键：已运行则切换，未运行则启动；冲突组合键当场标红且不生效。
2. 剪贴板记录文本/图片/文件并去重；卡片视图、搜索、置顶、分类板、`⌘1–9` 快贴、`Enter` 回贴均可用。
3. 剪贴板排除应用、暂停记录、条数与天数上限、置顶保护全部生效。
4. 截图支持区域/窗口/整屏、放大镜坐标、七个标注工具与撤销重做、复制/保存/贴图。
5. 多显示器 Retina 下截图尺寸与像素正确；贴图可移动、缩放、旋转、隐藏并在重启后恢复。
6. 取色器支持 HEX/RGB/HSL 并保留最近 10 个颜色。
7. 菜单栏常驻、无 Dock 图标；登录自动启动；`kill -9` 后 10 秒内自动拉起。
8. 正常退出不被拉起；二次启动只有单实例；交接失败时设置页明确提示。
9. 合盖唤醒与切换用户返回后，热键、剪贴板监听、贴图全部恢复。
10. 重启后配置、剪贴板历史、分类板、贴图、取色历史全部保留。
11. 屏幕录制/辅助功能被拒或被撤销时给出引导而非崩溃，降级行为符合 11.6。
12. CI 在 PR 上通过 `fmt`、`clippy -D warnings`、`cargo test`、`xcodebuild build`。

## 16. 后续（二期候选）

- Windows 端适配：复用 Rust 核心、JSON 协议、SQLite schema 与标注模型；重写热键、剪贴板监听、截图采集、贴图窗口与常驻守护。
- 恢复 v1.0 延后的启动器搜索、文件搜索、计算器、网页搜索、窗口管理。
- 截图扩展：滚动长截图、录屏、标注二次编辑、OCR。
- 自动更新与正式签名分发（Developer ID + 公证）。
