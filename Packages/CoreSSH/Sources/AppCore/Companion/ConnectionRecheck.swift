import Foundation

/// iPhone/iPad: decides when the open sessions are checked (`SessionManager.checkConnections`, which
/// drops a dead one so auto-reconnect brings it back). iOS suspends the app in the background, so a
/// session may have died meanwhile without a word; the network may also change under it (Wi-Fi to
/// cellular, VPN).
///
/// - Coming back from the background checks at once (not a launch, and not a return from Control
///   Center or the Face ID sheet, which never leave the foreground).
/// - A network change checks once the network works again (checking while it is down would end
///   sessions that survive a quick switch); the first report is the starting state. A change seen in
///   the background waits for the return.
/// - Checks closer than `coalesceInterval` are one: coming back usually also reports a new path.
@MainActor
public final class ConnectionRecheck {
    /// What matters about a network path: whether it works and which interfaces it uses.
    public struct PathSummary: Equatable, Sendable {
        public var satisfied: Bool
        public var interfaces: [String]

        public init(satisfied: Bool, interfaces: [String]) {
            self.satisfied = satisfied
            self.interfaces = interfaces
        }
    }

    public static let coalesceInterval: TimeInterval = 2

    private let check: @MainActor () -> Void
    private let now: @Sendable () -> Date
    private var lastPath: PathSummary?
    private var isInBackground = false
    private var pendingCheck = false
    private var lastCheck: Date?

    public init(now: @escaping @Sendable () -> Date = { Date() }, check: @escaping @MainActor () -> Void) {
        self.now = now
        self.check = check
    }

    public func didEnterBackground() {
        isInBackground = true
    }

    public func didBecomeActive() {
        let returning = isInBackground
        isInBackground = false
        if returning || pendingCheck { checkNow() }
    }

    public func pathChanged(_ summary: PathSummary) {
        defer { lastPath = summary }
        guard let lastPath, lastPath != summary, summary.satisfied else { return }
        if isInBackground {
            pendingCheck = true
        } else {
            checkNow()
        }
    }

    private func checkNow() {
        pendingCheck = false
        let date = now()
        if let lastCheck, date.timeIntervalSince(lastCheck) < Self.coalesceInterval { return }
        lastCheck = date
        check()
    }
}
