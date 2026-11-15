import SwiftUI
import AppKit

/// Marks a tab in the top bar: the bar's window-drag view (`WindowDragArea`) steps aside over it, so
/// a click and hold anywhere on the tab drags the tab (reorder, or drop on a terminal), never the window.
///
/// The window itself is not movable by macOS's title-bar handling (`WindowDragArea` turns that off),
/// because the system title bar sits above the app's views and would move the window from the top
/// part of a tab whatever those views say.
struct WindowDragBlocker: NSViewRepresentable {
    /// The tabs on screen, for `covers(_:in:)`.
    @MainActor private static let blockers = NSHashTable<BlockerView>.weakObjects()

    /// Whether `windowPoint` (window coordinates) is over a tab in `window`.
    @MainActor static func covers(_ windowPoint: NSPoint, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return blockers.allObjects.contains { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor
                && view.bounds.contains(view.convert(windowPoint, from: nil))
        }
    }

    func makeNSView(context: Context) -> BlockerView { BlockerView() }

    func updateNSView(_ view: BlockerView, context: Context) {}

    final class BlockerView: NSView {
        /// Transparent to clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Never part of a window-drag region (NSView says yes for any non-opaque view).
        override var mouseDownCanMoveWindow: Bool { false }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { WindowDragBlocker.blockers.remove(self) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { WindowDragBlocker.blockers.add(self) }
        }
    }
}
