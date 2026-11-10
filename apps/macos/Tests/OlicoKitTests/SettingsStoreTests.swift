import XCTest
@testable import OlicoKit

final class SettingsStoreTests: XCTestCase {
    private func makeStore() throws -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = try CoreClient(dataDir: dir)
        let catalog = AppCatalog(roots: [], maxDepth: 1, ttl: 60)
        return try SettingsStore(client: client, catalog: catalog)
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
