import Foundation
import SSHCore

/// One line of a tab's connection log (the connection screen's step list). Text never contains secrets.
public struct ConnectionLogLine: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable { case inProgress, done, failed }

    /// Increasing within one attempt's log.
    public let id: Int
    /// The step this line reports; nil for a line that is not a step (the failure message).
    public let step: ConnectionStep?
    public let text: String
    public var status: Status
    /// When the line was added.
    public let at: Date

    public init(id: Int, step: ConnectionStep?, text: String, status: Status, at: Date) {
        self.id = id
        self.step = step
        self.text = text
        self.status = status
        self.at = at
    }
}
