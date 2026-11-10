# Olico macOS Shell Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立可运行的 macOS 菜单栏应用外壳：SPM 构建、FFI 桥接、launchd 常驻、Carbon 全局热键、应用目录与设置界面。

**Architecture:** Swift Package（`OlicoKit` 可测试库 + `Olico` AppKit 可执行目标）通过 C module 调用 Rust 静态库。单进程、`LSUIElement`、无 Dock 图标；`AppDelegate` 负责装配 CoreClient、GlobalHotkeyCenter、AppCatalog、LaunchAgent 与设置窗口。构建脚本用 `swift build` 组装 `.app`，默认 ad-hoc 签名，支持 `CODESIGN_IDENTITY` 注入固定证书。

**Tech Stack:** Swift 5 语言模式、SwiftUI + AppKit、Carbon HIToolbox、ServiceManagement 之外的 `launchctl` + LaunchAgent、Rust `olico-ffi` 静态库。

**Spec:** `docs/superpowers/specs/2026-11-10-olico-design.md`

## Global Constraints

- 最低 macOS 14；`LSUIElement = true`；Bundle ID 固定 `com.olico.app`。
- 构建 Rust 时必须设置 `MACOSX_DEPLOYMENT_TARGET=14.0`，避免静态库按宿主系统版本链接。
- XcodeGen 不可用，改用 SPM + 脚本组装 `.app`；构建方式以本计划为准，并同步修订 spec §12.2。
- 数据目录：`~/Library/Application Support/Olico/`；日志目录 `logs/`；单文件 5MB、保留 3 份。
- 日志不得包含剪贴板正文、文件名或图片内容。
- 内置热键默认：截图 `⌥⇧S`（key_code 1）、剪贴板 `⌘⇧V`（key_code 9）、取色 `⌥⇧C`（key_code 8）、隐藏贴图 `⌥⇧H`（key_code 4）。
- 应用热键 `target` 为 Bundle ID；应用已卸载/移动时不注册、设置页标灰，不弹窗。
- 所有 FFI 调用串行化；UI 更新回主线程。
- 单实例：文件锁 + 2 秒重试；二次启动激活已有实例并 `exit(0)`。
- LaunchAgent：`RunAtLoad = true`、`KeepAlive.SuccessfulExit = false`、`LimitLoadToSessionType = Aqua`、`ProcessType = Interactive`。
- 录制快捷键时：`Esc` 取消；无修饰键且非功能键拒绝；`⌘⇧3/4/5` 拒绝；冲突当场提示。
- 提交策略：仅在用户明确授权后执行 `git commit`；未授权时保留工作区改动。

---

## 文件结构

```
apps/macos/Package.swift
apps/macos/Sources/COlicoFFI/include/olico.h
apps/macos/Sources/COlicoFFI/include/module.modulemap
apps/macos/Sources/COlicoFFI/shim.c
apps/macos/Sources/OlicoKit/CoreClient.swift
apps/macos/Sources/OlicoKit/Models.swift
apps/macos/Sources/OlicoKit/Hotkey.swift
apps/macos/Sources/OlicoKit/HotkeyValidator.swift
apps/macos/Sources/OlicoKit/AppCatalog.swift
apps/macos/Sources/OlicoKit/AppLauncher.swift
apps/macos/Sources/OlicoKit/SingleInstance.swift
apps/macos/Sources/OlicoKit/LaunchAgent.swift
apps/macos/Sources/OlicoKit/AppLogger.swift
apps/macos/Sources/OlicoKit/SettingsStore.swift
apps/macos/Sources/Olico/main.swift
apps/macos/Sources/Olico/AppDelegate.swift
apps/macos/Sources/Olico/StatusItemController.swift
apps/macos/Sources/Olico/GlobalHotkeyCenter.swift
apps/macos/Sources/Olico/SettingsWindowController.swift
apps/macos/Sources/Olico/SettingsView.swift
apps/macos/Sources/Olico/HotkeyRecorderView.swift
apps/macos/Resources/Info.plist
apps/macos/Tests/OlicoKitTests/CoreClientTests.swift
apps/macos/Tests/OlicoKitTests/HotkeyTests.swift
apps/macos/Tests/OlicoKitTests/AppCatalogTests.swift
apps/macos/Tests/OlicoKitTests/LaunchAgentTests.swift
apps/macos/Tests/OlicoKitTests/AppLoggerTests.swift
scripts/build-macos.sh
```

职责：

- `CoreClient`：FFI 句柄、JSON 收发、类型化解码。
- `Models`：与 Rust JSON 字段一一对应的 Codable 模型。
- `Hotkey` / `HotkeyValidator`：组合规范化、显示、冲突校验。
- `AppCatalog`：扫描应用目录、去重、5 分钟缓存。
- `AppLauncher`：激活或启动应用。
- `SingleInstance` / `LaunchAgent`：文件锁与 launchd 配置。
- `AppLogger`：滚动日志。
- `SettingsStore`：配置、应用列表、热键注册的单一状态源。
- `GlobalHotkeyCenter`：Carbon 注册与事件路由。
- `StatusItemController` / `AppDelegate`：菜单栏与生命周期。
- `SettingsWindowController` / `SettingsView` / `HotkeyRecorderView`：设置界面。

---

### Task 1: SPM 骨架、静态库链接、菜单栏图标

**Files:**
- Create: `apps/macos/Package.swift`
- Create: `apps/macos/Sources/COlicoFFI/include/olico.h`（复制 `crates/olico-ffi/include/olico.h`）
- Create: `apps/macos/Sources/COlicoFFI/include/module.modulemap`
- Create: `apps/macos/Sources/COlicoFFI/shim.c`
- Create: `apps/macos/Sources/Olico/main.swift`
- Create: `apps/macos/Sources/Olico/AppDelegate.swift`
- Create: `apps/macos/Sources/Olico/StatusItemController.swift`
- Create: `apps/macos/Resources/Info.plist`
- Create: `scripts/build-macos.sh`

**Interfaces:**
- Produces: 可执行的 `Olico.app`；`StatusItemController` 持有 `NSStatusItem`；`AppDelegate` 提供 `showSettings()` 与 `terminate()`。

- [x] **Step 1: 建立 Package.swift**

```swift
// swift-tools-version:5.9
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorDir = "\(packageDir)/Vendor"

let package = Package(
    name: "Olico",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Olico", targets: ["Olico"]),
        .library(name: "OlicoKit", targets: ["OlicoKit"]),
    ],
    targets: [
        .target(
            name: "COlicoFFI",
            path: "Sources/COlicoFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "OlicoKit",
            dependencies: ["COlicoFFI"],
            path: "Sources/OlicoKit",
            linkerSettings: [.unsafeFlags(["-L\(vendorDir)", "-lolico_ffi"])]
        ),
        .executableTarget(
            name: "Olico",
            dependencies: ["OlicoKit"],
            path: "Sources/Olico"
        ),
        .testTarget(
            name: "OlicoKitTests",
            dependencies: ["OlicoKit"],
            path: "Tests/OlicoKitTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
```

- [x] **Step 2: 建立 C module**

`Sources/COlicoFFI/include/module.modulemap`：

```
module COlicoFFI {
    header "olico.h"
    export *
}
```

`Sources/COlicoFFI/shim.c`：

```c
#include "olico.h"
```

复制头文件：

```bash
cp crates/olico-ffi/include/olico.h apps/macos/Sources/COlicoFFI/include/olico.h
```

- [x] **Step 3: 建立 Info.plist 模板**

`apps/macos/Resources/Info.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>Olico</string>
  <key>CFBundleIdentifier</key><string>com.olico.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Olico</string>
  <key>CFBundleDisplayName</key><string>Olico</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>__VERSION__</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
```

- [x] **Step 4: 最小 AppDelegate 与状态项**

`main.swift`：

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

`AppDelegate.swift`：

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        if CommandLine.arguments.contains("--settings") {
            showSettings()
        }
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
```

`StatusItemController.swift`：

```swift
import AppKit

final class StatusItemController {
    private let statusItem: NSStatusItem

    init(onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Olico")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(NSApplication.showSettingsWindow(_:)), keyEquivalent: ",")
        settings.target = NSApp
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Olico", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        _ = onSettings
        _ = onQuit
        statusItem.menu = menu
    }
}
```

- [x] **Step 5: 构建脚本**

`scripts/build-macos.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
HOST_TARGET="$(rustc -vV | awk '/^host:/{print $2}')"

export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --release -p olico-ffi --target "$HOST_TARGET"
mkdir -p "$ROOT/apps/macos/Vendor"
cp "$ROOT/target/$HOST_TARGET/release/libolico_ffi.a" "$ROOT/apps/macos/Vendor/libolico_ffi.a"

swift build --package-path "$ROOT/apps/macos" -c release

APP="$ROOT/build/Olico.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/apps/macos/.build/release/Olico" "$APP/Contents/MacOS/Olico"
sed "s/__VERSION__/$VERSION/g" "$ROOT/apps/macos/Resources/Info.plist" > "$APP/Contents/Info.plist"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
```

运行 `chmod +x scripts/build-macos.sh`。

- [x] **Step 6: 验证构建与启动**

Run:

```bash
./scripts/build-macos.sh
open build/Olico.app
sleep 1
pgrep -fl "Olico.app/Contents/MacOS/Olico"
```

Expected: 构建成功；进程存在；菜单栏出现 command 图标。

- [x] **Step 7: 更新 spec 构建方式**

把 `docs/superpowers/specs/2026-11-10-olico-design.md` §12.2 的 XcodeGen/`xcodebuild` 步骤改为：

```
1. scripts/build-macos.sh：设置 MACOSX_DEPLOYMENT_TARGET=14.0，构建宿主机架构静态库并复制到 apps/macos/Vendor。
2. swift build 生成可执行文件，脚本组装 build/Olico.app 并写入 Info.plist。
3. codesign（默认 ad-hoc，可用 CODESIGN_IDENTITY 指定固定自签名证书）。
```

- [ ] **Step 8: 提交（需用户授权）**

```bash
git add apps/macos scripts/build-macos.sh docs/superpowers/specs/2026-11-10-olico-design.md
git commit -m "feat(macos): scaffold spm app with status item"
```

---

### Task 2: CoreClient 与 Codable 模型

**Files:**
- Create: `apps/macos/Sources/OlicoKit/Models.swift`
- Create: `apps/macos/Sources/OlicoKit/CoreClient.swift`
- Test: `apps/macos/Tests/OlicoKitTests/CoreClientTests.swift`

**Interfaces:**
- Produces: `CoreClient.init(dataDir: URL) throws`、`call(_:payload:) throws -> Any`、`call<T: Decodable>(_:payload:as:) throws -> T`、`config() throws -> AppConfig`、`setConfig(_:) throws`、`clipboardClear() throws`、`clipboardDelete(id:) throws`、`clipboardPin(id:pinned:) throws`、`pinboards() throws -> [Pinboard]`。
- 模型字段使用 `JSONDecoder/Encoder` 的 `.convertFromSnakeCase` / `.convertToSnakeCase`。

- [x] **Step 1: 写失败测试**

`CoreClientTests.swift`：

```swift
import XCTest
@testable import OlicoKit

final class CoreClientTests: XCTestCase {
    func testConfigDefaultsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = try CoreClient(dataDir: dir)
        let config = try client.config()
        XCTAssertEqual(config.version, 2)
        XCTAssertEqual(config.hotkeys.clipboard.keyCode, 9)
        XCTAssertEqual(config.hotkeys.clipboard.modifiers, [.cmd, .shift])
    }

    func testConfigSetPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = try CoreClient(dataDir: dir)
        var config = try client.config()
        config.clipboard.maxItems = 11
        try client.setConfig(config)
        XCTAssertEqual(try client.config().clipboard.maxItems, 11)
    }

    func testErrorResponseThrowsWithCode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = try CoreClient(dataDir: dir)
        XCTAssertThrowsError(try client.call("nope", payload: [:])) { error in
            XCTAssertEqual((error as? CoreError)?.code, "unknown_op")
        }
    }

    func testClipboardRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = try CoreClient(dataDir: dir)
        let added: ClipboardItem = try client.call(
            "clipboard_add",
            payload: ["kind": "text", "text": "hello"],
            as: ClipboardItem.self
        )
        XCTAssertEqual(added.text, "hello")
        let items: [ClipboardItem] = try client.call(
            "clipboard_list", payload: [:], as: [ClipboardItem].self
        )
        XCTAssertEqual(items.first?.text, "hello")
    }
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `swift test --package-path apps/macos --filter CoreClientTests`
Expected: 编译失败，`CoreClient` 不存在。

- [x] **Step 3: 实现 Models**

`Models.swift` 关键定义：

```swift
import Foundation

public enum Modifier: String, Codable, CaseIterable, Hashable {
    case cmd, opt, ctrl, shift

    var sortOrder: Int {
        switch self {
        case .cmd: return 0
        case .opt: return 1
        case .ctrl: return 2
        case .shift: return 3
        }
    }
}

public struct Hotkey: Codable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: [Modifier]

    public init(keyCode: UInt32, modifiers: [Modifier]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public func canonical() -> String {
        let sorted = Set(modifiers).sorted { $0.sortOrder < $1.sortOrder }
        return "\(keyCode):\(sorted.map(\.rawValue).joined(separator: ","))"
    }
}

public struct HotkeySet: Codable, Equatable {
    public var screenshot: Hotkey
    public var clipboard: Hotkey
    public var colorPicker: Hotkey
    public var togglePins: Hotkey
}

public struct AppShortcut: Codable, Equatable, Identifiable {
    public var target: String
    public var path: String
    public var keyCode: UInt32
    public var modifiers: [Modifier]
    public var enabled: Bool
    public var id: String { target }
    public var hotkey: Hotkey { Hotkey(keyCode: keyCode, modifiers: modifiers) }
}

public struct ClipboardOptions: Codable, Equatable {
    public var enabled: Bool
    public var maxItems: UInt32
    public var retentionDays: UInt32
    public var maxImageMb: UInt64
    public var maxTextKb: UInt64
    public var excludedApps: [String]
}

public enum ColorFormat: String, Codable, CaseIterable, Identifiable {
    case hex, rgb, hsl
    public var id: String { rawValue }
}

public struct ScreenshotOptions: Codable, Equatable {
    public var saveDir: String
    public var colorFormat: ColorFormat
    public var restorePins: Bool
}

public struct ResidencyOptions: Codable, Equatable {
    public var launchAtLogin: Bool
}

public struct AppConfig: Codable, Equatable {
    public var version: Int
    public var hotkeys: HotkeySet
    public var shortcuts: [AppShortcut]
    public var clipboard: ClipboardOptions
    public var screenshot: ScreenshotOptions
    public var residency: ResidencyOptions
}

public enum ClipboardKind: String, Codable, Equatable {
    case text, image, file
}

public struct ClipboardItem: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: ClipboardKind
    public var text: String?
    public var filePaths: [String]
    public var imagePath: String?
    public var thumbPath: String?
    public var hash: String
    public var sourceBundle: String?
    public var sourceName: String?
    public var byteSize: Int64
    public var createdAt: Int64
    public var pinned: Bool
}

public struct Pinboard: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var color: String
    public var sortOrder: Int32
    public var createdAt: Int64
    public var itemCount: UInt32
}
```

- [x] **Step 4: 实现 CoreClient**

```swift
import Foundation
import COlicoFFI

public struct CoreError: Error, LocalizedError {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
}

public final class CoreClient {
    private let handle: OpaquePointer
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(dataDir: URL) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        guard let handle = olico_core_new(dataDir.path) else {
            throw CoreError(code: "init_failed", message: "无法打开数据目录 \(dataDir.path)")
        }
        self.handle = handle
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    deinit {
        olico_core_free(handle)
    }

    public func raw(_ request: String) -> String {
        guard let ptr = olico_dispatch(handle, request) else {
            return #"{"v":1,"ok":false,"error":{"code":"ffi_error","message":"dispatch returned null"}}"#
        }
        defer { olico_string_free(ptr) }
        return String(cString: ptr)
    }

    public func call(_ op: String, payload: [String: Any] = [:]) throws -> Any {
        let request: [String: Any] = ["v": 1, "op": op, "payload": payload]
        let data = try JSONSerialization.data(withJSONObject: request, options: [])
        let body = String(data: data, encoding: .utf8) ?? "{}"
        let responseData = Data(raw(body).utf8)
        let envelope = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
        guard (envelope["ok"] as? Bool) == true else {
            let error = envelope["error"] as? [String: Any] ?? [:]
            throw CoreError(
                code: error["code"] as? String ?? "unknown",
                message: error["message"] as? String ?? "未知错误"
            )
        }
        return envelope["data"] ?? [:]
    }

    public func call<T: Decodable>(_ op: String, payload: [String: Any] = [:], as type: T.Type) throws -> T {
        let value = try call(op, payload: payload)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try decoder.decode(T.self, from: data)
    }

    public func config() throws -> AppConfig {
        try call("config_get", as: AppConfig.self)
    }

    public func setConfig(_ config: AppConfig) throws {
        let data = try encoder.encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        _ = try call("config_set", payload: ["config": object])
    }

    public func clipboardClear() throws {
        _ = try call("clipboard_clear")
    }

    public func clipboardDelete(id: String) throws {
        _ = try call("clipboard_delete", payload: ["id": id])
    }

    public func clipboardPin(id: String, pinned: Bool) throws {
        _ = try call("clipboard_pin", payload: ["id": id, "pinned": pinned])
    }

    public func pinboards() throws -> [Pinboard] {
        try call("pinboard_list", as: [Pinboard].self)
    }
}
```

注意：`JSONSerialization` 不接受 `Optional`；`encoder.encode` 的 `/` 转义不影响核心解析。

- [x] **Step 5: 运行测试确认通过**

Run: `Vendor/libolico_ffi.a` 需先存在：

```bash
cargo build --release -p olico-ffi
mkdir -p apps/macos/Vendor
cp target/release/libolico_ffi.a apps/macos/Vendor/
swift test --package-path apps/macos --filter CoreClientTests
```

Expected: 4 passed。

- [ ] **Step 6: 提交（需用户授权）**

```bash
git add apps/macos/Sources/OlicoKit apps/macos/Tests/OlicoKitTests/CoreClientTests.swift
git commit -m "feat(macos): bridge rust core over json ffi"
```

---

### Task 3: 热键模型、显示与校验

**Files:**
- Create: `apps/macos/Sources/OlicoKit/Hotkey.swift`
- Create: `apps/macos/Sources/OlicoKit/HotkeyValidator.swift`
- Test: `apps/macos/Tests/OlicoKitTests/HotkeyTests.swift`

**Interfaces:**
- Produces: `HotkeyFormatter.display(_:) -> String`、`HotkeyFormatter.functionKeyCodes`、`HotkeyValidationError`、`HotkeyValidator.validate(hotkey:conflictsWith:) -> HotkeyValidationError?`。
- `Hotkey` 与 `Modifier` 已在 Task 2 定义；本任务只新增格式化与校验。

- [x] **Step 1: 写失败测试**

`HotkeyTests.swift`：

```swift
import XCTest
@testable import OlicoKit

final class HotkeyTests: XCTestCase {
    func testCanonicalSortsModifiers() {
        let a = Hotkey(keyCode: 9, modifiers: [.shift, .cmd])
        let b = Hotkey(keyCode: 9, modifiers: [.cmd, .shift])
        XCTAssertEqual(a.canonical(), b.canonical())
    }

    func testDisplaySymbols() {
        XCTAssertEqual(HotkeyFormatter.display(Hotkey(keyCode: 0, modifiers: [.cmd])), "⌘A")
        XCTAssertEqual(HotkeyFormatter.display(Hotkey(keyCode: 1, modifiers: [.opt, .shift])), "⌥⇧S")
        XCTAssertEqual(HotkeyFormatter.display(Hotkey(keyCode: 49, modifiers: [.ctrl])), "⌃Space")
    }

    func testBareKeyIsRejected() {
        let error = HotkeyValidator.validate(
            hotkey: Hotkey(keyCode: 0, modifiers: []),
            conflictsWith: []
        )
        XCTAssertEqual(error, .tooSimple)
    }

    func testBareFunctionKeyIsAllowed() {
        XCTAssertNil(HotkeyValidator.validate(
            hotkey: Hotkey(keyCode: 122, modifiers: []),
            conflictsWith: []
        ))
    }

    func testSystemScreenshotShortcutIsRejected() {
        let error = HotkeyValidator.validate(
            hotkey: Hotkey(keyCode: 20, modifiers: [.cmd, .shift]),
            conflictsWith: []
        )
        XCTAssertEqual(error, .reserved)
    }

    func testConflictUsesCanonicalForm() {
        let existing = Hotkey(keyCode: 0, modifiers: [.cmd, .shift])
        let error = HotkeyValidator.validate(
            hotkey: Hotkey(keyCode: 0, modifiers: [.shift, .cmd]),
            conflictsWith: [("截图", existing)]
        )
        XCTAssertEqual(error, .conflicts("截图"))
    }

    func testNoConflictForDistinctHotkey() {
        XCTAssertNil(HotkeyValidator.validate(
            hotkey: Hotkey(keyCode: 1, modifiers: [.opt, .shift]),
            conflictsWith: [("剪贴板", Hotkey(keyCode: 9, modifiers: [.cmd, .shift]))]
        ))
    }
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `swift test --package-path apps/macos --filter HotkeyTests`
Expected: 编译失败。

- [x] **Step 3: 实现 HotkeyFormatter**

```swift
import Foundation

public enum HotkeyFormatter {
    public static let functionKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
        9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab",
        49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
    ]

    public static func display(_ hotkey: Hotkey) -> String {
        let symbols = Set(hotkey.modifiers).sorted { $0.sortOrder < $1.sortOrder }.map { modifier -> String in
            switch modifier {
            case .cmd: return "⌘"
            case .opt: return "⌥"
            case .ctrl: return "⌃"
            case .shift: return "⇧"
            }
        }.joined()
        return symbols + (keyNames[hotkey.keyCode] ?? "Key\(hotkey.keyCode)")
    }
}
```

- [x] **Step 4: 实现校验器**

```swift
import Foundation

public enum HotkeyValidationError: Error, Equatable, LocalizedError {
    case tooSimple
    case reserved
    case conflicts(String)

    public var errorDescription: String? {
        switch self {
        case .tooSimple: return "请至少按下一个修饰键，或使用功能键"
        case .reserved: return "该组合被系统占用（⌘⇧3/4/5）"
        case .conflicts(let label): return "与「\(label)」冲突"
        }
    }
}

public enum HotkeyValidator {
    public static func validate(
        hotkey: Hotkey,
        conflictsWith existing: [(label: String, hotkey: Hotkey)]
    ) -> HotkeyValidationError? {
        if hotkey.modifiers.isEmpty, !HotkeyFormatter.functionKeyCodes.contains(hotkey.keyCode) {
            return .tooSimple
        }
        let reservedCodes: Set<UInt32> = [20, 21, 23]
        let modifiers = Set(hotkey.modifiers)
        if modifiers == [.cmd, .shift], reservedCodes.contains(hotkey.keyCode) {
            return .reserved
        }
        let canonical = hotkey.canonical()
        if let match = existing.first(where: { $0.hotkey.canonical() == canonical }) {
            return .conflicts(match.label)
        }
        return nil
    }
}
```

- [x] **Step 5: 运行测试确认通过**

Run: `swift test --package-path apps/macos --filter HotkeyTests`
Expected: 7 passed。

- [ ] **Step 6: 提交（需用户授权）**

```bash
git add apps/macos/Sources/OlicoKit/Hotkey.swift apps/macos/Sources/OlicoKit/HotkeyValidator.swift apps/macos/Tests/OlicoKitTests/HotkeyTests.swift
git commit -m "feat(macos): validate and format hotkeys"
```

---

### Task 4: 应用目录扫描与启动

**Files:**
- Create: `apps/macos/Sources/OlicoKit/AppCatalog.swift`
- Create: `apps/macos/Sources/OlicoKit/AppLauncher.swift`
- Test: `apps/macos/Tests/OlicoKitTests/AppCatalogTests.swift`

**Interfaces:**
- Produces: `AppEntry`、`AppCatalog.init(roots:maxDepth:ttl:)`、`scan(force:)`、`invalidate()`、`AppLauncher.activateOrLaunch(_:) throws`。

- [x] **Step 1: 写失败测试**

`AppCatalogTests.swift`：

```swift
import XCTest
@testable import OlicoKit

final class AppCatalogTests: XCTestCase {
    private func makeApp(root: URL, relative: String, bundleID: String, name: String) throws {
        let app = root.appendingPathComponent(relative)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testScansAndDedupesByBundleID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeApp(root: root, relative: "A.app", bundleID: "com.example.a", name: "Alpha")
        try makeApp(root: root, relative: "sub/B.app", bundleID: "com.example.a", name: "Alpha Copy")
        try makeApp(root: root, relative: "C.app", bundleID: "com.example.c", name: "Gamma")

        let catalog = AppCatalog(roots: [root], maxDepth: 3, ttl: 60)
        let apps = catalog.scan(force: true)
        XCTAssertEqual(apps.map(\.bundleID), ["com.example.a", "com.example.c"])
        XCTAssertEqual(apps.first?.name, "Alpha")
    }

    func testDepthLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeApp(root: root, relative: "a/b/c/Deep.app", bundleID: "com.example.deep", name: "Deep")
        let catalog = AppCatalog(roots: [root], maxDepth: 2, ttl: 60)
        XCTAssertTrue(catalog.scan(force: true).isEmpty)
    }

    func testNameFallsBackToFileStem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("NoName.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.noname"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        let catalog = AppCatalog(roots: [root], maxDepth: 3, ttl: 60)
        XCTAssertEqual(catalog.scan(force: true).first?.name, "NoName")
    }
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `swift test --package-path apps/macos --filter AppCatalogTests`
Expected: 编译失败。

- [x] **Step 3: 实现 AppCatalog**

```swift
import Foundation

public struct AppEntry: Identifiable, Equatable, Hashable {
    public let bundleID: String
    public let name: String
    public let path: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

public final class AppCatalog {
    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
    }

    private let roots: [URL]
    private let maxDepth: Int
    private let ttl: TimeInterval
    private var cached: [AppEntry] = []
    private var cachedAt: Date?

    public init(roots: [URL] = AppCatalog.defaultRoots, maxDepth: Int = 3, ttl: TimeInterval = 300) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.ttl = ttl
    }

    public func invalidate() {
        cachedAt = nil
    }

    public func scan(force: Bool = false) -> [AppEntry] {
        if !force, let cachedAt, Date().timeIntervalSince(cachedAt) < ttl {
            return cached
        }
        var seen = Set<String>()
        var entries: [AppEntry] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let relativeDepth = url.pathComponents.count - root.pathComponents.count
                if relativeDepth > maxDepth {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "app" else { continue }
                enumerator.skipDescendants()
                guard let entry = makeEntry(at: url), seen.insert(entry.bundleID).inserted else { continue }
                entries.append(entry)
            }
        }
        cached = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedAt = Date()
        return cached
    }

    private func makeEntry(at url: URL) -> AppEntry? {
        let info = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty
        else { return nil }
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppEntry(bundleID: bundleID, name: name, path: url.path)
    }

    public func entry(for bundleID: String) -> AppEntry? {
        scan().first { $0.bundleID == bundleID }
    }
}
```

注意：`.skipsPackageDescendants` 会阻止进入 `.app` 内部，枚举器仍能返回 `.app` 本身；若测试深度用例因跳过包内部失效，改为不用该选项并在识别 `.app` 后 `skipDescendants()`。

- [x] **Step 4: 实现 AppLauncher**

```swift
import AppKit

public enum AppLaunchError: Error, LocalizedError {
    case notFound(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let target): return "未找到应用 \(target)"
        case .launchFailed(let reason): return "启动失败：\(reason)"
        }
    }
}

public enum AppLauncher {
    public static func activateOrLaunch(_ entry: AppEntry) throws {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).first {
            running.unhide()
            if running.activate(options: [.activateAllWindows]) {
                return
            }
        }
        let url = URL(fileURLWithPath: entry.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppLaunchError.notFound(entry.name)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            failure = error
            semaphore.signal()
        }
        semaphore.wait()
        if let failure {
            throw AppLaunchError.launchFailed(failure.localizedDescription)
        }
    }
}
```

`NSWorkspace.openApplication` 的回调可能不在主线程；`semaphore.wait()` 会阻塞调用线程，因此调用方必须在后台队列执行（SettingsStore/热键处理统一 dispatch 到后台）。

- [x] **Step 5: 运行测试确认通过**

Run: `swift test --package-path apps/macos --filter AppCatalogTests`
Expected: 3 passed。

- [ ] **Step 6: 提交（需用户授权）**

```bash
git add apps/macos/Sources/OlicoKit/AppCatalog.swift apps/macos/Sources/OlicoKit/AppLauncher.swift apps/macos/Tests/OlicoKitTests/AppCatalogTests.swift
git commit -m "feat(macos): scan installed apps and launch them"
```

---

### Task 5: 单实例与 LaunchAgent

**Files:**
- Create: `apps/macos/Sources/OlicoKit/SingleInstance.swift`
- Create: `apps/macos/Sources/OlicoKit/LaunchAgent.swift`
- Test: `apps/macos/Tests/OlicoKitTests/LaunchAgentTests.swift`

**Interfaces:**
- Produces: `SingleInstance.init(lockURL:)`、`acquire(retries:interval:) -> Bool`、`release()`；`LaunchAgent.init(plistURL:executablePath:)`、`plistContents()`、`install() throws`、`uninstall() throws`、`isEnabled() -> Bool`。

- [x] **Step 1: 写失败测试**

`LaunchAgentTests.swift`：

```swift
import XCTest
@testable import OlicoKit

final class LaunchAgentTests: XCTestCase {
    func testPlistContainsKeepAliveAndProgram() {
        let agent = LaunchAgent(
            plistURL: URL(fileURLWithPath: "/tmp/com.olico.app.plist"),
            executablePath: "/Applications/Olico.app/Contents/MacOS/Olico"
        )
        let plist = agent.plistContents()
        XCTAssertTrue(plist.contains("<string>com.olico.app</string>"))
        XCTAssertTrue(plist.contains("<string>/Applications/Olico.app/Contents/MacOS/Olico</string>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(plist.contains("<key>SuccessfulExit</key>"))
        XCTAssertTrue(plist.contains("<false/>"))
        XCTAssertTrue(plist.contains("<string>Aqua</string>"))
        XCTAssertTrue(plist.contains("<string>Interactive</string>"))
    }

    func testPlistEscapesSpecialCharacters() {
        let agent = LaunchAgent(
            plistURL: URL(fileURLWithPath: "/tmp/x.plist"),
            executablePath: "/tmp/A & B/Olico"
        )
        XCTAssertTrue(agent.plistContents().contains("A &amp; B"))
    }
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `swift test --package-path apps/macos --filter LaunchAgentTests`
Expected: 编译失败。

- [x] **Step 3: 实现 SingleInstance**

```swift
import Foundation

public final class SingleInstance {
    private let lockURL: URL
    private var descriptor: Int32 = -1

    public init(lockURL: URL) {
        self.lockURL = lockURL
    }

    deinit {
        release()
    }

    public func acquire(retries: Int = 20, interval: TimeInterval = 0.1) -> Bool {
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for attempt in 0...retries {
            let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 {
                descriptor = fd
                return true
            }
            if fd >= 0 { close(fd) }
            if attempt < retries {
                Thread.sleep(forTimeInterval: interval)
            }
        }
        return false
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
```

- [x] **Step 4: 实现 LaunchAgent**

```swift
import Foundation

public enum LaunchAgentStatus: String {
    case enabled, disabled, unknown
}

public struct LaunchAgent {
    public static let label = "com.olico.app"

    public let plistURL: URL
    public let executablePath: String

    public init(plistURL: URL, executablePath: String) {
        self.plistURL = plistURL
        self.executablePath = executablePath
    }

    public static func defaultPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public func plistContents() -> String {
        let escaped = executablePath
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(Self.label)</string>
          <key>ProgramArguments</key>
          <array><string>\(escaped)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key>
          <dict><key>SuccessfulExit</key><false/></dict>
          <key>LimitLoadToSessionType</key><string>Aqua</string>
          <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
    }

    public func install() throws {
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plistContents().write(to: plistURL, atomically: true, encoding: .utf8)
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
        let status = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        if status != 0 {
            throw NSError(domain: "Olico.LaunchAgent", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "launchctl bootstrap 失败（\(status)）",
            ])
        }
    }

    public func uninstall() throws {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    public func isEnabled() -> Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(Self.label)"]) == 0
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
```

- [x] **Step 5: 运行测试确认通过**

Run: `swift test --package-path apps/macos --filter LaunchAgentTests`
Expected: 2 passed。

- [ ] **Step 6: 提交（需用户授权）**

```bash
git add apps/macos/Sources/OlicoKit/SingleInstance.swift apps/macos/Sources/OlicoKit/LaunchAgent.swift apps/macos/Tests/OlicoKitTests/LaunchAgentTests.swift
git commit -m "feat(macos): add single instance lock and launch agent"
```

---

### Task 6: 日志与 GlobalHotkeyCenter

**Files:**
- Create: `apps/macos/Sources/OlicoKit/AppLogger.swift`
- Create: `apps/macos/Sources/Olico/GlobalHotkeyCenter.swift`
- Test: `apps/macos/Tests/OlicoKitTests/AppLoggerTests.swift`

**Interfaces:**
- Produces: `AppLogger.init(directory:maxBytes:maxFiles:)`、`log(_:)`；`HotkeySlot`、`GlobalHotkeyCenter.reload(config:) -> [String: String]`、`registeredCount`、`onAction`。
- `HotkeySlot` 同时供设置界面与 Carbon 路由使用。

- [x] **Step 1: 写失败测试**

`AppLoggerTests.swift`：

```swift
import XCTest
@testable import OlicoKit

final class AppLoggerTests: XCTestCase {
    func testRotationKeepsLimitedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logger = AppLogger(directory: dir, maxBytes: 120, maxFiles: 3)
        for index in 0..<20 {
            logger.log("line-\(index)-abcdefghijklmnop")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("olico.log") }
        XCTAssertLessThanOrEqual(files.count, 3)
        let current = try String(contentsOf: dir.appendingPathComponent("olico.log"), encoding: .utf8)
        XCTAssertTrue(current.contains("line-19"))
    }

    func testLogDoesNotCrashWithoutDirectory() {
        let logger = AppLogger(
            directory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"),
            maxBytes: 100,
            maxFiles: 2
        )
        logger.log("still safe")
    }
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `swift test --package-path apps/macos --filter AppLoggerTests`
Expected: 编译失败。

- [x] **Step 3: 实现 AppLogger**

```swift
import Foundation

public final class AppLogger {
    private let directory: URL
    private let maxBytes: Int
    private let maxFiles: Int
    private let queue = DispatchQueue(label: "com.olico.logger")

    public init(directory: URL, maxBytes: Int = 5 * 1024 * 1024, maxFiles: Int = 3) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func log(_ message: String) {
        queue.async { [self] in
            let formatter = ISO8601DateFormatter()
            let line = "\(formatter.string(from: Date())) \(message)\n"
            let current = directory.appendingPathComponent("olico.log")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded(current)
            if let handle = try? FileHandle(forWritingTo: current) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: current, atomically: true, encoding: .utf8)
            }
        }
    }

    private func rotateIfNeeded(_ current: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maxBytes else { return }
        let fm = FileManager.default
        if maxFiles > 1 {
            for index in stride(from: maxFiles - 1, through: 1, by: -1) {
                let source = directory.appendingPathComponent(index == 1 ? "olico.log" : "olico.log.\(index - 1)")
                let destination = directory.appendingPathComponent("olico.log.\(index)")
                if fm.fileExists(atPath: source.path) {
                    try? fm.removeItem(at: destination)
                    try? fm.moveItem(at: source, to: destination)
                }
            }
        } else {
            try? fm.removeItem(at: current)
        }
    }
}
```

- [x] **Step 4: 实现 GlobalHotkeyCenter**

```swift
import AppKit
import Carbon.HIToolbox
import OlicoKit

public enum HotkeySlot: String, CaseIterable, Identifiable {
    case screenshot, clipboard, colorPicker, togglePins
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .screenshot: return "截图"
        case .clipboard: return "剪贴板"
        case .colorPicker: return "取色"
        case .togglePins: return "隐藏/显示贴图"
        }
    }
}

public enum HotkeyAction: Equatable {
    case builtin(HotkeySlot)
    case app(target: String, path: String)
}

public final class GlobalHotkeyCenter {
    private let signature: OSType = 0x4F4C4943 // 'OLIC'
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: HotkeyAction] = [:]
    private let lock = NSLock()

    public var onAction: ((HotkeyAction) -> Void)?

    public init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr {
                    center.dispatch(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    deinit {
        unregisterAll()
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    public var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations.count
    }

    @discardableResult
    public func reload(config: AppConfig) -> [String: String] {
        unregisterAll()
        var failures: [String: String] = [:]
        var nextID: UInt32 = 1
        for slot in HotkeySlot.allCases {
            let hotkey = hotkey(for: slot, config: config)
            register(hotkey, action: .builtin(slot), id: nextID, label: slot.label, failures: &failures)
            nextID += 1
        }
        for shortcut in config.shortcuts where shortcut.enabled {
            register(
                shortcut.hotkey,
                action: .app(target: shortcut.target, path: shortcut.path),
                id: nextID,
                label: shortcut.target,
                failures: &failures
            )
            nextID += 1
        }
        return failures
    }

    private func hotkey(for slot: HotkeySlot, config: AppConfig) -> Hotkey {
        switch slot {
        case .screenshot: return config.hotkeys.screenshot
        case .clipboard: return config.hotkeys.clipboard
        case .colorPicker: return config.hotkeys.colorPicker
        case .togglePins: return config.hotkeys.togglePins
        }
    }

    private func register(
        _ hotkey: Hotkey,
        action: HotkeyAction,
        id: UInt32,
        label: String,
        failures: inout [String: String]
    ) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            carbonModifiers(hotkey.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            failures[label] = "注册失败（\(status)），可能被系统或其他应用占用"
            return
        }
        lock.lock()
        registrations[id] = ref
        actions[id] = action
        lock.unlock()
    }

    private func carbonModifiers(_ modifiers: [Modifier]) -> UInt32 {
        modifiers.reduce(0) { partial, modifier in
            switch modifier {
            case .cmd: return partial | UInt32(cmdKey)
            case .opt: return partial | UInt32(optionKey)
            case .ctrl: return partial | UInt32(controlKey)
            case .shift: return partial | UInt32(shiftKey)
            }
        }
    }

    private func dispatch(id: UInt32) {
        lock.lock()
        let action = actions[id]
        lock.unlock()
        guard let action else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onAction?(action)
        }
    }

    public func unregisterAll() {
        lock.lock()
        let refs = registrations.values
        registrations.removeAll()
        actions.removeAll()
        lock.unlock()
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
    }
}
```

- [x] **Step 5: 运行测试确认通过**

Run: `swift test --package-path apps/macos --filter AppLoggerTests`
Expected: 2 passed；`swift build --package-path apps/macos` 编译通过。

- [ ] **Step 6: 提交（需用户授权）**

```bash
git add apps/macos/Sources/OlicoKit/AppLogger.swift apps/macos/Sources/Olico/GlobalHotkeyCenter.swift apps/macos/Tests/OlicoKitTests/AppLoggerTests.swift
git commit -m "feat(macos): add logger and carbon hotkey center"
```

---

### Task 7: SettingsStore 与设置界面

**Files:**
- Create: `apps/macos/Sources/OlicoKit/SettingsStore.swift`
- Create: `apps/macos/Sources/Olico/SettingsWindowController.swift`
- Create: `apps/macos/Sources/Olico/SettingsView.swift`
- Create: `apps/macos/Sources/Olico/HotkeyRecorderView.swift`
- Modify: `apps/macos/Sources/Olico/AppDelegate.swift`
- Test: `apps/macos/Tests/OlicoKitTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces: `SettingsStore`（`config`、`apps`、`conflicts`、`launchAtLogin`、`setBuiltinHotkey`、`setShortcut`、`removeShortcut`、`saveConfig`、`reloadApps`）；`SettingsWindowController.show()`。
- `SettingsStore` 依赖 `CoreClient`、`AppCatalog`、`GlobalHotkeyCenter` 由 AppDelegate 注入。

- [x] **Step 1: 写失败测试**

`SettingsStoreTests.swift`：

```swift
import XCTest
@testable import OlicoKit

final class SettingsStoreTests: XCTestCase {
    private func makeStore() throws -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = try CoreClient(dataDir: dir)
        let catalog = AppCatalog(roots: [], maxDepth: 1, ttl: 60)
        return SettingsStore(client: client, catalog: catalog)
    }

    func testSetBuiltinHotkeyPersists() throws {
        let store = try makeStore()
        try store.setBuiltinHotkey(.screenshot, Hotkey(keyCode: 2, modifiers: [.opt, .shift]))
        XCTAssertEqual(store.config.hotkeys.screenshot.keyCode, 2)
        XCTAssertEqual(store.persistedConfig().hotkeys.screenshot.keyCode, 2)
    }

    func testSetBuiltinHotkeyRejectsConflict() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.setBuiltinHotkey(.colorPicker, store.config.hotkeys.screenshot)) { error in
            XCTAssertEqual((error as? HotkeyValidationError), .conflicts("截图"))
        }
    }

    func testSetAndRemoveShortcut() throws {
        let store = try makeStore()
        let app = AppEntry(bundleID: "com.example.a", name: "Alpha", path: "/Applications/Alpha.app")
        try store.setShortcut(app: app, hotkey: Hotkey(keyCode: 3, modifiers: [.opt]))
        XCTAssertEqual(store.shortcut(for: "com.example.a")?.keyCode, 3)
        try store.removeShortcut(bundleID: "com.example.a")
        XCTAssertNil(store.shortcut(for: "com.example.a"))
    }

    func testShortcutConflictWithBuiltin() throws {
        let store = try makeStore()
        let app = AppEntry(bundleID: "com.example.a", name: "Alpha", path: "/Applications/Alpha.app")
        XCTAssertThrowsError(try store.setShortcut(app: app, hotkey: store.config.hotkeys.clipboard)) { error in
            XCTAssertEqual((error as? HotkeyValidationError), .conflicts("剪贴板"))
        }
    }
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `swift test --package-path apps/macos --filter SettingsStoreTests`
Expected: 编译失败。

- [x] **Step 3: 实现 SettingsStore**

```swift
import Foundation
import Combine

public final class SettingsStore: ObservableObject {
    @Published public private(set) var config: AppConfig
    @Published public private(set) var apps: [AppEntry] = []
    @Published public private(set) var conflicts: [String: String] = [:]
    @Published public var searchText = ""
    @Published public var onlyConfigured = false
    @Published public private(set) var lastError: String?

    public let launchAtLoginEnabled: Bool
    private let client: CoreClient
    private let catalog: AppCatalog
    private let onConfigChanged: ((AppConfig) -> [String: String])?

    public init(
        client: CoreClient,
        catalog: AppCatalog,
        onConfigChanged: ((AppConfig) -> [String: String])? = nil
    ) throws {
        self.client = client
        self.catalog = catalog
        self.onConfigChanged = onConfigChanged
        self.config = try client.config()
        self.launchAtLoginEnabled = config.residency.launchAtLogin
    }

    public func persistedConfig() -> AppConfig {
        (try? client.config()) ?? config
    }

    public func reloadApps() {
        apps = catalog.scan(force: true)
    }

    public func filteredApps() -> [AppEntry] {
        var result = apps
        if onlyConfigured {
            result = result.filter { shortcut(for: $0.bundleID) != nil }
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            result = result.filter {
                $0.name.lowercased().contains(needle) || $0.bundleID.lowercased().contains(needle)
            }
        }
        return result
    }

    public func shortcut(for bundleID: String) -> AppShortcut? {
        config.shortcuts.first { $0.target == bundleID }
    }

    public func setBuiltinHotkey(_ slot: HotkeySlot, _ hotkey: Hotkey) throws {
        var existing: [(String, Hotkey)] = []
        let labels: [(HotkeySlot, String, Hotkey)] = [
            (.screenshot, "截图", config.hotkeys.screenshot),
            (.clipboard, "剪贴板", config.hotkeys.clipboard),
            (.colorPicker, "取色", config.hotkeys.colorPicker),
            (.togglePins, "隐藏/显示贴图", config.hotkeys.togglePins),
        ]
        for (current, label, value) in labels where current != slot {
            existing.append((label, value))
        }
        for shortcut in config.shortcuts where shortcut.enabled {
            existing.append((shortcut.target, shortcut.hotkey))
        }
        if let error = HotkeyValidator.validate(hotkey: hotkey, conflictsWith: existing) {
            throw error
        }
        switch slot {
        case .screenshot: config.hotkeys.screenshot = hotkey
        case .clipboard: config.hotkeys.clipboard = hotkey
        case .colorPicker: config.hotkeys.colorPicker = hotkey
        case .togglePins: config.hotkeys.togglePins = hotkey
        }
        try saveConfig()
    }

    public func setShortcut(app: AppEntry, hotkey: Hotkey) throws {
        var existing: [(String, Hotkey)] = [
            ("截图", config.hotkeys.screenshot),
            ("剪贴板", config.hotkeys.clipboard),
            ("取色", config.hotkeys.colorPicker),
            ("隐藏/显示贴图", config.hotkeys.togglePins),
        ]
        for shortcut in config.shortcuts where shortcut.enabled && shortcut.target != app.bundleID {
            existing.append((shortcut.target, shortcut.hotkey))
        }
        if let error = HotkeyValidator.validate(hotkey: hotkey, conflictsWith: existing) {
            throw error
        }
        let updated = AppShortcut(
            target: app.bundleID,
            path: app.path,
            keyCode: hotkey.keyCode,
            modifiers: hotkey.modifiers,
            enabled: true
        )
        if let index = config.shortcuts.firstIndex(where: { $0.target == app.bundleID }) {
            config.shortcuts[index] = updated
        } else {
            config.shortcuts.append(updated)
        }
        try saveConfig()
    }

    public func removeShortcut(bundleID: String) throws {
        config.shortcuts.removeAll { $0.target == bundleID }
        try saveConfig()
    }

    public func saveConfig() throws {
        do {
            try client.setConfig(config)
            conflicts = onConfigChanged?(config) ?? [:]
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}
```

- [x] **Step 4: 实现热键录制视图**

`HotkeyRecorderView.swift`：

```swift
import SwiftUI
import AppKit
import OlicoKit

struct HotkeyRecorderView: View {
    let title: String
    let onCapture: (Hotkey) -> Void
    let onCancel: () -> Void

    @State private var captured: Hotkey?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text(captured.map(HotkeyFormatter.display) ?? "按下新的快捷键")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Text("Esc 取消").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let captured { onCapture(captured) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(captured == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(KeyCaptureView { hotkey in
            captured = hotkey
            errorText = nil
        } onCancel: {
            onCancel()
        })
    }
}

private struct KeyCaptureView: NSViewRepresentable {
    let onCapture: (Hotkey) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {}
}

private final class KeyCaptureNSView: NSView {
    var onCapture: ((Hotkey) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [Modifier] = []
        if flags.contains(.command) { modifiers.append(.cmd) }
        if flags.contains(.option) { modifiers.append(.opt) }
        if flags.contains(.control) { modifiers.append(.ctrl) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        onCapture?(Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }

    override func flagsChanged(with event: NSEvent) {}
}
```

- [x] **Step 5: 实现设置窗口与四个标签页**

`SettingsWindowController.swift`：

```swift
import AppKit
import SwiftUI
import OlicoKit

final class SettingsWindowController {
    private var window: NSWindow?
    private let store: SettingsStore
    private let launchAgent: LaunchAgent
    private let logger: AppLogger

    init(store: SettingsStore, launchAgent: LaunchAgent, logger: AppLogger) {
        self.store = store
        self.launchAgent = launchAgent
        self.logger = logger
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(store: store, launchAgent: launchAgent, logger: logger)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "Olico 设置"
            window.setContentSize(NSSize(width: 920, height: 640))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

`SettingsView.swift` 必须包含：

- `TabView`，四个标签：应用、剪贴板、截图、通用。
- 应用页：`已设置快捷键` 概览（横向胶囊）、搜索框、`仅显示已设置` 开关、刷新按钮；列表行显示图标（`NSWorkspace.shared.icon(forFile:)`）、名称、Bundle ID、`HotkeyFormatter.display`、`录制`/`清除`；点击录制裁开 `HotkeyRecorderView` sheet。
- 通用页：四个内置热键行（同样 sheet 录制）；`登录自启` Toggle；守护状态文案；辅助功能/屏幕录制状态与“打开系统设置”按钮；`打开日志目录`；版本号。
- 剪贴板页：启用、`maxItems`、`retentionDays`、`maxImageMb`、`maxTextKb`、排除应用（逗号分隔）；`清空历史` 二次确认调用 `client.clipboardClear()`（通过 store 新增 `clearClipboard()`）。
- 截图页：保存目录文本框 + 选择按钮（`NSOpenPanel`）、颜色格式 Picker、恢复贴图 Toggle。
- 保存反馈：`store.lastError` 显示红色横幅；热键冲突显示在 sheet 内。

`SettingsStore` 需补充：

```swift
public func clearClipboard() {
    do { try client.clipboardClear(); lastError = nil } catch { lastError = error.localizedDescription }
}

public func setLaunchAtLogin(_ enabled: Bool, agent: LaunchAgent) throws {
    if enabled { try agent.install() } else { try agent.uninstall() }
    config.residency.launchAtLogin = enabled
    try saveConfig()
}
```

`AppDelegate` 装配：

```swift
private var store: SettingsStore?
private var settingsWindow: SettingsWindowController?
private var hotkeyCenter: GlobalHotkeyCenter?
private var launchAgent: LaunchAgent?
private var logger: AppLogger?
private var singleInstance: SingleInstance?

func applicationDidFinishLaunching(_ notification: Notification) {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Olico")
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    logger = AppLogger(directory: support.appendingPathComponent("logs"))
    singleInstance = SingleInstance(lockURL: support.appendingPathComponent("instance.lock"))
    guard singleInstance?.acquire() == true else {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.olico.activate"), object: nil, userInfo: nil, deliverImmediately: true
        )
        NSApp.terminate(nil)
        return
    }
    do {
        let client = try CoreClient(dataDir: support)
        let center = GlobalHotkeyCenter()
        let catalog = AppCatalog()
        let agent = LaunchAgent(
            plistURL: LaunchAgent.defaultPlistURL(),
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0]
        )
        let store = try SettingsStore(client: client, catalog: catalog) { config in
            center.reload(config: config)
        }
        store.reloadApps()
        center.onAction = { action in
            switch action {
            case .builtin(.screenshot), .builtin(.clipboard), .builtin(.colorPicker), .builtin(.togglePins):
                break
            case .app(let target, let path):
                let entry = AppEntry(bundleID: target, name: target, path: path)
                DispatchQueue.global(qos: .userInitiated).async {
                    try? AppLauncher.activateOrLaunch(entry)
                }
            }
        }
        store.conflicts = center.reload(config: store.config)
        self.store = store
        self.hotkeyCenter = center
        self.launchAgent = agent
        self.settingsWindow = SettingsWindowController(store: store, launchAgent: agent, logger: logger!)
        statusItemController = StatusItemController(onSettings: { [weak self] in self?.showSettings() }, onQuit: { NSApp.terminate(nil) })
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.olico.activate"), object: nil, queue: .main
        ) { [weak self] _ in self?.showSettings() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let store = self.store else { return }
            self.hotkeyCenter?.reload(config: store.config)
            store.reloadApps()
        }
        if CommandLine.arguments.contains("--settings") { showSettings() }
        logger?.log("Olico started")
    } catch {
        logger?.log("startup failed: \(error.localizedDescription)")
        statusItemController = StatusItemController(onSettings: {}, onQuit: { NSApp.terminate(nil) })
    }
}

func showSettings() {
    settingsWindow?.show()
}
```

`SettingsStore.conflicts` 是 `private(set)`，AppDelegate 需通过 `store.conflicts = ...` 赋值；改为 `@Published public var conflicts`。

- [x] **Step 6: 运行测试与构建**

Run:

```bash
swift test --package-path apps/macos --filter SettingsStoreTests
swift build --package-path apps/macos
```

Expected: 4 passed；构建通过。

- [x] **Step 7: 手工验证**

```bash
./scripts/build-macos.sh
open build/Olico.app --args --settings
```

检查：设置窗口打开；应用页列出本机应用；给一个应用录制快捷键；关闭并重开应用后快捷键仍在；按快捷键能切换应用。若无法自动验证 UI，记录未覆盖项。

- [ ] **Step 8: 提交（需用户授权）**

```bash
git add apps/macos/Sources apps/macos/Tests
git commit -m "feat(macos): add settings store and configuration ui"
```

---

### Task 8: 健康自检、恢复与最终门禁

**Files:**
- Modify: `apps/macos/Sources/Olico/AppDelegate.swift`
- Modify: `scripts/build-macos.sh`
- Modify: `docs/superpowers/specs/2026-11-10-olico-design.md`

**Interfaces:**
- Produces: 30 秒健康自检；唤醒恢复；`scripts/build-macos.sh` 支持 `--universal`。

- [x] **Step 1: 健康自检与唤醒**

在 `AppDelegate` 增加：

```swift
private var healthTimer: Timer?

private func startHealthCheck() {
    healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
        guard let self, let store = self.store else { return }
        let expected = HotkeySlot.allCases.count + store.config.shortcuts.filter(\.enabled).count
        if self.hotkeyCenter?.registeredCount != expected {
            self.logger?.log("health: hotkey count mismatch, reloading")
            self.hotkeyCenter?.reload(config: store.config)
        }
        _ = try? store.persistedConfig()
    }
}
```

- [x] **Step 2: 构建脚本支持双架构**

在 `scripts/build-macos.sh` 增加：

```bash
if [[ "${1:-}" == "--universal" ]]; then
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  cargo build --release -p olico-ffi --target aarch64-apple-darwin
  cargo build --release -p olico-ffi --target x86_64-apple-darwin
  lipo -create \
    "$ROOT/target/aarch64-apple-darwin/release/libolico_ffi.a" \
    "$ROOT/target/x86_64-apple-darwin/release/libolico_ffi.a" \
    -output "$ROOT/apps/macos/Vendor/libolico_ffi.a"
  swift build --package-path "$ROOT/apps/macos" -c release --arch arm64 --arch x86_64
  BINARY="$(swift build --package-path "$ROOT/apps/macos" -c release --arch arm64 --arch x86_64 --show-bin-path)/Olico"
else
  swift build --package-path "$ROOT/apps/macos" -c release
  BINARY="$(swift build --package-path "$ROOT/apps/macos" -c release --show-bin-path)/Olico"
fi
```

并把 `cp` 改为使用 `$BINARY`。Swift 6.4 工具链下 xcode 构建产物路径为 `.build/out/Products/Release/Olico`，用 `--show-bin-path` 获取可避免硬编码。

- [x] **Step 3: 全量验证**

Run:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
swift test --package-path apps/macos
./scripts/build-macos.sh
open build/Olico.app
sleep 2
pgrep -fl "Olico.app/Contents/MacOS/Olico"
```

Expected: Rust 51 测试通过；Swift 测试全绿；应用进程存在。

- [x] **Step 4: 手工验收**

- 菜单栏图标存在，无 Dock 图标。
- 设置窗口可打开（`--settings`）。
- 录制应用快捷键后，冷启动/已运行均可切换。
- 开启登录自启后 LaunchAgent plist 存在且 `launchctl print` 成功；关闭后移除。
- `kill -9` 后 10 秒内被拉起（若已开启 LaunchAgent）。
- 正常退出不被拉起。
- 合盖唤醒后热键仍可用。

验收记录（2026-11-10）：菜单栏常驻与 `--settings` 打开、应用快捷键（QQ ⌥Q / WeChat ⌥X）冷/热切换、LaunchAgent 安装与 `launchctl print`、`kill -9` 后 3 秒拉起、正常退出（exit 0）不被拉起均已实测；睡眠唤醒路径已在代码中处理（`didWakeNotification` 重载热键与刷新应用目录），未在本机实际合盖验证。测试过程中录制的应用快捷键与临时调试代码已清理。

- [ ] **Step 5: 提交（需用户授权）**

```bash
git add apps/macos scripts/build-macos.sh docs/superpowers/specs/2026-11-10-olico-design.md
git commit -m "feat(macos): health checks and universal build"
```

---

## 自审记录

- **Spec 覆盖**：§6 应用热键（注册、执行、设置页、冲突）、§9 常驻（单实例、LaunchAgent、唤醒）、§10 设置窗口四个标签、§12 构建（SPM 修订）、§13 自动化与手工验收均已落到任务。剪贴板面板与截图/贴图/取色属于后续计划。
- **占位符**：无 TBD；设置页文本控件、权限状态与清空历史在 Task 7 明确接口。
- **类型一致性**：`Hotkey`、`AppShortcut`、`AppConfig`、`HotkeySlot`、`GlobalHotkeyCenter.reload`、`SettingsStore` 方法在任务间一致；Rust JSON 使用 snake_case 自动转换。
- **风险**：Carbon 回调与 Swift 闭包生命周期、`NSWorkspace.openApplication` 信号量阻塞、LaunchAgent 交接顺序需要运行时验证；若 SPM 双架构产物路径变化，以 `swift build -v` 输出为准，不改变接口。
