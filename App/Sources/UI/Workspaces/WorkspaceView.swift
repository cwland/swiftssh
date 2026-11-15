import SwiftUI
import AppKit
import AppCore
import CoreModels

/// A workspace tab's content: its panes in Split view (all visible, laid out by the split tree,
/// resizable dividers) or Focus mode (`FocusModeView`: one large terminal and the list of all).
///
/// Each pane is the tab's unchanged `TerminalTabView` (connection screen, reconnect popup and
/// banner, prompts, its own Change Theme / Snippets panel) under a `PaneHeader`. Clicking anywhere in
/// a pane focuses it (2 pt accent border) and the keyboard follows. While broadcasting, the focused
/// pane has a solid border, the other included panes a dashed one, and excluded panes none plus a
/// "not broadcasting" badge.
///
/// Drops: a terminal tab or host card dropped on a pane's half splits that pane there (the tab moves
/// in; a host opens a new connection); a pane dragged by its header moves next to the target. At 16
/// panes only moves are accepted.
///
/// Terminal views are never destroyed here: `TerminalViewStore` keeps them per tab, and each tab is
/// shown by at most one `TerminalTabView` at a time (one per pane in Split view, only the focused one
/// in Focus mode), so switching modes or rearranging panes just re-hosts the same views.
struct WorkspaceView: View {
    let workspace: Workspace
    let sessions: SessionManager
    let store: TerminalViewStore
    let vault: LocalVault
    let terminalSettings: TerminalSettings
    /// The window's open side panel (Change Theme or Snippets); shown on the pane whose tab it names.
    var sidePanel: TerminalSidePanel? = nil
    var closeSidePanel: () -> Void = {}
    /// "Change Theme…" in a pane's menu: open `TerminalSidePanel(tabID: paneID, kind: .theme)`.
    var changeTheme: (UUID) -> Void = { _ in }
    /// "Snippets…" in a pane's menu: open `TerminalSidePanel(tabID: paneID, kind: .snippets)`.
    var showSnippets: (UUID) -> Void = { _ in }
    /// "History…" in a pane's menu: open `TerminalSidePanel(tabID: paneID, kind: .history)`.
    var showHistory: (UUID) -> Void = { _ in }
    /// Closes one pane (its × and menu, the connection screen's Close, the reconnect popup's Close
    /// Terminal): end the session (`sessions.closePane`) and release its terminal view.
    var closePane: (UUID) -> Void
    /// "Edit host" on a pane's connection screen; nil hides it (windows without Vaults).
    var editHost: ((TerminalTab) -> Void)? = nil
    /// Edit / New Snippet in a pane's snippets panel; nil hides both (windows without Vaults).
    var editSnippet: ((UUID) -> Void)? = nil

    /// The pane being dragged by its header (or Focus mode row), for the overlays; the drop itself
    /// trusts only the dragged payload.
    @State private var draggingPaneID: UUID?
    @State private var dragEndWatch: Task<Void, Never>?
    @State private var renamingPaneID: UUID?
    @State private var renameText = ""
    @State private var dropError: String?

    static let maximumPanes = 16

    var body: some View {
        content
            // Keyboard focus follows the focused pane: after a click on its header, a mode switch, a
            // pane added or moved (hosting a terminal view gives it the focus, so the last one
            // attached would otherwise keep it).
            .task(id: FocusKey(pane: focusedPaneID, mode: workspace.viewMode, panes: workspace.paneIDs)) {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, let id = focusedPaneID else { return }
                store.focus(tabID: id)
            }
            .alert("Rename Tab", isPresented: renameBinding) {
                TextField("Tab name", text: $renameText)
                Button("Rename") {
                    if let id = renamingPaneID { sessions.rename(tabID: id, to: renameText) }
                    renamingPaneID = nil
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {
                    renamingPaneID = nil
                }
            } message: {
                Text("Only this tab is renamed; the host keeps its name. Leave empty to use the host\u{2019}s name.")
            }
            .alert("Couldn\u{2019}t Open the Host", isPresented: errorBinding) {
                Button("OK", role: .cancel) { dropError = nil }
            } message: {
                Text(dropError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.viewMode {
        case .split:
            splitView
        case .focus:
            FocusModeView(workspace: workspace, sessions: sessions, vault: vault, actions: actions,
                          draggingPaneID: $draggingPaneID,
                          beginPaneDrag: { beginPaneDrag($0) },
                          movePane: { movePane($0, beside: $1, at: $2) }) { id in
                pane(id, showsHeader: false)
            }
        }
    }

    // MARK: Split view

    private var splitView: some View {
        GeometryReader { proxy in
            let layout = PaneLayout(root: workspace.root, size: proxy.size)
            ZStack(alignment: .topLeading) {
                // The gaps between panes show this.
                Color.primary.opacity(0.18)
                ForEach(workspace.paneIDs, id: \.self) { id in
                    if let frame = layout.frames[id] {
                        pane(id, showsHeader: true)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                ForEach(layout.dividers) { divider in
                    PaneDivider(divider: divider) { ratio in
                        sessions.setRatio(ratio, atPath: divider.path, in: workspace.id)
                    }
                    .frame(width: divider.handle.width, height: divider.handle.height)
                    .position(x: divider.handle.midX, y: divider.handle.midY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(Theme.contentBackground)
    }

    // MARK: Pane

    /// One pane: header (Split view only), the tab's terminal, borders, badge, drop zone, and the
    /// click watch that focuses it.
    @ViewBuilder
    private func pane(_ id: UUID, showsHeader: Bool) -> some View {
        if let tab = sessions.tabs.first(where: { $0.id == id }) {
            let isFocused = id == focusedPaneID
            let isIncluded = !workspace.excludedFromBroadcast.contains(id)
            VStack(spacing: 0) {
                if showsHeader {
                    PaneHeader(tab: tab,
                               subtitle: PaneLabel.subtitle(tab, vault: vault),
                               status: workspace.status(of: id),
                               isFocused: isFocused,
                               isBroadcasting: workspace.isBroadcasting,
                               isIncludedInBroadcast: isIncluded,
                               toggleBroadcast: { actions.toggleBroadcast() },
                               changeTheme: { actions.changeTheme(id) },
                               enterFocusMode: { actions.enterFocusMode(id) },
                               close: { actions.close(id) })
                        .onDrag { beginPaneDrag(id) }
                        .contextMenu {
                            PaneContextMenu(paneID: id, isIncludedInBroadcast: isIncluded, actions: actions)
                        }
                }
                TerminalTabView(tab: tab, sessions: sessions, store: store, vault: vault,
                                terminalSettings: terminalSettings,
                                closeTab: { closePane(id) },
                                sidePanel: sidePanel?.tabID == id ? sidePanel?.kind : nil,
                                closeSidePanel: closeSidePanel,
                                editHost: editHost.map { edit in { edit(tab) } },
                                editSnippet: editSnippet)
                    .overlay(alignment: .topTrailing) {
                        if workspace.isBroadcasting, !isIncluded {
                            NotBroadcastingBadge()
                                .padding(8)
                        }
                    }
            }
            .overlay {
                PaneBorder(style: borderStyle(for: id, isFocused: isFocused, isIncluded: isIncluded))
            }
            .background {
                MouseDownWatch { actions.focus(id) }
            }
            .terminalDropZone(acceptsNewTerminals: workspace.paneIDs.count < Self.maximumPanes,
                              isMovingPane: draggingPaneID != nil,
                              isDragSource: draggingPaneID == id,
                              onDropTab: { tabID, edge in dropTab(tabID, beside: id, at: edge) },
                              onDropHost: { hostID, edge in dropHost(hostID, beside: id, at: edge) },
                              onDropPane: { paneID, edge in movePane(paneID, beside: id, at: edge) })
        } else {
            // The tab is gone and the tree hasn't caught up yet.
            Theme.contentBackground
        }
    }

    private func borderStyle(for id: UUID, isFocused: Bool, isIncluded: Bool) -> PaneBorder.Style {
        if workspace.isBroadcasting {
            if isFocused { return .solid }
            return isIncluded ? .dashed : .none
        }
        // Focus mode shows one terminal: no border needed to tell which.
        return isFocused && workspace.viewMode == .split ? .solid : .none
    }

    // MARK: Focus

    /// The workspace's focused pane, or its first one if that is gone.
    private var focusedPaneID: UUID? {
        let ids = workspace.paneIDs
        return ids.contains(workspace.focusedPaneID) ? workspace.focusedPaneID : ids.first
    }

    private struct FocusKey: Hashable {
        let pane: UUID?
        let mode: Workspace.ViewMode
        let panes: [UUID]
    }

    // MARK: Actions

    private var actions: PaneActions {
        let sessions = sessions
        let workspace = workspace
        let store = store
        let closePane = closePane
        let changeTheme = changeTheme
        let showSnippets = showSnippets
        let showHistory = showHistory
        let rename = $renamingPaneID
        let renameText = $renameText
        return PaneActions(
            focus: { id in
                if workspace.focusedPaneID != id { sessions.focusPane(id) }
            },
            close: { id in closePane(id) },
            popOut: { id in sessions.popOutPane(id) },
            rename: { id in
                let tab = sessions.tabs.first { $0.id == id }
                renameText.wrappedValue = tab.map { $0.customTitle ?? $0.title } ?? ""
                rename.wrappedValue = id
            },
            setIncludedInBroadcast: { id, included in sessions.setPane(id, includedInBroadcast: included) },
            changeTheme: { id in
                sessions.focusPane(id)
                changeTheme(id)
            },
            showSnippets: { id in
                sessions.focusPane(id)
                showSnippets(id)
            },
            showHistory: { id in
                sessions.focusPane(id)
                showHistory(id)
            },
            toggleBroadcast: {
                sessions.toggleBroadcast(in: workspace.id)
                store.focus(tabID: workspace.focusedPaneID)
            },
            enterFocusMode: { id in
                sessions.focusPane(id)
                sessions.setViewMode(.focus, for: workspace.id)
            },
            enterSplitView: {
                sessions.setViewMode(.split, for: workspace.id)
            }
        )
    }

    /// The window this workspace lives in (its panes' window).
    private var windowID: UUID? {
        let ids = Set(workspace.paneIDs)
        return sessions.tabs.first { ids.contains($0.id) }?.windowID
    }

    /// A tab from the tab bar: moves into the workspace next to `target`. A tab that is already a
    /// pane here just moves; a tab of another window is refused.
    private func dropTab(_ tabID: UUID, beside target: UUID, at edge: DropEdge) {
        if workspace.paneIDs.contains(tabID) {
            movePane(tabID, beside: target, at: edge)
            return
        }
        guard workspace.paneIDs.count < Self.maximumPanes,
              let tab = sessions.tabs.first(where: { $0.id == tabID }),
              tab.windowID == windowID else { return }
        sessions.addPane(tabID: tabID, to: workspace.id, beside: target, at: edge)
        sessions.focusPane(tabID)
    }

    /// A host card: a new connection to it next to `target`.
    private func dropHost(_ hostID: UUID, beside target: UUID, at edge: DropEdge) {
        guard workspace.paneIDs.count < Self.maximumPanes else { return }
        do {
            try sessions.addPane(hostID: hostID, to: workspace.id, beside: target, at: edge)
        } catch {
            dropError = error.localizedDescription
        }
    }

    /// A pane of this workspace dropped next to another one.
    private func movePane(_ paneID: UUID, beside target: UUID, at edge: DropEdge) {
        draggingPaneID = nil
        guard paneID != target, workspace.paneIDs.contains(paneID), workspace.paneIDs.contains(target) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            sessions.movePane(paneID, beside: target, at: edge, in: workspace.id)
        }
    }

    private func beginPaneDrag(_ id: UUID) -> NSItemProvider {
        draggingPaneID = id
        dragEndWatch?.cancel()
        dragEndWatch = DragEndWatch.start { draggingPaneID = nil }
        return WorkspaceDragPayload.pane(id).itemProvider
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingPaneID != nil }, set: { if !$0 { renamingPaneID = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })
    }
}

/// The pane's outline: the focused pane (solid), another pane included in a broadcast (dashed), or
/// none. Drawn inside the pane, over the header and terminal; never takes clicks.
struct PaneBorder: View {
    enum Style { case none, solid, dashed }

    let style: Style

    var body: some View {
        switch style {
        case .none:
            EmptyView()
        case .solid:
            Rectangle()
                .strokeBorder(Theme.accent, lineWidth: 2)
                .allowsHitTesting(false)
        case .dashed:
            Rectangle()
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .allowsHitTesting(false)
        }
    }
}

/// Shown on a pane left out of the workspace's broadcast while it is on.
struct NotBroadcastingBadge: View {
    var body: some View {
        Label("not broadcasting", systemImage: "speaker.slash.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .allowsHitTesting(false)
    }
}

/// Calls `action` for every mouse-down (left, right or other button) inside its frame, without
/// taking the click: the terminal (an AppKit view that SwiftUI gestures don't see) still gets it.
/// Used to focus a pane on any click in it.
struct MouseDownWatch: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> WatchView {
        let view = WatchView()
        view.action = action
        return view
    }

    func updateNSView(_ view: WatchView, context: Context) {
        view.action = action
    }

    final class WatchView: NSView {
        var action: (@MainActor () -> Void)?
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
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          !self.isHiddenOrHasHiddenAncestor else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(point) { self.action?() }
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
