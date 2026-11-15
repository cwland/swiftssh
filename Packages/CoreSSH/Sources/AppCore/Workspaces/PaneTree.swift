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

/// A workspace's layout: panes (terminal tab ids) and splits between them. Values are immutable: every
/// operation returns a new tree.
public indirect enum PaneNode: Equatable, Sendable {
    /// A terminal tab's id.
    case pane(UUID)
    /// `ratio` is the first child's share, clamped to 0.1…0.9.
    case split(SplitAxis, ratio: Double, PaneNode, PaneNode)

    /// The smallest and largest share a split gives its first child.
    public static let ratioRange: ClosedRange<Double> = 0.1...0.9

    /// `ratio` within `ratioRange`; nil for NaN.
    static func clamped(_ ratio: Double) -> Double? {
        guard !ratio.isNaN else { return nil }
        return min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    /// The pane ids in reading order (first child before second).
    public var paneIDs: [UUID] {
        var ids: [UUID] = []
        collect(into: &ids)
        return ids
    }

    private func collect(into ids: inout [UUID]) {
        switch self {
        case .pane(let id): ids.append(id)
        case .split(_, _, let first, let second):
            first.collect(into: &ids)
            second.collect(into: &ids)
        }
    }

    /// Whether the pane `id` is in the tree.
    public func contains(_ id: UUID) -> Bool {
        switch self {
        case .pane(let own): own == id
        case .split(_, _, let first, let second): first.contains(id) || second.contains(id)
        }
    }

    /// Puts `id` beside the pane `target`, on its `edge` half: the target's place becomes an even split
    /// of the two. An `id` already in the tree is moved (`moving`). Unchanged when `target` is not in the
    /// tree or is `id` itself.
    public func inserting(_ id: UUID, beside target: UUID, at edge: DropEdge) -> PaneNode {
        guard id != target, contains(target) else { return self }
        if contains(id) { return moving(id, beside: target, at: edge) }
        return replacingPane(target) { old in Self.pair(.pane(id), beside: old, at: edge) }
    }

    /// The tree without `id`; nil when nothing is left. A split left with one child becomes that child
    /// (keeping that child's own ratios). Unchanged when `id` is not in the tree.
    public func removing(_ id: UUID) -> PaneNode? {
        switch self {
        case .pane(let own):
            return own == id ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard contains(id) else { return self }
            let newFirst = first.removing(id)
            let newSecond = second.removing(id)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let f?, let s?): return .split(axis, ratio: ratio, f, s)
            }
        }
    }

    /// Moves the pane `id` beside `target`, on its `edge` half (its old place collapses). Unchanged when
    /// either is not in the tree or they are the same pane.
    public func moving(_ id: UUID, beside target: UUID, at edge: DropEdge) -> PaneNode {
        guard id != target, contains(id), contains(target), let without = removing(id) else { return self }
        return without.inserting(id, beside: target, at: edge)
    }

    /// Sets the ratio of the split at `path` (each step: 0 = first child, 1 = second; [] = this node),
    /// clamped to `ratioRange`. Unchanged for a path that does not end at a split, or NaN.
    public func settingRatio(_ ratio: Double, atPath path: [Int]) -> PaneNode {
        guard case .split(let axis, let old, let first, let second) = self else { return self }
        guard let step = path.first else {
            guard let clamped = Self.clamped(ratio) else { return self }
            return .split(axis, ratio: clamped, first, second)
        }
        let rest = Array(path.dropFirst())
        switch step {
        case 0: return .split(axis, ratio: old, first.settingRatio(ratio, atPath: rest), second)
        case 1: return .split(axis, ratio: old, first, second.settingRatio(ratio, atPath: rest))
        default: return self
        }
    }

    /// The same shape and ratios with `ids` placed in reading order. Unchanged unless `ids` holds exactly
    /// the tree's panes.
    public func reordered(_ ids: [UUID]) -> PaneNode {
        let current = paneIDs
        guard ids.count == current.count, Set(ids) == Set(current), Set(ids).count == ids.count else { return self }
        var iterator = ids.makeIterator()
        return placing(&iterator)
    }

    /// The same shape and ratios with the panes `a` and `b` trading places (Focus mode's list reorder).
    /// Unchanged when they are the same pane or either is not in the tree.
    public func swapping(_ a: UUID, _ b: UUID) -> PaneNode {
        guard a != b, contains(a), contains(b) else { return self }
        return reordered(paneIDs.map { $0 == a ? b : ($0 == b ? a : $0) })
    }

    private func placing(_ ids: inout IndexingIterator<[UUID]>) -> PaneNode {
        switch self {
        case .pane: return .pane(ids.next()!)
        case .split(let axis, let ratio, let first, let second):
            let f = first.placing(&ids)
            let s = second.placing(&ids)
            return .split(axis, ratio: ratio, f, s)
        }
    }

    /// A grid-ish layout of `ids` in reading order: ⌈√n⌉ columns per row, rows stacked, every pane the
    /// same size within its row and every row the same height. nil for no ids.
    public static func balanced(_ ids: [UUID]) -> PaneNode? {
        guard !ids.isEmpty else { return nil }
        let columns = Int((Double(ids.count)).squareRoot().rounded(.up))
        let rows = stride(from: 0, to: ids.count, by: columns).map { start in
            even(ids[start..<min(start + columns, ids.count)].map { PaneNode.pane($0) }, axis: .horizontal)!
        }
        return even(rows, axis: .vertical)
    }

    /// `nodes` side by side (or stacked), each getting the same share.
    private static func even(_ nodes: [PaneNode], axis: SplitAxis) -> PaneNode? {
        guard nodes.count > 1 else { return nodes.first }
        let half = nodes.count / 2
        return .split(axis, ratio: Double(half) / Double(nodes.count),
                      even(Array(nodes[..<half]), axis: axis)!, even(Array(nodes[half...]), axis: axis)!)
    }

    private static func pair(_ new: PaneNode, beside old: PaneNode, at edge: DropEdge) -> PaneNode {
        switch edge {
        case .left: .split(.horizontal, ratio: 0.5, new, old)
        case .right: .split(.horizontal, ratio: 0.5, old, new)
        case .top: .split(.vertical, ratio: 0.5, new, old)
        case .bottom: .split(.vertical, ratio: 0.5, old, new)
        }
    }

    private func replacingPane(_ target: UUID, with make: (PaneNode) -> PaneNode) -> PaneNode {
        switch self {
        case .pane(let id): id == target ? make(self) : self
        case .split(let axis, let ratio, let first, let second):
            .split(axis, ratio: ratio, first.replacingPane(target, with: make), second.replacingPane(target, with: make))
        }
    }
}
