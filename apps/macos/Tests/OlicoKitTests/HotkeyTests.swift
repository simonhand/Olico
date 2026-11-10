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
