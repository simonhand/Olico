import XCTest
@testable import OlicoKit

final class AppLoggerTests: XCTestCase {
    private func waitForFile(_ url: URL, containing needle: String, timeout: TimeInterval = 2) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(needle) {
                return text
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    func testRotationKeepsLimitedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logger = AppLogger(directory: dir, maxBytes: 120, maxFiles: 3)
        for index in 0..<20 {
            logger.log("line-\(index)-abcdefghijklmnop")
        }
        let current = try XCTUnwrap(
            waitForFile(dir.appendingPathComponent("olico.log"), containing: "line-19")
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("olico.log") }
        XCTAssertLessThanOrEqual(files.count, 3)
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
