import XCTest
import Synchronization
import CoreModels
import SSHCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

/// A scripted session: `script` runs inside `start(cols:rows:)`.
final class ScriptedSession: TerminalSession, Sendable {
    let plan: ConnectionPlan
    let evaluator: any HostKeyEvaluator
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let script: @Sendable (ScriptedSession) async -> Void
    private let closed = Mutex(false)

    init(plan: ConnectionPlan, evaluator: any HostKeyEvaluator, script: @escaping @Sendable (ScriptedSession) async -> Void) {
        self.plan = plan
        self.evaluator = evaluator
        self.script = script
        (events, continuation) = AsyncStream.makeStream()
    }

    func emit(_ event: SessionEvent) {
        let send = closed.withLock { done -> Bool in
            if done { return false }
            if case .closed = event { done = true }
            return true
        }
        guard send else { return }
        continuation.yield(event)
        if case .closed = event { continuation.finish() }
    }

    func start(cols: Int, rows: Int) async { await script(self) }
    func send(_ bytes: [UInt8]) async {}
    func resize(cols: Int, rows: Int) async {}
    func runCommand(_ command: String) async throws -> String { "" }
    func close() async { emit(.closed(.userClosed)) }
}

/// Connecting to a saved host with a backup address (`Host.fallbackAddress`): the main address first with
/// a 5-second reach limit, then the backup when the main one can't be reached.
@MainActor
final class SessionManagerBackupAddressTests: XCTestCase {
    private var vault: LocalVault!
    private var store: KnownHostsStore!
    private var sessions: [ScriptedSession] = []
    /// Script per session index; sessions past the end connect and become ready.
    private var scripts: [@Sendable (ScriptedSession) async -> Void] = []
    private var manager: SessionManager!

    static let connects: @Sendable (ScriptedSession) async -> Void = { s in
        s.emit(.progress(.connecting(address: s.plan.host, port: s.plan.port)))
        s.emit(.progress(.connected(address: s.plan.host)))
        s.emit(.connected)
        s.emit(.ready)
    }

    static func fails(_ error: SessionError, reached: Bool = false) -> @Sendable (ScriptedSession) async -> Void {
        { s in
            s.emit(.progress(.connecting(address: s.plan.host, port: s.plan.port)))
            if reached {
                s.emit(.progress(.connected(address: s.plan.host)))
                s.emit(.progress(.handshake))
            }
            s.emit(.closed(.failed(error)))
        }
    }

    /// Never finishes on its own (closing the tab ends it).
    static let hangs: @Sendable (ScriptedSession) async -> Void = { s in
        s.emit(.progress(.connecting(address: s.plan.host, port: s.plan.port)))
    }

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        store = KnownHostsStore(vault: vault)
        sessions = []
        scripts = []
        manager = makeManager()
    }

    private func makeManager(hostPlanner: (@MainActor (UUID, LocalVault) throws -> ConnectionPlan)? = nil) -> SessionManager {
        SessionManager(vault: vault, knownHosts: store,
                       makeSession: { [unowned self] plan, evaluator in
                           let index = self.sessions.count
                           let script = index < self.scripts.count ? self.scripts[index] : Self.connects
                           let session = ScriptedSession(plan: plan, evaluator: evaluator, script: script)
                           self.sessions.append(session)
                           return session
                       },
                       deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero,
                       sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                       hostPlanner: hostPlanner)
    }

    private func host(backup: String? = "100.64.0.10", port: Int? = nil) -> SavedHost {
        vault.saveNow(SavedHost(label: "NAS", address: "192.168.50.10", fallbackAddress: backup, port: port,
                                username: "root", password: "pw"))
    }

    private func waitUntil(_ what: String = "condition", timeout: TimeInterval = 2,
                           _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func texts(_ tab: TerminalTab) -> [String] { tab.connectionLog.map(\.text) }

    private func keyCandidate(host: String, port: Int = 22, blob: [UInt8] = [7, 7]) -> HostKeyCandidate {
        let t = Array("ssh-ed25519".utf8)
        return HostKeyCandidate(host: host, port: port, keyType: "ssh-ed25519",
                                publicKeyBlob: Data([0, 0, 0, UInt8(t.count)] + t + blob))
    }

    // MARK: Reach limit

    func testMainAttemptGetsTheFiveSecondReachLimitOnlyWithABackup() async throws {
        let tab = try manager.open(hostID: host().id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(sessions[0].plan.host, "192.168.50.10")
        XCTAssertEqual(sessions[0].plan.reachTimeout, .seconds(5))
        XCTAssertEqual(sessions[0].plan.connectTimeout, .seconds(15), "the rest of connecting keeps the normal limit")
        XCTAssertEqual(sessions.count, 1, "the main address answered: no backup attempt")
        XCTAssertEqual(tab.currentAddress, "192.168.50.10")
        XCTAssertFalse(tab.isUsingBackupAddress)

        let plain = try manager.open(hostID: host(backup: nil).id)
        await waitUntil("connected") { plain.state == .connected }
        XCTAssertNil(sessions[1].plan.reachTimeout, "no backup: unchanged")
        XCTAssertEqual(sessions[1].plan.connectTimeout, .seconds(15))
    }

    // MARK: Falling back

    func testTimeoutReachingTheMainAddressTriesTheBackup() async throws {
        scripts = [Self.fails(.timedOut)]
        let tab = try manager.open(hostID: host(port: 2222).id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(sessions.count, 2)
        let backup = sessions[1].plan
        XCTAssertEqual(backup.host, "100.64.0.10")
        XCTAssertEqual(backup.port, 2222, "same port")
        XCTAssertEqual(backup.username, "root", "same username")
        guard case .password("pw") = backup.credential else { return XCTFail("same credentials") }
        XCTAssertNil(backup.fallbackHost)
        XCTAssertNil(backup.reachTimeout, "the backup gets the normal timeout")
        XCTAssertEqual(backup.connectTimeout, .seconds(15))
        XCTAssertEqual(tab.currentAddress, "100.64.0.10")
        XCTAssertTrue(tab.isUsingBackupAddress)

        let log = tab.connectionLog
        let note = ConnectionFallback.note(main: "192.168.50.10", reason: "timed out", backup: "100.64.0.10")
        XCTAssertEqual(log.first?.text, "Connecting to 192.168.50.10:2222\u{2026}")
        XCTAssertEqual(log.first?.status, .failed, "the main attempt's step failed")
        XCTAssertEqual(log[1].text, note)
        XCTAssertEqual(log[1].status, .done)
        XCTAssertNil(log[1].step)
        XCTAssertTrue(texts(tab).contains("Connecting to 100.64.0.10:2222\u{2026}"))
        XCTAssertNil(tab.connectionFailure, "the main address's failure isn't the tab's failure")
        let text = tab.connectionLogText()
        XCTAssertTrue(text.contains("SSH root@100.64.0.10:2222"), text)
        XCTAssertTrue(text.contains("Backup address used: main address 192.168.50.10 unreachable"), text)
        XCTAssertTrue(text.contains(note), text)
    }

    func testRefusedOrUnresolvedMainAddressTriesTheBackup() async throws {
        for error in [SessionError.unreachable("Could not connect to 192.168.50.10:22 (connection refused)"),
                      .unreachable("Could not resolve nas.lan (host name not found)"),
                      .unreachable("ssh: connect to host 192.168.50.10 port 22: No route to host")] {
            sessions = []
            scripts = [Self.fails(error)]
            let tab = try manager.open(hostID: host().id)
            await waitUntil("connected") { tab.state == .connected }
            XCTAssertEqual(sessions.map(\.plan.host), ["192.168.50.10", "100.64.0.10"], "\(error)")
            XCTAssertTrue(texts(tab).contains(ConnectionFallback.note(main: "192.168.50.10",
                                                                      reason: ConnectionFallback.reason(of: error),
                                                                      backup: "100.64.0.10")))
        }
    }

    func testNoFallbackOnceTheServerWasReached() async throws {
        scripts = [Self.fails(.timedOut, reached: true)]
        let tab = try manager.open(hostID: host().id)
        await waitUntil("disconnected") { if case .disconnected = tab.state { true } else { false } }
        await settle()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(tab.connectionFailure, SessionError.timedOut.localizedDescription)
        XCTAssertEqual(tab.currentAddress, "192.168.50.10")
    }

    func testNoFallbackForSignInHostKeyOrOtherFailures() async throws {
        let failures: [SessionError] = [.authenticationFailed, .hostKeyRejected, .hostKeyChanged(previous: "a", presented: "b"),
                                        .connectionFailed("The server closed the connection before signing in."),
                                        .keyUnreadable]
        for error in failures {
            sessions = []
            scripts = [Self.fails(error)]
            let tab = try manager.open(hostID: host().id)
            await waitUntil("ended \(error)") { tab.state != .connecting }
            await settle()
            XCTAssertEqual(sessions.count, 1, "\(error)")
            XCTAssertFalse(texts(tab).contains { $0.hasPrefix("Main address") }, "\(error)")
        }
    }

    func testClosingTheTabWhileTheMainAddressConnectsTriesNothingElse() async throws {
        scripts = [Self.hangs]
        let tab = try manager.open(hostID: host().id)
        await waitUntil("started") { self.sessions.count == 1 }
        manager.close(tabID: tab.id)
        await settle()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(manager.tabs.isEmpty)
    }

    func testReconnectWhileTheMainAddressConnectsTriesTheMainAddressAgain() async throws {
        scripts = [Self.hangs]
        let tab = try manager.open(hostID: host().id)
        await waitUntil("started") { self.sessions.count == 1 }
        manager.reconnect(tabID: tab.id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(sessions.map(\.plan.host), ["192.168.50.10", "192.168.50.10"],
                       "the cancelled attempt is not a reason to use the backup")
    }

    func testBackupFailingToo() async throws {
        scripts = [Self.fails(.timedOut), Self.fails(.unreachable("Could not connect to 100.64.0.10:22 (connection refused)"))]
        let tab = try manager.open(hostID: host().id)
        await waitUntil("disconnected") { if case .disconnected = tab.state { true } else { false } }
        await settle()
        XCTAssertEqual(sessions.count, 2, "two addresses, two attempts")
        XCTAssertEqual(tab.state, .disconnected("The connection failed: Could not connect to 100.64.0.10:22 (connection refused)"))
        XCTAssertEqual(tab.connectionFailure, "The connection failed: Could not connect to 100.64.0.10:22 (connection refused)")
        XCTAssertEqual(texts(tab).filter { $0.hasPrefix("Connecting to") },
                       ["Connecting to 192.168.50.10:22\u{2026}", "Connecting to 100.64.0.10:22\u{2026}"])
    }

    func testABackupWithoutAMainFailureIsNotTriedOnLaterDrops() async throws {
        let tab = try manager.open(hostID: host().id)
        await waitUntil("connected") { tab.state == .connected }
        sessions[0].emit(.closed(.failed(.unreachable("Could not connect"))))
        await settle()
        XCTAssertEqual(sessions.count, 1, "a live session that drops goes to auto-reconnect, not straight to the backup")
        guard case .waiting = tab.autoReconnect else { return XCTFail("an unreachable drop is retried: \(String(describing: tab.autoReconnect))") }
    }

    // MARK: Reconnect, auto-reconnect, workspaces

    func testReconnectStartsWithTheMainAddressAgain() async throws {
        scripts = [Self.fails(.timedOut)]
        let tab = try manager.open(hostID: host().id)
        await waitUntil("connected") { tab.state == .connected }
        manager.reconnect(tabID: tab.id)
        await waitUntil("third session") { self.sessions.count == 3 }
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(sessions[2].plan.host, "192.168.50.10", "no memory of which address worked")
        XCTAssertEqual(sessions[2].plan.reachTimeout, .seconds(5))
        XCTAssertEqual(tab.currentAddress, "192.168.50.10")
        XCTAssertFalse(tab.isUsingBackupAddress)
        XCTAssertFalse(texts(tab).contains { $0.hasPrefix("Main address") }, "a new log for the new attempt")
    }

    func testAutomaticReconnectTryAlsoFallsBack() async throws {
        let sleeper = Mutex<[CheckedContinuation<Void, Never>]>([])
        manager = SessionManager(vault: vault, knownHosts: store,
                                 makeSession: { [unowned self] plan, evaluator in
                                     let index = self.sessions.count
                                     let script = index < self.scripts.count ? self.scripts[index] : Self.connects
                                     let session = ScriptedSession(plan: plan, evaluator: evaluator, script: script)
                                     self.sessions.append(session)
                                     return session
                                 },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero,
                                 sleep: { _ in await withCheckedContinuation { c in sleeper.withLock { $0.append(c) } } })
        // Live on the main address, then it drops; the automatic try can't reach the main address.
        scripts = [Self.connects, Self.fails(.timedOut)]
        let tab = try manager.open(hostID: host().id)
        await waitUntil("connected") { tab.state == .connected }
        sessions[0].emit(.closed(.failed(.connectionFailed("Broken pipe"))))
        await waitUntil("countdown") { sleeper.withLock { !$0.isEmpty } }
        sleeper.withLock { $0.removeFirst() }.resume()
        await waitUntil("backup try") { self.sessions.count == 3 }
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(sessions[1].plan.host, "192.168.50.10")
        XCTAssertEqual(sessions[1].plan.connectTimeout, .seconds(5), "an automatic try is short anyway")
        XCTAssertEqual(sessions[1].plan.reachTimeout, .seconds(5))
        XCTAssertEqual(sessions[2].plan.host, "100.64.0.10")
        XCTAssertEqual(sessions[2].plan.connectTimeout, .seconds(5), "the try's normal timeout")
        XCTAssertNil(tab.autoReconnect, "ready on the backup: auto-reconnect is over")
    }

    func testWorkspacePanesFallBackToo() async throws {
        let a = host()
        let b = vault.saveNow(SavedHost(label: "Pi", address: "pi.lan", username: "pi", password: "pw"))
        scripts = [Self.fails(.timedOut)]
        let workspace = try manager.openWorkspace(hostIDs: [a.id, b.id], name: nil)
        XCTAssertNotNil(workspace)
        await waitUntil("all connected") { self.manager.tabs.allSatisfy { $0.state == .connected } }
        XCTAssertEqual(Set(sessions.map(\.plan.host)), ["192.168.50.10", "100.64.0.10", "pi.lan"])
        XCTAssertEqual(manager.tabs.first { $0.savedHostID == a.id }?.currentAddress, "100.64.0.10")
    }

    func testIOSPlannerPlansGetTheSameFallback() async throws {
        manager = makeManager(hostPlanner: { id, vault in
            try ConnectionPlanner.plan(hostID: id, vault: vault, platform: .ios, importedKeys: [])
        })
        scripts = [Self.fails(.timedOut)]
        let tab = try manager.open(hostID: host().id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(sessions.map(\.plan.host), ["192.168.50.10", "100.64.0.10"])
        XCTAssertEqual(sessions[0].plan.reachTimeout, .seconds(5))
    }

    // MARK: Host keys

    func testBackupAttemptTrustsTheMainAddressKeyWithoutAPrompt() async throws {
        store.trust(keyCandidate(host: "192.168.50.10", port: 2222))
        let decision = Mutex<HostKeyDecision?>(nil)
        scripts = [Self.fails(.timedOut), { s in
            s.emit(.progress(.connected(address: s.plan.host)))
            let answer = await s.evaluator.evaluate(HostKeyCandidate(host: s.plan.host, port: s.plan.port, keyType: "ssh-ed25519",
                                                                     publicKeyBlob: Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [7, 7])))
            decision.withLock { $0 = answer }
            s.emit(.connected)
            s.emit(.ready)
        }]
        let tab = try manager.open(hostID: host(port: 2222).id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(decision.withLock { $0 }, .trusted)
        XCTAssertEqual(store.check(keyCandidate(host: "100.64.0.10", port: 2222)), .known, "recorded for the backup too")
    }

    func testBackupAttemptAsksForAnUnknownKey() async throws {
        store.trust(keyCandidate(host: "192.168.50.10", blob: [1]))
        scripts = [Self.fails(.timedOut), { s in
            s.emit(.progress(.connected(address: s.plan.host)))
            _ = await s.evaluator.evaluate(HostKeyCandidate(host: s.plan.host, port: s.plan.port, keyType: "ssh-ed25519",
                                                            publicKeyBlob: Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [2])))
        }]
        let tab = try manager.open(hostID: host().id)
        await waitUntil("asking") { if case .awaitingHostKey(_, .unknown) = tab.state { true } else { false } }
    }

    func testMainAttemptNeverBorrowsTrust() async throws {
        // A key trusted for the backup address doesn't make the main address trusted.
        store.trust(keyCandidate(host: "100.64.0.10"))
        scripts = [{ s in
            _ = await s.evaluator.evaluate(HostKeyCandidate(host: s.plan.host, port: s.plan.port, keyType: "ssh-ed25519",
                                                            publicKeyBlob: Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [7, 7])))
        }]
        let tab = try manager.open(hostID: host().id)
        await waitUntil("asking") { if case .awaitingHostKey(_, .unknown) = tab.state { true } else { false } }
    }
}
