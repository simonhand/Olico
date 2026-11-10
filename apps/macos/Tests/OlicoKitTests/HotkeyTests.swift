import AppKit
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

    func testKeyNameExcludesModifiers() {
        XCTAssertEqual(HotkeyFormatter.keyName(for: 1), "S")
        XCTAssertEqual(HotkeyFormatter.keyName(for: 49), "Space")
        XCTAssertEqual(HotkeyFormatter.keyName(for: 999), "Key999")
    }

    func testModifierSymbols() {
        XCTAssertEqual(HotkeyFormatter.symbol(for: .cmd), "⌘")
        XCTAssertEqual(HotkeyFormatter.symbol(for: .opt), "⌥")
        XCTAssertEqual(HotkeyFormatter.symbol(for: .ctrl), "⌃")
        XCTAssertEqual(HotkeyFormatter.symbol(for: .shift), "⇧")
    }

    func testBareKeyIsRejected() {        let error = HotkeyValidator.validate(
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

    func testCaptureRecordsThreeKeyChord() {
        let hotkey = HotkeyCapture.hotkey(keyCode: 9, flags: [.command, .shift])
        XCTAssertEqual(hotkey, Hotkey(keyCode: 9, modifiers: [.cmd, .shift]))
        XCTAssertEqual(hotkey.map(HotkeyFormatter.display), "⌘⇧V")
        XCTAssertNil(hotkey.flatMap {
            HotkeyValidator.validate(hotkey: $0, conflictsWith: [])
        })
    }

    func testCaptureRecordsAllFourModifiers() {
        let hotkey = HotkeyCapture.hotkey(
            keyCode: 0,
            flags: [.command, .option, .control, .shift]
        )
        XCTAssertEqual(hotkey?.modifiers, [.cmd, .opt, .ctrl, .shift])
    }

    func testCaptureMapsFunctionKeyWithoutModifiers() {
        let hotkey = HotkeyCapture.hotkey(keyCode: 122, flags: [])
        XCTAssertEqual(hotkey, Hotkey(keyCode: 122, modifiers: []))
        XCTAssertNil(hotkey.flatMap {
            HotkeyValidator.validate(hotkey: $0, conflictsWith: [])
        })
    }

    func testEscapeIsNotCaptured() {
        XCTAssertNil(HotkeyCapture.hotkey(keyCode: HotkeyCapture.cancelKeyCode, flags: []))
    }

    func testCaptureIgnoresCapsLockAndNumericPad() {
        let hotkey = HotkeyCapture.hotkey(keyCode: 9, flags: [.command, .capsLock, .numericPad])
        XCTAssertEqual(hotkey?.modifiers, [.cmd])
    }
}
