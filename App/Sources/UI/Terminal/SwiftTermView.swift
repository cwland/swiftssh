import SwiftUI
import AppKit
import Observation
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

/// Settings → Terminal → Keyword highlighting for this Mac: one instance, shared by the Settings
/// pane and every terminal view (`TerminalViewStore` pushes changes to open tabs).
@MainActor
enum TerminalHighlighting {
    static let settings = KeywordHighlightSettings()
}

/// One SwiftTerm view (and its delegate) per open terminal tab, kept while the tab is open.
@MainActor
final class TerminalViewStore {
    private var entries: [UUID: TerminalBridge] = [:]

    init() {
        followHighlightSettings()
    }

    /// Gives every open view the current keyword highlighting settings, now and after each change
    /// (Observation fires once per registration, so this registers again each time).
    private func followHighlightSettings() {
        let snapshot = withObservationTracking {
            TerminalHighlighting.settings.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in self?.followHighlightSettings() }
        }
        for entry in entries.values {
            entry.view.updateHighlighting(snapshot)
        }
    }

    /// The tab's terminal view, created (and wired to the session) on first use with
    /// `appearance`'s font. Callers apply `appearance` themselves (`SessionTerminalView.apply`).
    /// Session output goes through the view's `receive(_:)` (keyword highlighting).
    func view(for tab: TerminalTab, sessions: SessionManager, appearance: TerminalAppearance) -> SessionTerminalView {
        if let entry = entries[tab.id] { return entry.view }
        let entry = TerminalBridge(tabID: tab.id, sessions: sessions, appearance: appearance)
        entries[tab.id] = entry
        let view = entry.view
        view.updateHighlighting(TerminalHighlighting.settings.snapshot)
        tab.outputSink = { [weak entry] bytes in
            entry?.receiveOutput(bytes)
        }
        followSessionEnd(of: tab, view: view)
        return view
    }

    /// When the tab's session ends, the highlighter's held bytes (at most an incomplete escape or
    /// UTF-8 sequence) are fed at once instead of after the idle delay. Observation fires once per
    /// registration, so this registers again each time, until the tab or its view is gone.
    private func followSessionEnd(of tab: TerminalTab, view: SessionTerminalView) {
        let state = withObservationTracking {
            tab.state
        } onChange: { [weak self, weak tab, weak view] in
            Task { @MainActor in
                guard let self, let tab, let view, self.entries[tab.id]?.view === view else { return }
                self.followSessionEnd(of: tab, view: view)
            }
        }
        if case .disconnected = state {
            view.flushHighlighter()
        }
    }

    /// Pastes `text` into the tab's terminal the way ⌘V does: SwiftTerm wraps it in bracketed-paste
    /// markers when the shell asked for them (so a multi-line paste is inserted, not run) and applies
    /// its paste safety rules. False when the tab has no view yet.
    func paste(_ text: String, tabID: UUID) -> Bool {
        guard let view = entries[tabID]?.view else { return false }
        view.pasteAsUser(text)
        return true
    }

    /// Whether a multi-line paste would be inserted (bracketed paste on) rather than run line by line.
    func isBracketedPasteActive(tabID: UUID) -> Bool {
        entries[tabID]?.view.isBracketedPasteActive ?? false
    }

    /// Gives the tab's terminal the keyboard focus again (after the snippets panel pastes or runs);
    /// nothing while its view is not in a window.
    func focus(tabID: UUID) {
        guard let view = entries[tabID]?.view, let window = view.window else { return }
        window.makeFirstResponder(view)
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

/// Connects a terminal view to its tab's session: keystrokes go to `sendInput(fromTab:)` (which also
/// types them into the other panes of a broadcasting workspace), session output to the view and to
/// `noteOutput` (a workspace pane's "new output" dot), size changes to `resize`; ⌘-clicked links open
/// in their default app when `TerminalLinkFilter` allows them.
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

    /// Session output for this tab: into the view (through keyword highlighting), and noted for the
    /// pane status dot.
    func receiveOutput(_ bytes: [UInt8]) {
        view.receive(bytes)
        sessions?.noteOutput(tabID: tabID)
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
        // Only what the user typed or pasted may be broadcast to a workspace's other panes. The
        // terminal's own replies (cursor-position/device reports, clipboard answers, mouse reports)
        // belong to this pane alone.
        if view.isUserInput {
            sessions?.sendInput(fromTab: tabID, Array(data))
        } else {
            sessions?.send(tabID: tabID, Array(data))
        }
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// SwiftTerm calls this for a ⌘-click on a link (detected or OSC 8) while link reporting is on
    /// (Settings → Terminal → "Open links with ⌘-click"). `TerminalLinkFilter` decides: only safe
    /// http, https and mailto links open; anything else is ignored without a prompt. An OSC 8 link
    /// can show text other than its target, and SwiftTerm 1.99.3 doesn't tell us the text it was
    /// drawn as, so every OSC 8 link asks first, showing the full URL.
    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        guard view.opensLinks else { return }
        switch TerminalLinkFilter.decision(link: request.link, isExplicit: request.isExplicit, visibleText: nil) {
        case .ignore:
            return
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .confirm(let url):
            confirmOpening(url)
        }
    }

    private func confirmOpening(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Open this link?"
        alert.informativeText = "The program in this terminal made a link whose text may not show where it goes:\n\n\(url.absoluteString)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let open = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: open)
        } else {
            open(alert.runModal())
        }
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
    /// Set while the terminal's own reply (a device/cursor report, clipboard answer, mouse report)
    /// is handed to the delegate.
    private var isTerminalReply = false
    /// Set while a paste or text input from the user is being handled.
    private var userInputDepth = 0

    /// Whether data the terminal sends right now comes from the user: a paste, text input, or a key
    /// press in this view's window while it has the keyboard focus. Never for the terminal's own
    /// replies or mouse reports (`send(source: Terminal, …)` below marks those).
    var isUserInput: Bool {
        if isTerminalReply { return false }
        if userInputDepth > 0 { return true }
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              let window, event.window === window, window.firstResponder === self else { return false }
        return true
    }

    /// SwiftTerm's path for what the terminal itself sends back (it always arrives a main-queue hop
    /// after the output that caused it, so no flag set around `feed` could cover it), and also for a
    /// paste. Same hop as SwiftTerm's own. A paste runs inside our `paste`/`pasteAsUser` on the main
    /// thread, so it is recognised here, before the hop; anything else is marked as a reply so a
    /// broadcasting workspace keeps it in this pane.
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        let fromUser = Thread.isMainThread && MainActor.assumeIsolated { self.userInputDepth > 0 }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTerminalReply = !fromUser
                defer { self.isTerminalReply = false }
                self.userInputDepth += fromUser ? 1 : 0
                defer { self.userInputDepth -= fromUser ? 1 : 0 }
                self.terminalDelegate?.send(source: self, data: bytes[...])
            }
        }
    }

    override func paste(_ sender: Any) {
        userInputDepth += 1
        defer { userInputDepth -= 1 }
        super.paste(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        userInputDepth += 1
        defer { userInputDepth -= 1 }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Pastes text from the app (snippets) as user input.
    func pasteAsUser(_ text: String) {
        userInputDepth += 1
        defer { userInputDepth -= 1 }
        pasteText(text)
    }

    /// Called with each new grid size, once per change.
    var onSizeChange: ((Int, Int) -> Void)?
    private var reportedSize: (cols: Int, rows: Int)?
    private var appliedAppearance: TerminalAppearance?
    /// "Open links with ⌘-click"; read by the bridge when SwiftTerm asks to open a link.
    private(set) var opensLinks = TerminalBehaviour().opensLinks
    /// "Select text to copy & right-click to paste".
    private var selectToCopyRightClickToPaste = TerminalBehaviour().selectToCopyRightClickToPaste
    /// The selection when the left button went down, to copy only a new selection on mouse-up.
    private var selectionAtMouseDown: String?
    /// Keyword highlighting for this tab's output (package E). Always in the path, also when
    /// disabled (then it passes bytes through unchanged), so it keeps tracking colours and the
    /// alternate screen and turning it on mid-session is correct. It holds back nothing but an
    /// incomplete escape or UTF-8 sequence at the end of a chunk (bounded), so typed characters
    /// echo without delay.
    private let highlighter = KeywordHighlighter()
    /// Whether the shell turned on bracketed paste (`CSI ? 2004 h`), tracked from the output.
    var isBracketedPasteActive: Bool { highlighter.isBracketedPasteActive }
    /// When output last arrived. Held bytes are released `idleFlushDelay` after the last output
    /// (a safety net: normally the next chunk completes them) or at once when the session ends.
    private var lastOutput = ContinuousClock.now
    private var idleFlushScheduled = false
    private static let idleFlushDelay = Duration.milliseconds(50)

    /// `family` at `size` points; SF Mono (the system monospaced font) when `family` is nil or not
    /// installed (any more).
    static func terminalFont(family: String?, size: Int) -> NSFont {
        let pointSize = CGFloat(size)
        if let family, let font = font(family: family, size: pointSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    /// The family's regular face, or (a family without one) the face `TerminalFontChoice`
    /// prefers among the installed members; nil when the family isn't installed.
    static func font(family: String, size: CGFloat) -> NSFont? {
        let manager = NSFontManager.shared
        if let font = manager.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        // Each member is [PostScript name, style name, weight, traits].
        let members = (manager.availableMembers(ofFontFamily: family) ?? []).compactMap { entry -> TerminalFontChoice.Member? in
            guard entry.count >= 4, let name = entry[0] as? String,
                  let weight = (entry[2] as? NSNumber)?.intValue,
                  let traits = (entry[3] as? NSNumber)?.uintValue else { return nil }
            let mask = NSFontTraitMask(rawValue: traits)
            return TerminalFontChoice.Member(name: name, weight: weight, isBold: mask.contains(.boldFontMask),
                                             isItalic: mask.contains(.italicFontMask))
        }
        return TerminalFontChoice.preferredMember(members).flatMap { NSFont(name: $0, size: size) }
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

    /// Installs palette, bg/fg/caret/selection; sets the font only when family or size changed;
    /// applies the behaviour toggles. Returns early when `appearance` equals the last applied one.
    /// Cells keep palette indices, so the scrollback is redrawn in the new colors. A new font goes
    /// through SwiftTerm's
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

    /// Session output for this tab: through the keyword highlighter, then into the terminal.
    func receive(_ bytes: [UInt8]) {
        let output = highlighter.process(bytes[...])
        if !output.isEmpty {
            feed(byteArray: output[...])
        }
        lastOutput = .now
        scheduleIdleFlush()
    }

    /// Settings → Terminal → Keyword highlighting changed (or the view is new).
    func updateHighlighting(_ snapshot: KeywordHighlightSettings.Snapshot) {
        guard snapshot != highlighter.settings else { return }
        highlighter.update(settings: snapshot)
    }

    /// One wait per quiet period, not one per chunk: the task sleeps until `idleFlushDelay` after
    /// the latest output and then releases whatever the highlighter still holds (≤ 64 bytes, e.g.
    /// a prompt that ends in a word).
    private func scheduleIdleFlush() {
        guard !idleFlushScheduled else { return }
        idleFlushScheduled = true
        Task { @MainActor [weak self] in
            // `self` is re-read weakly on every turn, so the sleep doesn't keep a closed tab's view.
            while let due = self.map({ $0.lastOutput + SessionTerminalView.idleFlushDelay }) {
                if ContinuousClock.now >= due {
                    self?.idleFlushScheduled = false
                    self?.flushHighlighter()
                    return
                }
                try? await Task.sleep(until: due, clock: .continuous)
            }
        }
    }

    /// Feeds whatever the highlighter still holds (idle, or the session ended).
    func flushHighlighter() {
        let held = highlighter.flush()
        if !held.isEmpty {
            feed(byteArray: held[...])
        }
    }

    // MARK: Select to copy, right-click to paste

    override func mouseDown(with event: NSEvent) {
        selectionAtMouseDown = selectToCopyRightClickToPaste ? getSelection() : nil
        super.mouseDown(with: event)
    }

    /// With "Select text to copy" on, a mouse-up that made a new selection (drag, double- or
    /// triple-click) puts it on the clipboard. Not while the program tracks the mouse: SwiftTerm
    /// then leaves an old selection in place, and each click would copy it again.
    override func mouseUp(with event: NSEvent) {
        let tracking = programTracksMouse(event)
        super.mouseUp(with: event)
        guard selectToCopyRightClickToPaste else { return }
        let before = selectionAtMouseDown
        selectionAtMouseDown = nil
        let after = getSelection()
        guard SelectionCopyRule.shouldCopy(before: before, after: after, programTracksMouse: tracking),
              let after else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(after, forType: .string)
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
