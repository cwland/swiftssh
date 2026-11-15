import Foundation

/// How a split lays out its two children.
public enum SplitAxis: String, Codable, Sendable {
    /// Side by side: the first child on the left.
    case horizontal
    /// Stacked: the first child on top.
    case vertical
}

/// The half of a pane something is dropped onto.
public enum DropEdge: Sendable {
    case left, right, top, bottom
}

/// A workspace's layout: panes (terminal tab ids) and splits between them.
public indirect enum PaneNode: Equatable, Sendable {
    /// A terminal tab's id.
    case pane(UUID)
    /// `ratio` is the first child's share, clamped to 0.1…0.9.
    case split(SplitAxis, ratio: Double, PaneNode, PaneNode)

    /// The pane ids in reading order (first child before second).
    public var paneIDs: [UUID] { [] }

    /// Puts `id` beside the pane `target`, on its `edge` half.
    public func inserting(_ id: UUID, beside target: UUID, at edge: DropEdge) -> PaneNode { self }

    /// The tree without `id`; nil when nothing is left. A split left with one child becomes that child.
    public func removing(_ id: UUID) -> PaneNode? { self }

    /// Moves the pane `id` beside `target`, on its `edge` half.
    public func moving(_ id: UUID, beside target: UUID, at edge: DropEdge) -> PaneNode { self }

    /// Sets the ratio of the split at `path` (each step: 0 = first child, 1 = second; [] = this node).
    public func settingRatio(_ ratio: Double, atPath path: [Int]) -> PaneNode { self }
}
