import SwiftUI
import UIKit
import GameController
import Observation
import AppCore
import SwiftTerm
import SwiftSSHUI

// SwiftTerm also defines `Color`; this file uses UIKit colours only.

/// Shows a session's SwiftTerm view. The view lives in `TerminalViewStore`, not here, so switching
/// sessions (which tears this representable down) keeps the scrollback. `appearance` is applied on
/// every update, so a theme or text size change reaches the open session at once.
struct TerminalContainerView: UIViewRepresentable {
    let tab: TerminalTab
    let sessions: SessionManager
    let store: TerminalViewStore
    let appearance: TerminalAppearance
    /// Pinch to zoom: the new text size in points.
    let changeFontSize: @MainActor (Int) -> Void

    func makeUIView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        attach(to: host)
        return host
    }

    func updateUIView(_ host: TerminalHostView, context: Context) {
        attach(to: host)
    }

    private func attach(to host: TerminalHostView) {
        let view = store.view(for: tab, sessions: sessions, appearance: appearance)
        view.onFontSizeChange = changeFontSize
        view.apply(appearance)
        host.attach(view)
    }

    static func dismantleUIView(_ host: TerminalHostView, coordinator: ()) {
        host.detach()
    }
}

/// Plain container for a stored terminal view; the terminal fills it and takes the keyboard when it
/// lands in a window.
final class TerminalHostView: UIView {
    private weak var terminal: UIView?

    func attach(_ view: UIView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        terminal = view
        focusTerminal()
    }

    /// Takes the terminal out unless another host already took it over.
    func detach() {
        if let terminal, terminal.superview === self {
            terminal.resignFirstResponder()
            terminal.removeFromSuperview()
        }
        terminal = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        focusTerminal()
    }

    private func focusTerminal() {
        guard window != nil, let terminal else { return }
        DispatchQueue.main.async { _ = terminal.becomeFirstResponder() }
    }
}

/// One SwiftTerm view (and its delegate) per open session, kept while the session is open.
@MainActor
final class TerminalViewStore {
    private var entries: [UUID: TerminalBridge] = [:]

    /// The session's terminal view, created (and wired to the session) on first use.
    func view(for tab: TerminalTab, sessions: SessionManager, appearance: TerminalAppearance) -> SessionTerminalView {
        if let entry = entries[tab.id] { return entry.view }
        let entry = TerminalBridge(tabID: tab.id, sessions: sessions, appearance: appearance)
        entries[tab.id] = entry
        tab.outputSink = { [weak entry] bytes in
            entry?.view.feed(byteArray: bytes[...])
        }
        return entry.view
    }

    /// Pastes `text` as a paste from the user: SwiftTerm wraps it in bracketed-paste markers when the
    /// shell asked for them. False when the session has no view yet.
    func paste(_ text: String, tabID: UUID) -> Bool {
        guard let view = entries[tabID]?.view else { return false }
        view.pasteText(text)
        return true
    }

    /// Whether the shell turned on bracketed paste.
    func isBracketedPasteActive(tabID: UUID) -> Bool {
        entries[tabID]?.view.terminalInputStateSnapshot()?.bracketedPasteMode ?? false
    }

    /// Gives the session's terminal the keyboard again (after the snippets drawer closes).
    func focus(tabID: UUID) {
        guard let view = entries[tabID]?.view, view.window != nil else { return }
        _ = view.becomeFirstResponder()
    }

    /// Shows the keyboard when the session's terminal doesn't have it, hides it when it does (the
    /// session header's keyboard button; swiping the keyboard away has no way back otherwise).
    func toggleKeyboard(tabID: UUID) {
        guard let view = entries[tabID]?.view, view.window != nil else { return }
        if view.isFirstResponder {
            _ = view.resignFirstResponder()
        } else {
            _ = view.becomeFirstResponder()
        }
    }

    /// Releases the views of sessions that are no longer open. SwiftTerm requires `updateUiClosed()`
    /// before a view is let go; when it returns false the entry is kept and released later.
    func retain(only openTabIDs: Set<UUID>) {
        let closed = entries.keys.filter { !openTabIDs.contains($0) }
        for id in closed {
            guard let entry = entries[id], entry.view.updateUiClosed() else { continue }
            entry.view.terminalDelegate = nil
            entries.removeValue(forKey: id)
        }
    }
}

/// Connects a terminal view to its session: what the terminal sends (typed keys, the key bar, the
/// terminal's own replies) goes to `SessionManager.send`, size changes to `resize`. Links open only
/// when `TerminalLinkFilter` allows them.
@MainActor
final class TerminalBridge: TerminalViewDelegate {
    let view: SessionTerminalView
    private let tabID: UUID
    private weak var sessions: SessionManager?

    init(tabID: UUID, sessions: SessionManager, appearance: TerminalAppearance) {
        self.tabID = tabID
        self.sessions = sessions
        view = SessionTerminalView(fontSize: appearance.fontSize)
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
        // The session keeps the host's name.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sessions?.send(tabID: tabID, Array(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// Only safe http, https and mailto links open; an OSC 8 link (whose text may not show where it
    /// goes) asks first, showing the full address.
    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        switch TerminalLinkFilter.decision(link: request.link, isExplicit: request.isExplicit, visibleText: nil) {
        case .ignore:
            return
        case .open(let url):
            UIApplication.shared.open(url)
        case .confirm(let url):
            confirmOpening(url)
        }
    }

    private func confirmOpening(_ url: URL) {
        guard let presenter = view.window?.rootViewController.map(Self.topmost) else { return }
        let alert = UIAlertController(title: "Open this link?",
                                      message: "The program in this terminal made a link whose text may not show where it goes:\n\n\(url.absoluteString)",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in UIApplication.shared.open(url) })
        presenter.present(alert, animated: true)
    }

    private static func topmost(_ controller: UIViewController) -> UIViewController {
        var top = controller
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    func bell(source: TerminalView) {}

    // OSC 52 clipboard writes from the server keep SwiftTerm's default (ignored), as on the Mac: a
    // remote program never replaces what is on this device's clipboard.
}

/// SwiftTerm's iOS view plus: the size is reported as soon as the layout gives it one; the theme and
/// text size are applied through `apply(_:)`; pinch changes the text size; and the key bar (Esc, Ctrl,
/// Alt, Tab, arrows, symbols) sits above the software keyboard, hidden while a hardware keyboard is
/// attached. With the key bar's Ctrl or Alt on, a keystroke from the software keyboard goes through
/// `KeyBarState.transform`; a hardware keyboard's own modifiers are handled by SwiftTerm as usual.
final class SessionTerminalView: TerminalView {
    /// Called with each new grid size, once per change.
    var onSizeChange: (@MainActor (Int, Int) -> Void)?
    /// Pinch to zoom: the new text size in points.
    var onFontSizeChange: (@MainActor (Int) -> Void)?
    let keyBar = KeyBarState()
    private var keyBarView: KeyBarView?
    private var reportedSize: (cols: Int, rows: Int)?
    private var appliedAppearance: TerminalAppearance?
    private var pinchStartSize: Int?
    /// Hardware keyboard connect/disconnect observers; written once in `configure()`, read in deinit.
    nonisolated(unsafe) private var keyboardObservers: [NSObjectProtocol] = []

    static func terminalFont(size: Int) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    init(fontSize: Int) {
        super.init(frame: .zero, font: Self.terminalFont(size: fontSize))
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func configure() {
        collapseBrightColorsToBase = false
        let bar = KeyBarView(state: keyBar) { [weak self] key in
            self?.sendKey(key)
        }
        keyBarView = bar
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)
        updateKeyBar()
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            keyboardObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateKeyBar() }
            })
        }
    }

    /// The key bar shows only without a hardware keyboard (which has its own Esc, Ctrl and arrows).
    private func updateKeyBar() {
        let hardware = GCKeyboard.coalesced != nil
        if hardware { keyBar.releaseAll() }
        let wanted: UIView? = hardware ? nil : keyBarView
        guard inputAccessoryView !== wanted else { return }
        inputAccessoryView = wanted
        if isFirstResponder { reloadInputViews() }
    }

    // MARK: Input

    /// Software keyboard text (hardware keyboard text arrives here too, but then the bar is hidden
    /// and its modifiers are off).
    override func insertText(_ text: String) {
        guard keyBar.isActive else {
            super.insertText(text)
            return
        }
        let typed = text == "\n" ? "\r" : text
        send(keyBar.transform(Array(typed.utf8)))
    }

    private func sendKey(_ key: KeyBarState.Key) {
        let applicationCursor = terminalInputStateSnapshot()?.applicationCursor ?? false
        let bytes = keyBar.bytes(for: key, applicationCursor: applicationCursor)
        if !bytes.isEmpty { send(bytes) }
    }

    // MARK: Size

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let dimensions = terminalDimensions
        reportSize(cols: dimensions.cols, rows: dimensions.rows)
    }

    func reportSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let reportedSize, reportedSize.cols == cols, reportedSize.rows == rows { return }
        reportedSize = (cols, rows)
        onSizeChange?(cols, rows)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartSize = appliedAppearance?.fontSize ?? TerminalSettings.defaultFontSize
        case .changed:
            guard let start = pinchStartSize else { return }
            let range = TerminalSettings.fontSizeRange
            let size = min(max(Int((Double(start) * Double(gesture.scale)).rounded()), range.lowerBound), range.upperBound)
            if size != appliedAppearance?.fontSize { onFontSizeChange?(size) }
        default:
            pinchStartSize = nil
        }
    }

    // MARK: Appearance

    /// Installs the theme's colours and the text size; nothing when `appearance` is what was applied
    /// last. A new size goes through SwiftTerm's resize → `sizeChanged` → `SessionManager.resize`.
    func apply(_ appearance: TerminalAppearance) {
        guard appearance != appliedAppearance else { return }
        if appearance.theme != appliedAppearance?.theme {
            let theme = appearance.theme
            installColors(theme.swiftTermPalette)
            nativeBackgroundColor = theme.background.uiColor
            nativeForegroundColor = theme.foreground.uiColor
            caretColor = theme.cursor.uiColor
            selectedTextBackgroundColor = theme.selection.uiColor
            backgroundColor = theme.background.uiColor
            keyboardAppearance = Self.isDark(theme.background) ? .dark : .light
        }
        if appearance.fontSize != appliedAppearance?.fontSize {
            let newFont = Self.terminalFont(size: appearance.fontSize)
            if newFont != font { font = newFont }
        }
        if appearance.behaviour != appliedAppearance?.behaviour {
            optionAsMetaKey = appearance.behaviour.optionAsMetaKey
            useBrightColors = appearance.behaviour.boldUsesBrightColors
            bellStyle = appearance.behaviour.bellSound ? .sound : .none
        }
        appliedAppearance = appearance
    }

    private static func isDark(_ color: AppCore.RGBColor) -> Bool {
        (0.299 * Double(color.red) + 0.587 * Double(color.green) + 0.114 * Double(color.blue)) < 128
    }
}
