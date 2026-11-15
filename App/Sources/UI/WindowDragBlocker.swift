import SwiftUI
import AppKit

/// Keeps a click inside this view from moving the window.
///
/// The top bar sits in the hidden title bar, where AppKit starts a window drag for a mouse-down on any
/// spot SwiftUI doesn't claim (for example the see-through parts of an unselected tab), so a tab drag
/// sometimes moved the whole window. Behind a tab, this watches mouse-downs before AppKit handles them
/// and makes the window unmovable for that one click; the tab's own drag (reorder, drop on a terminal)
/// is unaffected. Empty parts of the bar still move the window.
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> BlockerView { BlockerView() }

    func updateNSView(_ view: BlockerView, context: Context) {}

    final class BlockerView: NSView {
        private var monitor: Any?

        /// Transparent to clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { stopWatching() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil { startWatching() }
        }

        private func startWatching() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window, window.isMovable,
                          !self.isHiddenOrHasHiddenAncestor else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(point) else { return }
                    // The title bar decides whether to move the window while it handles this
                    // mouse-down; it is movable again right after.
                    window.isMovable = false
                    DispatchQueue.main.async { [weak window] in
                        MainActor.assumeIsolated { window?.isMovable = true }
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
