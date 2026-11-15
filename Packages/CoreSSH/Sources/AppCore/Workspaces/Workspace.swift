import Foundation
import Observation

/// What a pane's status dot shows.
public enum PaneStatus: Sendable {
    case none, newOutput, waitingForInput, failed
}

/// One tab bar item holding 2–16 terminal tabs ("panes") laid out by `root`.
@MainActor @Observable
public final class Workspace: Identifiable {
    public enum ViewMode: String, Codable, Sendable {
        case split, focus
    }

    public let id: UUID
    public var name: String
    public private(set) var root: PaneNode
    public var viewMode: ViewMode
    public var focusedPaneID: UUID
    public private(set) var isBroadcasting: Bool = false
    public private(set) var excludedFromBroadcast: Set<UUID> = []
    /// The saved template it came from or was saved to.
    public var templateID: UUID?
    public private(set) var hasUnsavedChanges: Bool = true

    init(id: UUID = UUID(), name: String, root: PaneNode, viewMode: ViewMode = .split, focusedPaneID: UUID) {
        self.id = id
        self.name = name
        self.root = root
        self.viewMode = viewMode
        self.focusedPaneID = focusedPaneID
    }

    public var paneIDs: [UUID] { root.paneIDs }

    public func status(of paneID: UUID) -> PaneStatus { .none }
}
