import Foundation

public enum Timestamps {
    /// Returns `max(now, previous + 1ms)` truncated to whole milliseconds, so the value
    /// survives the millisecond-precision JSON encoding unchanged and is strictly
    /// greater than `previous` when one is given.
    public static func nextUpdate(previous: Date?, now: Date = Date()) -> Date {
        var ms = (now.timeIntervalSince1970 * 1000).rounded(.down)
        if let previous {
            let previousMs = (previous.timeIntervalSince1970 * 1000).rounded(.down)
            ms = max(ms, previousMs + 1)
        }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
