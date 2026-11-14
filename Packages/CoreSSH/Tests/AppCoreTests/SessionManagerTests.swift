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
                             keepAlivePolicy: (@MainActor () -> KeepAlivePolicy)? = nil) -> SessionManager {
        let factory = factory!
        let make: @MainActor (ConnectionPlan, any HostKeyEvaluator) -> any TerminalSession = { plan, evaluator in
            factory.make(plan, evaluator)
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

        current = .off   // changed while the tab is open: the open session keeps its plan
        XCTAssertEqual(factory.sessions[0].plan.keepAlive, .fast)
        manager.reconnect(tabID: tab.id)
        await waitUntil("second session") { self.factory.sessions.count == 2 }
        XCTAssertEqual(factory.sessions[1].plan.keepAlive, .off)

        current = .relaxed
        _ = try manager.open(hostID: passwordHost(label: "Second").id)
        XCTAssertEqual(factory.sessions[2].plan.keepAlive, .relaxed)
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

    func testRemoteCloseKeepsTabAndEndsLog() async throws {
        let tab = try manager.open(hostID: passwordHost().id)
        await waitUntil("log") { !self.vault.all(ConnectionLog.self).isEmpty }
        factory.sessions[0].emit(.closed(.remoteClosed))
        await waitUntil("disconnected") { tab.state == .disconnected(nil) }
        XCTAssertEqual(manager.tabs.map(\.id), [tab.id])
        XCTAssertNotNil(vault.all(ConnectionLog.self).first?.endedAt)
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
        factory.sessions[0].emit(.closed(.remoteClosed))
        await waitUntil("disconnected") { tab.state == .disconnected(nil) }

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
