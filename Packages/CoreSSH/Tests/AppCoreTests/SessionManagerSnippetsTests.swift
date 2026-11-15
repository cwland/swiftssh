import XCTest
import Synchronization
import CoreModels
import SSHCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

/// A scripted session: `start` emits `.connected` (and `.ready` when `readyOnStart`); it records what
/// is sent to it.
private final class SnippetFakeSession: TerminalSession, Sendable {
    let plan: ConnectionPlan
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let state = Mutex<(sends: [String], closed: Bool)>(([], false))
    private let readyOnStart: Bool

    init(plan: ConnectionPlan, readyOnStart: Bool) {
        self.plan = plan
        self.readyOnStart = readyOnStart
        (events, continuation) = AsyncStream.makeStream()
    }

    var sends: [String] { state.withLock { $0.sends } }

    func emit(_ event: SessionEvent) {
        let send = state.withLock { s -> Bool in
            if s.closed { return false }
            if case .closed = event { s.closed = true }
            return true
        }
        guard send else { return }
        continuation.yield(event)
        if case .closed = event { continuation.finish() }
    }

    func start(cols: Int, rows: Int) async {
        emit(.connected)
        if readyOnStart { emit(.ready) }
    }

    func send(_ bytes: [UInt8]) async {
        state.withLock { $0.sends.append(String(decoding: bytes, as: UTF8.self)) }
    }

    func resize(cols: Int, rows: Int) async {}

    func runCommand(_ command: String) async throws -> String { "Linux\nID=ubuntu\n" }

    func close() async { emit(.closed(.userClosed)) }
}

private final class SnippetFakeSleeper: Sendable {
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { continuation in waiters.withLock { $0.append(continuation) } }
    }

    var pending: Int { waiters.withLock { $0.count } }

    func elapseAll() {
        let all = waiters.withLock { w in defer { w = [] }; return w }
        for waiter in all { waiter.resume() }
    }
}

@MainActor
final class SessionManagerSnippetsTests: XCTestCase {
    private var vault: LocalVault!
    private var sessions: [SnippetFakeSession] = []
    private var readyOnStart = true
    private var sleeper: SnippetFakeSleeper!
    private var manager: SessionManager!

    private static let attachMain =
        "command -v tmux >/dev/null 2>&1 && tmux new -A -s 'main' || echo 'tmux is not installed on this server - skipping attach.'\r"

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        sessions = []
        readyOnStart = true
        sleeper = SnippetFakeSleeper()
        let sleeper = sleeper!
        manager = SessionManager(vault: vault, knownHosts: KnownHostsStore(vault: vault),
                                 makeSession: { [unowned self] plan, _ in
                                     let s = SnippetFakeSession(plan: plan, readyOnStart: self.readyOnStart)
                                     self.sessions.append(s)
                                     return s
                                 },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero,
                                 autoReconnectEnabled: { true },
                                 sleep: { try await sleeper.sleep($0) })
    }

    override func tearDown() async throws {
        sleeper?.elapseAll()
    }

    // MARK: Helpers

    private func waitUntil(_ what: String, timeout: TimeInterval = 2, _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func host(_ label: String = "Web", password: String? = "pw", tmux: TmuxChoice? = nil,
                      script: String? = nil) -> SavedHost {
        let snippetID = script.map { vault.saveNow(Snippet(name: "s", script: $0)).id }
        return vault.saveNow(SavedHost(label: label, address: "\(label.lowercased()).example", username: "root",
                                       password: password, startupSnippetID: snippetID, tmuxSession: tmux))
    }

    private func session(of tab: TerminalTab) -> SnippetFakeSession? {
        sessions.last { $0.plan.label == tab.title }
    }

    /// Opens a host tab and waits until it is connected and ready (nothing sent).
    private func connectedTab(_ label: String = "Web") async throws -> (TerminalTab, SnippetFakeSession) {
        let count = sessions.count
        let tab = try manager.open(hostID: host(label).id)
        await waitUntil("connected") { tab.state == .connected && self.sessions.count == count + 1 }
        await settle()
        return (tab, sessions[count])
    }

    // MARK: deliver

    func testPasteTypesTheTextWithoutReturn() async throws {
        let (tab, s) = try await connectedTab()
        XCTAssertTrue(manager.deliver("ls -la", as: .paste, toTab: tab.id))
        await waitUntil("sent") { s.sends == ["ls -la"] }
    }

    func testRunPressesReturn() async throws {
        let (tab, s) = try await connectedTab()
        XCTAssertTrue(manager.deliver("uptime", as: .run, toTab: tab.id))
        await waitUntil("sent") { s.sends == ["uptime\r"] }
    }

    func testNewlinesBecomeReturns() async throws {
        let (tab, s) = try await connectedTab()
        manager.deliver("cd /srv\nls\r\npwd", as: .paste, toTab: tab.id)
        manager.deliver("a\nb", as: .run, toTab: tab.id)
        await waitUntil("sent") { s.sends.count == 2 }
        XCTAssertEqual(s.sends, ["cd /srv\rls\rpwd", "a\rb\r"])
    }

    func testRunDoesNotAddASecondReturnAfterATrailingNewline() async throws {
        let (tab, s) = try await connectedTab()
        manager.deliver("uptime\n", as: .run, toTab: tab.id)
        manager.deliver("df\r\n", as: .run, toTab: tab.id)
        manager.deliver("ls\n", as: .paste, toTab: tab.id)
        await waitUntil("sent") { s.sends.count == 3 }
        XCTAssertEqual(s.sends, ["uptime\r", "df\r", "ls\r"])
    }

    func testDeliveryTextRules() async {
        XCTAssertEqual(SessionManager.deliveryText("x", as: .paste), "x")
        XCTAssertEqual(SessionManager.deliveryText("x", as: .run), "x\r")
        XCTAssertEqual(SessionManager.deliveryText("", as: .run), "\r")
        XCTAssertEqual(SessionManager.deliveryText("", as: .paste), "")
        XCTAssertEqual(SessionManager.deliveryText("a\r\n\nb\r", as: .run), "a\r\rb\r")
        XCTAssertEqual(SessionManager.deliveryText("\u{1F600}\n", as: .paste), "\u{1F600}\r")
    }

    func testNotConnectedSendsNothing() async throws {
        readyOnStart = false
        let h = host(password: nil)
        // Citadel without a password asks first: no session yet.
        let asking = try manager.open(hostID: h.id)
        XCTAssertEqual(asking.state, .awaitingPassword(prompt: "Password for root@web.example"))
        XCTAssertFalse(manager.deliver("ls", as: .run, toTab: asking.id))
        XCTAssertFalse(manager.deliver("ls", as: .run, toTab: UUID()), "unknown tab")

        let (tab, s) = try await connectedTab("Db")
        s.emit(.closed(.remoteClosed))
        await waitUntil("disconnected") { tab.state == .disconnected(nil) }
        XCTAssertFalse(manager.deliver("ls", as: .run, toTab: tab.id))
        await settle()
        XCTAssertEqual(s.sends, [])
    }

    func testConnectingTabSendsNothing() async throws {
        // A session that never reports `.connected`.
        manager = SessionManager(vault: vault, knownHosts: KnownHostsStore(vault: vault),
                                 makeSession: { [unowned self] plan, _ in
                                     let s = NeverConnects(plan: plan)
                                     self.silent.append(s)
                                     return s
                                 },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero)
        let tab = try manager.open(hostID: host().id)
        await waitUntil("started") { self.silent.count == 1 }
        XCTAssertEqual(tab.state, .connecting)
        XCTAssertFalse(manager.deliver("ls", as: .run, toTab: tab.id))
        XCTAssertEqual(manager.connectableTabCount(inWindow: nil), 0)
        XCTAssertEqual(manager.deliverToAllTabs("ls", as: .run, inWindow: nil), 0)
        await settle()
        XCTAssertEqual(silent[0].sendCount, 0)
    }

    private var silent: [NeverConnects] = []

    // MARK: deliverToAllTabs

    func testAllTabsOfTheWindowThatAreConnected() async throws {
        let (a, sa) = try await connectedTab("A")
        let (b, sb) = try await connectedTab("B")
        let (c, sc) = try await connectedTab("C")
        sc.emit(.closed(.remoteClosed))
        await waitUntil("C down") { c.state == .disconnected(nil) }
        let other = UUID()
        let copy = try XCTUnwrap(manager.duplicate(tabID: a.id, inWindow: other))
        await waitUntil("copy connected") { copy.state == .connected && self.sessions.count == 4 }
        await settle()
        let sCopy = sessions[3]

        XCTAssertEqual(manager.connectableTabCount(inWindow: nil), 2)
        XCTAssertEqual(manager.connectableTabCount(inWindow: other), 1)
        XCTAssertEqual(manager.connectableTabCount(inWindow: UUID()), 0)

        XCTAssertEqual(manager.deliverToAllTabs("uptime", as: .run, inWindow: nil), 2)
        await waitUntil("sent") { sa.sends == ["uptime\r"] && sb.sends == ["uptime\r"] }
        await settle()
        XCTAssertEqual(sc.sends, [])
        XCTAssertEqual(sCopy.sends, [], "other windows are left alone")
        _ = b

        XCTAssertEqual(manager.deliverToAllTabs("ls", as: .paste, inWindow: other), 1)
        await waitUntil("sent to other") { sCopy.sends == ["ls"] }
    }

    // MARK: runOnHosts

    func testRunOnHostsOpensATabPerHostAndRunsAfterReady() async throws {
        let a = host("A"), b = host("B")
        let tabs = try manager.runOnHosts([a.id, b.id], text: "uptime")
        XCTAssertEqual(tabs.map(\.savedHostID), [a.id, b.id])
        XCTAssertEqual(tabs.map(\.windowID), [nil, nil], "the main window")
        XCTAssertEqual(manager.tabs(inWindow: nil).map(\.id), tabs.map(\.id))
        await waitUntil("both ran") { self.sessions.count == 2 && self.sessions.allSatisfy { $0.sends == ["uptime\r"] } }
        await settle()
        XCTAssertTrue(sessions.allSatisfy { $0.sends == ["uptime\r"] }, "once each")
    }

    func testRunOnHostsUsesDeliveryRules() async throws {
        _ = try manager.runOnHosts([host().id], text: "cd /srv\nls\n")
        await waitUntil("ran") { self.sessions.first?.sends == ["cd /srv\rls\r"] }
    }

    func testRunOnHostsWaitsForReady() async throws {
        readyOnStart = false
        let tabs = try manager.runOnHosts([host().id], text: "uptime")
        await waitUntil("connected") { tabs[0].state == .connected }
        await settle()
        XCTAssertEqual(sessions[0].sends, [], "not on .connected")
        sessions[0].emit(.ready)
        await waitUntil("ran") { self.sessions[0].sends == ["uptime\r"] }
    }

    func testRunOnHostsRunsAfterStartupScriptAndTmuxAttach() async throws {
        _ = try manager.runOnHosts([host(tmux: .session("main"), script: "cd /srv").id], text: "uptime")
        await waitUntil("all three") { self.sessions.first?.sends.count == 3 }
        XCTAssertEqual(sessions[0].sends, ["cd /srv\n", Self.attachMain, "uptime\r"])
    }

    func testRunOnHostsIsNotRepeatedOnManualReconnect() async throws {
        let h = host(tmux: .session("main"))
        let tab = try manager.runOnHosts([h.id], text: "uptime")[0]
        await waitUntil("ran") { self.sessions.first?.sends == [Self.attachMain, "uptime\r"] }
        manager.reconnect(tabID: tab.id)
        await waitUntil("second attach") { self.sessions.count == 2 && self.sessions[1].sends == [Self.attachMain] }
        await settle()
        XCTAssertEqual(sessions[1].sends, [Self.attachMain], "the snippet ran on the first attempt only")
    }

    func testRunOnHostsIsNotRepeatedOnAutoReconnect() async throws {
        let tab = try manager.runOnHosts([host().id], text: "uptime")[0]
        await waitUntil("ran") { self.sessions.first?.sends == ["uptime\r"] }
        sessions[0].emit(.closed(.failed(.connectionFailed("Broken pipe"))))
        await waitUntil("countdown") { self.sleeper.pending == 1 }
        sleeper.elapseAll()
        await waitUntil("reconnected") { self.sessions.count == 2 && tab.state == .connected && tab.autoReconnect == nil }
        await settle()
        XCTAssertEqual(sessions[1].sends, [])
    }

    func testRunOnHostsDroppedWhenTheFirstAttemptFailsAndTheUserReconnects() async throws {
        readyOnStart = false
        let tab = try manager.runOnHosts([host().id], text: "uptime")[0]
        await waitUntil("connected") { tab.state == .connected }
        sessions[0].emit(.closed(.failed(.connectionFailed("Connection refused"))))
        await waitUntil("down") { if case .disconnected = tab.state { true } else { false } }
        readyOnStart = true
        manager.reconnect(tabID: tab.id)
        await waitUntil("second ready") { self.sessions.count == 2 && tab.state == .connected }
        await settle()
        XCTAssertEqual(sessions[1].sends, [], "a reconnect is not the first attempt")
    }

    func testRunOnHostsAfterATypedPassword() async throws {
        let tab = try manager.runOnHosts([host(password: nil).id], text: "uptime")[0]
        XCTAssertEqual(tab.state, .awaitingPassword(prompt: "Password for root@web.example"))
        XCTAssertEqual(sessions.count, 0)
        manager.providePassword(tabID: tab.id, "pw", save: false)
        await waitUntil("ran") { self.sessions.first?.sends == ["uptime\r"] }
    }

    func testRunOnHostsKeepsTheTextThroughARejectedTypedPassword() async throws {
        readyOnStart = false
        let tab = try manager.runOnHosts([host(password: nil).id], text: "uptime")[0]
        manager.providePassword(tabID: tab.id, "wrong", save: false)
        await waitUntil("started") { self.sessions.count == 1 }
        sessions[0].emit(.closed(.failed(.authenticationFailed)))
        await waitUntil("asks again") { if case .awaitingPassword = tab.state { true } else { false } }
        readyOnStart = true
        manager.providePassword(tabID: tab.id, "pw", save: false)
        await waitUntil("ran") { self.sessions.count == 2 && self.sessions[1].sends == ["uptime\r"] }
        XCTAssertEqual(sessions[0].sends, [])
    }

    func testRunOnHostsOpensEachHostOnce() async throws {
        let a = host("A")
        let tabs = try manager.runOnHosts([a.id, a.id], text: "uptime")
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(manager.tabs.count, 1)
    }

    func testRunOnHostsThrowsAndOpensNothingWhenAHostCannotBePlanned() async throws {
        let good = host("A")
        let noAddress = vault.saveNow(SavedHost(label: "Bad", address: "", username: "root", password: "pw"))
        XCTAssertThrowsError(try manager.runOnHosts([good.id, noAddress.id], text: "uptime"))
        XCTAssertThrowsError(try manager.runOnHosts([UUID()], text: "uptime"))
        XCTAssertEqual(manager.tabs.count, 0)
        await settle()
        XCTAssertEqual(sessions.count, 0)
    }

    func testRunOnNoHosts() async throws {
        XCTAssertEqual(try manager.runOnHosts([], text: "uptime").count, 0)
        XCTAssertEqual(manager.tabs.count, 0)
    }

    func testOpenWithoutRunOnHostsTypesNothing() async throws {
        let (_, s) = try await connectedTab()
        await settle()
        XCTAssertEqual(s.sends, [])
    }
}

/// A session that never reports anything.
private final class NeverConnects: TerminalSession, Sendable {
    let plan: ConnectionPlan
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let sends = Mutex(0)

    init(plan: ConnectionPlan) {
        self.plan = plan
        (events, continuation) = AsyncStream.makeStream()
    }

    var sendCount: Int { sends.withLock { $0 } }
    func start(cols: Int, rows: Int) async {}
    func send(_ bytes: [UInt8]) async { sends.withLock { $0 += 1 } }
    func resize(cols: Int, rows: Int) async {}
    func runCommand(_ command: String) async throws -> String { "" }
    func close() async { continuation.yield(.closed(.userClosed)); continuation.finish() }
}
