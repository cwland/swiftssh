import XCTest
@testable import AppCore

/// iPhone/iPad: when the open sessions are checked (and dropped ones reconnected) after the app comes
/// back from the background or the network changes.
@MainActor
final class ConnectionRecheckTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSinceReferenceDate: 10_000)
    }

    private var clock: Clock!
    private var checks = 0
    private var recheck: ConnectionRecheck!

    override func setUp() async throws {
        clock = Clock()
        checks = 0
        let clock = clock!
        recheck = ConnectionRecheck(now: { clock.now }) { [weak self] in self?.checks += 1 }
    }

    private let wifi = ConnectionRecheck.PathSummary(satisfied: true, interfaces: ["en0"])
    private let cellular = ConnectionRecheck.PathSummary(satisfied: true, interfaces: ["pdp_ip0"])
    private let offline = ConnectionRecheck.PathSummary(satisfied: false, interfaces: [])

    func testLaunchingDoesNotCheck() async {
        recheck.didBecomeActive()
        recheck.pathChanged(wifi)
        XCTAssertEqual(checks, 0)
    }

    func testReturningFromTheBackgroundChecksAtOnce() async {
        recheck.didBecomeActive()
        recheck.didEnterBackground()
        clock.now += 120
        recheck.didBecomeActive()
        XCTAssertEqual(checks, 1)
    }

    func testANetworkChangeChecksOnceItWorksAgain() async {
        recheck.didBecomeActive()
        recheck.pathChanged(wifi)
        recheck.pathChanged(offline)
        XCTAssertEqual(checks, 0, "checking while offline would end sessions that survive a quick switch")
        clock.now += 10
        recheck.pathChanged(cellular)
        XCTAssertEqual(checks, 1)
        clock.now += 10
        recheck.pathChanged(cellular)
        XCTAssertEqual(checks, 1, "the same path again is no change")
    }

    func testReturningAndANetworkChangeTogetherCheckOnce() async {
        recheck.didBecomeActive()
        recheck.pathChanged(wifi)
        recheck.didEnterBackground()
        clock.now += 300
        recheck.didBecomeActive()
        clock.now += 0.5
        recheck.pathChanged(cellular)
        XCTAssertEqual(checks, 1, "no second check (and so no duplicate reconnects) right after the first")
        clock.now += ConnectionRecheck.coalesceInterval + 0.1
        recheck.pathChanged(wifi)
        XCTAssertEqual(checks, 2)
    }

    func testANetworkChangeInTheBackgroundWaitsForTheReturn() async {
        recheck.didBecomeActive()
        recheck.pathChanged(wifi)
        recheck.didEnterBackground()
        recheck.pathChanged(cellular)
        XCTAssertEqual(checks, 0)
        clock.now += 5
        recheck.didBecomeActive()
        XCTAssertEqual(checks, 1)
    }

    func testInactiveWithoutBackgroundDoesNotCheck() async {
        recheck.didBecomeActive()
        // Control Center or the Face ID sheet: inactive, never background.
        recheck.didBecomeActive()
        XCTAssertEqual(checks, 0)
    }
}
