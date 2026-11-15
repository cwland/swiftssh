import XCTest
import Synchronization
import SSHCore
@testable import AppCore

@MainActor
final class OnePasswordPromptFocusTests: XCTestCase {
    /// Sleeps until `elapse()`; records nothing else.
    private final class ManualSleeper: Sendable {
        private let waiters = Mutex<[CheckedContinuation<Void, any Error>]>([])
        func sleep(_: Duration) async throws {
            try await withCheckedThrowingContinuation { c in waiters.withLock { $0.append(c) } }
            try Task.checkCancellation()
        }
        var pending: Int { waiters.withLock { $0.count } }
        func elapse() {
            let all = waiters.withLock { w in defer { w = [] }; return w }
            for w in all { w.resume() }
        }
    }

    private var events: [String] = []
    private var enabled = true
    private var sleeper = ManualSleeper()

    private func coordinator() -> OnePasswordPromptFocus {
        OnePasswordPromptFocus(isEnabled: { [unowned self] in enabled },
                               handOff: { [unowned self] in events.append("handOff") },
                               takeBack: { [unowned self] in events.append("takeBack") },
                               sleep: { [sleeper] in try await sleeper.sleep($0) })
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testHandsOffOnlyAfterTheDelayAndTakesBackWhenDone() async {
        let focus = coordinator()
        focus.beginWait()
        await settle()
        XCTAssertEqual(events, [], "an answer within the delay means no prompt was shown")
        sleeper.elapse()
        await settle()
        XCTAssertEqual(events, ["handOff"])
        focus.endWait()
        XCTAssertEqual(events, ["handOff", "takeBack"])
    }

    func testQuickAnswerNeverHandsOff() async {
        let focus = coordinator()
        focus.beginWait()
        await settle()
        focus.endWait()
        sleeper.elapse()
        await settle()
        XCTAssertEqual(events, [])
    }

    func testOverlappingWaitsHandOffOnceAndTakeBackAfterTheLast() async {
        let focus = coordinator()
        focus.beginWait()
        focus.beginWait()
        await settle()
        sleeper.elapse()
        await settle()
        XCTAssertEqual(events, ["handOff"])
        focus.endWait()
        XCTAssertEqual(events, ["handOff"])
        focus.endWait()
        XCTAssertEqual(events, ["handOff", "takeBack"])
        focus.endWait()
        XCTAssertEqual(events, ["handOff", "takeBack"], "an extra end is ignored")
    }

    func testTurnedOffDoesNothing() async {
        enabled = false
        let focus = coordinator()
        focus.beginWait()
        await settle()
        sleeper.elapse()
        await settle()
        focus.endWait()
        XCTAssertEqual(events, [])
    }

    func testAgentWaitFollowsTheTabsLogs() async {
        let focus = coordinator()
        focus.setAgentWaiting(true)
        focus.setAgentWaiting(true)
        await settle()
        sleeper.elapse()
        await settle()
        focus.setAgentWaiting(false)
        focus.setAgentWaiting(false)
        XCTAssertEqual(events, ["handOff", "takeBack"])
    }

    func testIsWaitingForAgentReadsTheLastLogLine() async {
        let now = Date()
        let agent = ConnectionLogLine(id: 1, step: .authenticating(method: "1Password agent"),
                                      text: "x", status: .inProgress, at: now)
        XCTAssertTrue(OnePasswordPromptFocus.isWaitingForAgent([agent]))
        var done = agent
        done.status = .done
        XCTAssertFalse(OnePasswordPromptFocus.isWaitingForAgent([done]))
        let password = ConnectionLogLine(id: 2, step: .authenticating(method: "password"),
                                         text: "x", status: .inProgress, at: now)
        XCTAssertFalse(OnePasswordPromptFocus.isWaitingForAgent([password]))
        XCTAssertFalse(OnePasswordPromptFocus.isWaitingForAgent([agent, password]))
        XCTAssertFalse(OnePasswordPromptFocus.isWaitingForAgent([]))
    }

    func testSettingDefaultsOnAndPersists() async {
        let defaults = UserDefaults(suiteName: "op-focus-\(UUID())")!
        let settings = OnePasswordSettings(defaults: defaults)
        XCTAssertTrue(settings.bringsPromptForward)
        settings.bringsPromptForward = false
        XCTAssertFalse(OnePasswordSettings(defaults: defaults).bringsPromptForward)
    }
}
