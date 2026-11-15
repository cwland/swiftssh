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
    /// nil = not auto-reconnecting. See `SessionManager` for when it starts and ends.
    public fileprivate(set) var autoReconnect: AutoReconnectState?
    /// A next step to offer next to the current `.disconnected` message; cleared when a new attempt starts.
    public fileprivate(set) var suggestedAction: SuggestedAction?
    /// A name the user gave this tab (Rename…); nil = the host's label. Never saved.
    public fileprivate(set) var customTitle: String?
    /// What the tab bar shows: the custom title, else `title`.
    public var displayTitle: String { customTitle ?? title }
    /// A theme for this tab only (quick connect, or a host that is gone); nil = resolved as usual.
    /// Never saved.
    public fileprivate(set) var themeOverrideID: String?
    /// The window the tab belongs to; nil = the main window. New connections open in the main window;
    /// "Duplicate in New Window" and duplicates of its tabs open in another.
    public fileprivate(set) var windowID: UUID?

    /// Set by the terminal view. Output received while it is nil is kept (up to 4 MB) and
    /// delivered, in order, as soon as it is set.
    @ObservationIgnored public var outputSink: (@MainActor ([UInt8]) -> Void)? {
        didSet { flushPendingOutput() }
    }

    @ObservationIgnored fileprivate let target: SessionTarget
    @ObservationIgnored fileprivate var attempt: SessionAttempt?
    /// Reading the attempt's secrets from 1Password before its session is made; ends (is cancelled)
    /// with the attempt.
    @ObservationIgnored fileprivate var resolvingSecrets: Task<Void, Never>?
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
    /// The countdown to the next automatic try, while `autoReconnect` is `.waiting`.
    @ObservationIgnored fileprivate var countdown: Task<Void, Never>?
    /// Bumped whenever a countdown is started or cancelled; a countdown acts only while its token is current
    /// (a cancelled sleep may still return).
    @ObservationIgnored fileprivate var countdownToken = 0
    /// The message of the latest dropped connection or failed try, shown again when the user stops a try.
    @ObservationIgnored fileprivate var dropMessage: String?
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

    /// The saved host this tab connects to; nil for quick connect.
    public var savedHostID: UUID? { hostID }

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
    /// The password as the user typed it, when this attempt uses one. It may be a 1Password reference
    /// whose value is in `plan`: only this text is ever saved.
    let enteredPassword: String?
    var logID: UUID?
    var eventLoop: Task<Void, Never>?

    var usedEnteredPassword: Bool { enteredPassword != nil }

    init(plan: ConnectionPlan, session: any TerminalSession,
         inputs: AsyncStream<SessionInput>.Continuation, enteredPassword: String?) {
        self.plan = plan
        self.session = session
        self.inputs = inputs
        self.enteredPassword = enteredPassword
    }
}

/// Drives terminal sessions for the UI: host key and password prompts, connection logs, OS
/// detection, startup scripts, reconnect, auto-reconnect and close-all at quit.
///
/// Auto-reconnect: when the session of a tab that had become ready ends with `.connectionFailed` or
/// `.timedOut` (a dropped connection) and `autoReconnectEnabled()` is true, the tab counts down
/// (`.waiting`) and then tries again (`.reconnecting`) the way `reconnect(tabID:)` does, on the
/// `ReconnectSchedule`. A try that drops the same way, before or after it connected, leads to the next
/// countdown, or to `.gaveUp` after the last; a try that becomes ready, fails any other way, or needs a
/// password typed ends auto-reconnect (`nil`) and the tab shows what it would after `reconnect`.
///
/// 1Password agent keys: a plan with `agentKey` gets its socket from `agentSocket()` at every attempt and
/// connects with `.agent(socketPath:publicKey:)` through system ssh. Without a socket no session starts:
/// the tab is disconnected with a setup hint and `suggestedAction = .openOnePasswordSetup`. An attempt
/// that ends with `.agentUnavailable`, or an agent attempt whose key the server rejects
/// (`.authenticationFailed`), also suggests the setup; auto-reconnect retries neither.
///
/// 1Password references: a password or key passphrase that is an `op://` reference is read with
/// `opClient()` before each attempt starts (after the agent check; agent plans never read). The value is
/// used for that attempt only and never stored. A typed password that is a reference is read the same
/// way; with "save", the reference as typed is stored, never its value.
@MainActor @Observable
public final class SessionManager {
    /// Every open tab of every window, in tab bar order (`tabs(inWindow:)` gives one window's).
    public private(set) var tabs: [TerminalTab] = []
    /// The main window's selected tab; nil = Vaults. Setting a tab of another window is ignored.
    /// Other windows: `selectedTabID(inWindow:)` / `select(tabID:inWindow:)`.
    public var selectedTabID: UUID? {
        get { selectedTabID(inWindow: nil) }
        set { select(tabID: newValue, inWindow: nil) }
    }
    /// Each window's selected tab (nil key = the main window); a window without an entry shows Vaults.
    private var selections: [UUID?: UUID] = [:]
    /// Theme choices for saved hosts waiting for their debounced save (`applyTheme`), by host id.
    public private(set) var pendingHostThemes: [UUID: PendingThemeChoice] = [:]
    @ObservationIgnored private var themeSaveTasks: [UUID: Task<Void, Never>] = [:]
    /// How long a host theme choice waits for another click before it is saved.
    @ObservationIgnored var themeSaveDelay: Duration = .milliseconds(300)

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
    @ObservationIgnored private let keepAlivePolicy: @MainActor () -> KeepAlivePolicy
    @ObservationIgnored private let terminalType: @MainActor () -> TerminalType
    @ObservationIgnored private let autoReconnectEnabled: @MainActor () -> Bool
    @ObservationIgnored private let agentSocket: @MainActor () -> String?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let opClient: @MainActor () -> (any OnePasswordCLI)?
    /// Every attempt whose session has not ended yet, including ones being closed.
    @ObservationIgnored private var liveAttempts: [ObjectIdentifier: SessionAttempt] = [:]
    /// Hosts whose OS was probed (or is being probed) in this app session.
    @ObservationIgnored private var probedHosts: Set<UUID> = []

    public init(vault: LocalVault, knownHosts: KnownHostsStore,
                makeSession: @escaping @MainActor (ConnectionPlan, any HostKeyEvaluator) -> any TerminalSession,
                deviceName: String, defaultUsername: String,
                initialSizeTimeout: Duration = .milliseconds(500),
                keepAlivePolicy: @escaping @MainActor () -> KeepAlivePolicy = { .normal },
                autoReconnectEnabled: @escaping @MainActor () -> Bool = { true },
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                agentSocket: @escaping @MainActor () -> String? = { nil },
                opClient: @escaping @MainActor () -> (any OnePasswordCLI)? = { nil },
                terminalType: @escaping @MainActor () -> TerminalType = { .default }) {
        self.terminalType = terminalType
        self.agentSocket = agentSocket
        self.opClient = opClient
        self.keepAlivePolicy = keepAlivePolicy
        self.autoReconnectEnabled = autoReconnectEnabled
        self.now = now
        self.sleep = sleep
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
        endAutoReconnect(of: tab)
        reselect(afterRemoving: tab, at: index)
        if let attempt = detachAttempt(of: tab) {
            let session = attempt.session
            Task { await session.close() }
        }
    }

    /// Starts a new session (with a new log) in the same tab, ending the current one first. Ends
    /// auto-reconnect for the tab.
    public func reconnect(tabID: UUID) {
        guard let tab = tab(tabID) else { return }
        endAutoReconnect(of: tab)
        connect(tab, plan: nil)
    }

    /// Closes every session concurrently and returns when all have ended, or after 3 s.
    /// Every tab is removed. Used at quit.
    public func closeAll() async {
        flushPendingThemeSaves()
        let open = tabs
        tabs = []
        selections = [:]
        for tab in open {
            endAutoReconnect(of: tab)
            _ = detachAttempt(of: tab)
        }
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

    // MARK: Tab order, windows, rename, duplicate, theme

    /// The tabs of one window (nil = the main window), in tab bar order.
    public func tabs(inWindow windowID: UUID?) -> [TerminalTab] {
        tabs.filter { $0.windowID == windowID }
    }

    /// The window's selected tab id; nil = Vaults.
    public func selectedTabID(inWindow windowID: UUID?) -> UUID? {
        selections[windowID]
    }

    /// Selects a tab of the window, or Vaults (nil). A tab that is not open in that window is ignored.
    public func select(tabID: UUID?, inWindow windowID: UUID?) {
        guard let tabID else {
            selections[windowID] = nil
            return
        }
        guard let tab = tab(tabID), tab.windowID == windowID else { return }
        selections[windowID] = tabID
    }

    /// Moves the tab to `index` among its window's tabs (clamped), the others keeping their order.
    /// Sessions and the selection are untouched. Unknown ids are ignored.
    public func moveTab(id: UUID, toIndex index: Int) {
        guard let tab = tab(id) else { return }
        var windowTabs = tabs(inWindow: tab.windowID)
        guard let from = windowTabs.firstIndex(where: { $0 === tab }) else { return }
        let to = max(0, min(index, windowTabs.count - 1))
        guard from != to else { return }
        windowTabs.remove(at: from)
        windowTabs.insert(tab, at: to)
        // The window's tabs fill the same places in `tabs`, in their new order.
        var reordered = windowTabs.makeIterator()
        tabs = tabs.map { $0.windowID == tab.windowID ? reordered.next()! : $0 }
    }

    /// Selects the window's next tab, wrapping; from Vaults, the first.
    public func selectNextTab(inWindow windowID: UUID?) { selectAdjacentTab(by: 1, inWindow: windowID) }

    /// Selects the window's previous tab, wrapping; from Vaults, the last.
    public func selectPreviousTab(inWindow windowID: UUID?) { selectAdjacentTab(by: -1, inWindow: windowID) }

    private func selectAdjacentTab(by step: Int, inWindow windowID: UUID?) {
        let windowTabs = tabs(inWindow: windowID)
        guard !windowTabs.isEmpty else { return }
        let next: Int
        if let current = selections[windowID], let index = windowTabs.firstIndex(where: { $0.id == current }) {
            next = (index + step + windowTabs.count) % windowTabs.count
        } else {
            next = step > 0 ? 0 : windowTabs.count - 1
        }
        selections[windowID] = windowTabs[next].id
    }

    /// Renames the tab only (the host keeps its label); a blank name goes back to the host's label.
    public func rename(tabID: UUID, to name: String) {
        guard let tab = tab(tabID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
    }

    /// Opens a new tab with a new session to the same host or quick connect target, right after the
    /// source in its window, and selects it. It keeps the source's theme override, not its custom
    /// title or a typed password. Nil when the source is not open.
    @discardableResult
    public func duplicate(tabID: UUID) -> TerminalTab? {
        guard let source = tab(tabID), let index = tabs.firstIndex(where: { $0 === source }) else { return nil }
        return openCopy(of: source, inWindow: source.windowID, at: index + 1)
    }

    /// The same, as the first tab of the window `windowID` (a new window), selected there.
    @discardableResult
    public func duplicate(tabID: UUID, inWindow windowID: UUID) -> TerminalTab? {
        guard let source = tab(tabID) else { return nil }
        return openCopy(of: source, inWindow: windowID, at: tabs.count)
    }

    private func openCopy(of source: TerminalTab, inWindow windowID: UUID?, at index: Int) -> TerminalTab {
        let copy = TerminalTab(target: source.target, title: source.title, badge: source.badge)
        copy.themeOverrideID = source.themeOverrideID
        copy.windowID = windowID
        tabs.insert(copy, at: index)
        selections[windowID] = copy.id
        connect(copy, plan: nil) // plans afresh; a host that can't be planned shows as disconnected
        return copy
    }

    /// Closes every tab of the window (nil = the main window): its window was closed. Other windows'
    /// tabs keep running.
    public func closeWindow(_ windowID: UUID?) {
        for tab in tabs(inWindow: windowID) { close(tabID: tab.id) }
        selections[windowID] = nil
    }

    /// Tabs of the window counting down to a try or trying now.
    public func waitingForReconnectCount(inWindow windowID: UUID?) -> Int {
        tabs(inWindow: windowID).filter { Self.isWaitingForReconnect($0) }.count
    }

    /// Every tab of the window that is counting down starts its try now.
    public func reconnectWaitingNow(inWindow windowID: UUID?) {
        for tab in tabs(inWindow: windowID) {
            if case .waiting(let attempt, _, _) = tab.autoReconnect { startTry(tab, attempt: attempt) }
        }
    }

    private static func isWaitingForReconnect(_ tab: TerminalTab) -> Bool {
        switch tab.autoReconnect {
        case .waiting, .reconnecting: true
        case .gaveUp, nil: false
        }
    }

    /// The theme the tab is drawn with, as chosen (nil = Default), the one rule the panel and the
    /// terminal both follow: the tab's override (quick connect, or set while its host was gone) wins;
    /// else its saved host's choice, a pending (not yet saved) one first.
    public func themeChoice(tabID: UUID) -> String? {
        guard let tab = tab(tabID) else { return nil }
        if let overrideID = tab.themeOverrideID { return overrideID }
        guard let hostID = tab.hostID else { return nil }
        if let pending = pendingHostThemes[hostID] { return pending.themeID }
        return vault.get(SavedHost.self, id: hostID)?.themeID
    }

    /// A host's theme choice that is shown already but not saved yet; nil = nothing pending.
    public func pendingTheme(forHost hostID: UUID) -> PendingThemeChoice? {
        pendingHostThemes[hostID]
    }

    /// Applies a theme from the tab's theme panel (nil = Default). A saved host's tab shows it at once in
    /// all the host's tabs (`pendingTheme(forHost:)`) and saves it to the host (it syncs) once no other
    /// click came for `themeSaveDelay`, so browsing the gallery writes once; the tab's override is
    /// dropped. Other tabs (quick connect, a deleted host) get a per-tab override.
    public func applyTheme(_ themeID: String?, tabID: UUID) {
        guard let tab = tab(tabID) else { return }
        guard let hostID = tab.hostID, vault.get(SavedHost.self, id: hostID) != nil else {
            tab.themeOverrideID = themeID
            return
        }
        tab.themeOverrideID = nil
        pendingHostThemes[hostID] = PendingThemeChoice(themeID: themeID)
        themeSaveTasks[hostID]?.cancel()
        let delay = themeSaveDelay
        themeSaveTasks[hostID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.commitPendingTheme(hostID: hostID)
        }
    }

    /// Saves every pending host theme now (the panel closed, or the app quits).
    public func flushPendingThemeSaves() {
        for hostID in Array(pendingHostThemes.keys) { commitPendingTheme(hostID: hostID) }
    }

    private func commitPendingTheme(hostID: UUID) {
        themeSaveTasks.removeValue(forKey: hostID)?.cancel()
        guard let pending = pendingHostThemes.removeValue(forKey: hostID),
              var host = vault.get(SavedHost.self, id: hostID), host.themeID != pending.themeID else { return }
        host.themeID = pending.themeID
        vault.saveNow(host)
    }

    /// After `tab` was removed from `tabs` at `index`: if it was its window's selection, selects the
    /// window's tab that took its place, else the one before it, else Vaults.
    private func reselect(afterRemoving tab: TerminalTab, at index: Int) {
        guard selections[tab.windowID] == tab.id else { return }
        let siblings = tabs(inWindow: tab.windowID)
        let place = tabs[..<index].filter { $0.windowID == tab.windowID }.count
        selections[tab.windowID] = siblings.isEmpty ? nil : siblings[min(place, siblings.count - 1)].id
    }

    // MARK: Auto-reconnect

    /// Tabs (of every window) counting down to a try or trying now (`.waiting` or `.reconnecting`).
    public var waitingForReconnectCount: Int {
        tabs.filter { tab in
            switch tab.autoReconnect {
            case .waiting, .reconnecting: true
            case .gaveUp, nil: false
            }
        }.count
    }

    /// Every tab that is counting down starts its try now.
    public func reconnectWaitingNow() {
        for tab in tabs {
            if case .waiting(let attempt, _, _) = tab.autoReconnect { startTry(tab, attempt: attempt) }
        }
    }

    /// Stops auto-reconnect for the tab: a countdown is cancelled, a try that is connecting is ended, and
    /// the tab stays (or becomes) disconnected with the last drop's message. Ignored when not auto-reconnecting.
    public func stopAutoReconnect(tabID: UUID) {
        guard let tab = tab(tabID), let current = tab.autoReconnect else { return }
        endAutoReconnect(of: tab)
        if case .reconnecting = current {
            if let attempt = detachAttempt(of: tab) {
                let session = attempt.session
                Task { await session.close() }
            }
            tab.state = .disconnected(tab.dropMessage)
        }
    }

    private func cancelCountdown(of tab: TerminalTab) {
        tab.countdownToken += 1
        tab.countdown?.cancel()
        tab.countdown = nil
    }

    private func endAutoReconnect(of tab: TerminalTab) {
        cancelCountdown(of: tab)
        tab.autoReconnect = nil
    }

    /// Counts down to try `attempt`, then starts it.
    private func scheduleTry(_ tab: TerminalTab, attempt: Int) {
        cancelCountdown(of: tab)
        guard let delay = ReconnectSchedule.delay(beforeAttempt: attempt) else {
            tab.autoReconnect = nil
            return
        }
        tab.autoReconnect = .waiting(attempt: attempt, deadline: now().addingTimeInterval(delay), delay: delay)
        let token = tab.countdownToken
        let sleep = sleep
        tab.countdown = Task { [weak self, weak tab] in
            do { try await sleep(.seconds(delay)) } catch { return }
            guard let self, let tab, tab.countdownToken == token, self.isOpen(tab) else { return }
            self.startTry(tab, attempt: attempt)
        }
    }

    /// Starts try `attempt` the way `reconnect(tabID:)` does. A try that can't start a session (a password
    /// must be typed, or the host can't be planned any more) ends auto-reconnect; the tab shows why.
    private func startTry(_ tab: TerminalTab, attempt: Int) {
        cancelCountdown(of: tab)
        tab.autoReconnect = .reconnecting(attempt: attempt)
        connect(tab, plan: nil)
        if tab.attempt == nil, tab.resolvingSecrets == nil { tab.autoReconnect = nil }
    }

    /// After the tab's current attempt ended with `reason` (its state already updated).
    private func continueAutoReconnect(after reason: SessionEndReason, attempt: SessionAttempt, tab: TerminalTab) {
        var dropped: SessionError?
        if case .failed(let error) = reason {
            switch error {
            case .connectionFailed, .timedOut: dropped = error
            default: break
            }
        }
        if case .reconnecting(let tried) = tab.autoReconnect {
            guard let dropped else {
                tab.autoReconnect = nil
                return
            }
            tab.dropMessage = dropped.localizedDescription
            if tried >= ReconnectSchedule.maxAttempts {
                cancelCountdown(of: tab)
                tab.autoReconnect = .gaveUp(attempts: tried)
            } else if autoReconnectEnabled() {
                scheduleTry(tab, attempt: tried + 1)
            } else {
                endAutoReconnect(of: tab)
            }
        } else if let dropped, attempt.logID != nil, autoReconnectEnabled() {
            // The attempt had become ready: a session that was running dropped.
            tab.dropMessage = dropped.localizedDescription
            scheduleTry(tab, attempt: 1)
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
        endAutoReconnect(of: tab)
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

    /// Detaches the current attempt (its later events only finish its log), cancels reading its
    /// secrets, rejects a pending host key prompt and stops input. The caller closes the session.
    private func detachAttempt(of tab: TerminalTab) -> SessionAttempt? {
        tab.generation += 1
        tab.resolvingSecrets?.cancel()
        tab.resolvingSecrets = nil
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
        tab.suggestedAction = nil
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
        plan.keepAlive = keepAlivePolicy() // read once per attempt: open tabs keep theirs, Reconnect uses the current one
        plan.terminalType = terminalType() // the same for TERM
        tab.title = plan.label
        if let hostID = tab.hostID, let host = vault.get(SavedHost.self, id: hostID) { tab.badge = host.osBadge }

        if let agentKey = plan.agentKey {
            guard let socket = agentSocket() else {
                tab.state = .disconnected(Self.agentNotFoundMessage)
                tab.suggestedAction = .openOnePasswordSetup
                return
            }
            plan.credential = .agent(socketPath: socket, publicKey: agentKey.publicKey) // also selects system ssh
        }

        var enteredPassword: String? // as typed (maybe a 1Password reference)
        if let entered = tab.enteredPassword {
            switch plan.credential {
            case .password, .none:
                plan.credential = .password(entered)
                enteredPassword = entered
            case .privateKey, .agent:
                break
            }
        }
        if case .none = plan.credential, plan.engine == .citadel {
            tab.state = .awaitingPassword(prompt: "Password for \(Self.userAtHost(plan))")
            return
        }

        tab.state = .connecting
        if Self.secretReferences(in: plan.credential) {
            resolveSecrets(of: plan, enteredPassword: enteredPassword, tab: tab)
            return
        }
        startAttempt(tab, plan: plan, enteredPassword: enteredPassword)
    }

    // MARK: Secrets from 1Password

    /// Whether the plan's password or key passphrase is a 1Password secret reference.
    private static func secretReferences(in credential: SSHCredential) -> Bool {
        switch credential {
        case .password(let password): SecretReference.isReference(password)
        case .privateKey(_, _, let passphrase?): SecretReference.isReference(passphrase)
        case .privateKey, .none, .agent: false
        }
    }

    /// Reads the plan's referenced secret with `op read`, then starts the attempt with the value. The value
    /// lives only in that attempt's plan: it is never stored, and every attempt (including each automatic
    /// try) reads it again. A typed reference is resolved the same way; saving it stores the reference
    /// (`enteredPassword`), never the value. A failure ends the attempt (and auto-reconnect) with the
    /// error's message.
    private func resolveSecrets(of plan: ConnectionPlan, enteredPassword: String?, tab: TerminalTab) {
        let generation = tab.generation
        guard let client = opClient() else {
            failResolving(tab, .cliNotFound)
            return
        }
        let credential = plan.credential
        tab.resolvingSecrets = Task { [weak self, weak tab] in
            let result: Result<SSHCredential, OnePasswordError>
            do throws(OnePasswordError) {
                result = .success(try await Self.resolve(credential, with: client))
            } catch {
                result = .failure(error)
            }
            guard let self, let tab, self.isOpen(tab), tab.generation == generation else { return }
            tab.resolvingSecrets = nil
            switch result {
            case .success(let resolved):
                var plan = plan
                plan.credential = resolved
                self.startAttempt(tab, plan: plan, enteredPassword: enteredPassword)
            case .failure(let error):
                self.failResolving(tab, error)
            }
        }
    }

    private nonisolated static func resolve(_ credential: SSHCredential,
                                            with client: any OnePasswordCLI) async throws(OnePasswordError) -> SSHCredential {
        switch credential {
        case .password(let reference) where SecretReference.isReference(reference):
            return .password(try await client.read(reference: Self.trimmed(reference)))
        case .privateKey(let type, let pem, let passphrase?) where SecretReference.isReference(passphrase):
            return .privateKey(type: type, pem: pem, passphrase: try await client.read(reference: Self.trimmed(passphrase)))
        case .password, .privateKey, .none, .agent:
            return credential
        }
    }

    private nonisolated static func trimmed(_ reference: String) -> String {
        reference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func failResolving(_ tab: TerminalTab, _ error: OnePasswordError) {
        endAutoReconnect(of: tab)
        switch error {
        case .cancelled:
            tab.state = .disconnected("Cancelled")
        case .cliNotFound, .integrationOff, .appLocked:
            tab.state = .disconnected(error.message)
            tab.suggestedAction = .openOnePasswordSetup
        case .timedOut, .notFound, .failed:
            tab.state = .disconnected(error.message)
        }
    }

    /// Makes the attempt's session and starts it.
    private func startAttempt(_ tab: TerminalTab, plan: ConnectionPlan, enteredPassword: String?) {
        let generation = tab.generation
        let evaluator = PromptingHostKeyEvaluator(store: knownHosts) { [weak self, weak tab] candidate, check in
            guard let self, let tab else { return .rejected }
            return await self.askHostKey(tab: tab, generation: generation, candidate, check)
        }
        let session = makeSession(plan, evaluator)
        let (inputs, inputContinuation) = AsyncStream<SessionInput>.makeStream()
        let attempt = SessionAttempt(plan: plan, session: session, inputs: inputContinuation,
                                     enteredPassword: enteredPassword)
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
            // ssh asks in the terminal (no stored secret): the user may have to type a password, so this
            // try is no longer automatic.
            if let current, case .reconnecting = current.autoReconnect, case .none = attempt.plan.credential {
                endAutoReconnect(of: current)
            }
        case .ready:
            guard let current, attempt.logID == nil else { return }
            endAutoReconnect(of: current)
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
            continueAutoReconnect(after: reason, attempt: attempt, tab: current)
        }
    }

    private func sessionBecameReady(_ attempt: SessionAttempt, tab: TerminalTab) {
        let plan = attempt.plan
        let log = vault.saveNow(ConnectionLog(hostID: plan.hostID, hostLabel: plan.label, username: plan.username,
                                              deviceName: deviceName, startedAt: Date()))
        attempt.logID = log.id
        // The server accepted the typed password: now it may be saved (where the existing rule says), as
        // typed: a 1Password reference stays a reference, its value is never stored.
        if let entered = attempt.enteredPassword, tab.saveEnteredPassword, let hostID = tab.hostID,
           case .password = plan.credential {
            storePassword(entered, hostID: hostID)
        }
        // From now on the vault (or a new prompt) decides, so later vault edits are not shadowed.
        tab.enteredPassword = nil
        tab.saveEnteredPassword = false
        if let hostID = plan.hostID, var host = vault.get(SavedHost.self, id: hostID) {
            host.lastConnectedAt = Date()
            vault.saveNow(host)
            // Once per host per app session, and again on the next connection after the user chose
            // "Automatic" in Host Details (`vault.requestOSProbe`), even if nothing was detected.
            if !host.osBadgeIsManual {
                let requested = vault.takeOSProbeRequest(for: hostID)
                if requested || !probedHosts.contains(hostID) { probeOS(of: hostID, over: attempt.session) }
            }
        }
        if let script = plan.startupScript, !script.isEmpty {
            attempt.inputs.yield(.bytes(Array((script + "\n").utf8)))
        }
    }

    private func probeOS(of hostID: UUID, over session: any TerminalSession) {
        probedHosts.insert(hostID)
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
            case .agent:
                // 1Password may hold another key, be locked, or not have been allowed to sign.
                tab.suggestedAction = .openOnePasswordSetup
                return .disconnected("The server didn't accept the key from 1Password's SSH agent for \(who). Either the key's public half isn't in ~/.ssh/authorized_keys on the server, or 1Password is locked \u{2014} unlock it and try again.")
            case .none:
                return .disconnected(SessionError.authenticationFailed.localizedDescription)
            }
        case .failed(let error):
            if case .agentUnavailable = error { tab.suggestedAction = .openOnePasswordSetup }
            return .disconnected(error.localizedDescription)
        }
    }

    static let agentNotFoundMessage =
        "1Password's SSH agent wasn't found. Turn on \u{201C}Use the SSH agent\u{201D} in 1Password \u{2192} Settings \u{2192} Developer."

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

/// A theme chosen for a saved host that is not saved yet (nil = Default).
public struct PendingThemeChoice: Equatable, Sendable {
    public let themeID: String?

    public init(themeID: String?) {
        self.themeID = themeID
    }
}
