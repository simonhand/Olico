import XCTest
@testable import OlicoKit

final class ConfigTransferTests: XCTestCase {
    private func sampleConfig() -> AppConfig {
        AppConfig(
            version: 2,
            hotkeys: HotkeySet(
                screenshot: Hotkey(keyCode: 1, modifiers: [.opt, .shift]),
                clipboard: Hotkey(keyCode: 9, modifiers: [.cmd, .shift]),
                colorPicker: Hotkey(keyCode: 8, modifiers: [.opt, .shift]),
                togglePins: Hotkey(keyCode: 4, modifiers: [.opt, .shift])
            ),
            shortcuts: [
                AppShortcut(
                    target: "com.tencent.qq",
                    path: "/Applications/QQ.app",
                    keyCode: 12,
                    modifiers: [.opt],
                    enabled: true
                ),
            ],
            clipboard: ClipboardOptions(
                enabled: true,
                maxItems: 500,
                retentionDays: 30,
                maxImageMb: 50,
                maxTextKb: 512,
                excludedApps: ["com.agilebits.onepassword7"]
            ),
            screenshot: ScreenshotOptions(
                saveDir: "~/Pictures/Olico",
                colorFormat: .hex,
                restorePins: true
            ),
            residency: ResidencyOptions(launchAtLogin: true)
        )
    }

    func testExportImportRoundTripPreservesConfig() throws {
        let config = sampleConfig()
        let data = try ConfigTransfer.encode(config)
        let restored = try ConfigTransfer.decode(data)
        XCTAssertEqual(restored, config)
    }

    func testDecodeRejectsUnsupportedVersion() throws {
        var config = sampleConfig()
        config.version = 1
        let data = try ConfigTransfer.encode(config)
        XCTAssertThrowsError(try ConfigTransfer.decode(data)) { error in
            XCTAssertEqual(error as? ConfigTransferError, .unsupportedVersion(1))
        }
    }

    func testDecodeRejectsConflictingHotkeys() throws {
        var config = sampleConfig()
        config.hotkeys.clipboard = config.hotkeys.screenshot
        let data = try ConfigTransfer.encode(config)
        XCTAssertThrowsError(try ConfigTransfer.decode(data)) { error in
            guard case .invalidHotkey(let label, let reason)? = error as? ConfigTransferError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(label, "剪贴板")
            XCTAssertEqual(reason, .conflicts("截图"))
        }
    }

    func testDecodeRejectsMalformedJSON() {
        let data = Data("{ not json".utf8)
        XCTAssertThrowsError(try ConfigTransfer.decode(data)) { error in
            XCTAssertEqual(error as? ConfigTransferError, .decodeFailed)
        }
    }
}
