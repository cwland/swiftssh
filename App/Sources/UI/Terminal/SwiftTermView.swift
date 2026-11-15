import SwiftUI
import AppKit
import AppCore
import SwiftTerm

// SwiftTerm also defines `Color`; this file uses only AppKit colors. Theme colors come from
// AppCore's `TerminalThemeCatalog` (conversions in TerminalTheme+AppKit.swift).

/// Shows a tab's SwiftTerm view. The view itself lives in `TerminalViewStore`, not here, so
/// switching tabs (which tears this representable down) keeps the scrollback. `appearance` is
/// applied on every update, so theme, font, text size and behaviour changes reach the open tab
/// live (and a tab that was hidden gets the current one when it is shown, before it draws).
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
    /// `appearance`'s font. Callers apply `appearance` themselves (`SessionTerminalView.apply`).
    /// Session output goes through the view's `receive(_:)` (keyword highlighting).
    func view(for tab: TerminalTab, sessions: SessionManager, appearance: TerminalAppearance) -> SessionTerminalView {
        if let entry = entries[tab.id] { return entry.view }
        let entry = TerminalBridge(tabID: tab.id, sessions: sessions, appearance: appearance)
        entries[tab.id] = entry
        let view = entry.view
        tab.outputSink = { [weak view] bytes in
            view?.receive(bytes)
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
/// `resize`; ⌘-clicked links open in their default app when `TerminalLinkFilter` allows them.
@MainActor
final class TerminalBridge: TerminalViewDelegate {
    let view: SessionTerminalView
    private let tabID: UUID
    private weak var sessions: SessionManager?

    init(tabID: UUID, sessions: SessionManager, appearance: TerminalAppearance) {
        self.tabID = tabID
        self.sessions = sessions
        view = SessionTerminalView(font: SessionTerminalView.terminalFont(family: appearance.fontName,
                                                                          size: appearance.fontSize))
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

    /// SwiftTerm calls this for a ⌘-click on a link (detected or OSC 8) while link reporting is on
    /// (Settings → Terminal → "Open links with ⌘-click"). Only http, https, ssh and mailto open;
    /// anything else is ignored without a prompt.
    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        guard view.opensLinks, let url = TerminalLinkFilter.openableURL(request.link) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Only reached with `bellStyle == .sound` (the "Bell sound" setting).
    func bell(source: TerminalView) {
        NSSound.beep()
    }
}

/// SwiftTerm's view plus: the size is reported as soon as the frame gives it one (SwiftTerm only
/// calls `sizeChanged` when the grid changes from its 80×25 default), and the tab's theme, font,
/// text size and behaviour are applied through `apply(_:)`. Automatic's light/dark choice is made
/// by the caller (SwiftUI's color scheme), so this view no longer re-themes itself on appearance
/// changes.
final class SessionTerminalView: TerminalView {
    /// Called with each new grid size, once per change.
    var onSizeChange: ((Int, Int) -> Void)?
    private var reportedSize: (cols: Int, rows: Int)?
    private var appliedAppearance: TerminalAppearance?
    /// "Open links with ⌘-click"; read by the bridge when SwiftTerm asks to open a link.
    private(set) var opensLinks = TerminalBehaviour().opensLinks
    /// "Select text to copy & right-click to paste".
    private var selectToCopyRightClickToPaste = TerminalBehaviour().selectToCopyRightClickToPaste

    /// `family` at `size` points; SF Mono (the system monospaced font) when `family` is nil or not
    /// installed (any more).
    static func terminalFont(family: String?, size: Int) -> NSFont {
        let pointSize = CGFloat(size)
        if let family, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: pointSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    init(font: NSFont) {
        super.init(frame: .zero, font: font)
        configureDefaults()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureDefaults()
    }

    /// Behaviour that no setting changes: bold-as-bright off never collapses explicit bright
    /// colours (ESC[9xm, 256-colour indices) to the base ones; ⌘ underlines and ⌘-click opens.
    private func configureDefaults() {
        collapseBrightColorsToBase = false
        linkHighlightMode = .hoverWithModifier
        apply(TerminalBehaviour())
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
        if appearance.fontName != appliedAppearance?.fontName || appearance.fontSize != appliedAppearance?.fontSize {
            let newFont = Self.terminalFont(family: appearance.fontName, size: appearance.fontSize)
            // Setting `font` clears the selection and re-lays out, so only on a real change (the
            // first apply after init usually matches the font the view was created with).
            if newFont != font {
                font = newFont
            }
        }
        if appearance.behaviour != appliedAppearance?.behaviour {
            apply(appearance.behaviour)
        }
        appliedAppearance = appearance
    }

    private func apply(_ behaviour: TerminalBehaviour) {
        optionAsMetaKey = behaviour.optionAsMetaKey
        useBrightColors = behaviour.boldUsesBrightColors
        bellStyle = behaviour.bellSound ? .sound : .none
        // `.none` also stops the ⌘-hover underline, so a disabled setting shows no links at all.
        linkReporting = behaviour.opensLinks ? .implicit : .none
        opensLinks = behaviour.opensLinks
        selectToCopyRightClickToPaste = behaviour.selectToCopyRightClickToPaste
    }

    // MARK: Output

    /// Session output for this tab.
    func receive(_ bytes: [UInt8]) {
        feed(byteArray: bytes[...])
    }

    // MARK: Select to copy, right-click to paste

    /// With "Select text to copy" on, a mouse-up that leaves a selection (drag, double- or
    /// triple-click) puts it on the clipboard.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard selectToCopyRightClickToPaste, let text = getSelection(), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// With "right-click to paste" on, a right-click pastes, unless the program is tracking the
    /// mouse (then the click is the program's, as SwiftTerm reports it; Shift bypasses that, as
    /// it does for selection).
    override func rightMouseDown(with event: NSEvent) {
        guard selectToCopyRightClickToPaste, !programTracksMouse(event) else {
            super.rightMouseDown(with: event)
            return
        }
        paste(self)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard selectToCopyRightClickToPaste, !programTracksMouse(event) else {
            super.rightMouseUp(with: event)
            return
        }
    }

    private func programTracksMouse(_ event: NSEvent) -> Bool {
        allowMouseReporting && currentMouseMode != .off && !event.modifierFlags.contains(.shift)
    }
}
