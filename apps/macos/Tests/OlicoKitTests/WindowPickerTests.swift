import CoreGraphics
import XCTest
@testable import OlicoKit

final class WindowPickerTests: XCTestCase {
    private func window(
        id: UInt32,
        frame: CGRect,
        layer: Int = 0,
        pid: pid_t = 100,
        alpha: Double = 1
    ) -> WindowCandidate {
        WindowCandidate(id: id, frame: frame, layer: layer, ownerPID: pid, alpha: alpha)
    }

    func testPicksFrontmostWindowContainingPoint() {
        let windows = [
            window(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
            window(id: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
        ]
        XCTAssertEqual(
            WindowPicker.pick(at: CGPoint(x: 50, y: 50), from: windows, excludingPID: 999)?.id,
            1
        )
    }

    func testSkipsExcludedPID() {
        let windows = [
            window(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 200), pid: 777),
            window(id: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
        ]
        XCTAssertEqual(
            WindowPicker.pick(at: CGPoint(x: 50, y: 50), from: windows, excludingPID: 777)?.id,
            2
        )
    }

    func testSkipsNonZeroLayer() {
        let windows = [
            window(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 400), layer: 25),
        ]
        XCTAssertNil(WindowPicker.pick(at: CGPoint(x: 50, y: 50), from: windows, excludingPID: 999))
    }

    func testSkipsTransparentWindow() {
        let windows = [
            window(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 400), alpha: 0),
        ]
        XCTAssertNil(WindowPicker.pick(at: CGPoint(x: 50, y: 50), from: windows, excludingPID: 999))
    }

    func testSkipsEmptyWindow() {
        let windows = [
            window(id: 1, frame: CGRect(x: 0, y: 0, width: 0, height: 400)),
        ]
        XCTAssertNil(WindowPicker.pick(at: CGPoint(x: 0, y: 50), from: windows, excludingPID: 999))
    }

    func testReturnsNilWhenNoWindowContainsPoint() {
        let windows = [
            window(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
        ]
        XCTAssertNil(WindowPicker.pick(at: CGPoint(x: 150, y: 50), from: windows, excludingPID: 999))
    }
}
