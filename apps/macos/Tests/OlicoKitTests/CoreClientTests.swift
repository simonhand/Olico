import XCTest
@testable import OlicoKit

final class CoreClientTests: XCTestCase {
    private func makeClient() throws -> CoreClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try CoreClient(dataDir: dir)
    }

    func testConfigDefaultsRoundTrip() throws {
        let client = try makeClient()
        let config = try client.config()
        XCTAssertEqual(config.version, 2)
        XCTAssertEqual(config.hotkeys.clipboard.keyCode, 9)
        XCTAssertEqual(config.hotkeys.clipboard.modifiers, [.cmd, .shift])
    }

    func testConfigSetPersists() throws {
        let client = try makeClient()
        var config = try client.config()
        config.clipboard.maxItems = 11
        try client.setConfig(config)
        XCTAssertEqual(try client.config().clipboard.maxItems, 11)
    }

    func testErrorResponseThrowsWithCode() throws {
        let client = try makeClient()
        XCTAssertThrowsError(try client.call("nope", payload: [:])) { error in
            XCTAssertEqual((error as? CoreError)?.code, "unknown_op")
        }
    }

    func testClipboardRoundTrip() throws {
        let client = try makeClient()
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
