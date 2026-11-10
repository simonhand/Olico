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
        XCTAssertTrue(plist.contains("<string>--login-item</string>"))
    }

    func testPlistEscapesSpecialCharacters() {
        let agent = LaunchAgent(
            plistURL: URL(fileURLWithPath: "/tmp/x.plist"),
            executablePath: "/tmp/A & B/Olico"
        )
        XCTAssertTrue(agent.plistContents().contains("A &amp; B"))
    }

    func testSingleInstanceExcludesSecondAcquirer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockURL = dir.appendingPathComponent("instance.lock")

        let first = SingleInstance(lockURL: lockURL)
        XCTAssertTrue(first.acquire(retries: 0))
        let second = SingleInstance(lockURL: lockURL)
        XCTAssertFalse(second.acquire(retries: 0))
        first.release()
        XCTAssertTrue(second.acquire(retries: 0))
        second.release()
    }
}
