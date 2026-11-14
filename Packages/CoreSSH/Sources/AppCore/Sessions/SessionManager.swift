import Foundation
import Observation
import Synchronization
import CoreModels
import SSHCore

/// One terminal tab: what it connects to, its live state and the output waiting for its view.
@MainActor @Observable
public final class TerminalTab: Identifiable {
    public enum State: Equatable, Sendable {
        case connecting
        /// The server presented a key that needs the user's decision (`answerHostKey`). The check tells
        /// first contact (`.unknown`) apart from a new key type or a changed key.
        case awaitingHostKey(HostKeyCandidate, HostKeyCheck)
        /// A password is needed (`providePassword`).
        case awaitingPassword(prompt: String)
        case connected
        /// The session ended; the message is nil for a normal remote close.
        case disconnected(String?)
    }

    /// The most output kept while no view is attached; older bytes are dropped first.
    static let pendingOutputLimit = 4 * 1024 * 1024
    static let truncationMarker = Array("\r\n[output truncated]\r\n".utf8)

    public let id = UUID()
    public fileprivate(set) var title: String
    public fileprivate(set) var badge: OSBadge?
    public fileprivate(set) var state: State = .connecting

    /// Set by the terminal view. Output received while it is nil is kept (up to 4 MB) and
    /// delivered, in order, as soon as it is set.
    @ObservationIgnored public var outputSink: (@MainActor ([UInt8]) -> Void)? {
        didSet { flushPendingOutput() }
    }

    @ObservationIgnored fileprivate let target: SessionTarget
    @ObservationIgnored fileprivate var attempt: SessionAttempt?
    /// Bumped whenever the current attempt is replaced or ended; stale host key prompts compare it.
    @ObservationIgnored fileprivate var generation = 0
    /// A password typed for this tab, used instead of the stored one until the server rejects it
    /// or a session using it becomes ready.
    @ObservationIgnored fileprivate var enteredPassword: String?
    /// The user asked to save `enteredPassword`; it is stored once a session using it is ready.
    @ObservationIgnored fileprivate var saveEnteredPassword = false
    @ObservationIgnored fileprivate var size = (cols: 80, rows: 24)
    /// True once the view sent a size or the first start stopped waiting for one; later starts
    /// (reconnects) use `size` at once.
    @ObservationIgnored fileprivate var sizeSettled = false
    /// Wakes a start that is waiting for the view's first size.
    @ObservationIgnored fileprivate var sizeWaiter: ResumeOnce?
    @ObservationIgnored fileprivate var hostKeyAnswer: CheckedContinuation<HostKeyDecision, Never>?
    @ObservationIgnored private var pendingOutput: [[UInt8]] = []
    @ObservationIgnored private var pendingBytes = 0
    @ObservationIgnored private var pendingTruncated = false

    fileprivate init(target: SessionTarget, title: String, badge: OSBadge?) {
        self.target = target
        self.title = title
        self.badge = badge
    }

    fileprivate var hostID: UUID? {
        if case .host(let id) = target { return id }
        return nil
    }

    /// Whether a typed password can be saved: only a saved host has somewhere to keep it.
    public var canSavePassword: Bool { hostID != nil }

    fileprivate func deliver(_ bytes: [UInt8]) {
        if let outputSink {
            outputSink(bytes)
            return
        }
        pendingOutput.append(bytes)
        pendingBytes += bytes.count
        var overflow = pendingBytes - Self.pendingOutputLimit
        guard overflow > 0 else { return }
        pendingTruncated = true
        pendingBytes -= overflow
        while overflow > 0 {
            if pendingOutput[0].count <= overflow {
                overflow -= pendingOutput.removeFirst().count
            } else {
                pendingOutput[0].removeFirst(overflow)
                overflow = 0
            }
        }
    }

    private func flushPendingOutput() {
        guard let outputSink else { return }
        let chunks = pendingOutput
        let truncated = pendingTruncated
        pendingOutput = []
        pendingBytes = 0
        pendingTruncated = false
        if truncated { outputSink(Self.truncationMarker) }
        for chunk in chunks { outputSink(chunk) }
    }
}

fileprivate enum SessionTarget {
    case host(UUID)
    case quickConnect(QuickConnectTarget)
}

fileprivate enum SessionInput: Sendable {
    case bytes([UInt8])
    case resize(cols: Int, rows: Int)
}

/// One connection attempt of a tab: a session, its input queue and its log.
@MainActor
fileprivate final class SessionAttempt {
    let plan: ConnectionPlan
    let session: any TerminalSession
    let inputs: AsyncStream<SessionInput>.Continuation
    let usedEnteredPassword: Bool
    var logID: UUID?
    var eventLoop: Task<Void, Never>?

    init(plan: ConnectionPlan, session: any TerminalSession,
         inputs: AsyncStream<SessionInput>.Continuation, usedEnteredPassword: Bool) {
        self.plan = plan
        self.session = session
        self.inputs = inputs
        self.usedEnteredPassword = usedEnteredPassword
    }
}

/// Drives terminal sessions for the UI: host key and password prompts, connection logs, OS
/// detection, startup scripts, reconnect and close-all at quit.
@MainActor @Observable
public final class SessionManager {
    public private(set) var tabs: [TerminalTab] = []
    public var selectedTabID: UUID?

    /// How long `closeAll()` waits for sessions to end.
    @ObservationIgnored var closeAllTimeout: Duration = .seconds(3)
    /// How long a tab's first session start waits for the view's first `resize` before using the
    /// default size.
    @ObservationIgnored private let initialSizeTimeout: Duration

    @ObservationIgnored private let vault: LocalVault
    @ObservationIgnored private let knownHosts: KnownHostsStore
    @ObservationIgnored private let makeSession: @MainActor (ConnectionPlan, any HostKeyEvaluator) -> any TerminalSession
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let defaultUsername: String
    /// Every attempt whose session has not ended yet, including ones being closed.
    @ObservationIgnored private var liveAttempts: [ObjectIdentifier: SessionAttempt] = [:]
    /// Hosts whose OS was probed (or is being probed) in this app session.
    @ObservationIgnored private var probedHosts: Set<UUID> = []

    public init(vault: LocalVault, knownHosts: KnownHostsStore,
                makeSession: @escaping @MainActor (ConnectionPlan, any HostKeyEvaluator) -> any TerminalSession,
                deviceName: String, defaultUsername: String,
                initialSizeTimeout: Duration = .milliseconds(500)) {
        self.initialSizeTimeout = initialSizeTimeout
        self.vault = vault
        self.knownHosts = knownHosts
        self.makeSession = makeSession
        self.deviceName = deviceName
        self.defaultUsername = defaultUsername
    }

    // MARK: Opening and closing

    /// Opens a tab for a saved host and starts connecting. Throws when the host can't be planned
    /// (missing, no address, no username); no tab is created then.
    @discardableResult
    public func open(hostID: UUID) throws -> TerminalTab {
        let plan = try ConnectionPlanner.plan(hostID: hostID, vault: vault)
        let badge = vault.get(SavedHost.self, id: hostID)?.osBadge
        return add(TerminalTab(target: .host(hostID), title: plan.label, badge: badge), plan: plan)
    }

    @discardableResult
    public func open(quickConnect target: QuickConnectTarget) -> TerminalTab {
        let plan = ConnectionPlanner.plan(quickConnect: target, defaultUsername: defaultUsername)
        return add(TerminalTab(target: .quickConnect(target), title: plan.label, badge: nil), plan: plan)
    }

    private func add(_ tab: TerminalTab, plan: ConnectionPlan) -> TerminalTab {
        tabs.append(tab)
        selectedTabID = tab.id
        connect(tab, plan: plan)
        return tab
    }

    /// Ends the tab's session (if any) and removes the tab.
    public func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs.remove(at: index)
        if selectedTabID == tabID {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if let attempt = detachAttempt(of: tab) {
            let session = attempt.session
            Task { await session.close() }
        }
    }

    /// Starts a new session (with a new log) in the same tab, ending the current one first.
    public func reconnect(tabID: UUID) {
        guard let tab = tab(tabID) else { return }
        connect(tab, plan: nil)
    }

    /// Closes every session concurrently and returns when all have ended, or after 3 s.
    /// Every tab is removed. Used at quit.
    public func closeAll() async {
        let open = tabs
        tabs = []
        selectedTabID = nil
        for tab in open { _ = detachAttempt(of: tab) }
        let work = liveAttempts.values.map { ($0.session, $0.eventLoop) }
        guard !work.isEmpty else { return }
        let timeout = closeAllTimeout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = ResumeOnce(continuation)
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for (session, eventLoop) in work {
                        group.addTask {
                            await session.close()
                            await eventLoop?.value
                        }
                    }
                }
                done.resume()
            }
            Task {
                try? await Task.sleep(for: timeout)
                done.resume()
            }
        }
    }

    // MARK: Prompts

    /// Answers the tab's pending host key prompt. Ignored when the tab is gone or not asking.
    public func answerHostKey(tabID: UUID, _ decision: HostKeyDecision) {
        guard let tab = tab(tabID), let answer = tab.hostKeyAnswer else { return }
        tab.hostKeyAnswer = nil
        answer.resume(returning: decision)
    }

    /// Connects with `password` after a password prompt. With `save`, the password is stored where
    /// the host's credentials come from: on the identity in effect, otherwise on the host itself.
    /// It is stored only once the server accepts it (the session is ready), so a mistyped password
    /// never replaces a good saved one.
    public func providePassword(tabID: UUID, _ password: String, save: Bool) {
        guard let tab = tab(tabID), case .awaitingPassword = tab.state else { return }
        tab.enteredPassword = password
        tab.saveEnteredPassword = save && tab.canSavePassword
        connect(tab, plan: nil)
    }

    /// Dismisses the tab's password prompt without connecting: the tab shows as disconnected and
    /// `reconnect` asks again. Ignored when the tab is gone or not asking.
    public func cancelPasswordPrompt(tabID: UUID) {
        guard let tab = tab(tabID), case .awaitingPassword = tab.state else { return }
        if let attempt = detachAttempt(of: tab) {
            let session = attempt.session
            Task { await session.close() }
        }
        tab.state = .disconnected(nil)
    }

    private func storePassword(_ password: String, hostID: UUID) {
        guard var host = vault.get(SavedHost.self, id: hostID) else { return }
        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
        let resolved = CredentialResolution.resolve(host: host, directory: directory, vault: vault)
        if var identity = resolved.identity {
            identity.password = password
            vault.saveNow(identity)
        } else {
            host.password = password
            vault.saveNow(host)
        }
    }

    // MARK: Input

    public func send(tabID: UUID, _ bytes: [UInt8]) {
        tab(tabID)?.attempt?.inputs.yield(.bytes(bytes))
    }

    public func resize(tabID: UUID, cols: Int, rows: Int) {
        guard let tab = tab(tabID) else { return }
        tab.size = (cols, rows)
        tab.sizeSettled = true
        if let waiter = tab.sizeWaiter {
            tab.sizeWaiter = nil
            waiter.resume()
        }
        tab.attempt?.inputs.yield(.resize(cols: cols, rows: rows))
    }

    // MARK: Connecting

    private func tab(_ id: UUID) -> TerminalTab? {
        tabs.first { $0.id == id }
    }

    private func isOpen(_ tab: TerminalTab) -> Bool {
        tabs.contains { $0 === tab }
    }

    /// Detaches the current attempt (its later events only finish its log), rejects a pending host
    /// key prompt and stops input. The caller closes the session.
    private func detachAttempt(of tab: TerminalTab) -> SessionAttempt? {
        tab.generation += 1
        rejectPendingHostKey(of: tab)
        if let waiter = tab.sizeWaiter {
            tab.sizeWaiter = nil
            waiter.resume()
        }
        guard let attempt = tab.attempt else { return nil }
        tab.attempt = nil
        attempt.inputs.finish()
        return attempt
    }

    /// Answers a pending host key prompt with `.rejected`: its attempt is gone.
    private func rejectPendingHostKey(of tab: TerminalTab) {
        guard let answer = tab.hostKeyAnswer else { return }
        tab.hostKeyAnswer = nil
        answer.resume(returning: .rejected)
    }

    private func connect(_ tab: TerminalTab, plan given: ConnectionPlan?) {
        if let old = detachAttempt(of: tab) {
            let session = old.session
            Task { await session.close() }
        }
        var plan: ConnectionPlan
        if let given {
            plan = given
        } else {
            do {
                plan = try currentPlan(for: tab.target)
            } catch {
                tab.state = .disconnected(error.localizedDescription)
                return
            }
        }
        tab.title = plan.label
        if let hostID = tab.hostID, let host = vault.get(SavedHost.self, id: hostID) { tab.badge = host.osBadge }

        var usedEnteredPassword = false
        if let entered = tab.enteredPassword {
            switch plan.credential {
            case .password, .none:
                plan.credential = .password(entered)
                usedEnteredPassword = true
            case .privateKey:
                break
            }
        }
        if case .none = plan.credential, plan.engine == .citadel {
            tab.state = .awaitingPassword(prompt: "Password for \(Self.userAtHost(plan))")
            return
        }

        tab.state = .connecting
        let generation = tab.generation
        let evaluator = PromptingHostKeyEvaluator(store: knownHosts) { [weak self, weak tab] candidate, check in
            guard let self, let tab else { return .rejected }
            return await self.askHostKey(tab: tab, generation: generation, candidate, check)
        }
        let session = makeSession(plan, evaluator)
        let (inputs, inputContinuation) = AsyncStream<SessionInput>.makeStream()
        let attempt = SessionAttempt(plan: plan, session: session, inputs: inputContinuation,
                                     usedEnteredPassword: usedEnteredPassword)
        tab.attempt = attempt
        liveAttempts[ObjectIdentifier(attempt)] = attempt

        // Start (once the view's size is known), then forward input in call order. Awaiting the
        // session runs off the main actor.
        Task { [weak self, weak tab] in
            if let self, let tab, !tab.sizeSettled { await self.waitForViewSize(tab) }
            // Read the size when starting; skip the start when the attempt was replaced or closed meanwhile.
            guard let tab, tab.attempt === attempt else { return }
            await session.start(cols: tab.size.cols, rows: tab.size.rows)
            for await input in inputs {
                switch input {
                case .bytes(let bytes): await session.send(bytes)
                case .resize(let cols, let rows): await session.resize(cols: cols, rows: rows)
                }
            }
        }
        attempt.eventLoop = Task { [weak self, weak tab] in
            for await event in session.events {
                guard let self else { return }
                self.handle(event, attempt: attempt, tab: tab)
            }
            self?.liveAttempts[ObjectIdentifier(attempt)] = nil
        }
    }

    /// Waits until the view's first `resize`, the timeout, or the attempt ends, whichever is first.
    private func waitForViewSize(_ tab: TerminalTab) async {
        let timeout = initialSizeTimeout
        var installed: ResumeOnce?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = ResumeOnce(continuation)
            installed = waiter
            tab.sizeWaiter = waiter
            Task {
                try? await Task.sleep(for: timeout)
                waiter.resume()
            }
        }
        // Still installed means the timeout fired: stop waiting for this tab from now on. A resize
        // already settled the size; a detached attempt leaves it unsettled for the next start.
        if let installed, tab.sizeWaiter === installed {
            tab.sizeWaiter = nil
            tab.sizeSettled = true
        }
    }

    private func currentPlan(for target: SessionTarget) throws -> ConnectionPlan {
        switch target {
        case .host(let id):
            try ConnectionPlanner.plan(hostID: id, vault: vault)
        case .quickConnect(let quick):
            ConnectionPlanner.plan(quickConnect: quick, defaultUsername: defaultUsername)
        }
    }

    /// The `ask` callback of the tab's host key evaluator: shows the prompt and waits for
    /// `answerHostKey`. A closed or reconnected tab answers `.rejected`.
    private func askHostKey(tab: TerminalTab, generation: Int,
                            _ candidate: HostKeyCandidate, _ check: HostKeyCheck) async -> HostKeyDecision {
        guard isOpen(tab), tab.generation == generation else { return .rejected }
        if let previous = tab.hostKeyAnswer {
            tab.hostKeyAnswer = nil
            previous.resume(returning: .rejected)
        }
        tab.state = .awaitingHostKey(candidate, check)
        let decision = await withCheckedContinuation { tab.hostKeyAnswer = $0 }
        guard isOpen(tab), tab.generation == generation else { return .rejected }
        if decision == .trusted, case .awaitingHostKey = tab.state { tab.state = .connecting }
        return decision
    }

    // MARK: Session events

    private func handle(_ event: SessionEvent, attempt: SessionAttempt, tab: TerminalTab?) {
        let current = tab.flatMap { $0.attempt === attempt ? $0 : nil }
        switch event {
        case .connected:
            current?.state = .connected
        case .ready:
            guard let current, attempt.logID == nil else { return }
            sessionBecameReady(attempt, tab: current)
        case .output(let bytes):
            current?.deliver(bytes)
        case .closed(let reason):
            endLog(of: attempt)
            attempt.inputs.finish()
            liveAttempts[ObjectIdentifier(attempt)] = nil
            guard let current else { return }
            current.attempt = nil
            current.generation += 1
            rejectPendingHostKey(of: current)
            if reason == .userClosed {
                if isOpen(current) { close(tabID: current.id) }
                return
            }
            current.state = state(after: reason, attempt: attempt, tab: current)
        }
    }

    private func sessionBecameReady(_ attempt: SessionAttempt, tab: TerminalTab) {
        let plan = attempt.plan
        let log = vault.saveNow(ConnectionLog(hostID: plan.hostID, hostLabel: plan.label, username: plan.username,
                                              deviceName: deviceName, startedAt: Date()))
        attempt.logID = log.id
        // The server accepted the typed password: now it may be saved (where the existing rule says).
        if attempt.usedEnteredPassword, tab.saveEnteredPassword, let hostID = tab.hostID,
           case .password(let accepted) = plan.credential {
            storePassword(accepted, hostID: hostID)
        }
        // From now on the vault (or a new prompt) decides, so later vault edits are not shadowed.
        tab.enteredPassword = nil
        tab.saveEnteredPassword = false
        if let hostID = plan.hostID, var host = vault.get(SavedHost.self, id: hostID) {
            host.lastConnectedAt = Date()
            vault.saveNow(host)
            // Once per host per app session, and again whenever an automatic host has no badge
            // (e.g. after "Automatic" in Host Details).
            if !host.osBadgeIsManual, !probedHosts.contains(hostID) || host.osBadge == nil {
                probedHosts.insert(hostID)
                let session = attempt.session
                Task { [weak self] in
                    do {
                        var output = try await session.runCommand(OSDetector.probeCommand)
                        if let followUp = OSDetector.followUpCommand(forProbeOutput: output),
                           let more = try? await session.runCommand(followUp) {
                            output += "\n" + more
                        }
                        self?.applyProbe(output, hostID: hostID)
                    } catch {
                        self?.probedHosts.remove(hostID) // try again on the next connection
                    }
                }
            }
        }
        if let script = plan.startupScript, !script.isEmpty {
            attempt.inputs.yield(.bytes(Array((script + "\n").utf8)))
        }
    }

    private func applyProbe(_ output: String, hostID: UUID) {
        guard let badge = OSDetector.badge(fromProbeOutput: output),
              var host = vault.get(SavedHost.self, id: hostID),
              !host.osBadgeIsManual, host.osBadge != badge else { return }
        host.osBadge = badge
        vault.saveNow(host)
        for tab in tabs where tab.hostID == hostID { tab.badge = badge }
    }

    private func endLog(of attempt: SessionAttempt) {
        guard let id = attempt.logID, var log = vault.get(ConnectionLog.self, id: id) else { return }
        log.endedAt = Date()
        vault.saveNow(log)
    }

    private func state(after reason: SessionEndReason, attempt: SessionAttempt,
                       tab: TerminalTab) -> TerminalTab.State {
        let who = Self.userAtHost(attempt.plan)
        switch reason {
        case .remoteClosed, .userClosed:
            return .disconnected(nil)
        case .failed(.authenticationFailed):
            switch attempt.plan.credential {
            case .password:
                if attempt.usedEnteredPassword {
                    tab.enteredPassword = nil
                    tab.saveEnteredPassword = false
                    return .awaitingPassword(prompt: "Password for \(who) (that password was rejected)")
                }
                return .awaitingPassword(prompt: "Password for \(who) (the saved one was rejected)")
            case .privateKey:
                return .disconnected("The server rejected the key for \(who).")
            case .none:
                return .disconnected(SessionError.authenticationFailed.localizedDescription)
            }
        case .failed(let error):
            return .disconnected(error.localizedDescription)
        }
    }

    private static func userAtHost(_ plan: ConnectionPlan) -> String {
        "\(plan.username)@\(plan.host)"
    }
}

/// Resumes a continuation the first time `resume()` is called.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume() {
        continuation.withLock { $0.take() }?.resume()
    }
}
