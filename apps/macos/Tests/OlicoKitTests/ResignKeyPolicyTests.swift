import XCTest
@testable import OlicoKit

final class ResignKeyPolicyTests: XCTestCase {
    func testRekeysWithinAttemptBudgetThenCancels() {
        var policy = ResignKeyPolicy(maxAttempts: 3, retryDelay: 0.5)
        XCTAssertEqual(policy.nextAction(), .rekey(0.5))
        XCTAssertEqual(policy.nextAction(), .rekey(0.5))
        XCTAssertEqual(policy.nextAction(), .rekey(0.5))
        XCTAssertEqual(policy.nextAction(), .cancel)
    }

    func testFreshPolicyStartsAtZeroAttempts() {
        let policy = ResignKeyPolicy(maxAttempts: 2, retryDelay: 0.25)
        XCTAssertEqual(policy.attempts, 0)
    }

    func testZeroAttemptsCancelsImmediately() {
        var policy = ResignKeyPolicy(maxAttempts: 0, retryDelay: 0.5)
        XCTAssertEqual(policy.nextAction(), .cancel)
    }
}
