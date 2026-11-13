import XCTest
@testable import CoreModels

final class TimestampsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.123)

    func testNextUpdateBeatsPreviousEvenWhenClockIsBehind() {
        let previous = now.addingTimeInterval(300)
        XCTAssertGreaterThan(Timestamps.nextUpdate(previous: previous, now: now), previous)
    }

    func testNextUpdateUsesNowWhenAhead() {
        let previous = now.addingTimeInterval(-60)
        XCTAssertEqual(Timestamps.nextUpdate(previous: previous, now: now), now)
    }

    func testNextUpdateIsWholeMilliseconds() {
        let fractionalNow = Date(timeIntervalSince1970: 1_800_000_000.1236)
        let results = [
            Timestamps.nextUpdate(previous: nil, now: fractionalNow),
            Timestamps.nextUpdate(previous: fractionalNow.addingTimeInterval(300), now: fractionalNow),
            Timestamps.nextUpdate(previous: fractionalNow.addingTimeInterval(-60), now: fractionalNow),
        ]
        for result in results {
            let ms = result.timeIntervalSince1970 * 1000
            XCTAssertEqual(ms - ms.rounded(.down), 0)
        }
        let previous = fractionalNow.addingTimeInterval(300)
        XCTAssertGreaterThan(Timestamps.nextUpdate(previous: previous, now: fractionalNow), previous)
    }
}
