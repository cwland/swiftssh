import XCTest
@testable import SyncCore

final class MergeRuleTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    func testNewerTimestampWins() {
        XCTAssertTrue(MergeRule.incomingWins((t.addingTimeInterval(1), "mac-a"), over: (t, "mac-z")))
    }

    func testOlderTimestampLoses() {
        XCTAssertFalse(MergeRule.incomingWins((t, "mac-z"), over: (t.addingTimeInterval(1), "mac-a")))
    }

    func testTieBrokenByLargerDeviceID() {
        XCTAssertTrue(MergeRule.incomingWins((t, "mac-b"), over: (t, "mac-a")))
        XCTAssertFalse(MergeRule.incomingWins((t, "mac-a"), over: (t, "mac-b")))
    }

    func testIdenticalRecordDoesNotWin() {
        XCTAssertFalse(MergeRule.incomingWins((t, "mac-a"), over: (t, "mac-a")))
    }
}
