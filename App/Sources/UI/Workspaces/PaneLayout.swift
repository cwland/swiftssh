import CoreGraphics
import Foundation
import AppCore

/// Frames for a workspace's split view: each pane's rectangle and each split's divider, computed
/// from the layout tree for one container size. Panes are laid out flat (not as nested stacks), so a
/// pane keeps its view identity — and its terminal stays in place — when the tree around it changes.
///
/// Ratios are honoured within limits that keep every pane at least `minimumPaneSize` (when the
/// container is big enough), on top of the tree's own 0.1…0.9 clamp.
struct PaneLayout {
    /// The visible line between two panes.
    static let gap: CGFloat = 2
    /// How wide the divider's drag area is (centred on the gap, reaching a little into both panes).
    static let handleThickness: CGFloat = 8
    /// A pane, header included, never gets smaller than this by dragging a divider.
    static let minimumPaneSize = CGSize(width: 160, height: 100)

    struct Divider: Identifiable {
        /// The split's path in the tree (0 = first child, 1 = second), for `setRatio(_:atPath:in:)`.
        let path: [Int]
        let axis: SplitAxis
        /// The drag area.
        let handle: CGRect
        /// The ratio as shown (after the minimum-size limits).
        let ratio: Double
        /// Length shared by the two children along the axis (the split's size minus the gap).
        let available: CGFloat
        /// The ratios a drag may reach.
        let bounds: ClosedRange<Double>

        var id: String { "split" + path.map(String.init).joined() }

        /// `proposed` within this divider's limits.
        func clamped(_ proposed: Double) -> Double {
            min(max(proposed, bounds.lowerBound), bounds.upperBound)
        }
    }

    private(set) var frames: [UUID: CGRect] = [:]
    private(set) var dividers: [Divider] = []

    init(root: PaneNode, size: CGSize) {
        place(root, in: CGRect(origin: .zero, size: size), path: [])
    }

    private mutating func place(_ node: PaneNode, in rect: CGRect, path: [Int]) {
        switch node {
        case .pane(let id):
            frames[id] = rect
        case .split(let axis, ratio: let ratio, let first, let second):
            let horizontal = axis == .horizontal
            let length = horizontal ? rect.width : rect.height
            let available = max(length - Self.gap, 0)
            let bounds = Self.ratioBounds(axis: axis, available: available, first: first, second: second)
            let shown = min(max(ratio, bounds.lowerBound), bounds.upperBound)
            let firstLength = (available * shown).rounded()
            let secondLength = max(available - firstLength, 0)
            let firstRect: CGRect
            let secondRect: CGRect
            let handle: CGRect
            if horizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height)
                secondRect = CGRect(x: rect.minX + firstLength + Self.gap, y: rect.minY,
                                    width: secondLength, height: rect.height)
                handle = CGRect(x: rect.minX + firstLength + Self.gap / 2 - Self.handleThickness / 2,
                                y: rect.minY, width: Self.handleThickness, height: rect.height)
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength)
                secondRect = CGRect(x: rect.minX, y: rect.minY + firstLength + Self.gap,
                                    width: rect.width, height: secondLength)
                handle = CGRect(x: rect.minX,
                                y: rect.minY + firstLength + Self.gap / 2 - Self.handleThickness / 2,
                                width: rect.width, height: Self.handleThickness)
            }
            place(first, in: firstRect, path: path + [0])
            place(second, in: secondRect, path: path + [1])
            // After the children, so a parent's divider is drawn (and hit) above nested ones where
            // they meet.
            dividers.append(Divider(path: path, axis: axis, handle: handle, ratio: shown,
                                    available: available, bounds: bounds))
        }
    }

    /// The smallest size `node` can take with every pane at `minimumPaneSize`.
    static func minimumSize(of node: PaneNode) -> CGSize {
        switch node {
        case .pane:
            return minimumPaneSize
        case .split(let axis, ratio: _, let first, let second):
            let a = minimumSize(of: first)
            let b = minimumSize(of: second)
            switch axis {
            case .horizontal:
                return CGSize(width: a.width + gap + b.width, height: max(a.height, b.height))
            case .vertical:
                return CGSize(width: max(a.width, b.width), height: a.height + gap + b.height)
            }
        }
    }

    /// The ratios that keep both children at their minimum size, within the tree's 0.1…0.9. When the
    /// split is too small for both minimums, the one ratio that shares the shortfall fairly.
    static func ratioBounds(axis: SplitAxis, available: CGFloat, first: PaneNode,
                            second: PaneNode) -> ClosedRange<Double> {
        let minFirst = axis == .horizontal ? minimumSize(of: first).width : minimumSize(of: first).height
        let minSecond = axis == .horizontal ? minimumSize(of: second).width : minimumSize(of: second).height
        let treeBounds = 0.1...0.9
        guard available > 0 else { return treeBounds }
        let lower = max(treeBounds.lowerBound, Double(minFirst / available))
        let upper = min(treeBounds.upperBound, 1 - Double(minSecond / available))
        if lower <= upper { return lower...upper }
        let fair = min(max(Double(minFirst / (minFirst + minSecond)), treeBounds.lowerBound),
                       treeBounds.upperBound)
        return fair...fair
    }
}
