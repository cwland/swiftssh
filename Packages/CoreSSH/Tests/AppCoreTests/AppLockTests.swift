import XCTest
@testable import AppCore

/// A clock the tests move by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 10_000)
    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now += seconds } }
}

@MainActor
final class AppLockTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
    }

    private func defaults(enabled: Bool? = nil) -> UserDefaults {
        let name = "app-lock-tests-\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        if let enabled { defaults.set(enabled, forKey: AppLock.enabledKey) }
        return defaults
    }

    private func lock(enabled: Bool, clock: TestClock = TestClock(),
                      answers: [AppLockAuthentication] = [.success]) -> (AppLock, Counter) {
        let counter = Counter(answers: answers)
        let lock = AppLock(defaults: defaults(enabled: enabled), authenticate: { await counter.next() },
                           now: { clock.now })
        return (lock, counter)
    }

    @MainActor
    final class Counter {
        var answers: [AppLockAuthentication]
        var calls = 0
        init(answers: [AppLockAuthentication]) { self.answers = answers }
        func next() async -> AppLockAuthentication {
            calls += 1
            await Task.yield()
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }

    func testOffByDefaultAndNeverLocks() async {
        let lock = AppLock(defaults: defaults(), authenticate: { .success })
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
        lock.didEnterBackground()
        lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.showsCover(isActive: false))
    }

    func testLockedAtLaunchWhenOn() async {
        let (lock, _) = lock(enabled: true)
        XCTAssertTrue(lock.isLocked)
        XCTAssertTrue(lock.showsCover(isActive: true))
    }

    func testUnlockSucceeds() async {
        let (lock, counter) = lock(enabled: true)
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.message)
        XCTAssertEqual(counter.calls, 1)
        XCTAssertFalse(lock.showsCover(isActive: true))
    }

    func testFailedUnlockStaysLockedWithTheReason() async {
        let (lock, _) = lock(enabled: true, answers: [.failed("Try again."), .success])
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(lock.message, "Try again.")
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.message)
    }

    func testNoPasscodeOnTheDeviceLetsTheUserIn() async {
        let (lock, _) = lock(enabled: true, answers: [.unavailable("Set a passcode to use the lock.")])
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(lock.message, "Set a passcode to use the lock.")
    }

    func testShortTripToTheBackgroundDoesNotLock() async {
        let clock = TestClock()
        let (lock, _) = lock(enabled: true, clock: clock)
        await lock.unlock()
        lock.didEnterBackground()
        clock.advance(AppLock.gracePeriod)
        lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked)
    }

    func testReturnAfterTheGracePeriodLocks() async {
        let clock = TestClock()
        let (lock, _) = lock(enabled: true, clock: clock)
        await lock.unlock()
        lock.didEnterBackground()
        clock.advance(AppLock.gracePeriod + 1)
        lock.didBecomeActive()
        XCTAssertTrue(lock.isLocked)
    }

    func testBecomingActiveWithoutBackgroundDoesNotLock() async {
        // Control Center, a Face ID sheet and similar only make the app inactive.
        let clock = TestClock()
        let (lock, _) = lock(enabled: true, clock: clock)
        await lock.unlock()
        clock.advance(600)
        lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked)
    }

    func testCoverHidesTheAppSwitcherSnapshotWhenOn() async {
        let (lock, _) = lock(enabled: true)
        await lock.unlock()
        XCTAssertTrue(lock.showsCover(isActive: false))
        XCTAssertFalse(lock.showsCover(isActive: true))
    }

    func testTurningOffUnlocksAndIsSaved() async {
        let store = defaults(enabled: true)
        let lock = AppLock(defaults: store, authenticate: { .failed("no") })
        await lock.unlock()
        XCTAssertNotNil(lock.message)
        lock.isEnabled = false
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.message)
        XCTAssertFalse(store.bool(forKey: AppLock.enabledKey))
        XCTAssertFalse(AppLock(defaults: store, authenticate: { .success }).isLocked)
    }

    func testTurningOnDoesNotLockUntilNextLaunch() async {
        let store = defaults()
        let lock = AppLock(defaults: store, authenticate: { .success })
        lock.isEnabled = true
        XCTAssertFalse(lock.isLocked)
        XCTAssertTrue(store.bool(forKey: AppLock.enabledKey))
        XCTAssertTrue(AppLock(defaults: store, authenticate: { .success }).isLocked)
    }

    func testOneUnlockRequestAtATime() async {
        let (lock, counter) = lock(enabled: true)
        async let first: Void = lock.unlock()
        async let second: Void = lock.unlock()
        _ = await (first, second)
        XCTAssertEqual(counter.calls, 1)
        XCTAssertFalse(lock.isLocked)
    }
}
