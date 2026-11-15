import SwiftUI
import AppKit

/// Keeps a click inside this view from moving the window.
///
/// The top bar sits in the hidden title bar, where AppKit starts a window drag for a mouse-down on any
/// spot SwiftUI doesn't claim (for example the see-through parts of an unselected tab), so a tab drag
/// sometimes moved the whole window. Behind a tab, this watches mouse-downs before AppKit handles them
/// and makes the window unmovable until the button is released; the tab's own drag (reorder, drop on a terminal)
/// is unaffected. Empty parts of the bar still move the window.
struct WindowDragBlocker: NSViewRepresentable {
    /// The blockers on screen, for `covers(_:in:)`.
    @MainActor private static let blockers = NSHashTable<BlockerView>.weakObjects()

    /// Whether `windowPoint` (window coordinates) is over a tab in `window`. The top bar's own
    /// window-drag view (`WindowDragArea`) steps aside there, so the tab gets the mouse-down.
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
        private var monitor: Any?

        /// Transparent to clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                stopWatching()
                WindowDragBlocker.blockers.remove(self)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                WindowDragBlocker.blockers.add(self)
                if monitor == nil { startWatching() }
            }
        }

        private func startWatching() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window, window.isMovable,
                          !self.isHiddenOrHasHiddenAncestor else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(point) else { return }
                    // macOS starts moving the window once the mouse moves, not on the mouse-down, so
                    // the window stays unmovable until every button is released (the tab's drag runs
                    // its own loop, so a mouse-up event can't be relied on to arrive here).
                    window.isMovable = false
                    Task { @MainActor [weak window] in
                        while NSEvent.pressedMouseButtons != 0 {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        window?.isMovable = true
                    }
                }
                return event
            }
        }

        private func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
