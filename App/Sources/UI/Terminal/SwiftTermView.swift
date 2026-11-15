import SwiftUI
import AppKit
import AppCore
import SwiftTerm

// SwiftTerm also defines `Color`; this file uses only AppKit colors. Theme colors come from
// AppCore's `TerminalThemeCatalog` (conversions in TerminalTheme+AppKit.swift).

/// Shows a tab's SwiftTerm view. The view itself lives in `TerminalViewStore`, not here, so
/// switching tabs (which tears this representable down) keeps the scrollback. `appearance` is
/// applied on every update, so theme and text size changes reach the open tab live (and a tab
/// that was hidden gets the current one when it is shown, before it draws).
struct SwiftTermView: NSViewRepresentable {
    let tab: TerminalTab
    let sessions: SessionManager
    let store: TerminalViewStore
    let appearance: TerminalAppearance

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        attachTerminal(to: host)
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        attachTerminal(to: host)
    }

    private func attachTerminal(to host: TerminalHostView) {
        let view = store.view(for: tab, sessions: sessions, appearance: appearance)
        view.apply(appearance)
        host.attach(view)
    }

    static func dismantleNSView(_ host: TerminalHostView, coordinator: ()) {
        host.detach()
    }
}

/// Plain container for a stored terminal view; the terminal fills it and takes keyboard focus
/// when it lands in a window.
final class TerminalHostView: NSView {
    private weak var terminal: NSView?

    func attach(_ view: NSView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        terminal = view
        focusTerminal()
    }

    /// Takes the terminal out unless another host already took it over.
    func detach() {
        if let terminal, terminal.superview === self {
            terminal.removeFromSuperview()
        }
        terminal = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTerminal()
    }

    private func focusTerminal() {
        guard let window, let terminal else { return }
        window.makeFirstResponder(terminal)
    }
}

/// One SwiftTerm view (and its delegate) per open terminal tab, kept while the tab is open.
@MainActor
final class TerminalViewStore {
    private var entries: [UUID: TerminalBridge] = [:]

    /// The tab's terminal view, created (and wired to the session) on first use with
    /// `appearance`'s text size. Callers apply `appearance` themselves (`SessionTerminalView.apply`).
    func view(for tab: TerminalTab, sessions: SessionManager, appearance: TerminalAppearance) -> SessionTerminalView {
        if let entry = entries[tab.id] { return entry.view }
        let entry = TerminalBridge(tabID: tab.id, sessions: sessions, fontSize: appearance.fontSize)
        entries[tab.id] = entry
        let view = entry.view
        tab.outputSink = { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        return view
    }

    /// Releases the views of tabs that are no longer open. SwiftTerm requires `updateUiClosed()`
    /// before a view is let go; when it returns false (GPU work still in flight) the entry is kept
    /// and released on a later call.
    func retain(only openTabIDs: Set<UUID>) {
        let closed = entries.keys.filter { !openTabIDs.contains($0) }
        for id in closed {
            guard let entry = entries[id], entry.view.updateUiClosed() else { continue }
            entry.view.terminalDelegate = nil
            entries.removeValue(forKey: id)
        }
    }
}

/// Connects a terminal view to its tab's session: keystrokes go to `send`, size changes to
/// `resize`.
@MainActor
final class TerminalBridge: TerminalViewDelegate {
    let view: SessionTerminalView
    private let tabID: UUID
    private weak var sessions: SessionManager?

    init(tabID: UUID, sessions: SessionManager, fontSize: Int) {
        self.tabID = tabID
        self.sessions = sessions
        view = SessionTerminalView(font: SessionTerminalView.terminalFont(size: fontSize))
        view.terminalDelegate = self
        view.onSizeChange = { [weak self] cols, rows in
            guard let self else { return }
            self.sessions?.resize(tabID: self.tabID, cols: cols, rows: rows)
        }
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view.reportSize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // The tab keeps the host's label.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sessions?.send(tabID: tabID, Array(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// SwiftTerm's view plus: the size is reported as soon as the frame gives it one (SwiftTerm only
/// calls `sizeChanged` when the grid changes from its 80×25 default), and the tab's theme and text
/// size are applied through `apply(_:)`. Automatic's light/dark choice is made by the caller
/// (SwiftUI's color scheme), so this view no longer re-themes itself on appearance changes.
final class SessionTerminalView: TerminalView {
    /// Called with each new grid size, once per change.
    var onSizeChange: ((Int, Int) -> Void)?
    private var reportedSize: (cols: Int, rows: Int)?
    private var appliedAppearance: TerminalAppearance?

    /// SF Mono at `size` points.
    static func terminalFont(size: Int) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    init(font: NSFont) {
        super.init(frame: .zero, font: font)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard frame.width > 0, frame.height > 0 else { return }
        let dimensions = terminalDimensions
        reportSize(cols: dimensions.cols, rows: dimensions.rows)
    }

    func reportSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let reportedSize, reportedSize.cols == cols, reportedSize.rows == rows { return }
        reportedSize = (cols, rows)
        onSizeChange?(cols, rows)
    }

    /// Installs palette, bg/fg/caret/selection; sets the font only when the size changed.
    /// Returns early when `appearance` equals the last applied one. Cells keep palette indices, so
    /// the scrollback is redrawn in the new colors. A new font size goes through SwiftTerm's
    /// resize → `sizeChanged` → `reportSize` → `SessionManager.resize` (remote window change),
    /// the same path a window resize takes.
    func apply(_ appearance: TerminalAppearance) {
        guard appearance != appliedAppearance else { return }
        if appearance.theme != appliedAppearance?.theme {
            let theme = appearance.theme
            installColors(theme.swiftTermPalette)
            nativeBackgroundColor = theme.background.nsColor
            nativeForegroundColor = theme.foreground.nsColor
            caretColor = theme.cursor.nsColor
            selectedTextBackgroundColor = theme.selection.nsColor
        }
        let pointSize = CGFloat(appearance.fontSize)
        if font.pointSize != pointSize {
            font = Self.terminalFont(size: appearance.fontSize)
        }
        appliedAppearance = appearance
    }
}
