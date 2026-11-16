import XCTest
import Synchronization
import CoreModels
import SSHCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

/// A scripted session: `start` emits `.connected` (and `.ready` when `readyOnStart`); it records what
/// is sent to it.
private final class TmuxFakeSession: TerminalSession, Sendable {
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

private final class TmuxFakeSleeper: Sendable {
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
final class SessionManagerTmuxTests: XCTestCase {
    private var vault: LocalVault!
    private var sessions: [TmuxFakeSession] = []
    private var readyOnStart = true
    private var sleeper: TmuxFakeSleeper!
    private var manager: SessionManager!

    private static let attachMain =
        "command -v tmux >/dev/null 2>&1 && tmux new -A -s 'main' || echo 'tmux is not installed on this server - skipping attach.'\r"

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        sessions = []
        readyOnStart = true
        sleeper = TmuxFakeSleeper()
        let sleeper = sleeper!
        manager = SessionManager(vault: vault, knownHosts: KnownHostsStore(vault: vault),
                                 makeSession: { [unowned self] plan, _ in
                                     let s = TmuxFakeSession(plan: plan, readyOnStart: self.readyOnStart)
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

    private func host(tmux: TmuxChoice? = nil, groupID: UUID? = nil, script: String? = nil) -> SavedHost {
        let snippetID = script.map { vault.saveNow(Snippet(name: "s", script: $0)).id }
        return vault.saveNow(SavedHost(label: "Web", address: "web.example", groupID: groupID, username: "root",
                                       password: "pw", startupSnippetID: snippetID, tmuxSession: tmux))
    }

    // MARK: Tests

    func testAttachCommandIsExactlyThePlannedLine() async {
        XCTAssertEqual(SessionManager.tmuxAttachCommand(session: "main"), Self.attachMain)
        XCTAssertEqual(SessionManager.tmuxAttachCommand(session: "dev_box-2"),
                       "command -v tmux >/dev/null 2>&1 && tmux new -A -s 'dev_box-2' || echo 'tmux is not installed on this server - skipping attach.'\r")
    }

    func testSendsTheAttachLineAfterReady() async throws {
        let tab = try manager.open(hostID: host(tmux: .session("main")).id)
        await waitUntil("attach") { self.sessions.first?.sends == [Self.attachMain] }
        XCTAssertEqual(tab.state, .connected)
        await settle()
        XCTAssertEqual(sessions[0].sends, [Self.attachMain], "sent once")
    }

    func testAttachAddsADoneLineToTheConnectionLog() async throws {
        let tab = try manager.open(hostID: host(tmux: .session("main")).id)
        await waitUntil("attach") { self.sessions.first?.sends == [Self.attachMain] }
        let line = tab.connectionLog.last
        XCTAssertEqual(line?.step, .attachingTmux(session: "main"))
        XCTAssertEqual(line?.status, .done)
        XCTAssertFalse(tab.connectionLog.contains { $0.status == .inProgress })
    }

    func testNothingIsSentBeforeReady() async throws {
        readyOnStart = false
        let tab = try manager.open(hostID: host(tmux: .session("main")).id)
        await waitUntil("connected") { tab.state == .connected }
        await settle()
        XCTAssertEqual(sessions[0].sends, [], "not on .connected")
        sessions[0].emit(.ready)
        await waitUntil("attach") { self.sessions[0].sends == [Self.attachMain] }
    }

    func testNotSentWhenOffOrInheritedOff() async throws {
        let onGroup = vault.saveNow(HostGroup(name: "G", defaultTmuxSession: .session("ops")))
        for h in [host(), host(tmux: .off), host(tmux: .off, groupID: onGroup.id), host(tmux: .inherit)] {
            let tab = try manager.open(hostID: h.id)
            await waitUntil("ready") { tab.state == .connected }
        }
        await settle()
        XCTAssertEqual(sessions.flatMap(\.sends), [])
    }

    func testInheritsTheGroupSession() async throws {
        let group = vault.saveNow(HostGroup(name: "G", defaultTmuxSession: .session("ops")))
        _ = try manager.open(hostID: host(groupID: group.id).id)
        await waitUntil("attach") {
            self.sessions.first?.sends == ["command -v tmux >/dev/null 2>&1 && tmux new -A -s 'ops' || echo 'tmux is not installed on this server - skipping attach.'\r"]
        }
    }

    func testInvalidStoredNameIsNotSent() async throws {
        let tab = try manager.open(hostID: host(tmux: .session("x'; rm -rf ~; '")).id)
        await waitUntil("ready") { tab.state == .connected }
        await settle()
        XCTAssertEqual(sessions[0].sends, [])
    }

    func testNotSentForQuickConnect() async throws {
        // Even with a saved host of the same address that attaches.
        _ = host(tmux: .session("main"))
        let tab = manager.open(quickConnect: QuickConnectTarget(username: "root", host: "web.example", port: nil))
        if case .awaitingPassword = tab.state { manager.providePassword(tabID: tab.id, "pw", save: false) }
        await waitUntil("ready") { tab.state == .connected }
        await settle()
        XCTAssertEqual(sessions[0].sends, [])
    }

    func testStartupScriptRunsFirstThenAttach() async throws {
        _ = try manager.open(hostID: host(tmux: .session("main"), script: "cd /srv").id)
        await waitUntil("both") { self.sessions.first?.sends.count == 2 }
        XCTAssertEqual(sessions[0].sends, ["cd /srv\n", Self.attachMain])
    }

    func testSentAgainOnManualReconnect() async throws {
        let tab = try manager.open(hostID: host(tmux: .session("main")).id)
        await waitUntil("first attach") { self.sessions.first?.sends == [Self.attachMain] }
        manager.reconnect(tabID: tab.id)
        await waitUntil("second attach") { self.sessions.count == 2 && self.sessions[1].sends == [Self.attachMain] }
    }

    func testSentAgainOnAutoReconnect() async throws {
        let tab = try manager.open(hostID: host(tmux: .session("main")).id)
        await waitUntil("first attach") { self.sessions.first?.sends == [Self.attachMain] }
        sessions[0].emit(.closed(.failed(.connectionFailed("Broken pipe"))))
        await waitUntil("countdown") { self.sleeper.pending == 1 }
        sleeper.elapseAll()
        await waitUntil("second attach") { self.sessions.count == 2 && self.sessions[1].sends == [Self.attachMain] }
        await waitUntil("reconnected") { tab.state == .connected && tab.autoReconnect == nil }
    }

    func testUsesTheChoiceCurrentAtEachAttempt() async throws {
        let h = host(tmux: .session("main"))
        let tab = try manager.open(hostID: h.id)
        await waitUntil("first attach") { self.sessions.first?.sends == [Self.attachMain] }
        var changed = try XCTUnwrap(vault.get(SavedHost.self, id: h.id))
        changed.tmuxSession = .off
        vault.saveNow(changed)
        manager.reconnect(tabID: tab.id)
        await waitUntil("second ready") { self.sessions.count == 2 && tab.state == .connected }
        await settle()
        XCTAssertEqual(sessions[1].sends, [])
    }

    func testGroupStartupSnippetRunsForAHostWithoutItsOwnThenAttach() async throws {
        let snippet = vault.saveNow(Snippet(name: "g", script: "cd /srv"))
        let group = vault.saveNow(HostGroup(name: "Ops", defaultTmuxSession: .session("main"),
                                            startupSnippetID: snippet.id))
        _ = try manager.open(hostID: host(groupID: group.id).id)
        await waitUntil("script and attach") { self.sessions.first?.sends == ["cd /srv\n", Self.attachMain] }
    }
}
