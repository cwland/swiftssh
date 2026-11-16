import Foundation

/// Which window a window-level command or prompt goes to. The app passes its windows in as opaque
/// tokens (`ObjectIdentifier` of the `NSWindow`), so the rules can be tested without AppKit.
public enum WindowRouting {
    /// What kind of window is key when File > Close (Cmd+W) runs.
    public enum KeyWindow: Equatable, Sendable {
        /// A main window or a terminal window (one that shows terminal tabs).
        case appWindow
        /// Settings, or any other window without terminal tabs.
        case otherWindow
    }

    public enum CloseAction: Equatable, Sendable {
        /// Close the focused window's selected tab, or its workspace's focused pane.
        case closeTabOrPane
        /// The standard window close (`performClose`) of the key window.
        case closeKeyWindow
    }

    /// Cmd+W: with Settings (or any window without tabs) in front, that window closes, never a tab
    /// behind it. In a main or terminal window the selected tab or pane closes; with none (Vaults
    /// shown), the window. With no key window, a selected tab still closes.
    public static func closeCommand(keyWindow: KeyWindow?, hasActiveTab: Bool) -> CloseAction {
        if keyWindow == .otherWindow { return .closeKeyWindow }
        return hasActiveTab ? .closeTabOrPane : .closeKeyWindow
    }

    /// The one window that shows a prompt about a workspace (save before closing a pane, name a first
    /// save): `candidates` are the windows showing it, front to back. The key window when it is one of
    /// them, else the frontmost of them; with none, the key window.
    public static func promptWindow<Window: Equatable>(among candidates: [Window], keyWindow: Window?) -> Window? {
        if let keyWindow, candidates.contains(keyWindow) { return keyWindow }
        return candidates.first ?? keyWindow
    }
}

/// A request for one window to show a prompt about `subjectID` (a pane or a workspace). Two main
/// windows show the same tabs, so a request names its window and only that window takes it.
public struct WindowTargetedRequest<Window: Hashable & Sendable>: Hashable, Sendable {
    public let subjectID: UUID
    /// The window that shows the prompt; nil when none could be identified (then no window does).
    public let window: Window?

    public init(subjectID: UUID, window: Window?) {
        self.subjectID = subjectID
        self.window = window
    }

    /// Whether the window `window` should take this request.
    public func isFor(window: Window?) -> Bool {
        guard let target = self.window, let window else { return false }
        return target == window
    }
}
