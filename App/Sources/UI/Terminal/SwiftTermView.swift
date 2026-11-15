import SwiftUI
import AppKit
import AppCore
import SwiftTerm

// SwiftTerm also defines `Color`; this file uses only AppKit colors. Theme colors come from
// AppCore's `TerminalThemeCatalog` (conversions in TerminalTheme+AppKit.swift).

/// Shows a tab's SwiftTerm view. The view itself lives in `TerminalViewStore`, not here, so
/// switching tabs (which tears this representable down) keeps the scrollback.
struct SwiftTermView: NSViewRepresentable {
    let tab: TerminalTab
    let sessions: SessionManager
    let store: TerminalViewStore

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.attach(store.view(for: tab, sessions: sessions))
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        host.attach(store.view(for: tab, sessions: sessions))
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

    /// The tab's terminal view, created (and wired to the session) on first use.
    func view(for tab: TerminalTab, sessions: SessionManager) -> SessionTerminalView {
        if let entry = entries[tab.id] { return entry.view }
        let entry = TerminalBridge(tabID: tab.id, sessions: sessions)
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

    init(tabID: UUID, sessions: SessionManager) {
        self.tabID = tabID
        self.sessions = sessions
        view = SessionTerminalView(font: Self.terminalFont)
        view.terminalDelegate = self
        view.onSizeChange = { [weak self] cols, rows in
            guard let self else { return }
            self.sessions?.resize(tabID: self.tabID, cols: cols, rows: rows)
        }
    }

    /// SF Mono 13 pt.
    private static var terminalFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
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
/// calls `sizeChanged` when the grid changes from its 80×25 default), and light/dark colors follow
/// the effective appearance.
final class SessionTerminalView: TerminalView {
    /// Called with each new grid size, once per change.
    var onSizeChange: ((Int, Int) -> Void)?
    private var reportedSize: (cols: Int, rows: Int)?
    private var appliedDarkTheme: Bool?

    init(font: NSFont) {
        super.init(frame: .zero, font: font)
        applyTheme()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// Automatic: Reimagined Light or Dark from the theme catalog, by the effective appearance.
    private func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard dark != appliedDarkTheme else { return }
        appliedDarkTheme = dark
        let theme = TerminalThemeCatalog.shared.automatic(prefersDark: dark)
        installColors(theme.swiftTermPalette)
        nativeBackgroundColor = theme.background.nsColor
        nativeForegroundColor = theme.foreground.nsColor
        caretColor = theme.cursor.nsColor
        selectedTextBackgroundColor = theme.selection.nsColor
    }
}
