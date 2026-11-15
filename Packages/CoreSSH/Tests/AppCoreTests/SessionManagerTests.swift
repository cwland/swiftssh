import XCTest
import Synchronization
import CoreModels
import SSHCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

/// A scripted in-memory `TerminalSession`. `onStart` runs inside `start(cols:rows:)`; by default it
/// emits `.connected` then `.ready`.
private final class FakeSession: TerminalSession, Sendable {
    struct Recorded {
        var started: (cols: Int, rows: Int)?
        var inputs: [String] = []          // "send:<utf8>" or "resize:<c>x<r>"
        var commands: [String] = []
        var closeCalls = 0
        var closed = false
    }

    let plan: ConnectionPlan
    let evaluator: any HostKeyEvaluator
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let state = Mutex(Recorded())
    let onStart: @Sendable (FakeSession) async -> Void
    let commandOutput: String
    /// Per-command answers; any other command gets `commandOutput`.
    let outputsByCommand: [String: String]
    /// When false, `close()` never ends the session (to test the close-all deadline).
    let closesOnRequest: Bool

    init(plan: ConnectionPlan, evaluator: any HostKeyEvaluator,
         onStart: @escaping @Sendable (FakeSession) async -> Void,
         commandOutput: String, outputsByCommand: [String: String] = [:], closesOnRequest: Bool) {
        self.plan = plan
        self.evaluator = evaluator
        self.onStart = onStart
        self.commandOutput = commandOutput
        self.outputsByCommand = outputsByCommand
        self.closesOnRequest = closesOnRequest
        (events, continuation) = AsyncStream.makeStream()
    }

    var recorded: Recorded { state.withLock { $0 } }

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
        state.withLock { $0.started = (cols, rows) }
        await onStart(self)
    }

    func send(_ bytes: [UInt8]) async {
        state.withLock { $0.inputs.append("send:" + String(decoding: bytes, as: UTF8.self)) }
    }

    func resize(cols: Int, rows: Int) async {
        state.withLock { $0.inputs.append("resize:\(cols)x\(rows)") }
    }

    func runCommand(_ command: String) async throws -> String {
        state.withLock { $0.commands.append(command) }
        return outputsByCommand[command] ?? commandOutput
    }

    func close() async {
        state.withLock { $0.closeCalls += 1 }
        if closesOnRequest { emit(.closed(.userClosed)) }
    }
}

@MainActor
private final class FakeFactory {
    var sessions: [FakeSession] = []
    var onStart: @Sendable (FakeSession) async -> Void = { s in
        s.emit(.connected)
        s.emit(.ready)
    }
    var commandOutput = "Linux\nID=ubuntu\n"
    var outputsByCommand: [String: String] = [:]
    var closesOnRequest = true

    func make(_ plan: ConnectionPlan, _ evaluator: any HostKeyEvaluator) -> any TerminalSession {
        let s = FakeSession(plan: plan, evaluator: evaluator, onStart: onStart,
                            commandOutput: commandOutput, outputsByCommand: outputsByCommand,
                            closesOnRequest: closesOnRequest)
        sessions.append(s)
        return s
    }
}

@MainActor
final class SessionManagerTests: XCTestCase {
    private var vault: LocalVault!
    private var store: KnownHostsStore!
    private var factory: FakeFactory!
    private var manager: SessionManager!

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        store = KnownHostsStore(vault: vault)
        factory = FakeFactory()
        manager = makeManager(initialSizeTimeout: .zero)
    }

    private func makeManager(initialSizeTimeout: Duration,
                             keepAlivePolicy: (@MainActor () -> KeepAlivePolicy)? = nil,
                             agentSocket: (@MainActor () -> String?)? = nil) -> SessionManager {
        let factory = factory!
        let make: @MainActor (ConnectionPlan, any HostKeyEvaluator) -> any TerminalSession = { plan, evaluator in
            factory.make(plan, evaluator)
        }
        if let agentSocket {
            return SessionManager(vault: vault, knownHosts: store, makeSession: make,
                                  deviceName: "Test Mac", defaultUsername: "me",
                                  initialSizeTimeout: initialSizeTimeout, agentSocket: agentSocket)
        }
        if let keepAlivePolicy {
            return SessionManager(vault: vault, knownHosts: store, makeSession: make,
                                  deviceName: "Test Mac", defaultUsername: "me",
                                  initialSizeTimeout: initialSizeTimeout, keepAlivePolicy: keepAlivePolicy)
        }
        return SessionManager(vault: vault, knownHosts: store, makeSession: make,
                              deviceName: "Test Mac", defaultUsername: "me",
                              initialSizeTimeout: initialSizeTimeout)
    }

    func testPlansDefaultToTheNormalKeepAlive() async throws {
        _ = try manager.open(hostID: passwordHost().id)
        XCTAssertEqual(factory.sessions[0].plan.keepAlive, .normal)
    }

    func testEachAttemptGetsThePolicyCurrentAtThatTime() async throws {
        var current = KeepAlivePolicy.fast
        manager = makeManager(initialSizeTimeout: .zero, keepAlivePolicy: { current })
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(factory.sessions[0].plan.keepAlive, .fast)

        current = .off   // changed while the tab is open; the first session was built with .fast (asserted above)
        manager.reconnect(tabID: tab.id)
        await waitUntil("second session") { self.factory.sessions.count == 2 }
        XCTAssertEqual(factory.sessions[1].plan.keepAlive, .off)

        current = .relaxed
        _ = try manager.open(hostID: passwordHost(label: "Second").id)
        XCTAssertEqual(factory.sessions[2].plan.keepAlive, .relaxed)
    }

    func testPlansDefaultToXterm256Color() async throws {
        _ = try manager.open(hostID: passwordHost().id)
        XCTAssertEqual(factory.sessions[0].plan.terminalType, .xterm256color)
    }

    func testEachAttemptGetsTheTerminalTypeCurrentAtThatTime() async throws {
        var current = TerminalType.vt100
        let factory = factory!
        manager = SessionManager(vault: vault, knownHosts: store,
                                 makeSession: { plan, evaluator in factory.make(plan, evaluator) },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero,
                                 terminalType: { current })
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(factory.sessions[0].plan.terminalType, .vt100)

        current = .linux // open tabs keep theirs; Reconnect and new tabs use the current one
        manager.reconnect(tabID: tab.id)
        await waitUntil("second session") { factory.sessions.count == 2 }
        XCTAssertEqual(factory.sessions[1].plan.terminalType, .linux)

        current = .xterm
        _ = try manager.open(hostID: passwordHost(label: "Second").id)
        XCTAssertEqual(factory.sessions.last?.plan.terminalType, .xterm)
        XCTAssertEqual(factory.sessions.count, 3)
    }

    // MARK: Helpers

    private func waitUntil(_ what: String = "condition", timeout: TimeInterval = 2,
                           _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Lets queued main-actor work run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func passwordHost(label: String = "Web", script: String? = nil, badge: OSBadge? = nil,
                              manual: Bool = false, useSystemSSH: Bool? = nil) -> SavedHost {
        var snippetID: UUID?
        if let script { snippetID = vault.saveNow(Snippet(name: "s", script: script)).id }
        return vault.saveNow(SavedHost(label: label, address: "web.example", username: "root", password: "pw",
                                       osBadge: badge, osBadgeIsManual: manual, startupSnippetID: snippetID,
                                       useSystemSSH: useSystemSSH))
    }

    private func candidate(blob: [UInt8] = [1, 2, 3]) -> HostKeyCandidate {
        let t = Array("ssh-ed25519".utf8)
        let wire = [0, 0, 0, UInt8(t.count)] + t + blob
        return HostKeyCandidate(host: "web.example", port: 22, keyType: "ssh-ed25519", publicKeyBlob: Data(wire))
    }

    private func sends(_ s: FakeSession) -> [String] { s.recorded.inputs.filter { $0.hasPrefix("send:") } }

    // MARK: Tests

    func testOpenCreatesTabAndConnects() async throws {
        let host = passwordHost()
        let tab = try manager.open(hostID: host.id)
        XCTAssertEqual(manager.tabs.map(\.id), [tab.id])
        XCTAssertEqual(manager.selectedTabID, tab.id)
        XCTAssertEqual(tab.title, "Web")
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(factory.sessions.count, 1)
        guard case .password("pw") = factory.sessions[0].plan.credential else { return XCTFail() }
        XCTAssertNotNil(factory.sessions[0].recorded.started)
    }

    func testOpenUnknownHostThrows() async {
        XCTAssertThrowsError(try manager.open(hostID: UUID()))
        XCTAssertTrue(manager.tabs.isEmpty)
    }

    func testStartWaitsForViewSize() async throws {
        manager = makeManager(initialSizeTimeout: .seconds(60))
        let tab = try manager.open(hostID: passwordHost().id)
        await settle()
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertNil(factory.sessions[0].recorded.started, "no start before the view's size")
        manager.resize(tabID: tab.id, cols: 132, rows: 43)
        await waitUntil("connected") { tab.state == .connected }
        let started = try XCTUnwrap(factory.sessions[0].recorded.started)
        XCTAssertEqual(started.cols, 132)
        XCTAssertEqual(started.rows, 43)
    }

    func testStartFallsBackToDefaultSizeAfterTimeout() async throws {
        manager = makeManager(initialSizeTimeout: .milliseconds(50))
        let tab = try manager.open(hostID: passwordHost().id)
        await Task.yield()
        XCTAssertNil(factory.sessions[0].recorded.started)
        await waitUntil("connected") { tab.state == .connected }
        let started = try XCTUnwrap(factory.sessions[0].recorded.started)
        XCTAssertEqual(started.cols, 80)
        XCTAssertEqual(started.rows, 24)
    }

    func testReconnectStartsImmediatelyWithCurrentSize() async throws {
        manager = makeManager(initialSizeTimeout: .seconds(60))
        let tab = try manager.open(hostID: passwordHost().id)
        manager.resize(tabID: tab.id, cols: 100, rows: 30)
        await waitUntil("connected") { tab.state == .connected }
        manager.resize(tabID: tab.id, cols: 90, rows: 20)
        manager.reconnect(tabID: tab.id)
        await waitUntil("second start") { self.factory.sessions.count == 2 && self.factory.sessions[1].recorded.started != nil }
        let started = try XCTUnwrap(factory.sessions[1].recorded.started)
        XCTAssertEqual(started.cols, 90)
        XCTAssertEqual(started.rows, 20)
        await waitUntil("reconnected") { tab.state == .connected }
    }

    func testOutputIsBufferedUntilSinkThenInOrder() async throws {
        factory.onStart = { @Sendable s in
            s.emit(.connected)
            s.emit(.output(Array("one ".utf8)))
            s.emit(.output(Array("two ".utf8)))
        }
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("connected") { tab.state == .connected }
        await settle()
        var received: [UInt8] = []
        tab.outputSink = { received += $0 }
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "one two ")
        factory.sessions[0].emit(.output(Array("three".utf8)))
        await waitUntil("live output") { received.count == 13 }
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "one two three")
    }

    func testPreSinkBufferIsCappedWithMarker() async throws {
        let chunk = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        factory.onStart = { @Sendable s in
            s.emit(.connected)
            for _ in 0..<5 { s.emit(.output(chunk)) }
            s.emit(.output(Array("END".utf8)))
        }
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("connected") { tab.state == .connected }
        await settle()
        var received: [UInt8] = []
        tab.outputSink = { received += $0 }
        let marker = Array("\r\n[output truncated]\r\n".utf8)
        XCTAssertEqual(Array(received.prefix(marker.count)), marker)
        XCTAssertEqual(received.count, marker.count + 4 * 1024 * 1024)
        XCTAssertEqual(Array(received.suffix(3)), Array("END".utf8))
    }

    func testConnectedWritesLogAndLastConnected() async throws {
        factory.onStart = { @Sendable s in s.emit(.connected) }
        let host = passwordHost()
        let tab = try manager.open(hostID: host.id)
        await waitUntil("connected") { tab.state == .connected }
        await settle()
        XCTAssertTrue(vault.all(ConnectionLog.self).isEmpty, "no log before .ready")
        XCTAssertNil(vault.get(SavedHost.self, id: host.id)?.lastConnectedAt)

        factory.sessions[0].emit(.ready)
        await waitUntil("log") { !self.vault.all(ConnectionLog.self).isEmpty }
        let log = try XCTUnwrap(vault.all(ConnectionLog.self).first)
        XCTAssertEqual(log.hostID, host.id)
        XCTAssertEqual(log.hostLabel, "Web")
        XCTAssertEqual(log.username, "root")
        XCTAssertEqual(log.deviceName, "Test Mac")
        XCTAssertNil(log.endedAt)
        XCTAssertNotNil(vault.get(SavedHost.self, id: host.id)?.lastConnectedAt)
    }

    func testOSDetectionUpdatesBadgeUnlessManual() async throws {
        let auto = passwordHost(label: "Auto")
        let tab = try manager.open(hostID: auto.id)
        await waitUntil("badge") { self.vault.get(SavedHost.self, id: auto.id)?.osBadge == .ubuntu }
        XCTAssertEqual(tab.badge, .ubuntu)
        XCTAssertEqual(factory.sessions[0].recorded.commands, [OSDetector.probeCommand])

        // Once per host per app session.
        let second = try manager.open(hostID: auto.id)
        await waitUntil("second connected") { second.state == .connected }
        await settle()
        XCTAssertEqual(factory.sessions[1].recorded.commands, [])

        let manual = passwordHost(label: "Manual", badge: .debian, manual: true)
        let mtab = try manager.open(hostID: manual.id)
        await waitUntil("manual connected") { mtab.state == .connected }
        await settle()
        XCTAssertEqual(vault.get(SavedHost.self, id: manual.id)?.osBadge, .debian)
        XCTAssertEqual(mtab.badge, .debian)
    }

    func testWindowsCmdProbeAsksForTheBuild() async throws {
        factory.commandOutput = "TR_OS_ENV=Windows_NT; sh -c \"uname -s; true\"\r\n"
        factory.outputsByCommand = [
            OSDetector.windowsVersionCommand:
                "\r\nMicrosoft Windows [Version 10.0.19045.5011]\r\n    InstallationType    REG_SZ    Client\r\n",
        ]
        let host = passwordHost(label: "Win")
        let tab = try manager.open(hostID: host.id)
        await waitUntil("badge") { self.vault.get(SavedHost.self, id: host.id)?.osBadge == .windows10 }
        XCTAssertEqual(tab.badge, .windows10)
        XCTAssertEqual(factory.sessions[0].recorded.commands, [OSDetector.probeCommand, OSDetector.windowsVersionCommand])
    }

    func testPosixProbeRunsNoFollowUp() async throws {
        factory.commandOutput = "TR_OS_ENV=%OS%\nLinux\nID=debian\nTR_OS_MARKER=proxmox\n"
        let host = passwordHost(label: "PVE")
        _ = try manager.open(hostID: host.id)
        await waitUntil("badge") { self.vault.get(SavedHost.self, id: host.id)?.osBadge == .proxmox }
        await settle()
        XCTAssertEqual(factory.sessions[0].recorded.commands, [OSDetector.probeCommand])
    }

    /// "Automatic" in Host Details clears the badge; the next connection probes again even if
    /// this host was probed earlier in the app session.
    func testChoosingAutomaticProbesAgainOnNextConnection() async throws {
        let host = passwordHost(label: "Auto")
        let first = try manager.open(hostID: host.id)
        await waitUntil("badge") { self.vault.get(SavedHost.self, id: host.id)?.osBadge == .ubuntu }
        XCTAssertEqual(first.badge, .ubuntu)

        HostDetailsViewModel(vault: vault, hostID: host.id).useAutomaticOS()
        factory.commandOutput = "TR_OS_ENV=%OS%\nLinux\nID=debian\n"
        let second = try manager.open(hostID: host.id)
        await waitUntil("re-probed") { self.vault.get(SavedHost.self, id: host.id)?.osBadge == .debian }
        XCTAssertEqual(second.badge, .debian)
        XCTAssertEqual(factory.sessions[1].recorded.commands, [OSDetector.probeCommand])
    }

    /// An automatic host whose OS the probe cannot identify keeps no badge, and is probed once
    /// per app session, not on every connection.
    func testUndetectableAutomaticHostIsProbedOncePerAppSession() async throws {
        factory.commandOutput = "Unknown action 0\n"
        let host = passwordHost(label: "Router")
        _ = try manager.open(hostID: host.id)
        await waitUntil("probed") { self.factory.sessions.first?.recorded.commands == [OSDetector.probeCommand] }
        await settle()
        let second = try manager.open(hostID: host.id)
        await waitUntil("second connected") { self.factory.sessions.count == 2 }
        await settle()
        XCTAssertNil(second.badge)
        XCTAssertEqual(factory.sessions[1].recorded.commands, [])
    }

    /// The Automatic request is spent by one probe, even when the probe finds nothing.
    func testAutomaticRequestIsConsumedByOneProbe() async throws {
        factory.commandOutput = "Unknown action 0\n"
        let host = passwordHost(label: "Router")
        _ = try manager.open(hostID: host.id)
        await settle()
        HostDetailsViewModel(vault: vault, hostID: host.id).useAutomaticOS()
        _ = try manager.open(hostID: host.id)
        await waitUntil("re-probed") { self.factory.sessions.count == 2 && self.factory.sessions[1].recorded.commands == [OSDetector.probeCommand] }
        await settle()
        _ = try manager.open(hostID: host.id)
        await waitUntil("third") { self.factory.sessions.count == 3 }
        await settle()
        XCTAssertEqual(factory.sessions[2].recorded.commands, [])
    }

    func testStartupScriptIsSentAfterConnect() async throws {
        factory.onStart = { @Sendable s in s.emit(.connected) }
        let tab = try manager.open(hostID: passwordHost(script: "cd /srv").id)
        await waitUntil("connected") { tab.state == .connected }
        await settle()
        XCTAssertEqual(sends(factory.sessions[0]), [], "nothing typed before .ready")
        factory.sessions[0].emit(.ready)
        await waitUntil("script") { self.sends(self.factory.sessions[0]) == ["send:cd /srv\n"] }
    }

    func testSendAndResizeAreForwardedInOrder() async throws {
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("connected") { tab.state == .connected }
        manager.send(tabID: tab.id, Array("a".utf8))
        manager.resize(tabID: tab.id, cols: 100, rows: 30)
        manager.send(tabID: tab.id, Array("b".utf8))
        await waitUntil("inputs") { self.factory.sessions[0].recorded.inputs.count == 3 }
        XCTAssertEqual(factory.sessions[0].recorded.inputs, ["send:a", "resize:100x30", "send:b"])
    }

    func testRemoteCloseBeforeTheTerminalIsLiveKeepsTheTab() async throws {
        factory.onStart = { @Sendable s in s.emit(.connected) } // never ready
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("connected") { tab.state == .connected }
        factory.sessions[0].emit(.closed(.remoteClosed))
        await waitUntil("disconnected") { tab.state == .disconnected(nil) }
        XCTAssertEqual(manager.tabs.map(\.id), [tab.id])
    }

    func testCloseRemovesTab() async throws {
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("log") { !self.vault.all(ConnectionLog.self).isEmpty }
        manager.close(tabID: tab.id)
        XCTAssertTrue(manager.tabs.isEmpty)
        XCTAssertNil(manager.selectedTabID)
        await waitUntil("log ended") { self.vault.all(ConnectionLog.self).first?.endedAt != nil }
        XCTAssertEqual(factory.sessions[0].recorded.closeCalls, 1)
    }

    func testHostKeyPromptFlow() async throws {
        let c = candidate()
        factory.onStart = { @Sendable s in
            guard await s.evaluator.evaluate(c) == .trusted else {
                return s.emit(.closed(.failed(.hostKeyRejected)))
            }
            s.emit(.connected)
            s.emit(.ready)
        }
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("prompt") { tab.state == .awaitingHostKey(c, .unknown) }
        manager.answerHostKey(tabID: tab.id, .trusted)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(store.check(c), .known)
    }

    func testHostKeyRejectedDisconnects() async throws {
        let c = candidate()
        factory.onStart = { @Sendable s in
            guard await s.evaluator.evaluate(c) == .trusted else {
                return s.emit(.closed(.failed(.hostKeyRejected)))
            }
            s.emit(.connected)
        }
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("prompt") { tab.state == .awaitingHostKey(c, .unknown) }
        manager.answerHostKey(tabID: tab.id, .rejected)
        await waitUntil("disconnected") {
            tab.state == .disconnected(SessionError.hostKeyRejected.localizedDescription)
        }
        XCTAssertEqual(store.check(c), .unknown)
    }

    func testHostKeyNewTypeAndChangedArePassedThrough() async throws {
        let old = candidate(blob: [1])
        store.trust(old)
        let changed = candidate(blob: [9])
        factory.onStart = { @Sendable s in _ = await s.evaluator.evaluate(changed) }
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("changed prompt") {
            tab.state == .awaitingHostKey(changed, .changed(previousFingerprint: old.fingerprint))
        }
        manager.close(tabID: tab.id)

        let t = Array("ecdsa-sha2-nistp256".utf8)
        let ecdsa = HostKeyCandidate(host: "web.example", port: 22, keyType: "ecdsa-sha2-nistp256",
                                     publicKeyBlob: Data([0, 0, 0, UInt8(t.count)] + t + [5]))
        factory.onStart = { @Sendable s in _ = await s.evaluator.evaluate(ecdsa) }
        let tab2 = try manager.open(hostID: passwordHost().id)
        await waitUntil("new type prompt") {
            tab2.state == .awaitingHostKey(ecdsa, .newKeyType(knownKeyTypes: ["ssh-ed25519"]))
        }
    }

    func testClosingTabWhileAwaitingHostKeyRejectsAndLateAnswerIsIgnored() async throws {
        let c = candidate()
        let decision = Mutex<HostKeyDecision?>(nil)
        factory.onStart = { @Sendable s in
            let d = await s.evaluator.evaluate(c)
            decision.withLock { $0 = d }
        }
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("prompt") { tab.state == .awaitingHostKey(c, .unknown) }
        manager.close(tabID: tab.id)
        await waitUntil("rejected") { decision.withLock { $0 } == .rejected }
        manager.answerHostKey(tabID: tab.id, .trusted)
        await settle()
        XCTAssertEqual(store.check(c), .unknown)
        XCTAssertTrue(vault.all(KnownHost.self).isEmpty)
    }

    func testSessionEndingWhileAwaitingHostKeyRejectsPrompt() async throws {
        let c = candidate()
        let decision = Mutex<HostKeyDecision?>(nil)
        factory.onStart = { @Sendable s in
            let d = await s.evaluator.evaluate(c)
            decision.withLock { $0 = d }
        }
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("prompt") { tab.state == .awaitingHostKey(c, .unknown) }
        factory.sessions[0].emit(.closed(.failed(.timedOut)))
        await waitUntil("rejected") { decision.withLock { $0 } == .rejected }
        XCTAssertEqual(tab.state, .disconnected(SessionError.timedOut.localizedDescription))
        manager.answerHostKey(tabID: tab.id, .trusted)
        await settle()
        XCTAssertEqual(store.check(c), .unknown)
        XCTAssertTrue(vault.all(KnownHost.self).isEmpty)
    }

    func testMissingPasswordPromptsAndSaveStoresIt() async throws {
        let host = vault.saveNow(SavedHost(label: "NoPw", address: "np.example", username: "root"))
        let tab = try manager.open(hostID: host.id)
        XCTAssertEqual(tab.state, .awaitingPassword(prompt: "Password for root@np.example"))
        XCTAssertTrue(factory.sessions.isEmpty, "no connection attempt without a password")

        manager.providePassword(tabID: tab.id, "typed", save: true)
        await waitUntil("connected") { tab.state == .connected }
        guard case .password("typed") = factory.sessions[0].plan.credential else { return XCTFail() }
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.password, "typed")
    }

    func testMissingPasswordWithoutSaveDoesNotStore() async throws {
        let host = vault.saveNow(SavedHost(label: "NoPw", address: "np.example", username: "root"))
        let tab = try manager.open(hostID: host.id)
        manager.providePassword(tabID: tab.id, "typed", save: false)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertNil(vault.get(SavedHost.self, id: host.id)?.password)
    }

    func testSavingPasswordForIdentityCredentialUpdatesIdentity() async throws {
        let identity = vault.saveNow(Identity(label: "i", username: "alice"))
        let host = vault.saveNow(SavedHost(label: "H", address: "h.example", identityID: identity.id))
        let tab = try manager.open(hostID: host.id)
        XCTAssertEqual(tab.state, .awaitingPassword(prompt: "Password for alice@h.example"))
        manager.providePassword(tabID: tab.id, "secret", save: true)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(vault.get(Identity.self, id: identity.id)?.password, "secret")
        XCTAssertNil(vault.get(SavedHost.self, id: host.id)?.password)
    }

    /// The server accepts only "good"; every other password is rejected.
    private func acceptOnly(_ good: String) {
        factory.onStart = { @Sendable s in
            if case .password(good) = s.plan.credential {
                s.emit(.connected)
                s.emit(.ready)
            } else {
                s.emit(.closed(.failed(.authenticationFailed)))
            }
        }
    }

    func testMistypedPasswordWithSaveKeepsStoredPasswordAndRightOneIsSaved() async throws {
        acceptOnly("good")
        let host = passwordHost() // stored "pw", which the server now rejects
        let tab = try manager.open(hostID: host.id)
        await waitUntil("prompt") {
            tab.state == .awaitingPassword(prompt: "Password for root@web.example (the saved one was rejected)")
        }
        manager.providePassword(tabID: tab.id, "typo", save: true)
        await waitUntil("rejected prompt") {
            tab.state == .awaitingPassword(prompt: "Password for root@web.example (that password was rejected)")
        }
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.password, "pw",
                       "a rejected password must not replace the stored one")
        manager.providePassword(tabID: tab.id, "good", save: true)
        await waitUntil("connected") { tab.state == .connected }
        await waitUntil("saved") { self.vault.get(SavedHost.self, id: host.id)?.password == "good" }
    }

    func testSavedPasswordIsStoredOnlyWhenSessionIsReady() async throws {
        factory.onStart = { @Sendable s in s.emit(.connected) }
        let identity = vault.saveNow(Identity(label: "i", username: "alice"))
        let host = vault.saveNow(SavedHost(label: "H", address: "h.example", identityID: identity.id))
        let tab = try manager.open(hostID: host.id)
        manager.providePassword(tabID: tab.id, "secret", save: true)
        await waitUntil("connected") { tab.state == .connected }
        await settle()
        XCTAssertNil(vault.get(Identity.self, id: identity.id)?.password, "not stored before .ready")
        factory.sessions[0].emit(.ready)
        await waitUntil("stored on identity") { self.vault.get(Identity.self, id: identity.id)?.password == "secret" }
        XCTAssertNil(vault.get(SavedHost.self, id: host.id)?.password)
    }

    func testMistypedPasswordWithSaveOnIdentityKeepsIdentityPassword() async throws {
        acceptOnly("good")
        let identity = vault.saveNow(Identity(label: "i", username: "alice", password: "old"))
        let host = vault.saveNow(SavedHost(label: "H", address: "h.example", identityID: identity.id))
        let tab = try manager.open(hostID: host.id)
        await waitUntil("prompt") { if case .awaitingPassword = tab.state { true } else { false } }
        manager.providePassword(tabID: tab.id, "typo", save: true)
        await waitUntil("rejected prompt") {
            tab.state == .awaitingPassword(prompt: "Password for alice@h.example (that password was rejected)")
        }
        XCTAssertEqual(vault.get(Identity.self, id: identity.id)?.password, "old")
        manager.providePassword(tabID: tab.id, "good", save: true)
        await waitUntil("connected") { tab.state == .connected }
        await waitUntil("saved") { self.vault.get(Identity.self, id: identity.id)?.password == "good" }
        XCTAssertNil(vault.get(SavedHost.self, id: host.id)?.password)
    }

    func testEnteredPasswordIsForgottenOnceReadySoReconnectAsksAgain() async throws {
        let host = vault.saveNow(SavedHost(label: "NoPw", address: "np.example", username: "root"))
        let tab = try manager.open(hostID: host.id)
        manager.providePassword(tabID: tab.id, "typed", save: false)
        await waitUntil("connected") { tab.state == .connected }
        await waitUntil("log") { !self.vault.all(ConnectionLog.self).isEmpty }
        manager.reconnect(tabID: tab.id)
        XCTAssertEqual(tab.state, .awaitingPassword(prompt: "Password for root@np.example"))
        XCTAssertEqual(factory.sessions.count, 1)
    }

    func testReconnectAfterReadyUsesVaultPasswordNotEnteredOne() async throws {
        let host = vault.saveNow(SavedHost(label: "NoPw", address: "np.example", username: "root"))
        let tab = try manager.open(hostID: host.id)
        manager.providePassword(tabID: tab.id, "typed", save: false)
        await waitUntil("connected") { tab.state == .connected }
        await waitUntil("log") { !self.vault.all(ConnectionLog.self).isEmpty }
        var edited = try XCTUnwrap(vault.get(SavedHost.self, id: host.id))
        edited.password = "fromVault"
        vault.saveNow(edited)
        manager.reconnect(tabID: tab.id)
        await waitUntil("second session") { self.factory.sessions.count == 2 }
        guard case .password("fromVault") = factory.sessions[1].plan.credential else {
            return XCTFail("expected the vault password, got \(factory.sessions[1].plan.credential)")
        }
    }

    func testCanSavePasswordOnlyForSavedHosts() async throws {
        let hostTab = try manager.open(hostID: passwordHost().id)
        XCTAssertTrue(hostTab.canSavePassword)
        let quick = manager.open(quickConnect: QuickConnectTarget(username: nil, host: "q.example", port: 22))
        XCTAssertFalse(quick.canSavePassword)
    }

    func testSavedHostIDForHostTab() async throws {
        let host = passwordHost()
        let tab = try manager.open(hostID: host.id)
        XCTAssertEqual(tab.savedHostID, host.id)
    }

    func testSavedHostIDNilForQuickConnect() async throws {
        let tab = manager.open(quickConnect: QuickConnectTarget(username: nil, host: "q.example", port: 22))
        XCTAssertNil(tab.savedHostID)
    }

    func testSystemSSHWithoutPasswordStartsWithoutPrompt() async throws {
        let host = vault.saveNow(SavedHost(label: "S", address: "s.example", username: "root", useSystemSSH: true))
        let tab = try manager.open(hostID: host.id)
        await waitUntil("connected") { tab.state == .connected }
        guard case .none = factory.sessions[0].plan.credential else { return XCTFail() }
    }

    func testQuickConnectPromptsForPassword() async throws {
        let tab = manager.open(quickConnect: QuickConnectTarget(username: nil, host: "q.example", port: 2200))
        XCTAssertEqual(tab.state, .awaitingPassword(prompt: "Password for me@q.example"))
        manager.providePassword(tabID: tab.id, "pw", save: true)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(factory.sessions[0].plan.port, 2200)
    }

    func testRejectedPasswordPromptsWithoutChangingStoredCredentials() async throws {
        factory.onStart = { @Sendable s in
            if case .password("pw") = s.plan.credential {
                s.emit(.closed(.failed(.authenticationFailed)))
            } else {
                s.emit(.connected)
                s.emit(.ready)
            }
        }
        let host = passwordHost()
        let tab = try manager.open(hostID: host.id)
        await waitUntil("prompt") {
            tab.state == .awaitingPassword(prompt: "Password for root@web.example (the saved one was rejected)")
        }
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.password, "pw")
        manager.providePassword(tabID: tab.id, "new", save: false)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.password, "pw")
        XCTAssertEqual(manager.tabs.count, 1)
    }

    func testCancellingPasswordPromptDisconnectsAndReconnectAsksAgain() async throws {
        let host = vault.saveNow(SavedHost(label: "NoPw", address: "np.example", username: "root"))
        let tab = try manager.open(hostID: host.id)
        XCTAssertEqual(tab.state, .awaitingPassword(prompt: "Password for root@np.example"))
        manager.cancelPasswordPrompt(tabID: tab.id)
        XCTAssertEqual(tab.state, .disconnected(nil))
        XCTAssertEqual(manager.tabs.count, 1, "the tab stays open")
        XCTAssertTrue(factory.sessions.isEmpty)
        manager.reconnect(tabID: tab.id)
        XCTAssertEqual(tab.state, .awaitingPassword(prompt: "Password for root@np.example"))
    }

    func testCancellingPasswordPromptIgnoredWhenNotAsking() async throws {
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("connected") { tab.state == .connected }
        manager.cancelPasswordPrompt(tabID: tab.id)
        XCTAssertEqual(tab.state, .connected)
        XCTAssertEqual(factory.sessions[0].recorded.closeCalls, 0)
    }

    func testCancellingRejectedPasswordPromptDisconnects() async throws {
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.authenticationFailed))) }
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("prompt") { if case .awaitingPassword = tab.state { true } else { false } }
        manager.cancelPasswordPrompt(tabID: tab.id)
        XCTAssertEqual(tab.state, .disconnected(nil))
    }

    func testRejectedKeyDisconnectsWithoutPrompt() async throws {
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.authenticationFailed))) }
        let key = vault.saveNow(SSHKey(label: "k", keyType: .ed25519, publicKey: "p", privateKey: "PEM"))
        let host = vault.saveNow(SavedHost(label: "K", address: "k.example", username: "root", sshKeyID: key.id))
        let tab = try manager.open(hostID: host.id)
        await waitUntil("disconnected") {
            tab.state == .disconnected("The server rejected the key for root@k.example.")
        }
    }

    func testOtherFailuresDisconnectWithDescription() async throws {
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.keyUnreadable))) }
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("disconnected") {
            tab.state == .disconnected(SessionError.keyUnreadable.localizedDescription)
        }
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.timedOut))) }
        manager.reconnect(tabID: tab.id)
        await waitUntil("timed out") { tab.state == .disconnected(SessionError.timedOut.localizedDescription) }
    }

    func testReconnectReusesTab() async throws {
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("log") { self.vault.all(ConnectionLog.self).count == 1 }
        factory.sessions[0].emit(.closed(.failed(.timedOut)))
        await waitUntil("disconnected") { tab.state == .disconnected(SessionError.timedOut.localizedDescription) }

        manager.reconnect(tabID: tab.id)
        await waitUntil("reconnected") { tab.state == .connected && self.vault.all(ConnectionLog.self).count == 2 }
        XCTAssertEqual(manager.tabs.map(\.id), [tab.id])
        XCTAssertEqual(factory.sessions.count, 2)
        let logs = vault.all(ConnectionLog.self)
        XCTAssertNotEqual(logs[0].id, logs[1].id)
        XCTAssertNotNil(logs[0].endedAt)
        XCTAssertNil(logs[1].endedAt)
    }

    func testReconnectWhileConnectedClosesOldSession() async throws {
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("log") { self.vault.all(ConnectionLog.self).count == 1 }
        manager.reconnect(tabID: tab.id)
        await waitUntil("second log") { self.vault.all(ConnectionLog.self).count == 2 }
        await waitUntil("old log ended") { self.vault.all(ConnectionLog.self)[0].endedAt != nil }
        XCTAssertEqual(factory.sessions[0].recorded.closeCalls, 1)
        XCTAssertEqual(tab.state, .connected, "old session's close must not affect the new state")
        XCTAssertEqual(manager.tabs.count, 1)
    }

    func testCloseAllEndsEverySession() async throws {
        let a = try manager.open(hostID: passwordHost(label: "A").id)
        let b = try manager.open(hostID: passwordHost(label: "B").id)
        await waitUntil("connected") { a.state == .connected && b.state == .connected }
        await waitUntil("logs") { self.vault.all(ConnectionLog.self).count == 2 }
        await manager.closeAll()
        XCTAssertTrue(manager.tabs.isEmpty)
        XCTAssertEqual(factory.sessions.map { $0.recorded.closeCalls }, [1, 1])
        XCTAssertTrue(vault.all(ConnectionLog.self).allSatisfy { $0.endedAt != nil })
    }

    func testCloseAllGivesUpAfterDeadline() async throws {
        factory.closesOnRequest = false
        manager.closeAllTimeout = .milliseconds(200)
        let a = try manager.open(hostID: passwordHost().id)
        await waitUntil("connected") { a.state == .connected }
        let started = Date()
        await manager.closeAll()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertEqual(factory.sessions[0].recorded.closeCalls, 1)
    }
}

// MARK: - Auto-reconnect

/// A `sleep` the test controls: every call waits until `elapseAll()`, which ends it normally (as if the
/// time had passed), even when the sleeping task was cancelled meanwhile — so a countdown that was
/// cancelled must not act on a sleep that returns anyway.
private final class FakeSleeper: Sendable {
    private struct State {
        var requests: [Duration] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.requests.append(duration)
                $0.waiters.append(continuation)
            }
        }
    }

    var requests: [Duration] { state.withLock { $0.requests } }
    var pending: Int { state.withLock { $0.waiters.count } }

    func elapseAll() {
        let waiters = state.withLock { state in
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
final class SessionManagerAutoReconnectTests: XCTestCase {
    private var vault: LocalVault!
    private var store: KnownHostsStore!
    private var factory: FakeFactory!
    private var sleeper: FakeSleeper!
    private var manager: SessionManager!
    private var enabled = true
    private var policy = KeepAlivePolicy.fast
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let broken = SessionError.connectionFailed("Broken pipe")

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        store = KnownHostsStore(vault: vault)
        factory = FakeFactory()
        sleeper = FakeSleeper()
        enabled = true
        let factory = factory!
        let sleeper = sleeper!
        let now = now
        manager = SessionManager(vault: vault, knownHosts: store,
                                 makeSession: { plan, evaluator in factory.make(plan, evaluator) },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero,
                                 keepAlivePolicy: { [unowned self] in self.policy },
                                 autoReconnectEnabled: { [unowned self] in self.enabled },
                                 now: { now },
                                 sleep: { try await sleeper.sleep($0) })
    }

    override func tearDown() async throws {
        sleeper?.elapseAll() // let any countdown tasks finish
    }

    // MARK: Helpers

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
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func passwordHost(label: String) -> SavedHost {
        vault.saveNow(SavedHost(label: label, address: "\(label.lowercased()).example", username: "root", password: "pw"))
    }

    private func isWaiting(_ tab: TerminalTab, attempt: Int) -> Bool {
        if case .waiting(attempt, _, _) = tab.autoReconnect { true } else { false }
    }

    /// A tab whose session became ready (its log exists).
    private func readyTab(label: String = "Web", file: StaticString = #filePath, line: UInt = #line) async throws -> TerminalTab {
        let logs = vault.all(ConnectionLog.self).count
        let tab = try manager.open(hostID: passwordHost(label: label).id)
        await waitUntil("ready", { tab.state == .connected && self.vault.all(ConnectionLog.self).count == logs + 1 },
                        file: file, line: line)
        return tab
    }

    /// A ready tab whose connection then dropped: counting down to try 1.
    private func droppedTab(label: String = "Web", file: StaticString = #filePath, line: UInt = #line) async throws -> TerminalTab {
        let tab = try await readyTab(label: label, file: file, line: line)
        factory.sessions.last!.emit(.closed(.failed(broken)))
        await waitUntil("waiting", { self.isWaiting(tab, attempt: 1) }, file: file, line: line)
        return tab
    }

    // MARK: Tests

    func testReconnectScheduleValues() async {
        XCTAssertEqual(ReconnectSchedule.delays, [5, 10, 20, 30, 30])
        XCTAssertEqual(ReconnectSchedule.maxAttempts, 5)
        XCTAssertEqual((1...5).map { ReconnectSchedule.delay(beforeAttempt: $0) }, [5, 10, 20, 30, 30])
        XCTAssertNil(ReconnectSchedule.delay(beforeAttempt: 0))
        XCTAssertNil(ReconnectSchedule.delay(beforeAttempt: -1))
        XCTAssertNil(ReconnectSchedule.delay(beforeAttempt: 6))
    }

    func testDropAfterReadyStartsTheCountdown() async throws {
        for (index, error) in [broken, SessionError.timedOut].enumerated() {
            let tab = try await readyTab(label: "T\(index)")
            XCTAssertNil(tab.autoReconnect)
            factory.sessions.last!.emit(.closed(.failed(error)))
            await waitUntil("waiting") { tab.autoReconnect != nil }
            XCTAssertEqual(tab.autoReconnect, .waiting(attempt: 1, deadline: now.addingTimeInterval(5), delay: 5))
            XCTAssertEqual(tab.state, .disconnected(error.localizedDescription), "the banner shows the drop")
            XCTAssertEqual(sleeper.requests.last, .seconds(5))
        }
        XCTAssertEqual(manager.waitingForReconnectCount, 2)
        await settle()
        XCTAssertEqual(factory.sessions.count, 2, "no try before the countdown ends")
    }

    func testDropBeforeReadyDoesNotStartTheCountdown() async throws {
        factory.onStart = { @Sendable s in
            s.emit(.connected)
            s.emit(.closed(.failed(.connectionFailed("Broken pipe"))))
        }
        let tab = try manager.open(hostID: passwordHost(label: "Web").id)
        await waitUntil("disconnected") { tab.state == .disconnected(self.broken.localizedDescription) }
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.timedOut))) }
        manager.reconnect(tabID: tab.id)
        await waitUntil("timed out") { tab.state == .disconnected(SessionError.timedOut.localizedDescription) }
        await settle()
        XCTAssertNil(tab.autoReconnect)
        XCTAssertTrue(sleeper.requests.isEmpty)
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
    }

    func testOtherEndsAfterReadyDoNotStartTheCountdown() async throws {
        let reasons: [SessionEndReason] = [
            .remoteClosed, .failed(.authenticationFailed), .failed(.hostKeyRejected),
            .failed(.hostKeyChanged(previous: "SHA256:old", presented: "SHA256:new")), .failed(.keyUnreadable),
            .failed(.unsupportedKey("rsa")),
        ]
        for (index, reason) in reasons.enumerated() {
            let tab = try await readyTab(label: "R\(index)")
            factory.sessions.last!.emit(.closed(reason))
            // `.remoteClosed` (exit) closes the tab; the others keep it disconnected.
            await waitUntil("ended") { tab.state != .connected || !self.manager.tabs.contains { $0 === tab } }
            await settle()
            XCTAssertNil(tab.autoReconnect, "\(reason)")
        }
        // The user's own close (here reported by the session) closes the tab.
        let tab = try await readyTab(label: "U")
        factory.sessions.last!.emit(.closed(.userClosed))
        await waitUntil("closed") { !self.manager.tabs.contains { $0 === tab } }
        await settle()
        XCTAssertNil(tab.autoReconnect)
        XCTAssertTrue(sleeper.requests.isEmpty)
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
        XCTAssertEqual(factory.sessions.count, reasons.count + 1)
    }

    func testCountdownStartsATryAndReadyClearsTheState() async throws {
        let tab = try await droppedTab()
        policy = .relaxed // the try uses the policy current when it starts, like Reconnect
        factory.onStart = { @Sendable s in s.emit(.connected) } // connecting; not ready yet
        sleeper.elapseAll()
        await waitUntil("try") { self.factory.sessions.count == 2 }
        XCTAssertEqual(tab.autoReconnect, .reconnecting(attempt: 1))
        XCTAssertEqual(manager.waitingForReconnectCount, 1)
        let attempt = factory.sessions[1]
        guard case .password("pw") = attempt.plan.credential else { return XCTFail("saved credentials") }
        XCTAssertEqual(attempt.plan.keepAlive, .relaxed)

        attempt.emit(.ready)
        await waitUntil("cleared") { tab.autoReconnect == nil }
        XCTAssertEqual(tab.state, .connected)
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
        XCTAssertEqual(vault.all(ConnectionLog.self).count, 2, "a new log for the new session")

        // A later drop counts from the first try again.
        attempt.emit(.closed(.failed(.timedOut)))
        await waitUntil("waiting again") { self.isWaiting(tab, attempt: 1) }
        XCTAssertEqual(sleeper.requests, [.seconds(5), .seconds(5)])
    }

    func testBackoffThenGiveUpAfterFiveTries() async throws {
        let tab = try await droppedTab()
        let refused = SessionError.connectionFailed("Connection refused")
        // Each try fails like a network error: some before, some after the session showed as connected.
        let tries = Mutex(0)
        factory.onStart = { @Sendable s in
            let n = tries.withLock { $0 += 1; return $0 }
            if n.isMultiple(of: 2) { s.emit(.connected) }
            s.emit(.closed(.failed(n == 3 ? .timedOut : refused)))
        }
        let delays: [TimeInterval] = [5, 10, 20, 30, 30]
        for attempt in 1...5 {
            await waitUntil("waiting \(attempt)") { self.isWaiting(tab, attempt: attempt) }
            XCTAssertEqual(tab.autoReconnect, .waiting(attempt: attempt, deadline: now.addingTimeInterval(delays[attempt - 1]),
                                                       delay: delays[attempt - 1]))
            XCTAssertEqual(manager.waitingForReconnectCount, 1)
            XCTAssertEqual(factory.sessions.count, attempt)
            sleeper.elapseAll()
            await waitUntil("try \(attempt)") { self.factory.sessions.count == attempt + 1 }
        }
        await waitUntil("gave up") { tab.autoReconnect == .gaveUp(attempts: 5) }
        XCTAssertEqual(sleeper.requests, delays.map { .seconds($0) })
        XCTAssertEqual(tab.state, .disconnected(refused.localizedDescription))
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
        await settle()
        XCTAssertEqual(factory.sessions.count, 6)
        XCTAssertEqual(sleeper.pending, 0)

        // Reconnect by hand clears it.
        factory.onStart = { @Sendable s in
            s.emit(.connected)
            s.emit(.ready)
        }
        manager.reconnect(tabID: tab.id)
        XCTAssertNil(tab.autoReconnect)
        await waitUntil("connected") { tab.state == .connected }
    }

    func testATryFailingAnotherWayStopsAutoReconnect() async throws {
        let errors: [SessionError] = [.authenticationFailed, .hostKeyRejected,
                                      .hostKeyChanged(previous: "SHA256:old", presented: "SHA256:new"),
                                      .keyUnreadable, .unsupportedKey("rsa")]
        for (index, error) in errors.enumerated() {
            factory.onStart = { @Sendable s in
                s.emit(.connected)
                s.emit(.ready)
            }
            let tab = try await droppedTab(label: "E\(index)")
            let before = factory.sessions.count
            factory.onStart = { @Sendable s in s.emit(.closed(.failed(error))) }
            sleeper.elapseAll()
            await waitUntil("try") { self.factory.sessions.count == before + 1 }
            await waitUntil("stopped") { tab.autoReconnect == nil }
            if error == .authenticationFailed {
                XCTAssertEqual(tab.state, .awaitingPassword(prompt: "Password for root@e\(index).example (the saved one was rejected)"))
            } else {
                XCTAssertEqual(tab.state, .disconnected(error.localizedDescription))
            }
            await settle()
            XCTAssertEqual(sleeper.pending, 0, "\(error)")
            XCTAssertEqual(factory.sessions.count, before + 1)
        }
    }

    func testATryThatNeedsATypedPasswordStopsAndShowsThePrompt() async throws {
        let host = vault.saveNow(SavedHost(label: "NoPw", address: "np.example", username: "root"))
        let tab = try manager.open(hostID: host.id)
        manager.providePassword(tabID: tab.id, "typed", save: false)
        await waitUntil("ready") { !self.vault.all(ConnectionLog.self).isEmpty }
        factory.sessions[0].emit(.closed(.failed(broken)))
        await waitUntil("waiting") { self.isWaiting(tab, attempt: 1) }
        sleeper.elapseAll()
        await waitUntil("prompt") { tab.state == .awaitingPassword(prompt: "Password for root@np.example") }
        XCTAssertNil(tab.autoReconnect)
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
        XCTAssertEqual(factory.sessions.count, 1, "no connection without the password")
    }

    /// System ssh without a stored secret asks in the terminal: once that try shows the terminal, the
    /// user may have to type, so it is no longer automatic.
    func testATryAskingInTheTerminalIsNoLongerAutomatic() async throws {
        let host = vault.saveNow(SavedHost(label: "S", address: "s.example", username: "root", useSystemSSH: true))
        let tab = try manager.open(hostID: host.id)
        await waitUntil("ready") { !self.vault.all(ConnectionLog.self).isEmpty }
        factory.sessions[0].emit(.closed(.failed(broken)))
        await waitUntil("waiting") { self.isWaiting(tab, attempt: 1) }
        factory.onStart = { @Sendable s in s.emit(.connected) } // ssh's password prompt is in the terminal
        sleeper.elapseAll()
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertNil(tab.autoReconnect)
        factory.sessions[1].emit(.closed(.failed(.connectionFailed("Connection reset"))))
        await waitUntil("disconnected") { tab.state != .connected }
        await settle()
        XCTAssertNil(tab.autoReconnect, "a drop before ready of a manual session does not start a countdown")
        XCTAssertEqual(sleeper.requests, [.seconds(5)])
    }

    func testStopAutoReconnectCancelsTheCountdown() async throws {
        let tab = try await droppedTab()
        manager.stopAutoReconnect(tabID: tab.id)
        XCTAssertNil(tab.autoReconnect)
        XCTAssertEqual(tab.state, .disconnected(broken.localizedDescription), "the banner stays")
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
        sleeper.elapseAll()
        await settle()
        XCTAssertEqual(factory.sessions.count, 1, "no stray try")
        XCTAssertNil(tab.autoReconnect)
        manager.stopAutoReconnect(tabID: tab.id) // nothing to stop: ignored
        XCTAssertEqual(tab.state, .disconnected(broken.localizedDescription))
    }

    func testStopAutoReconnectDuringATryEndsIt() async throws {
        let tab = try await droppedTab()
        factory.onStart = { @Sendable s in s.emit(.connected) } // never becomes ready
        sleeper.elapseAll()
        await waitUntil("try") { self.factory.sessions.count == 2 }
        await waitUntil("reconnecting") { tab.autoReconnect == .reconnecting(attempt: 1) }
        manager.stopAutoReconnect(tabID: tab.id)
        XCTAssertNil(tab.autoReconnect)
        XCTAssertEqual(tab.state, .disconnected(broken.localizedDescription))
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
        await waitUntil("try closed") { self.factory.sessions[1].recorded.closeCalls == 1 }
        await settle()
        XCTAssertEqual(tab.state, .disconnected(broken.localizedDescription), "the try's end changes nothing")
        XCTAssertNil(tab.autoReconnect)
        XCTAssertEqual(factory.sessions.count, 2)
    }

    func testCloseCancelsTheCountdown() async throws {
        let tab = try await droppedTab()
        manager.close(tabID: tab.id)
        XCTAssertNil(tab.autoReconnect)
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
        sleeper.elapseAll()
        await settle()
        XCTAssertEqual(factory.sessions.count, 1, "no stray try")
        XCTAssertTrue(manager.tabs.isEmpty)
    }

    func testReconnectByHandCancelsTheCountdown() async throws {
        let tab = try await droppedTab()
        manager.reconnect(tabID: tab.id)
        XCTAssertNil(tab.autoReconnect)
        await waitUntil("reconnected") { tab.state == .connected }
        XCTAssertEqual(factory.sessions.count, 2)
        sleeper.elapseAll()
        await settle()
        XCTAssertEqual(factory.sessions.count, 2, "no stray try")
        XCTAssertEqual(tab.state, .connected)
        XCTAssertNil(tab.autoReconnect)
    }

    func testCloseAllCancelsTheCountdowns() async throws {
        let a = try await droppedTab(label: "A")
        let b = try await droppedTab(label: "B")
        await manager.closeAll()
        XCTAssertNil(a.autoReconnect)
        XCTAssertNil(b.autoReconnect)
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
        sleeper.elapseAll()
        await settle()
        XCTAssertEqual(factory.sessions.count, 2, "no stray try")
    }

    func testReconnectWaitingNowStartsEveryWaitingTab() async throws {
        let a = try await droppedTab(label: "A")
        let b = try await droppedTab(label: "B")
        let c = try await readyTab(label: "C")
        XCTAssertEqual(manager.waitingForReconnectCount, 2)
        factory.onStart = { @Sendable s in s.emit(.connected) }
        manager.reconnectWaitingNow()
        XCTAssertEqual(a.autoReconnect, .reconnecting(attempt: 1))
        XCTAssertEqual(b.autoReconnect, .reconnecting(attempt: 1))
        XCTAssertNil(c.autoReconnect)
        XCTAssertEqual(manager.waitingForReconnectCount, 2, "reconnecting tabs still count")
        await waitUntil("tries") { self.factory.sessions.count == 5 }
        XCTAssertEqual(Set(factory.sessions[3...].map(\.plan.label)), ["A", "B"])
        XCTAssertEqual(c.state, .connected, "a connected tab is left alone")

        sleeper.elapseAll()
        await settle()
        XCTAssertEqual(factory.sessions.count, 5, "the countdowns were cancelled")
        manager.reconnectWaitingNow() // nothing waiting: nothing happens
        await settle()
        XCTAssertEqual(factory.sessions.count, 5)

        factory.sessions[3].emit(.ready)
        factory.sessions[4].emit(.ready)
        await waitUntil("ready") { a.autoReconnect == nil && b.autoReconnect == nil }
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
    }

    func testDisabledAutoReconnectNeverStarts() async throws {
        enabled = false
        let tab = try await readyTab()
        factory.sessions[0].emit(.closed(.failed(broken)))
        await waitUntil("disconnected") { tab.state == .disconnected(self.broken.localizedDescription) }
        await settle()
        XCTAssertNil(tab.autoReconnect)
        XCTAssertTrue(sleeper.requests.isEmpty)
        XCTAssertEqual(factory.sessions.count, 1)
    }

    func testTurningAutoReconnectOffStopsFurtherTries() async throws {
        let tab = try await droppedTab()
        enabled = false
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.connectionFailed("Connection refused")))) }
        sleeper.elapseAll() // the try already counted down starts
        await waitUntil("try") { self.factory.sessions.count == 2 }
        await waitUntil("stopped") { tab.autoReconnect == nil }
        await settle()
        XCTAssertEqual(sleeper.requests, [.seconds(5)])
        XCTAssertEqual(factory.sessions.count, 2)
    }
}

// MARK: - 1Password SSH agent

extension SessionManagerTests {
    private static let noAgentMessage =
        "1Password's SSH agent wasn't found. Turn on \u{201C}Use the SSH agent\u{201D} in 1Password \u{2192} Settings \u{2192} Developer."

    private func agentHost(_ choice: AgentKeyChoice = AgentKeyChoice(publicKey: "ssh-ed25519 AAAA pin")) -> SavedHost {
        vault.saveNow(SavedHost(label: "Agent", address: "agent.example", username: "root", password: "pw",
                                agentKey: choice))
    }

    func testAgentPlanUsesTheSocketAtConnectTime() async throws {
        let socket = SocketBox("/tmp/first.sock")
        manager = makeManager(initialSizeTimeout: .zero, agentSocket: { socket.path })
        let tab = try manager.open(hostID: agentHost().id)
        await waitUntil("connected") { tab.state == .connected }
        let plan = factory.sessions[0].plan
        guard case .agent("/tmp/first.sock", "ssh-ed25519 AAAA pin") = plan.credential else { return XCTFail("\(plan.credential)") }
        XCTAssertEqual(plan.engine, .systemSSH)
        XCTAssertNil(tab.suggestedAction)

        socket.path = "/tmp/second.sock" // read again for every attempt
        manager.reconnect(tabID: tab.id)
        await waitUntil("second session") { self.factory.sessions.count == 2 }
        guard case .agent("/tmp/second.sock", _) = factory.sessions[1].plan.credential else {
            return XCTFail("\(factory.sessions[1].plan.credential)")
        }
    }

    func testUnpinnedAgentKeyPassesNoPublicKey() async throws {
        manager = makeManager(initialSizeTimeout: .zero, agentSocket: { "/tmp/a.sock" })
        let tab = try manager.open(hostID: agentHost(AgentKeyChoice(publicKey: nil)).id)
        await waitUntil("connected") { tab.state == .connected }
        guard case .agent("/tmp/a.sock", nil) = factory.sessions[0].plan.credential else {
            return XCTFail("\(factory.sessions[0].plan.credential)")
        }
    }

    func testMissingAgentSocketDisconnectsWithSetupSuggestion() async throws {
        let socket = SocketBox(nil)
        manager = makeManager(initialSizeTimeout: .zero, agentSocket: { socket.path })
        let tab = try manager.open(hostID: agentHost().id)
        XCTAssertEqual(tab.state, .disconnected(Self.noAgentMessage))
        XCTAssertEqual(tab.suggestedAction, .openOnePasswordSetup)
        XCTAssertTrue(factory.sessions.isEmpty, "no session without a socket")

        // The default provider has no socket either.
        manager = makeManager(initialSizeTimeout: .zero)
        let other = try manager.open(hostID: agentHost().id)
        XCTAssertEqual(other.state, .disconnected(Self.noAgentMessage))
        XCTAssertEqual(other.suggestedAction, .openOnePasswordSetup)

        // Once the agent is there, a new attempt clears the suggestion.
        manager = makeManager(initialSizeTimeout: .zero, agentSocket: { socket.path })
        let retried = try manager.open(hostID: agentHost().id)
        XCTAssertEqual(retried.suggestedAction, .openOnePasswordSetup)
        socket.path = "/tmp/a.sock"
        manager.reconnect(tabID: retried.id)
        XCTAssertNil(retried.suggestedAction)
        await waitUntil("connected") { retried.state == .connected }
    }

    func testPasswordHostsNeverAskForTheAgent() async throws {
        let asked = SocketBox(nil)
        manager = makeManager(initialSizeTimeout: .zero, agentSocket: { asked.reads += 1; return nil })
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(asked.reads, 0)
        XCTAssertNil(tab.suggestedAction)
        guard case .password("pw") = factory.sessions[0].plan.credential else { return XCTFail() }
    }

    func testRejectedAgentKeyMessage() async throws {
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.authenticationFailed))) }
        manager = makeManager(initialSizeTimeout: .zero, agentSocket: { "/tmp/a.sock" })
        let tab = try manager.open(hostID: agentHost().id)
        await waitUntil("disconnected") {
            tab.state == .disconnected("The server didn't accept the key from 1Password's SSH agent for root@agent.example. Either the key's public half isn't in ~/.ssh/authorized_keys on the server, or 1Password is locked \u{2014} unlock it and try again.")
        }
        XCTAssertEqual(tab.suggestedAction, .openOnePasswordSetup, "1Password may hold another key, or be locked")
    }

    func testUnreachableAgentDisconnectsWithItsMessageAndSetupSuggestion() async throws {
        let unreachable = SessionError.agentUnavailable(
            "Couldn't reach 1Password's SSH agent. Make sure 1Password is running and unlocked, and that Termius Reimagined may access it.")
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(unreachable))) }
        manager = makeManager(initialSizeTimeout: .zero, agentSocket: { "/tmp/a.sock" })
        let tab = try manager.open(hostID: agentHost().id)
        await waitUntil("disconnected") { tab.state == .disconnected(unreachable.localizedDescription) }
        XCTAssertEqual(tab.state, .disconnected(
            "Couldn't reach 1Password's SSH agent. Make sure 1Password is running and unlocked, and that Termius Reimagined may access it."))
        XCTAssertEqual(tab.suggestedAction, .openOnePasswordSetup)
        XCTAssertNil(tab.autoReconnect)
    }

    func testRejectedKeyWithoutTheAgentSuggestsNothing() async throws {
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.authenticationFailed))) }
        let key = vault.saveNow(SSHKey(label: "k", keyType: .ed25519, publicKey: "p", privateKey: "PEM"))
        let tab = try manager.open(hostID: vault.saveNow(SavedHost(label: "K", address: "k.example", username: "root",
                                                                   sshKeyID: key.id)).id)
        await waitUntil("disconnected") { tab.state == .disconnected("The server rejected the key for root@k.example.") }
        XCTAssertNil(tab.suggestedAction)
    }
}

@MainActor
private final class SocketBox {
    var path: String?
    var reads = 0
    init(_ path: String?) { self.path = path }
}

// MARK: - Secrets from 1Password

/// A scripted `OnePasswordCLI`: `answer` decides each `read`; reads are recorded.
private final class FakeOnePassword: OnePasswordCLI, Sendable {
    private let state = Mutex<(reads: [String], cancelled: Int)>(([], 0))
    let answer: Mutex<@Sendable (String) async throws(OnePasswordError) -> String>

    init(_ answer: @escaping @Sendable (String) async throws(OnePasswordError) -> String) {
        self.answer = Mutex(answer)
    }

    var reads: [String] { state.withLock { $0.reads } }
    var cancelled: Int { state.withLock { $0.cancelled } }

    func setAnswer(_ answer: @escaping @Sendable (String) async throws(OnePasswordError) -> String) {
        self.answer.withLock { $0 = answer }
    }

    func read(reference: String) async throws(OnePasswordError) -> String {
        state.withLock { $0.reads.append(reference) }
        let answer = self.answer.withLock { $0 }
        do {
            return try await answer(reference)
        } catch {
            if case .cancelled = error { state.withLock { $0.cancelled += 1 } }
            throw error
        }
    }

    func listItems() async throws(OnePasswordError) -> [OnePasswordItemSummary] { [] }
    func fields(itemID: String, vault: String) async throws(OnePasswordError) -> [OnePasswordField] { [] }
    func check() async throws(OnePasswordError) {}
}

@MainActor
final class SessionManagerOnePasswordTests: XCTestCase {
    private var vault: LocalVault!
    private var store: KnownHostsStore!
    private var factory: FakeFactory!
    private var sleeper: FakeSleeper!
    private var manager: SessionManager!
    private var op: FakeOnePassword?
    private let reference = "op://Private/web/password"
    private let broken = SessionError.connectionFailed("Broken pipe")

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        store = KnownHostsStore(vault: vault)
        factory = FakeFactory()
        sleeper = FakeSleeper()
        op = FakeOnePassword { _ in "resolved-pw" }
        let factory = factory!
        let sleeper = sleeper!
        manager = SessionManager(vault: vault, knownHosts: store,
                                 makeSession: { plan, evaluator in factory.make(plan, evaluator) },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero,
                                 sleep: { try await sleeper.sleep($0) },
                                 opClient: { [unowned self] in self.op })
    }

    override func tearDown() async throws {
        sleeper?.elapseAll()
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
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func referenceHost(password: String? = nil, useSystemSSH: Bool? = nil) -> SavedHost {
        vault.saveNow(SavedHost(label: "Web", address: "web.example", username: "root",
                                password: password ?? reference, useSystemSSH: useSystemSSH))
    }

    private func password(of session: FakeSession) -> String? {
        if case .password(let p) = session.plan.credential { return p }
        return nil
    }

    func testReferencedPasswordIsReadBeforeTheSessionStarts() async throws {
        let host = referenceHost(password: "  \(reference) ")
        let tab = try manager.open(hostID: host.id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(op?.reads, [reference])
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(password(of: factory.sessions[0]), "resolved-pw")
        XCTAssertNil(tab.suggestedAction)
        await waitUntil("log") { !self.vault.all(ConnectionLog.self).isEmpty }
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.password, "  \(reference) ", "the secret is never stored")
    }

    func testStartWaitsForTheRead() async throws {
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        op?.setAnswer { _ in
            await withCheckedContinuation { c in gate.withLock { $0 = c } }
            return "late"
        }
        let tab = try manager.open(hostID: referenceHost().id)
        XCTAssertEqual(tab.state, .connecting)
        await waitUntil("reading") { gate.withLock { $0 != nil } }
        await settle()
        XCTAssertEqual(factory.sessions.count, 0, "no session before the secret is known")
        gate.withLock { $0.take() }?.resume()
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(password(of: factory.sessions[0]), "late")
    }

    func testReferencedPassphraseIsRead() async throws {
        let key = vault.saveNow(SSHKey(label: "k", keyType: .ed25519, publicKey: "p", privateKey: "PEM",
                                       passphrase: "op://Private/key/passphrase"))
        let host = vault.saveNow(SavedHost(label: "K", address: "k.example", username: "root", sshKeyID: key.id))
        op?.setAnswer { _ in "resolved-passphrase" }
        let tab = try manager.open(hostID: host.id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(op?.reads, ["op://Private/key/passphrase"])
        guard case .privateKey(.ed25519, "PEM", "resolved-passphrase") = factory.sessions[0].plan.credential else {
            return XCTFail("\(factory.sessions[0].plan.credential)")
        }
    }

    func testPlainSecretsDoNotCallOnePassword() async throws {
        let tab = try manager.open(hostID: referenceHost(password: "plain").id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(op?.reads, [])
        XCTAssertEqual(password(of: factory.sessions[0]), "plain")
    }

    func testATypedPasswordWinsOverTheReference() async throws {
        op?.setAnswer { _ throws(OnePasswordError) in throw .notFound("could not find item web") }
        let tab = try manager.open(hostID: referenceHost().id)
        await waitUntil("failed") { tab.state != .connecting }
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.authenticationFailed))) }
        // A rejected resolved password leads to a prompt; the typed one is used without reading again.
        op?.setAnswer { _ in "resolved-pw" }
        manager.reconnect(tabID: tab.id)
        await waitUntil("prompt") { if case .awaitingPassword = tab.state { true } else { false } }
        XCTAssertEqual(password(of: factory.sessions[0]), "resolved-pw")
        factory.onStart = { @Sendable s in s.emit(.connected); s.emit(.ready) }
        let reads = op?.reads.count
        manager.providePassword(tabID: tab.id, "typed", save: false)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(op?.reads.count, reads)
        XCTAssertEqual(password(of: factory.sessions[1]), "typed")
    }

    func testErrorsDisconnectWithTheMessageAndSuggestSetupWhenItHelps() async throws {
        let cases: [(OnePasswordError, SuggestedAction?)] = [
            (.cliNotFound, .openOnePasswordSetup), (.integrationOff(details: "No accounts configured"), .openOnePasswordSetup),
            (.appLocked(details: nil), .openOnePasswordSetup), (.timedOut(details: "authorization timeout"), nil), (.notFound("could not find item web"), nil),
            (.failed("boom"), nil),
        ]
        for (error, suggestion) in cases {
            op?.setAnswer { _ throws(OnePasswordError) in throw error }
            let tab = try manager.open(hostID: referenceHost().id)
            await waitUntil("disconnected \(error)") { tab.state == .disconnected(error.message) }
            XCTAssertEqual(tab.suggestedAction, suggestion, "\(error)")
            manager.close(tabID: tab.id)
        }
        XCTAssertEqual(factory.sessions.count, 0)
    }

    func testCancelledShowsCancelledWithoutASuggestion() async throws {
        op?.setAnswer { _ throws(OnePasswordError) in throw .cancelled(details: "authorization prompt dismissed") }
        let tab = try manager.open(hostID: referenceHost().id)
        await waitUntil("disconnected") { tab.state == .disconnected("Cancelled") }
        XCTAssertNil(tab.suggestedAction)
    }

    func testNoClientMeansCLINotFound() async throws {
        op = nil
        let tab = try manager.open(hostID: referenceHost().id)
        await waitUntil("disconnected") { tab.state == .disconnected(OnePasswordError.cliNotFound.message) }
        XCTAssertEqual(tab.suggestedAction, .openOnePasswordSetup)
        XCTAssertEqual(factory.sessions.count, 0)
    }

    func testSuggestionIsClearedWhenANewAttemptStarts() async throws {
        op?.setAnswer { _ throws(OnePasswordError) in throw .appLocked(details: nil) }
        let tab = try manager.open(hostID: referenceHost().id)
        await waitUntil("suggestion") { tab.suggestedAction == .openOnePasswordSetup }
        op?.setAnswer { _ in "resolved-pw" }
        manager.reconnect(tabID: tab.id)
        XCTAssertNil(tab.suggestedAction)
        XCTAssertEqual(tab.state, .connecting)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertNil(tab.suggestedAction)
    }

    func testClosingTheTabWhileReadingCancelsTheRead() async throws {
        op?.setAnswer { _ throws(OnePasswordError) in
            do { try await Task.sleep(for: .seconds(30)) } catch { throw .cancelled(details: nil) }
            return "too late"
        }
        let tab = try manager.open(hostID: referenceHost().id)
        await waitUntil("reading") { self.op?.reads.count == 1 }
        manager.close(tabID: tab.id)
        await waitUntil("cancelled") { self.op?.cancelled == 1 }
        await settle()
        XCTAssertEqual(factory.sessions.count, 0)
    }

    func testReconnectWhileReadingSupersedesTheOldRead() async throws {
        let first = Mutex(true)
        op?.setAnswer { _ throws(OnePasswordError) in
            let isFirst = first.withLock { value -> Bool in
                defer { value = false }
                return value
            }
            if isFirst {
                do { try await Task.sleep(for: .seconds(30)) } catch { throw .cancelled(details: nil) }
                return "stale"
            }
            return "fresh"
        }
        let tab = try manager.open(hostID: referenceHost().id)
        await waitUntil("reading") { self.op?.reads.count == 1 }
        manager.reconnect(tabID: tab.id)
        await waitUntil("connected") { tab.state == .connected }
        await waitUntil("old read cancelled") { self.op?.cancelled == 1 }
        await settle()
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(password(of: factory.sessions[0]), "fresh")
        XCTAssertEqual(tab.state, .connected, "the cancelled read changes nothing")
    }

    func testAutoReconnectReadsAgainOnEveryTry() async throws {
        let count = Mutex(0)
        op?.setAnswer { _ in "pw-\(count.withLock { $0 += 1; return $0 })" }
        let tab = try manager.open(hostID: referenceHost().id)
        await waitUntil("ready") { !self.vault.all(ConnectionLog.self).isEmpty }
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.connectionFailed("Connection refused")))) }
        factory.sessions[0].emit(.closed(.failed(broken)))
        for attempt in 1...2 {
            await waitUntil("waiting \(attempt)") { if case .waiting(attempt, _, _) = tab.autoReconnect { true } else { false } }
            sleeper.elapseAll()
            await waitUntil("try \(attempt)") { self.factory.sessions.count == attempt + 1 }
        }
        XCTAssertEqual(op?.reads.count, 3)
        XCTAssertEqual(factory.sessions.map { password(of: $0) }, ["pw-1", "pw-2", "pw-3"])
    }

    func testAutoReconnectStopsOnAOnePasswordError() async throws {
        let tab = try manager.open(hostID: referenceHost().id)
        await waitUntil("ready") { !self.vault.all(ConnectionLog.self).isEmpty }
        factory.sessions[0].emit(.closed(.failed(broken)))
        await waitUntil("waiting") { tab.autoReconnect != nil }
        op?.setAnswer { _ throws(OnePasswordError) in throw .appLocked(details: nil) }
        sleeper.elapseAll()
        await waitUntil("stopped") { tab.state == .disconnected(OnePasswordError.appLocked(details: nil).message) }
        XCTAssertNil(tab.autoReconnect)
        XCTAssertEqual(tab.suggestedAction, .openOnePasswordSetup)
        await settle()
        XCTAssertEqual(sleeper.pending, 0)
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
    }

    func testAutoReconnectStaysReconnectingWhileReading() async throws {
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let tab = try manager.open(hostID: referenceHost().id)
        await waitUntil("ready") { !self.vault.all(ConnectionLog.self).isEmpty }
        factory.sessions[0].emit(.closed(.failed(broken)))
        await waitUntil("waiting") { tab.autoReconnect != nil }
        op?.setAnswer { _ in
            await withCheckedContinuation { c in gate.withLock { $0 = c } }
            return "pw"
        }
        sleeper.elapseAll()
        await waitUntil("reading") { gate.withLock { $0 != nil } }
        XCTAssertEqual(tab.autoReconnect, .reconnecting(attempt: 1))
        XCTAssertEqual(manager.waitingForReconnectCount, 1)
        manager.stopAutoReconnect(tabID: tab.id)
        XCTAssertNil(tab.autoReconnect)
        XCTAssertEqual(tab.state, .disconnected(broken.localizedDescription))
        gate.withLock { $0.take() }?.resume()
        await settle()
        XCTAssertEqual(factory.sessions.count, 1, "the stopped try never starts")
        XCTAssertEqual(tab.state, .disconnected(broken.localizedDescription))
    }

    func testSystemSSHAlsoResolvesTheReference() async throws {
        let tab = try manager.open(hostID: referenceHost(useSystemSSH: true).id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(factory.sessions[0].plan.engine, .systemSSH)
        XCTAssertEqual(password(of: factory.sessions[0]), "resolved-pw")
    }

    // MARK: Agent keys and 1Password references together

    /// A manager with both providers, in the init's final order (…, sleep, agentSocket, opClient).
    private func agentAndOpManager(socket: @escaping @MainActor () -> String?) -> SessionManager {
        let factory = factory!
        let sleeper = sleeper!
        return SessionManager(vault: vault, knownHosts: store,
                              makeSession: { plan, evaluator in factory.make(plan, evaluator) },
                              deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero,
                              sleep: { try await sleeper.sleep($0) },
                              agentSocket: socket,
                              opClient: { [unowned self] in self.op })
    }

    private func agentHostWithReference() -> SavedHost {
        // The stored password is a reference, but the agent key wins: it must never be read.
        vault.saveNow(SavedHost(label: "Agent", address: "agent.example", username: "root", password: reference,
                                agentKey: AgentKeyChoice(publicKey: nil)))
    }

    func testAgentHostNeverReadsTheStoredReference() async throws {
        manager = agentAndOpManager(socket: { "/tmp/a.sock" })
        let tab = try manager.open(hostID: agentHostWithReference().id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(op?.reads, [])
        guard case .agent("/tmp/a.sock", nil) = factory.sessions[0].plan.credential else {
            return XCTFail("\(factory.sessions[0].plan.credential)")
        }
    }

    func testMissingAgentSocketIsReportedBeforeAnyOnePasswordRead() async throws {
        manager = agentAndOpManager(socket: { nil })
        let tab = try manager.open(hostID: agentHostWithReference().id)
        XCTAssertEqual(tab.state, .disconnected(
            "1Password's SSH agent wasn't found. Turn on \u{201C}Use the SSH agent\u{201D} in 1Password \u{2192} Settings \u{2192} Developer."))
        XCTAssertEqual(tab.suggestedAction, .openOnePasswordSetup)
        await settle()
        XCTAssertEqual(op?.reads, [])
        XCTAssertTrue(factory.sessions.isEmpty)
    }

    private let unreachable = SessionError.agentUnavailable(
        "Couldn't reach 1Password's SSH agent. Make sure 1Password is running and unlocked, and that Termius Reimagined may access it.")

    func testAutoReconnectStopsWhenTheAgentCantBeReached() async throws {
        manager = agentAndOpManager(socket: { "/tmp/a.sock" })
        let tab = try manager.open(hostID: agentHostWithReference().id)
        await waitUntil("ready") { !self.vault.all(ConnectionLog.self).isEmpty }
        factory.sessions[0].emit(.closed(.failed(broken)))
        await waitUntil("waiting") { tab.autoReconnect != nil }
        let unreachable = unreachable
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(unreachable))) }
        sleeper.elapseAll()
        await waitUntil("stopped") { tab.state == .disconnected(unreachable.localizedDescription) }
        XCTAssertNil(tab.autoReconnect)
        XCTAssertEqual(tab.suggestedAction, .openOnePasswordSetup)
        await settle()
        XCTAssertEqual(sleeper.pending, 0)
        XCTAssertEqual(factory.sessions.count, 2, "never tried again")
        XCTAssertEqual(manager.waitingForReconnectCount, 0)
    }

    func testAutoReconnectStopsWhenTheAgentKeyIsRejected() async throws {
        manager = agentAndOpManager(socket: { "/tmp/a.sock" })
        let tab = try manager.open(hostID: agentHostWithReference().id)
        await waitUntil("ready") { !self.vault.all(ConnectionLog.self).isEmpty }
        factory.sessions[0].emit(.closed(.failed(broken)))
        await waitUntil("waiting") { tab.autoReconnect != nil }
        factory.onStart = { @Sendable s in s.emit(.closed(.failed(.authenticationFailed))) }
        sleeper.elapseAll()
        await waitUntil("stopped") {
            tab.state == .disconnected("The server didn't accept the key from 1Password's SSH agent for root@agent.example. Either the key's public half isn't in ~/.ssh/authorized_keys on the server, or 1Password is locked \u{2014} unlock it and try again.")
        }
        XCTAssertNil(tab.autoReconnect)
        XCTAssertEqual(tab.suggestedAction, .openOnePasswordSetup)
        await settle()
        XCTAssertEqual(sleeper.pending, 0)
        XCTAssertEqual(factory.sessions.count, 2)
    }

    // MARK: A typed 1Password reference

    func testTypedReferenceIsReadForTheLoginAndTheReferenceIsSaved() async throws {
        let host = vault.saveNow(SavedHost(label: "NoPw", address: "np.example", username: "root"))
        let tab = try manager.open(hostID: host.id)
        XCTAssertEqual(tab.state, .awaitingPassword(prompt: "Password for root@np.example"))
        manager.providePassword(tabID: tab.id, " \(reference) ", save: true)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(op?.reads, [reference])
        XCTAssertEqual(password(of: factory.sessions[0]), "resolved-pw", "the login uses the value")
        await waitUntil("log") { !self.vault.all(ConnectionLog.self).isEmpty }
        await settle()
        XCTAssertEqual(vault.get(SavedHost.self, id: host.id)?.password, " \(reference) ",
                       "the vault holds the reference as typed, never the value")
    }

    func testTypedReferenceSavedOnTheIdentityIsTheReference() async throws {
        let identity = vault.saveNow(Identity(label: "i", username: "alice"))
        let host = vault.saveNow(SavedHost(label: "H", address: "h.example", identityID: identity.id))
        let tab = try manager.open(hostID: host.id)
        manager.providePassword(tabID: tab.id, reference, save: true)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(password(of: factory.sessions[0]), "resolved-pw")
        await waitUntil("stored on identity") { self.vault.get(Identity.self, id: identity.id)?.password != nil }
        XCTAssertEqual(vault.get(Identity.self, id: identity.id)?.password, reference)
        XCTAssertNil(vault.get(SavedHost.self, id: host.id)?.password)
    }

    func testTypedReferenceWithoutSaveStoresNothing() async throws {
        let host = vault.saveNow(SavedHost(label: "NoPw", address: "np.example", username: "root"))
        let tab = try manager.open(hostID: host.id)
        manager.providePassword(tabID: tab.id, reference, save: false)
        await waitUntil("connected") { tab.state == .connected }
        await waitUntil("log") { !self.vault.all(ConnectionLog.self).isEmpty }
        await settle()
        XCTAssertNil(vault.get(SavedHost.self, id: host.id)?.password)
    }

    func testReferenceHostsStillResolveWhenAnAgentProviderIsSet() async throws {
        var socketReads = 0
        manager = agentAndOpManager(socket: { socketReads += 1; return "/tmp/a.sock" })
        let tab = try manager.open(hostID: referenceHost().id)
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(socketReads, 0)
        XCTAssertEqual(op?.reads, [reference])
        XCTAssertEqual(password(of: factory.sessions[0]), "resolved-pw")
    }
}

// MARK: - Connection log

@MainActor
final class SessionManagerConnectionLogTests: XCTestCase {
    private var vault: LocalVault!
    private var factory: FakeFactory!
    private var manager: SessionManager!
    private let clock = TestClock()
    private var agentSocketPath: String? = "/tmp/agent.sock"

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        factory = FakeFactory()
        let factory = factory!
        manager = SessionManager(vault: vault, knownHosts: KnownHostsStore(vault: vault),
                                 makeSession: { plan, evaluator in factory.make(plan, evaluator) },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero,
                                 now: { [clock] in clock.tick() },
                                 agentSocket: { [unowned self] in self.agentSocketPath })
    }

    private func waitUntil(_ what: String = "condition", timeout: TimeInterval = 2,
                           _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func host() -> CoreModels.Host {
        vault.saveNow(CoreModels.Host(label: "Web", address: "web.example", username: "root", password: "pw"))
    }

    private func statuses(_ tab: TerminalTab) -> [ConnectionLogLine.Status] { tab.connectionLog.map(\.status) }

    func testStepsBecomeLinesAndTheLastIsDoneOnceConnected() async throws {
        let gate = TestGate()
        factory.onStart = { @Sendable s in
            s.emit(.progress(.resolving(host: "web.example")))
            s.emit(.progress(.connecting(address: "10.0.0.5", port: 22)))
            await gate.wait()
            s.emit(.progress(.connected(address: "10.0.0.5")))
            s.emit(.progress(.authenticating(method: "password")))
            s.emit(.connected)
            s.emit(.ready)
        }
        let tab = try manager.open(hostID: host().id)
        await waitUntil("two lines") { tab.connectionLog.count == 2 }
        XCTAssertEqual(tab.connectionLog.map(\.step), [.resolving(host: "web.example"), .connecting(address: "10.0.0.5", port: 22)])
        XCTAssertEqual(tab.connectionLog.map(\.text), ["Resolving web.example\u{2026}", "Connecting to 10.0.0.5:22\u{2026}"])
        XCTAssertEqual(statuses(tab), [.done, .inProgress])
        XCTAssertFalse(tab.hasEverConnected)
        XCTAssertFalse(tab.hadLiveSession)
        XCTAssertNil(tab.connectionFailure)
        XCTAssertEqual(tab.state, .connecting)

        gate.open()
        await waitUntil("connected") { tab.state == .connected }
        XCTAssertEqual(statuses(tab), [.done, .done, .done, .done])
        XCTAssertTrue(tab.hasEverConnected)
        XCTAssertNil(tab.connectionFailure)
        XCTAssertEqual(Set(tab.connectionLog.map(\.id)).count, 4, "unique ids")
        XCTAssertLessThan(tab.connectionLog[0].at, tab.connectionLog[3].at)
    }

    func testFailureMarksTheStepFailedAndAddsTheMessage() async throws {
        let refused = SessionError.connectionFailed("Could not connect to web.example:22 (connection refused)")
        factory.onStart = { @Sendable s in
            s.emit(.progress(.resolving(host: "web.example")))
            s.emit(.progress(.connecting(address: "10.0.0.5", port: 22)))
            s.emit(.closed(.failed(refused)))
        }
        let tab = try manager.open(hostID: host().id)
        await waitUntil("failed") { tab.connectionFailure != nil }
        XCTAssertEqual(statuses(tab), [.done, .failed, .failed])
        XCTAssertEqual(tab.connectionLog.last?.step, nil)
        XCTAssertEqual(tab.connectionFailure, refused.localizedDescription)
        XCTAssertEqual(tab.state, .disconnected(refused.localizedDescription))
        XCTAssertFalse(tab.hasEverConnected)
    }

    func testEachAttemptStartsAFreshLog() async throws {
        factory.onStart = { @Sendable s in
            s.emit(.progress(.connecting(address: "10.0.0.5", port: 22)))
            s.emit(.closed(.failed(.timedOut)))
        }
        let tab = try manager.open(hostID: host().id)
        await waitUntil("failed") { tab.connectionFailure != nil }
        let firstIDs = tab.connectionLog.map(\.id)
        XCTAssertFalse(tab.hadLiveSession, "never went live")

        factory.onStart = { @Sendable s in
            s.emit(.progress(.connecting(address: "10.0.0.5", port: 22)))
        }
        manager.reconnect(tabID: tab.id) // "Start over"
        await waitUntil("second attempt") { self.factory.sessions.count == 2 && tab.connectionLog.count == 1 }
        XCTAssertEqual(statuses(tab), [.inProgress])
        XCTAssertNil(tab.connectionFailure)
        XCTAssertTrue(Set(firstIDs).isDisjoint(with: tab.connectionLog.map(\.id)), "ids never repeat")
    }

    func testDroppedSessionKeepsHasEverConnected() async throws {
        factory.onStart = { @Sendable s in
            s.emit(.progress(.openingShell))
            s.emit(.connected)
            s.emit(.ready)
        }
        let tab = try manager.open(hostID: host().id)
        await waitUntil("connected") { tab.state == .connected }
        factory.sessions[0].emit(.closed(.failed(.connectionFailed("Broken pipe"))))
        await waitUntil("dropped") { tab.state != .connected }
        XCTAssertTrue(tab.hasEverConnected, "the screen is for attempts that never connected")
        XCTAssertEqual(statuses(tab), [.done, .failed])
    }

    func testExitingTheShellClosesTheTab() async throws {
        factory.onStart = { @Sendable s in
            s.emit(.connected)
            s.emit(.ready)
        }
        let other = try manager.open(hostID: host().id)
        let tab = try manager.open(hostID: host().id)
        await waitUntil("connected") { tab.state == .connected && other.state == .connected }
        await waitUntil("logs") { self.vault.all(ConnectionLog.self).count == 2 }
        factory.sessions[1].emit(.closed(.remoteClosed)) // `exit`
        await waitUntil("closed") { self.manager.tabs.map(\.id) == [other.id] }
        XCTAssertEqual(manager.selectedTabID, other.id)
        XCTAssertNotNil(vault.all(ConnectionLog.self).first { $0.endedAt != nil }, "the log still ends")
    }

    func testAFailureAfterTheTerminalWasLiveStillShowsDisconnected() async throws {
        factory.onStart = { @Sendable s in
            s.emit(.connected)
            s.emit(.ready)
        }
        let tab = try manager.open(hostID: host().id)
        await waitUntil("connected") { tab.state == .connected }
        await waitUntil("log") { self.vault.all(ConnectionLog.self).count == 1 }
        factory.sessions[0].emit(.closed(.failed(.timedOut)))
        await waitUntil("disconnected") { tab.state == .disconnected(SessionError.timedOut.localizedDescription) }
        XCTAssertEqual(manager.tabs.map(\.id), [tab.id])
    }

    func testStaleAttemptsDoNotWriteToTheLog() async throws {
        factory.onStart = { @Sendable _ in }
        let tab = try manager.open(hostID: host().id)
        await waitUntil("started") { self.factory.sessions.first?.recorded.started != nil }
        let old = factory.sessions[0]
        manager.reconnect(tabID: tab.id)
        await waitUntil("second") { self.factory.sessions.count == 2 }
        old.emit(.progress(.handshake))
        old.emit(.closed(.failed(.timedOut)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tab.connectionLog, [])
    }

    func testFailuresBeforeASessionAreLogged() async throws {
        agentSocketPath = nil
        let agentHost = vault.saveNow(CoreModels.Host(label: "Agent", address: "a.example", username: "root",
                                                      agentKey: AgentKeyChoice(publicKey: nil)))
        let tab = try manager.open(hostID: agentHost.id)
        XCTAssertEqual(tab.connectionFailure, SessionManager.agentNotFoundMessage)
        XCTAssertFalse(tab.hasEverConnected)
        XCTAssertTrue(factory.sessions.isEmpty)
    }

    func testRejectedPasswordIsLoggedBeforeAskingAgain() async throws {
        factory.onStart = { @Sendable s in
            s.emit(.progress(.authenticating(method: "password")))
            s.emit(.closed(.failed(.authenticationFailed)))
        }
        let tab = try manager.open(hostID: host().id)
        await waitUntil("asks") { if case .awaitingPassword = tab.state { true } else { false } }
        XCTAssertEqual(statuses(tab), [.failed, .failed])
        XCTAssertEqual(tab.connectionFailure, SessionError.authenticationFailed.localizedDescription)
    }

    func testAnAutomaticTryStartsAFreshLog() async throws {
        let sleeper = FakeSleeper()
        let factory = factory!
        manager = SessionManager(vault: vault, knownHosts: KnownHostsStore(vault: vault),
                                 makeSession: { plan, evaluator in factory.make(plan, evaluator) },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero,
                                 autoReconnectEnabled: { true }, now: { [clock] in clock.tick() },
                                 sleep: { try await sleeper.sleep($0) })
        factory.onStart = { @Sendable s in
            s.emit(.progress(.openingShell))
            s.emit(.connected)
            s.emit(.ready)
        }
        let tab = try manager.open(hostID: host().id)
        await waitUntil("connected") { tab.state == .connected }
        let firstIDs = tab.connectionLog.map(\.id)
        XCTAssertTrue(tab.hadLiveSession)

        factory.onStart = { @Sendable s in s.emit(.progress(.connecting(address: "10.0.0.5", port: 22))) }
        factory.sessions[0].emit(.closed(.failed(.connectionFailed("Broken pipe"))))
        await waitUntil("countdown") { sleeper.pending == 1 }
        XCTAssertTrue(tab.hasEverConnected, "until the next try starts")
        sleeper.elapseAll()
        await waitUntil("automatic try") { self.factory.sessions.count == 2 && tab.connectionLog.count == 1 }
        XCTAssertEqual(tab.connectionLog.map(\.step), [.connecting(address: "10.0.0.5", port: 22)])
        XCTAssertEqual(statuses(tab), [.inProgress])
        XCTAssertFalse(tab.hasEverConnected)
        XCTAssertTrue(tab.hadLiveSession, "the tab was live once; attempts don't reset it")
        XCTAssertNil(tab.connectionFailure)
        XCTAssertTrue(Set(firstIDs).isDisjoint(with: tab.connectionLog.map(\.id)))
        if case .reconnecting = tab.autoReconnect {} else { XCTFail("\(String(describing: tab.autoReconnect))") }
        sleeper.elapseAll()
    }

    func testLogTextHasAHeaderAndTimedLinesWithoutSecrets() async throws {
        factory.onStart = { @Sendable s in
            s.emit(.progress(.connecting(address: "10.0.0.5", port: 2222)))
            s.emit(.progress(.authenticating(method: "password")))
            s.emit(.closed(.failed(.connectionFailed("connection reset by peer"))))
        }
        let saved = vault.saveNow(CoreModels.Host(label: "Web", address: "web.example", port: 2222, username: "root",
                                                  password: "hunter2-secret"))
        let tab = try manager.open(hostID: saved.id)
        await waitUntil("failed") { tab.connectionFailure != nil }
        let text = tab.connectionLogText()
        XCTAssertTrue(text.hasPrefix("Connection log \u{2014} Web\n"), text)
        XCTAssertTrue(text.contains("SSH root@web.example:2222\n"), text)
        XCTAssertTrue(text.contains("Engine: built-in (Citadel)\n"), text)
        XCTAssertTrue(text.contains("Started: "), text)
        XCTAssertTrue(text.contains("[done]  Connecting to 10.0.0.5:2222\u{2026}\n"), text)
        XCTAssertTrue(text.contains("[FAIL]  Signing in with password\u{2026}\n"), text)
        XCTAssertTrue(text.contains("[FAIL]  The connection failed: connection reset by peer\n"), text)
        XCTAssertFalse(text.contains("hunter2"), "never a secret")
        let lines = text.split(separator: "\n")
        XCTAssertTrue(lines.last?.range(of: #"^\d{2}:\d{2}:\d{2}\.\d{3}  \["#, options: .regularExpression) != nil, text)
    }
}

/// Each reading is 100 ms later than the one before.
private final class TestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_700_000_000))

    func tick() -> Date {
        date.withLock { $0 = $0.addingTimeInterval(0.1); return $0 }
    }
}

/// Holds a fake session's script until `open()`.
private final class TestGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
