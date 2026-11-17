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
    public internal(set) var windowID: UUID?

    /// The connection log of the current attempt (the connection screen's steps); reset when an attempt
    /// starts (open, Reconnect / Start over, an automatic try, a typed password).
    public fileprivate(set) var connectionLog: [ConnectionLogLine] = []
    /// The failure text for the connection screen; nil while connecting, once connected, or after a
    /// normal close.
    public var connectionFailure: String? {
        connectionLog.last(where: { $0.status == .failed && $0.step == nil })?.text
    }
    /// Whether this attempt reached `.connected` (the terminal went live).
    public fileprivate(set) var hasEverConnected = false
    /// Whether this tab's terminal has ever been live (any attempt). Never reset by a new attempt, so
    /// a tab that dropped keeps its scrollback and banner instead of the connection screen.
    public fileprivate(set) var hadLiveSession = false
    /// The address the current attempt connects to: the saved host's address, or its backup address once
    /// the main one couldn't be reached. nil before an attempt was planned.
    public fileprivate(set) var currentAddress: String?
    /// Whether the current attempt moved on to the saved host's backup address.
    public fileprivate(set) var isUsingBackupAddress = false

    /// The log as text for "Copy logs": a header (host label, user@host:port, engine, date) and one
    /// line per step with its time and status. Never contains secrets: only names, addresses, ports,
    /// auth method names and error messages (which never carry secrets).
    public func connectionLogText() -> String {
        var text = "Connection log \u{2014} \(logContext?.label ?? title)\n"
        if let context = logContext {
            text += "SSH \(context.username)@\(context.host):\(context.port)\n"
            if let backupReason = context.backupReason {
                text += "Backup address used: \(backupReason)\n"
            }
            text += "Engine: \(context.engine == .citadel ? "built-in (Citadel)" : "system ssh")\n"
            text += "Started: \(Self.headerDateFormatter.string(from: context.startedAt))\n"
        }
        text += "\n"
        if connectionLog.isEmpty { text += "(no steps reported)\n" }
        for line in connectionLog {
            let mark = switch line.status {
            case .done: "done"
            case .inProgress: "...."
            case .failed: "FAIL"
            }
            text += "\(Self.lineTimeFormatter.string(from: line.at))  [\(mark)]  \(line.text)\n"
        }
        return text
    }

    /// What the current attempt connects to, for the log's header.
    fileprivate struct LogContext {
        let label: String
        let username: String
        /// The address connected to (the backup address after a fallback).
        var host: String
        let port: Int
        let engine: SSHEngine
        let startedAt: Date
        /// After a fallback: "main address <address> unreachable (<reason>)".
        var backupReason: String?
    }

    @ObservationIgnored fileprivate var logContext: LogContext?
    /// The next log line's id; never reset, so ids stay unique across attempts.
    @ObservationIgnored fileprivate var nextLogLineID = 0

    private static let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }()

    private static let lineTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Starts a new attempt's log.
    fileprivate func resetConnectionLog(context: LogContext?) {
        connectionLog = []
        hasEverConnected = false
        logContext = context
        currentAddress = context?.host
        isUsingBackupAddress = false
    }

    /// The main address couldn't be reached: its step failed, `note` says so, and the log (header,
    /// `currentAddress`) continues with the backup address.
    fileprivate func switchToBackupAddress(_ backup: String, main: String, reason: String, note: String, at date: Date) {
        finishCurrentStep(as: .failed)
        appendLine(step: nil, text: note, status: .done, at: date)
        logContext?.host = backup
        logContext?.backupReason = "main address \(main) unreachable (\(reason))"
        currentAddress = backup
        isUsingBackupAddress = true
    }

    /// A new step: the step before it is done, this one is in progress.
    fileprivate func appendStep(_ step: ConnectionStep, at date: Date) {
        finishCurrentStep(as: .done)
        appendLine(step: step, text: step.text, status: .inProgress, at: date)
    }

    /// Marks the step in progress (if any) `status`.
    fileprivate func finishCurrentStep(as status: ConnectionLogLine.Status) {
        guard let index = connectionLog.lastIndex(where: { $0.status == .inProgress }) else { return }
        connectionLog[index].status = status
    }

    /// The attempt failed: the step in progress failed, and the message follows as a failed line.
    fileprivate func appendFailure(_ message: String, at date: Date) {
        finishCurrentStep(as: .failed)
        appendLine(step: nil, text: message, status: .failed, at: date)
    }

    /// Replaces the text of the attempt's failure line (the last line) when it is `old`.
    fileprivate func replaceLastFailure(with text: String, ifItIs old: String) {
        guard let index = connectionLog.indices.last, connectionLog[index].status == .failed,
              connectionLog[index].step == nil, connectionLog[index].text == old else { return }
        let line = connectionLog[index]
        connectionLog[index] = ConnectionLogLine(id: line.id, step: nil, text: text, status: .failed, at: line.at)
    }

    private func appendLine(step: ConnectionStep?, text: String, status: ConnectionLogLine.Status, at date: Date) {
        connectionLog.append(ConnectionLogLine(id: nextLogLineID, step: step, text: text, status: status, at: date))
        nextLogLineID += 1
    }

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
    /// Text to type once the tab's first connection is ready (`runOnHosts`), after the startup script
    /// and tmux attach. Typed once; dropped by Reconnect / Start over and automatic tries, so it never
    /// runs again on a later connection. A typed password (also after a rejected one) keeps it.
    @ObservationIgnored fileprivate var textAfterFirstReady: String?
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

    /// The quick connect target this tab connects to; nil for a saved host.
    var quickConnectTarget: QuickConnectTarget? {
        if case .quickConnect(let quick) = target { return quick }
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

/// How a snippet is typed into a terminal: `paste` inserts it without running it; `run` also presses
/// Return.
public enum SnippetDelivery: Sendable, Equatable {
    case paste, run
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
    /// The server answered (TCP up or a later step reported, or `.connected`): a failure from here on
    /// never moves on to the backup address.
    var reachedServer = false

    var usedEnteredPassword: Bool { enteredPassword != nil }

    init(plan: ConnectionPlan, session: any TerminalSession,
         inputs: AsyncStream<SessionInput>.Continuation, enteredPassword: String?) {
        self.plan = plan
        self.session = session
        self.inputs = inputs
        self.enteredPassword = enteredPassword
    }
}

/// Workspaces (`SessionManager+Workspaces.swift`): a workspace's panes are ordinary tabs of `tabs` (so
/// `tabs(inWindow:)` lists every session of the window, panes included, each workspace's panes together
/// at its place in reading order); the tab bar shows `strip(inWindow:)`, where a workspace is one item.
/// A window's selection is a strip item; `selectedTabID(inWindow:)` gives a selected workspace's focused
/// pane, so commands acting on "the selected tab" act on that pane.
///
/// Drives terminal sessions for the UI: host key and password prompts, connection logs, OS
/// detection, startup scripts, reconnect, auto-reconnect and close-all at quit.
///
/// Auto-reconnect: when the session of a tab that had become ready ends with `.connectionFailed`,
/// `.unreachable` or `.timedOut` (a dropped connection) and `autoReconnectEnabled()` is true, the tab counts down
/// (`.waiting`) and then tries again (`.reconnecting`) the way `reconnect(tabID:)` does, on the
/// `ReconnectSchedule`. A try that drops the same way, before or after it connected, leads to the next
/// countdown, or to `.gaveUp` after the last; a try that becomes ready, fails any other way, or needs a
/// password typed ends auto-reconnect (`nil`) and the tab shows what it would after `reconnect`.
///
/// 1Password agent keys: a plan with `agentKey` gets its socket from `agentSocket()` at every attempt and
/// connects with `.agent(socketPath:publicKey:)` through system ssh. Without a socket no session starts:
/// the tab is disconnected with a setup hint and `suggestedAction = .openOnePasswordSetup`. An attempt
/// that ends with `.agentUnavailable`, or an agent attempt whose key the server rejects
/// (`.authenticationFailed`), also suggests the setup; auto-reconnect retries neither. For a rejected
/// agent key, `agentKeys` (when given) asks the agent what it offers right then, and the message and
/// suggestion become the precise one (`AgentAuthFailure`): no keys or not the pinned key (choose the
/// vaults), locked / not running, blocked by macOS, or the server's authorized_keys.
///
/// 1Password references: a password or key passphrase that is an `op://` reference is read with
/// `opClient()` before each attempt starts (after the agent check; agent plans never read). The value is
/// used for that attempt only and never stored. A typed password that is a reference is read the same
/// way; with "save", the reference as typed is stored, never its value.
///
/// Host updates: by default (the Mac) a ready connection saves the host's `lastConnectedAt` and the
/// detected OS badge, a typed password can be saved and theme changes are saved on the host. With
/// `recordsHostUpdates: false` (iOS, which may hold a stale copy of a host that sync would then spread)
/// none of these rewrite a synced record: the detected badge is kept in memory (`detectedBadge(hostID:)`)
/// and shown on tabs; connection logs (new records) are still saved.
///
/// Backup address (`ConnectionPlan.fallbackHost`, from the saved host's `fallbackAddress`): every attempt
/// (open, Reconnect, an automatic try, a workspace pane) goes to the main address first, with
/// `reachTimeout` = `ConnectionFallback.reachTimeout`. When it ends `.timedOut` or `.unreachable` before
/// the server was reached (`ConnectionFallback.shouldTryBackup`), the log notes it and a new attempt on
/// the backup address starts at once in the same log, with the same credential (secrets aren't read
/// again), the normal timeouts and a host key evaluator that accepts the key already trusted for the main
/// address. Sign-in, host key and later failures, and the user closing or reconnecting, never fall back.
/// The tab's `currentAddress` / `isUsingBackupAddress` and the log header say which address is in use.
///
/// Imported keys (iOS): `hostPlanner` plans saved hosts (`ConnectionPlanner.plan(hostID:vault:platform:importedKeys:)`).
/// When the server refuses every offered key (`.privateKeys`), the tab says so and suggests `.importKey`;
/// auto-reconnect doesn't retry it.
@MainActor @Observable
public final class SessionManager {
    /// Every open tab of every window, in tab bar order (`tabs(inWindow:)` gives one window's).
    public internal(set) var tabs: [TerminalTab] = []
    /// The tab being dragged from a tab bar right now (set by the app while the drag lasts), so a
    /// terminal area can refuse a drop of the tab it is itself showing. A workspace's id while its tab
    /// bar item is dragged (to reorder it).
    public var draggedTabID: UUID?
    /// A workspace's tab bar item is being dragged: terminal areas take no drop then (a workspace only
    /// reorders in the tab bar).
    public var isDraggingWorkspace: Bool {
        draggedTabID.map { workspacesByID[$0] != nil } ?? false
    }
    /// The main window's selected tab; nil = Vaults. Setting a tab of another window is ignored.
    /// Other windows: `selectedTabID(inWindow:)` / `select(tabID:inWindow:)`.
    public var selectedTabID: UUID? {
        get { selectedTabID(inWindow: nil) }
        set { select(tabID: newValue, inWindow: nil) }
    }
    /// Each window's selected strip item, a plain tab's or a workspace's id (nil key = the main window);
    /// a window without an entry shows Vaults.
    var selections: [UUID?: UUID] = [:]
    /// Every open workspace, by id.
    var workspacesByID: [UUID: Workspace] = [:]
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
    /// Lists the keys of the agent at a socket path (public halves only); nil = never asked.
    @ObservationIgnored private let agentKeys: (@Sendable (String) async throws -> [AgentKey])?
    /// Every attempt whose session has not ended yet, including ones being closed.
    @ObservationIgnored private var liveAttempts: [ObjectIdentifier: SessionAttempt] = [:]
    /// Hosts whose OS was probed (or is being probed) in this app session.
    @ObservationIgnored private var probedHosts: Set<UUID> = []
    /// Plans a saved host's connection; nil = `ConnectionPlanner.plan(hostID:vault:)` (the Mac).
    @ObservationIgnored private let hostPlanner: (@MainActor (UUID, LocalVault) throws -> ConnectionPlan)?
    /// False on iOS: connecting never rewrites a saved host (or identity); see the type's doc.
    @ObservationIgnored private let recordsHostUpdates: Bool
    /// OS badges detected in this app session, kept here instead of on the host when
    /// `recordsHostUpdates` is false.
    private var detectedBadges: [UUID: OSBadge] = [:]

    public init(vault: LocalVault, knownHosts: KnownHostsStore,
                makeSession: @escaping @MainActor (ConnectionPlan, any HostKeyEvaluator) -> any TerminalSession,
                deviceName: String, defaultUsername: String,
                initialSizeTimeout: Duration = .milliseconds(500),
                keepAlivePolicy: @escaping @MainActor () -> KeepAlivePolicy = { .standard },
                autoReconnectEnabled: @escaping @MainActor () -> Bool = { true },
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                agentSocket: @escaping @MainActor () -> String? = { nil },
                opClient: @escaping @MainActor () -> (any OnePasswordCLI)? = { nil },
                agentKeys: (@Sendable (String) async throws -> [AgentKey])? = nil,
                terminalType: @escaping @MainActor () -> TerminalType = { .default },
                recordsHostUpdates: Bool = true,
                hostPlanner: (@MainActor (UUID, LocalVault) throws -> ConnectionPlan)? = nil) {
        self.recordsHostUpdates = recordsHostUpdates
        self.hostPlanner = hostPlanner
        self.terminalType = terminalType
        self.agentKeys = agentKeys
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
        let plan = try planHost(hostID)
        let badge = displayBadge(hostID: hostID)
        return add(TerminalTab(target: .host(hostID), title: plan.label, badge: badge), plan: plan)
    }

    /// Opens a tab for a saved host in the window `windowID` (nil = the main window), selected there.
    /// Throws as `open(hostID:)` does; no tab is created then.
    /// After a network change or a wake from sleep: every live session checks right away whether its
    /// server still answers (`TerminalSession.checkConnection`); a dead one drops and reconnects.
    public func checkConnections() {
        for attempt in liveAttempts.values {
            let session = attempt.session
            Task { await session.checkConnection() }
        }
    }

    @discardableResult
    public func open(hostID: UUID, inWindow windowID: UUID?) throws -> TerminalTab {
        let plan = try planHost(hostID)
        let tab = appendTab(hostID: hostID, plan: plan, inWindow: windowID)
        select(tabID: tab.id, inWindow: windowID)
        return tab
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

    /// Ends the tab's session (if any) and removes the tab. A workspace pane is closed as `closePane` does.
    public func close(tabID: UUID) {
        guard let tab = tab(tabID) else { return }
        if let workspace = workspace(containing: tabID) {
            removeClosedPane(tab, from: workspace)
            return
        }
        let window = tab.windowID
        let place = strip(inWindow: window).firstIndex(of: .tab(tabID))
        tabs.removeAll { $0 === tab }
        endSession(of: tab)
        reselect(afterRemoving: tabID, at: place, inWindow: window)
    }

    /// Ends auto-reconnect and the session of a tab that was removed.
    func endSession(of tab: TerminalTab) {
        endAutoReconnect(of: tab)
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
        tab.textAfterFirstReady = nil
        connect(tab, plan: nil)
    }

    /// Closes every session concurrently and returns when all have ended, or after 3 s.
    /// Every tab is removed. Used at quit.
    public func closeAll() async {
        flushPendingThemeSaves()
        let open = tabs
        tabs = []
        selections = [:]
        workspacesByID = [:]
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

    /// Every session of one window (nil = the main window): plain tabs and workspace panes, in tab bar
    /// order with each workspace's panes together at its place, in reading order. The tab bar itself
    /// shows `strip(inWindow:)`.
    public func tabs(inWindow windowID: UUID?) -> [TerminalTab] {
        tabs.filter { $0.windowID == windowID }
    }

    /// The tab the window's commands act on: the selected plain tab, or the selected workspace's focused
    /// pane; nil = Vaults.
    public func selectedTabID(inWindow windowID: UUID?) -> UUID? {
        guard let id = selections[windowID] else { return nil }
        if let workspace = workspacesByID[id] { return workspace.focusedPaneID }
        return id
    }

    /// Selects a strip item of the window, or Vaults (nil): a plain tab, a workspace (by its id), or a
    /// workspace pane (its workspace is selected and the pane focused). Anything not open in that window
    /// is ignored.
    public func select(tabID: UUID?, inWindow windowID: UUID?) {
        guard let tabID else {
            selections[windowID] = nil
            return
        }
        if let workspace = workspacesByID[tabID] {
            guard workspace.windowID == windowID else { return }
            selections[windowID] = workspace.id
            return
        }
        guard let tab = tab(tabID), tab.windowID == windowID else { return }
        if let workspace = workspace(containing: tabID) {
            selections[windowID] = workspace.id
            focusPane(tabID)
        } else {
            selections[windowID] = tabID
        }
    }

    /// Moves a strip item (a plain tab's or a workspace's id) to `index` among its window's strip items
    /// (clamped), the others keeping their order. Sessions and the selection are untouched. Unknown ids,
    /// and panes (not strip items), are ignored.
    public func moveTab(id: UUID, toIndex index: Int) {
        let window: UUID?
        if let workspace = workspacesByID[id] {
            window = workspace.windowID
        } else if let tab = tab(id) {
            window = tab.windowID
        } else {
            return
        }
        var items = strip(inWindow: window)
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(index, items.count - 1))
        guard from != to else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
        applyOrder(items, inWindow: window)
    }

    /// Selects the window's next strip item (tab or workspace), wrapping; from Vaults, the first.
    public func selectNextTab(inWindow windowID: UUID?) { selectAdjacentTab(by: 1, inWindow: windowID) }

    /// Selects the window's previous strip item (tab or workspace), wrapping; from Vaults, the last.
    public func selectPreviousTab(inWindow windowID: UUID?) { selectAdjacentTab(by: -1, inWindow: windowID) }

    private func selectAdjacentTab(by step: Int, inWindow windowID: UUID?) {
        let items = strip(inWindow: windowID)
        guard !items.isEmpty else { return }
        let next: Int
        if let current = selections[windowID], let index = items.firstIndex(where: { $0.id == current }) {
            next = (index + step + items.count) % items.count
        } else {
            next = step > 0 ? 0 : items.count - 1
        }
        selections[windowID] = items[next].id
    }

    /// Renames the tab only (the host keeps its label); a blank name goes back to the host's label.
    public func rename(tabID: UUID, to name: String) {
        guard let tab = tab(tabID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
        workspace(containing: tabID)?.refreshUnsavedChanges()
    }

    /// Opens a new tab with a new session to the same host or quick connect target, right after the
    /// source in its window (after its workspace, for a pane), and selects it. It keeps the source's theme
    /// override, not its custom title or a typed password. Nil when the source is not open.
    @discardableResult
    public func duplicate(tabID: UUID) -> TerminalTab? {
        guard let source = tab(tabID), let index = tabs.firstIndex(where: { $0 === source }) else { return nil }
        let copy = openCopy(of: source, inWindow: source.windowID, at: index + 1)
        if workspace(containing: tabID) != nil { normalizeOrder(inWindow: source.windowID) }
        return copy
    }

    /// The same, as the first tab of the window `windowID` (a new window), selected there.
    @discardableResult
    public func duplicate(tabID: UUID, inWindow windowID: UUID) -> TerminalTab? {
        guard let source = tab(tabID) else { return nil }
        return openCopy(of: source, inWindow: windowID, at: tabs.count)
    }

    private func openCopy(of source: TerminalTab, inWindow windowID: UUID?, at index: Int, select: Bool = true) -> TerminalTab {
        let copy = TerminalTab(target: source.target, title: source.title, badge: source.badge)
        copy.themeOverrideID = source.themeOverrideID
        copy.windowID = windowID
        tabs.insert(copy, at: index)
        if select { selections[windowID] = copy.id }
        connect(copy, plan: nil) // plans afresh; a host that can't be planned shows as disconnected
        return copy
    }

    // MARK: New tabs for workspaces (appended to their window, connecting, not selected)

    /// A copy of `source` as `duplicate` makes it, appended, not selected.
    func appendCopy(of source: TerminalTab) -> TerminalTab {
        openCopy(of: source, inWindow: source.windowID, at: tabs.count, select: false)
    }

    /// A tab for a saved host with its plan made already.
    func appendTab(hostID: UUID, plan: ConnectionPlan, inWindow windowID: UUID?) -> TerminalTab {
        let tab = TerminalTab(target: .host(hostID), title: plan.label, badge: displayBadge(hostID: hostID))
        tab.windowID = windowID
        tabs.append(tab)
        connect(tab, plan: plan)
        return tab
    }

    /// A tab for a saved host that may not be plannable: then it shows as disconnected with the reason.
    func appendTab(hostID: UUID, fallbackTitle: String, inWindow windowID: UUID?) -> TerminalTab {
        if let plan = try? planHost(hostID) {
            return appendTab(hostID: hostID, plan: plan, inWindow: windowID)
        }
        let tab = TerminalTab(target: .host(hostID), title: fallbackTitle, badge: nil)
        tab.windowID = windowID
        tabs.append(tab)
        connect(tab, plan: nil)
        return tab
    }

    func appendTab(quickConnect target: QuickConnectTarget, inWindow windowID: UUID?) -> TerminalTab {
        let plan = ConnectionPlanner.plan(quickConnect: target, defaultUsername: defaultUsername)
        let tab = TerminalTab(target: .quickConnect(target), title: plan.label, badge: nil)
        tab.windowID = windowID
        tabs.append(tab)
        connect(tab, plan: plan)
        return tab
    }

    func plan(hostID: UUID) throws -> ConnectionPlan {
        try planHost(hostID)
    }

    /// Closes every tab of the window (nil = the main window), workspaces included: its window was
    /// closed. Other windows' tabs keep running.
    public func closeWindow(_ windowID: UUID?) {
        for workspace in workspacesByID.values where workspace.windowID == windowID { closeWorkspace(workspace.id) }
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

    /// Sets a tab's own theme (opening a saved workspace's pane).
    func setThemeOverride(_ themeID: String?, tabID: UUID) {
        tab(tabID)?.themeOverrideID = themeID
    }

    /// Applies a theme from the tab's theme panel (nil = Default). A workspace's pane gets it as its own
    /// theme only (see below). A saved host's tab shows it at once in
    /// all the host's tabs (`pendingTheme(forHost:)`) and saves it to the host (it syncs) once no other
    /// click came for `themeSaveDelay`, so browsing the gallery writes once; the tab's override is
    /// dropped. Other tabs (quick connect, a deleted host) get a per-tab override.
    public func applyTheme(_ themeID: String?, tabID: UUID) {
        guard let tab = tab(tabID) else { return }
        // A workspace's pane: that pane only, never its host (nil = follows the host again); part of
        // what the workspace saves.
        if let workspace = workspace(containing: tabID) {
            tab.themeOverrideID = themeID
            workspace.refreshUnsavedChanges()
            return
        }
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
              recordsHostUpdates,
              var host = vault.get(SavedHost.self, id: hostID), host.themeID != pending.themeID else { return }
        host.themeID = pending.themeID
        vault.saveNow(host)
    }

    /// After the strip item `id` was removed from the window's strip at `place`: if it was the window's
    /// selection, selects the item that took its place, else the one before it, else Vaults.
    func reselect(afterRemoving id: UUID, at place: Int?, inWindow windowID: UUID?) {
        guard selections[windowID] == id else { return }
        let items = strip(inWindow: windowID)
        selections[windowID] = items.isEmpty ? nil : items[min(place ?? 0, items.count - 1)].id
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
            tab.appendFailure(tab.dropMessage ?? "Stopped.", at: now())
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
        tab.textAfterFirstReady = nil
        tab.autoReconnect = .reconnecting(attempt: attempt)
        connect(tab, plan: nil)
        if tab.attempt == nil, tab.resolvingSecrets == nil { tab.autoReconnect = nil }
    }

    /// After the tab's current attempt ended with `reason` (its state already updated).
    private func continueAutoReconnect(after reason: SessionEndReason, attempt: SessionAttempt, tab: TerminalTab) {
        var dropped: SessionError?
        if case .failed(let error) = reason {
            switch error {
            case .connectionFailed, .unreachable, .timedOut: dropped = error
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
        tab.saveEnteredPassword = save && tab.canSavePassword && recordsHostUpdates
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

    /// Sends to the tab only when it is connected (a broadcast target).
    @discardableResult
    func sendIfConnected(tabID: UUID, _ bytes: [UInt8]) -> Bool {
        guard let tab = tab(tabID), let attempt = Self.liveAttempt(of: tab) else { return false }
        attempt.inputs.yield(.bytes(bytes))
        return true
    }

    // MARK: Snippets

    /// Types `text` into the tab as `deliveryText(_:as:)` gives it. False, and nothing sent, when the
    /// tab is not open or not connected (`.connected` with a live session). Placeholders must already
    /// be filled. When the tab is the focused pane of a broadcasting workspace, the same bytes also go to
    /// the workspace's other included, connected panes (as typed input does, `sendInput`).
    /// `bracketedPaste`: the terminal has bracketed paste on (the shell asked for it), so a `.paste`
    /// is wrapped in its markers and a multi-line paste is inserted, not run line by line.
    @discardableResult
    public func deliver(_ text: String, as delivery: SnippetDelivery, toTab tabID: UUID,
                        bracketedPaste: Bool = false) -> Bool {
        deliver(text, as: delivery, toTab: tabID, bracketedPaste: bracketedPaste, broadcasting: true)
    }

    /// `broadcasting: false` types into this tab only, even when it is a broadcasting workspace's
    /// focused pane ("Run in all tabs" already reaches every pane itself).
    @discardableResult
    private func deliver(_ text: String, as delivery: SnippetDelivery, toTab tabID: UUID,
                         bracketedPaste: Bool, broadcasting: Bool) -> Bool {
        guard let tab = tab(tabID), let attempt = Self.liveAttempt(of: tab) else { return false }
        let typed = Self.deliveryText(text, as: delivery, bracketedPaste: bracketedPaste)
        guard !typed.isEmpty else { return true }
        let bytes = Array(typed.utf8)
        attempt.inputs.yield(.bytes(bytes))
        if broadcasting {
            for target in broadcastTargets(fromTab: tabID) { sendIfConnected(tabID: target, bytes) }
        }
        return true
    }

    /// "Run in all tabs": delivers `text` to every connected tab of the window (nil = the main window);
    /// other tabs and windows are left alone. Returns how many tabs it was typed into.
    @discardableResult
    public func deliverToAllTabs(_ text: String, as delivery: SnippetDelivery, inWindow windowID: UUID?) -> Int {
        tabs(inWindow: windowID).filter {
            deliver(text, as: delivery, toTab: $0.id, bracketedPaste: false, broadcasting: false)
        }.count
    }

    /// How many tabs `deliverToAllTabs` would type into now (for its confirmation).
    public func connectableTabCount(inWindow windowID: UUID?) -> Int {
        tabs(inWindow: windowID).filter { Self.liveAttempt(of: $0) != nil }.count
    }

    /// "Run on several hosts": opens a new tab per host (each host once, in order) in the main window,
    /// connecting as `open(hostID:)` does (prompts as usual), and types `text` as `.run` once that tab's
    /// first connection is ready, after the startup snippet and tmux attach, so it runs inside the session
    /// the user sees. It is typed on that first connection only: never again on Reconnect or an
    /// automatic reconnect (a first try that fails before it is ready drops it). Every host is planned
    /// first: when one can't be (missing, no address, no username), its error is thrown and no tab opens.
    @discardableResult
    public func runOnHosts(_ hostIDs: [UUID], text: String) throws -> [TerminalTab] {
        var seen: Set<UUID> = []
        let ids = hostIDs.filter { seen.insert($0).inserted }
        let plans = try ids.map { try planHost($0) }
        let typed = Self.deliveryText(text, as: .run)
        return zip(ids, plans).map { id, plan in
            let tab = TerminalTab(target: .host(id), title: plan.label, badge: displayBadge(hostID: id))
            tab.textAfterFirstReady = typed
            return add(tab, plan: plan)
        }
    }

    /// What is typed for a snippet: every newline (`\n`, `\r\n` or `\r`) becomes a carriage return
    /// (Return), and `.run` adds one at the end unless the text already ends with a newline.
    static func deliveryText(_ text: String, as delivery: SnippetDelivery, bracketedPaste: Bool = false) -> String {
        var typed = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if delivery == .run, !typed.hasSuffix("\r") { typed += "\r" }
        if delivery == .paste, bracketedPaste {
            // An end marker inside the text would end the paste early and run the rest.
            typed = typed.replacingOccurrences(of: "\u{1B}[201~", with: "")
            typed = "\u{1B}[200~" + typed + "\u{1B}[201~"
        }
        return typed
    }

    /// Why `runCommand(_:inTab:)` failed before reaching the server.
    public struct TabNotConnected: LocalizedError {
        public var errorDescription: String? { "This tab is not connected." }
    }

    /// Runs `command` on a separate exec channel of the tab's connection (nothing is typed into the
    /// terminal). Throws `TabNotConnected` unless the tab is connected.
    public func runCommand(_ command: String, inTab tabID: UUID) async throws -> String {
        guard let tab = tab(tabID), let attempt = Self.liveAttempt(of: tab) else { throw TabNotConnected() }
        return try await attempt.session.runCommand(command)
    }

    /// The tab's session when the tab is connected and it can take input.
    private static func liveAttempt(of tab: TerminalTab) -> SessionAttempt? {
        guard tab.state == .connected else { return nil }
        return tab.attempt
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

    func tab(_ id: UUID) -> TerminalTab? {
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
        tab.resetConnectionLog(context: nil)
        var plan: ConnectionPlan
        if let given {
            plan = given
        } else {
            do {
                plan = try currentPlan(for: tab.target)
            } catch {
                tab.state = .disconnected(error.localizedDescription)
                tab.appendFailure(error.localizedDescription, at: now())
                return
            }
        }
        plan.keepAlive = keepAlivePolicy() // read once per attempt: open tabs keep theirs, Reconnect uses the current one
        plan.terminalType = terminalType() // the same for TERM
        // An automatic reconnect try gives up fast while the server is still down.
        if case .reconnecting = tab.autoReconnect { plan.connectTimeout = .seconds(5) }
        // With a backup address, an unreachable main address gives way to it quickly.
        plan.reachTimeout = plan.fallbackHost == nil ? nil : ConnectionFallback.reachTimeout
        tab.title = plan.label
        if let hostID = tab.hostID, vault.get(SavedHost.self, id: hostID) != nil { tab.badge = displayBadge(hostID: hostID) }

        if let agentKey = plan.agentKey {
            guard let socket = agentSocket() else {
                tab.state = .disconnected(Self.agentNotFoundMessage)
                tab.suggestedAction = .openOnePasswordSetup
                tab.appendFailure(Self.agentNotFoundMessage, at: now())
                return
            }
            plan.credential = .agent(socketPath: socket, publicKey: agentKey.publicKey) // also selects system ssh
        }
        tab.resetConnectionLog(context: TerminalTab.LogContext(label: plan.label, username: plan.username, host: plan.host,
                                                               port: plan.port, engine: plan.engine, startedAt: now()))

        var enteredPassword: String? // as typed (maybe a 1Password reference)
        if let entered = tab.enteredPassword {
            switch plan.credential {
            case .password, .none:
                plan.credential = .password(entered)
                enteredPassword = entered
            case .privateKey, .privateKeys, .agent:
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
        case .privateKey, .privateKeys, .none, .agent: false
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
        case .password, .privateKey, .privateKeys, .none, .agent:
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
            tab.appendFailure("Cancelled", at: now())
        case .cliNotFound, .integrationOff, .appLocked, .containerBlocked, .appNotRunning:
            tab.state = .disconnected(error.message)
            tab.suggestedAction = .openOnePasswordSetup
            tab.appendFailure(error.message, at: now())
        case .timedOut, .notFound, .failed:
            tab.state = .disconnected(error.message)
            tab.appendFailure(error.message, at: now())
        }
    }

    /// Makes the attempt's session and starts it. `alsoTrusting` (an attempt on the backup address): the
    /// main address's host:port, whose trusted key is accepted without a prompt.
    private func startAttempt(_ tab: TerminalTab, plan: ConnectionPlan, enteredPassword: String?,
                              alsoTrusting mainHostPort: String? = nil) {
        let generation = tab.generation
        let evaluator = PromptingHostKeyEvaluator(store: knownHosts, alsoTrusting: mainHostPort) { [weak self, weak tab] candidate, check in
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

    /// The plan for a saved host, from `hostPlanner` when given (iOS: `platform: .ios` with the imported keys).
    private func planHost(_ hostID: UUID) throws -> ConnectionPlan {
        if let hostPlanner { return try hostPlanner(hostID, vault) }
        return try ConnectionPlanner.plan(hostID: hostID, vault: vault)
    }

    private func currentPlan(for target: SessionTarget) throws -> ConnectionPlan {
        switch target {
        case .host(let id):
            try planHost(id)
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
        case .progress(let step):
            if ConnectionFallback.reachesServer(step) { attempt.reachedServer = true }
            current?.appendStep(step, at: now())
        case .connected:
            attempt.reachedServer = true
            current?.state = .connected
            current?.finishCurrentStep(as: .done)
            current?.hasEverConnected = true
            current?.hadLiveSession = true
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
            if let current { noteOutput(tabID: current.id) }
        case .closed(let reason):
            // Ready this attempt (its log started): the terminal was live.
            let wasLive = attempt.logID != nil
            endLog(of: attempt)
            attempt.inputs.finish()
            liveAttempts[ObjectIdentifier(attempt)] = nil
            guard let current else { return }
            current.attempt = nil
            current.generation += 1
            rejectPendingHostKey(of: current)
            if let backup = attempt.plan.fallbackHost, isOpen(current),
               ConnectionFallback.shouldTryBackup(after: reason, reachedServer: attempt.reachedServer),
               case .failed(let error) = reason {
                tryBackupAddress(backup, after: error, attempt: attempt, tab: current)
                return
            }
            if reason == .userClosed {
                if isOpen(current) { close(tabID: current.id) }
                return
            }
            // The shell ended normally (`exit`, logout) after the terminal was live: the tab (or pane)
            // closes, as in Terminal. A drop or failure keeps the tab with its Disconnected screen.
            if reason == .remoteClosed, wasLive {
                if isOpen(current) { close(tabID: current.id) }
                return
            }
            current.state = state(after: reason, attempt: attempt, tab: current)
            if let message = Self.failureText(after: reason, state: current.state, connected: current.hasEverConnected) {
                current.appendFailure(message, at: now())
            } else {
                current.finishCurrentStep(as: .done)
            }
            continueAutoReconnect(after: reason, attempt: attempt, tab: current)
            if reason == .failed(.authenticationFailed), case .agent(let socket, let pinned) = attempt.plan.credential {
                diagnoseAgentFailure(of: current, socket: socket, pinnedPublicKey: pinned, plan: attempt.plan)
            }
        }
    }

    /// The main address of `attempt` couldn't be reached: notes it and starts the same plan on the backup
    /// address (no further fallback, the normal timeouts, the main address's key trusted).
    private func tryBackupAddress(_ backup: String, after error: SessionError, attempt: SessionAttempt, tab: TerminalTab) {
        var plan = attempt.plan
        let main = plan.host
        let reason = ConnectionFallback.reason(of: error)
        plan.host = backup
        plan.fallbackHost = nil
        plan.reachTimeout = nil
        tab.switchToBackupAddress(backup, main: main, reason: reason,
                                  note: ConnectionFallback.note(main: main, reason: reason, backup: backup), at: now())
        tab.state = .connecting
        startAttempt(tab, plan: plan, enteredPassword: attempt.enteredPassword,
                     alsoTrusting: HostKeyFormat.hostPort(host: main, port: plan.port))
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
            if recordsHostUpdates {
                host.lastConnectedAt = Date()
                vault.saveNow(host)
            }
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
        attachTmuxIfChosen(attempt, tab: tab)
        if let text = tab.textAfterFirstReady {
            tab.textAfterFirstReady = nil
            if !text.isEmpty { attempt.inputs.yield(.bytes(Array(text.utf8))) }
        }
    }

    // MARK: Attach to tmux

    /// After `.ready` (every attempt: first connect, Reconnect, each automatic try), when the saved
    /// host's effective tmux choice (host, then nearest group) is a session with a valid name: notes the
    /// step in the connection log and types the attach line. It comes after the startup script, so the
    /// script runs in the login shell each time and is never typed into a reattached session. Quick
    /// connect tabs never attach.
    private func attachTmuxIfChosen(_ attempt: SessionAttempt, tab: TerminalTab) {
        guard let hostID = tab.hostID, let host = vault.get(SavedHost.self, id: hostID) else { return }
        let directory = HostDirectory(hosts: [host], groups: vault.all(HostGroup.self))
        guard let name = directory.effectiveTmuxSession(for: host), TmuxChoice.isValidSessionName(name) else { return }
        noteTmuxAttachProgress(session: name, tab: tab)
        attempt.inputs.yield(.bytes(Array(Self.tmuxAttachCommand(session: name).utf8)))
    }

    /// Adds "Attaching to tmux session <name>…" to the tab's connection log (marked done: the command
    /// has been sent; whether tmux exists shows in the terminal itself).
    private func noteTmuxAttachProgress(session name: String, tab: TerminalTab) {
        tab.appendStep(.attachingTmux(session: name), at: now())
        tab.finishCurrentStep(as: .done)
    }

    /// Attaches to (or creates) the session, or says tmux is missing. `name` must already pass
    /// `TmuxChoice.isValidSessionName`; it is single-quoted all the same. Ends with a carriage return
    /// (Return), as typed.
    static func tmuxAttachCommand(session name: String) -> String {
        "command -v tmux >/dev/null 2>&1 && tmux new -A -s '\(name)' || echo 'tmux is not installed on this server - skipping attach.'\r"
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
              var host = vault.get(SavedHost.self, id: hostID), !host.osBadgeIsManual else { return }
        if !recordsHostUpdates {
            detectedBadges[hostID] = badge
        } else {
            guard host.osBadge != badge else { return }
            host.osBadge = badge
            vault.saveNow(host)
        }
        for tab in tabs where tab.hostID == hostID { tab.badge = badge }
    }

    /// The OS badge detected for the host in this app session when host updates aren't recorded
    /// (`recordsHostUpdates: false`); nil otherwise (the Mac saves it on the host), when nothing was
    /// detected yet, or when the host's badge is set by hand.
    public func detectedBadge(hostID: UUID) -> OSBadge? {
        guard let badge = detectedBadges[hostID],
              vault.get(SavedHost.self, id: hostID)?.osBadgeIsManual != true else { return nil }
        return badge
    }

    /// The badge a tab for the host shows: one detected in this app session (see `detectedBadge`),
    /// otherwise the saved one.
    private func displayBadge(hostID: UUID) -> OSBadge? {
        detectedBadge(hostID: hostID) ?? vault.get(SavedHost.self, id: hostID)?.osBadge
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
            case .privateKeys:
                tab.suggestedAction = .importKey
                return .disconnected("The server didn't accept any of the keys imported on this device for \(who). Import the key this server knows (its public half must be in ~/.ssh/authorized_keys on the server).")
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

    /// The connection log's last line for an attempt that ended: the message the tab shows (or the error's
    /// own when the tab asks for a password again); for a normal close before the terminal went live, that
    /// it closed. Nil for a normal close of a live session.
    private static func failureText(after reason: SessionEndReason, state: TerminalTab.State, connected: Bool) -> String? {
        switch reason {
        case .userClosed:
            return nil
        case .remoteClosed:
            return connected ? nil : "The server closed the connection."
        case .failed(let error):
            if case .disconnected(let message?) = state { return message }
            return error.localizedDescription
        }
    }

    /// After a rejected agent key: asks the agent what it offers and, if the tab still shows that
    /// failure (no new attempt started meanwhile), replaces the message, its log line and the suggestion.
    private func diagnoseAgentFailure(of tab: TerminalTab, socket: String, pinnedPublicKey: String?, plan: ConnectionPlan) {
        guard let agentKeys, case .disconnected(let shown?) = tab.state else { return }
        let generation = tab.generation
        Task { [weak self, weak tab] in
            let listing: Result<[AgentKey], any Error>
            do { listing = .success(try await agentKeys(socket)) } catch { listing = .failure(error) }
            guard let self, let tab, tab.generation == generation, tab.attempt == nil,
                  tab.state == .disconnected(shown) else { return }
            let failure = AgentAuthFailure.diagnose(pinnedPublicKey: pinnedPublicKey, listing: listing)
            let message = failure.message(who: Self.userAtHost(plan))
            tab.state = .disconnected(message)
            tab.suggestedAction = failure.suggestedAction
            tab.replaceLastFailure(with: message, ifItIs: shown)
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
