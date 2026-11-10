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

    func testSaveLinkNormalizesAndPersists() throws {
        let store = try makeStore()
        let link = try store.saveLink(
            id: nil,
            title: "  文档  ",
            url: "example.com/docs",
            hotkey: Hotkey(keyCode: 12, modifiers: [.opt])
        )
        XCTAssertEqual(link.title, "文档")
        XCTAssertEqual(link.url, "https://example.com/docs")
        XCTAssertEqual(store.link(for: link.id)?.keyCode, 12)
        XCTAssertEqual(store.persistedConfig().links, [link])
    }

    func testUpdateLinkKeepsItsOwnHotkey() throws {
        let store = try makeStore()
        let first = try store.saveLink(
            id: nil,
            title: "A",
            url: "https://a.example",
            hotkey: Hotkey(keyCode: 12, modifiers: [.opt])
        )
        _ = try store.saveLink(
            id: nil,
            title: "B",
            url: "https://b.example",
            hotkey: Hotkey(keyCode: 13, modifiers: [.opt])
        )
        let updated = try store.saveLink(
            id: first.id,
            title: "A2",
            url: "https://a.example/new",
            hotkey: Hotkey(keyCode: 12, modifiers: [.opt])
        )
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(store.config.links.count, 2)
        XCTAssertEqual(store.link(for: first.id)?.title, "A2")
    }

    func testRemoveLink() throws {
        let store = try makeStore()
        let link = try store.saveLink(
            id: nil,
            title: "A",
            url: "https://a.example",
            hotkey: Hotkey(keyCode: 12, modifiers: [.opt])
        )
        try store.removeLink(id: link.id)
        XCTAssertNil(store.link(for: link.id))
        XCTAssertTrue(store.persistedConfig().links.isEmpty)
    }

    func testLinkConflictWithBuiltin() throws {
        let store = try makeStore()
        XCTAssertThrowsError(
            try store.saveLink(id: nil, title: "A", url: "https://a.example", hotkey: store.config.hotkeys.clipboard)
        ) { error in
            XCTAssertEqual(error as? LinkValidationError, .invalidHotkey(.conflicts("剪贴板")))
        }
    }

    func testLinkConflictWithAnotherLink() throws {
        let store = try makeStore()
        _ = try store.saveLink(
            id: nil,
            title: "A",
            url: "https://a.example",
            hotkey: Hotkey(keyCode: 12, modifiers: [.opt])
        )
        XCTAssertThrowsError(
            try store.saveLink(
                id: nil,
                title: "B",
                url: "https://b.example",
                hotkey: Hotkey(keyCode: 12, modifiers: [.opt])
            )
        ) { error in
            XCTAssertEqual(error as? LinkValidationError, .invalidHotkey(.conflicts("A")))
        }
    }

    func testBuiltinHotkeyConflictsWithLink() throws {
        let store = try makeStore()
        _ = try store.saveLink(
            id: nil,
            title: "A",
            url: "https://a.example",
            hotkey: Hotkey(keyCode: 12, modifiers: [.opt])
        )
        XCTAssertThrowsError(
            try store.setBuiltinHotkey(.screenshot, Hotkey(keyCode: 12, modifiers: [.opt]))
        ) { error in
            XCTAssertEqual(error as? HotkeyValidationError, .conflicts("A"))
        }
    }

    func testLinkRequiresTitleAndHTTPURL() throws {
        let store = try makeStore()
        let hotkey = Hotkey(keyCode: 12, modifiers: [.opt])
        XCTAssertThrowsError(try store.saveLink(id: nil, title: "  ", url: "https://a.example", hotkey: hotkey)) { error in
            XCTAssertEqual(error as? LinkValidationError, .emptyTitle)
        }
        XCTAssertThrowsError(try store.saveLink(id: nil, title: "A", url: "ftp://a.example", hotkey: hotkey)) { error in
            XCTAssertEqual(error as? LinkValidationError, .invalidURL)
        }
    }
}
