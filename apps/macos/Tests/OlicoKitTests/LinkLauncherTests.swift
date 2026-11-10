import XCTest
@testable import OlicoKit

final class LinkLauncherTests: XCTestCase {
    func testNormalizeAddsMissingScheme() {
        XCTAssertEqual(
            LinkLauncher.normalizedURL("example.com/docs")?.absoluteString,
            "https://example.com/docs"
        )
    }

    func testNormalizeKeepsExplicitHttpSchemes() {
        XCTAssertEqual(
            LinkLauncher.normalizedURL("http://example.com")?.absoluteString,
            "http://example.com"
        )
        XCTAssertEqual(
            LinkLauncher.normalizedURL("  https://example.com/a?b=1  ")?.absoluteString,
            "https://example.com/a?b=1"
        )
    }

    func testNormalizeRejectsEmptyAndNonHttp() {
        XCTAssertNil(LinkLauncher.normalizedURL(""))
        XCTAssertNil(LinkLauncher.normalizedURL("   "))
        XCTAssertNil(LinkLauncher.normalizedURL("ftp://example.com"))
        XCTAssertNil(LinkLauncher.normalizedURL("file:///etc/passwd"))
        XCTAssertNil(LinkLauncher.normalizedURL("javascript:alert(1)"))
    }
}
