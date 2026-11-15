import Foundation
import Observation

/// What a pane's status dot shows: green = new output since the pane was last focused, yellow = waiting
/// for input (host key or password prompt), red = failed or disconnected, none otherwise.
public enum PaneStatus: Sendable {
    case none, newOutput, waitingForInput, failed
}

/// One tab bar item holding 2–16 terminal tabs ("panes") laid out by `root`. Changed through
/// `SessionManager`; `name` and `viewMode` may also be set directly (both count as unsaved changes).
@MainActor @Observable
public final class Workspace: Identifiable {
    public enum ViewMode: String, Codable, Sendable {
        case split, focus
    }

    /// The fewest and most panes a workspace holds.
    public static let paneLimit = 2...16
    public static let defaultName = "Workspace"

    public let id: UUID
    public var name: String {
        didSet { refreshUnsavedChanges() }
    }
    public private(set) var root: PaneNode
    public var viewMode: ViewMode {
        didSet { refreshUnsavedChanges() }
    }
    /// The pane typed into (the selected terminal in Focus mode). Setting it clears its new-output dot.
    public var focusedPaneID: UUID {
        didSet { newOutputPanes.remove(focusedPaneID) }
    }
    public private(set) var isBroadcasting: Bool = false
    public private(set) var excludedFromBroadcast: Set<UUID> = []
    /// The saved template it came from or was saved to.
    public var templateID: UUID?
    /// True when name, layout (panes, splits, ratios), view mode or a pane's tab title differs from what
    /// was last saved or opened from a template, or it was never saved. Focus and broadcast don't count.
    public private(set) var hasUnsavedChanges: Bool = true
    /// The window it lives in (nil = the main window), as its panes do.
    public let windowID: UUID?

    /// Panes with output they got while not focused.
    private(set) var newOutputPanes: Set<UUID> = []
    @ObservationIgnored private(set) var paneSet: Set<UUID>
    @ObservationIgnored weak var sessions: SessionManager?
    @ObservationIgnored private var saved: Snapshot?

    private struct Snapshot: Equatable {
        var name: String
        var root: PaneNode
        var viewMode: ViewMode
        var titles: [UUID: String]
    }

    init(id: UUID = UUID(), name: String, root: PaneNode, viewMode: ViewMode = .split, focusedPaneID: UUID,
         windowID: UUID?) {
        self.id = id
        self.name = name
        self.root = root
        self.viewMode = viewMode
        self.focusedPaneID = focusedPaneID
        self.windowID = windowID
        self.paneSet = Set(root.paneIDs)
    }

    public var paneIDs: [UUID] { root.paneIDs }

    public func contains(_ paneID: UUID) -> Bool { paneSet.contains(paneID) }

    public func status(of paneID: UUID) -> PaneStatus {
        guard contains(paneID), let tab = sessions?.tab(paneID) else { return .none }
        switch tab.state {
        case .awaitingHostKey, .awaitingPassword: return .waitingForInput
        case .disconnected: return .failed
        case .connecting, .connected: break
        }
        return newOutputPanes.contains(paneID) && paneID != focusedPaneID ? .newOutput : .none
    }

    /// The one pane whose host-key or password question is shown now: the focused pane when it is
    /// waiting, else the first waiting pane in layout order. The others wait their turn, so the
    /// window never stacks several sheets.
    public var promptingPaneID: UUID? {
        if status(of: focusedPaneID) == .waitingForInput { return focusedPaneID }
        return paneIDs.first { status(of: $0) == .waitingForInput }
    }

    /// Whether the pane gets broadcast input (when broadcasting).
    public func isIncludedInBroadcast(_ paneID: UUID) -> Bool {
        contains(paneID) && !excludedFromBroadcast.contains(paneID)
    }

    // MARK: Changes (SessionManager)

    /// A new layout. Per-pane state of panes that left is dropped; a focused pane that left passes the
    /// focus to the pane after it in the old reading order, else the one before.
    func setRoot(_ newRoot: PaneNode) {
        guard newRoot != root else { return }
        let old = root.paneIDs
        root = newRoot
        paneSet = Set(newRoot.paneIDs)
        excludedFromBroadcast.formIntersection(paneSet)
        newOutputPanes.formIntersection(paneSet)
        if !paneSet.contains(focusedPaneID), let index = old.firstIndex(of: focusedPaneID) {
            let after = old[(index + 1)...].first { paneSet.contains($0) }
            let before = old[..<index].last { paneSet.contains($0) }
            if let next = after ?? before ?? newRoot.paneIDs.first { focusedPaneID = next }
        }
        refreshUnsavedChanges()
    }

    func setBroadcasting(_ on: Bool) {
        if isBroadcasting != on { isBroadcasting = on }
    }

    func setIncluded(_ paneID: UUID, _ included: Bool) {
        guard contains(paneID) else { return }
        if included {
            excludedFromBroadcast.remove(paneID)
        } else if !excludedFromBroadcast.contains(paneID) {
            excludedFromBroadcast.insert(paneID)
        }
    }

    func noteOutput(_ paneID: UUID) {
        guard paneID != focusedPaneID, contains(paneID), !newOutputPanes.contains(paneID) else { return }
        newOutputPanes.insert(paneID)
    }

    /// What is saved now matches the workspace (after a save, or opening a template).
    func markSaved() {
        saved = snapshot()
        refreshUnsavedChanges()
    }

    func refreshUnsavedChanges() {
        let unsaved = saved.map { $0 != snapshot() } ?? true
        if unsaved != hasUnsavedChanges { hasUnsavedChanges = unsaved }
    }

    private func snapshot() -> Snapshot {
        var titles: [UUID: String] = [:]
        for id in root.paneIDs {
            if let title = sessions?.tab(id)?.customTitle { titles[id] = title }
        }
        return Snapshot(name: name, root: root, viewMode: viewMode, titles: titles)
    }
}
