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
    /// What `handOff` reports (false: this app wasn't active, nothing was handed over).
    private var handOffSucceeds = true
    private var sleeper = ManualSleeper()

    private func coordinator() -> OnePasswordPromptFocus {
        OnePasswordPromptFocus(isEnabled: { [unowned self] in enabled },
                               handOff: { [unowned self] in events.append("handOff"); return handOffSucceeds },
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

    func testRefusedHandOffIsTriedAgainWhileWaiting() async {
        handOffSucceeds = false
        let focus = coordinator()
        focus.beginWait()
        await settle()
        sleeper.elapse()
        await settle()
        XCTAssertEqual(events, ["handOff"])
        handOffSucceeds = true
        sleeper.elapse() // asked again: now the prompt is up
        await settle()
        XCTAssertEqual(events, ["handOff", "handOff"])
        focus.endWait()
        XCTAssertEqual(events, ["handOff", "handOff", "takeBack"])
    }

    func testRefusedHandOffNeverTakesFocusBackOnItsOwn() async {
        handOffSucceeds = false
        let focus = coordinator()
        focus.beginWait()
        await settle()
        sleeper.elapse()
        await settle()
        focus.endWait()
        sleeper.elapse()
        await settle()
        XCTAssertEqual(events, ["handOff"], "nothing was handed over, so nothing is taken back")
    }

    func testAStuckWaitDoesNotDisableLaterHandOffs() async {
        let focus = coordinator()
        focus.beginWait() // never ends
        await settle()
        sleeper.elapse() // delay: hand off
        await settle()
        sleeper.elapse() // cap: take back
        await settle()
        focus.beginWait() // a new prompt while the first wait is still counted
        await settle()
        sleeper.elapse()
        await settle()
        XCTAssertEqual(events, ["handOff", "takeBack", "handOff"])
    }

    func testFocusComesBackAfterTheCapEvenIfAWaitNeverEnds() async {
        let focus = coordinator()
        focus.beginWait()
        await settle()
        sleeper.elapse() // the hand-off delay
        await settle()
        XCTAssertEqual(events, ["handOff"])
        sleeper.elapse() // the cap
        await settle()
        XCTAssertEqual(events, ["handOff", "takeBack"])
        focus.endWait()
        XCTAssertEqual(events, ["handOff", "takeBack"], "taken back once")
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
