import Foundation

/// When a dropped connection is tried again: after 5 s, then 10, 20, 30 and 30 s; then it gives up.
public enum ReconnectSchedule {
    /// Delay before try n (1-based): every 5 seconds for the first half minute, then every 10, then
    /// every 15 seconds: about 3 minutes in all, long enough for a server to reboot.
    public static let delays: [TimeInterval] = Array(repeating: 5, count: 6) + Array(repeating: 10, count: 6)
        + Array(repeating: 15, count: 6)

    public static var maxAttempts: Int { delays.count }

    /// nil when n > maxAttempts or n < 1.
    public static func delay(beforeAttempt n: Int) -> TimeInterval? {
        guard n >= 1, n <= maxAttempts else { return nil }
        return delays[n - 1]
    }
}

/// Where a tab is in reconnecting on its own after its connection dropped.
public enum AutoReconnectState: Equatable, Sendable {
    /// Counting down to try `attempt` (1-based); `delay` is the full countdown length, for the ring.
    case waiting(attempt: Int, deadline: Date, delay: TimeInterval)
    /// Try `attempt` is connecting now.
    case reconnecting(attempt: Int)
    /// All tries failed; the tab shows the disconnected banner with Reconnect.
    case gaveUp(attempts: Int)
}
