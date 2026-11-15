import SwiftUI
import AppKit
import AppCore

/// The drag area of a split's divider (the visible line is the gap between the panes). Dragging
/// moves the split's ratio live, within the divider's minimum-size limits; a double-click resets it
/// to 50/50. Shows the resize cursor (left-right for side-by-side panes, up-down for stacked ones)
/// while over it and while dragging.
///
/// An AppKit view, so the cursor rect, the drag and the double-click don't compete with SwiftUI
/// gestures or with the terminals underneath.
struct PaneDivider: NSViewRepresentable {
    let divider: PaneLayout.Divider
    /// A new ratio (already clamped to the divider's limits).
    let setRatio: @MainActor (Double) -> Void

    func makeNSView(context: Context) -> DividerHandleView {
        let view = DividerHandleView()
        configure(view)
        return view
    }

    func updateNSView(_ view: DividerHandleView, context: Context) {
        configure(view)
    }

    private func configure(_ view: DividerHandleView) {
        let divider = divider
        let setRatio = setRatio
        view.axis = divider.axis
        view.ratio = divider.ratio
        view.available = divider.available
        view.onRatio = { proposed in setRatio(divider.clamped(proposed)) }
        view.onReset = { setRatio(divider.clamped(0.5)) }
        view.setAccessibilityLabel(divider.axis == .horizontal ? "Vertical divider" : "Horizontal divider")
    }
}

final class DividerHandleView: NSView {
    var axis: SplitAxis = .horizontal {
        didSet {
            if oldValue != axis { window?.invalidateCursorRects(for: self) }
        }
    }
    /// The ratio shown now; a drag starts from it.
    var ratio = 0.5
    var available: CGFloat = 0
    var onRatio: (@MainActor (Double) -> Void)?
    var onReset: (@MainActor () -> Void)?

    private var dragStart: (point: NSPoint, ratio: Double)?

    private var cursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStart = nil
            onReset?()
            return
        }
        dragStart = (event.locationInWindow, ratio)
        cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, available > 0 else { return }
        let point = event.locationInWindow
        // Window coordinates grow upwards; a stacked split's first pane is the top one.
        let delta = axis == .horizontal ? point.x - start.point.x : start.point.y - point.y
        // Over a terminal the cursor would otherwise turn into its I-beam mid-drag.
        cursor.set()
        onRatio?(start.ratio + Double(delta / available))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        window?.invalidateCursorRects(for: self)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
}
