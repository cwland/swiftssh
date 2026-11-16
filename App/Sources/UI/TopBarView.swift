import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore
import SwiftSSHUI

/// The navy tab strip that replaces the window's title bar: Vaults, then one item per terminal tab or
/// workspace of this window (`SessionManager.strip(inWindow:)`; a workspace's panes are not listed on
/// their own). The traffic lights sit over its leading inset; empty parts of the bar drag the window.
/// Every tab and workspace item has the same width (`EqualWidthTabsLayout`), shrinking as more open.
/// Plain terminal tabs and workspaces can be dragged to reorder them (Vaults stays first); a plain tab
/// can also be dropped onto a terminal area to build a workspace. Both kinds of item have a right-click
/// menu (Cmd+Shift+[ and Cmd+Shift+] in the Session menu follow the bar order). A workspace item shows
/// a grid icon, its name, and a grey dot while it differs from its saved template (a click on the dot
/// saves). "+" opens a new connection; its menu also lists the saved workspaces. A terminal window's bar has no Vaults tab and no "+".
struct TopBarView: View {
    let navigation: AppNavigation
    /// nil until the vault is open.
    let sessions: SessionManager?
    /// nil until the vault is open; drives the Vaults tab's cloud icon.
    let sync: SyncCoordinator?
    /// The window this bar belongs to; nil = the main window.
    var windowID: UUID? = nil
    /// false in a terminal window ("Duplicate in New Window").
    var showsVaults = true
    let selectVaults: () -> Void
    let closeTab: (UUID) -> Void
    /// Change Theme…: opens the theme panel over the tab (after selecting it).
    var changeTheme: (UUID) -> Void = { _ in }
    /// Snippets…: opens the snippets panel over the tab (after selecting it).
    var showSnippets: (UUID) -> Void = { _ in }
    /// History…: opens the shell history panel over the tab (after selecting it).
    var showHistory: (UUID) -> Void = { _ in }
    /// Duplicate in New Window.
    var duplicateInNewWindow: (UUID) -> Void = { _ in }
    /// Saved workspaces for the "+" menu; nil hides that submenu.
    var workspaceTemplates: WorkspaceTemplateStore? = nil
    /// Shows a tab bar item (a workspace: its focused pane).
    var selectItem: (StripItem) -> Void = { _ in }
    /// Split Right / Split Down on a plain tab.
    var splitTab: (UUID, DropEdge) throws -> Void = { _, _ in }
    /// Save Workspace (⌘S, the grey dot).
    var saveWorkspace: (Workspace) throws -> Void = { _ in }
    /// Close Workspace: ends all its sessions.
    var closeWorkspace: (UUID) -> Void = { _ in }
    /// Rename Workspace: renames it and, when it has a saved copy, that copy too.
    var renameWorkspace: (Workspace, String) throws -> Void = { workspace, name in workspace.name = name }
    /// Settings → "Ask to save workspaces when closing".
    var asksToSaveWorkspaces: () -> Bool = { false }
    /// Whether saving updates an existing saved copy; a first save asks for a name.
    var hasSavedCopy: (Workspace) -> Bool = { _ in true }
    /// Whether a window token in a request (`ObjectIdentifier` of an `NSWindow`) is this window: two main
    /// windows show the same tabs, so only the window a request names takes it.
    var isThisWindow: (ObjectIdentifier) -> Bool = { _ in false }
    /// ⌘S on a never-saved workspace (from the menu): the window it names asks for the name.
    var namingRequest: WindowTargetedRequest<ObjectIdentifier>? = nil
    var clearNamingRequest: () -> Void = {}
    /// Opens a saved workspace (each pane connects).
    var openTemplate: (WorkspaceTemplate) throws -> Void = { _ in }
    /// A pane whose closing would turn its unsaved workspace into a plain tab: the window showing it
    /// asks Save / Don't Save / Cancel (`AppEnvironment.closeTab`); only the window the request names.
    var closingPaneRequest: WindowTargetedRequest<ObjectIdentifier>? = nil
    var clearClosingPaneRequest: () -> Void = {}
    /// Closes a pane without asking again (after Save or Don't Save).
    var closePaneNow: (UUID) -> Void = { _ in }

    /// The tab bar item (a plain tab's or a workspace's id) being dragged, for the drop indicator; the
    /// drop itself trusts only the dragged payload.
    @State private var draggingTabID: UUID?
    @State private var dropTargetID: UUID?
    /// Clears `draggingTabID` once the mouse is up: a drag that is cancelled or ends outside the bar
    /// gets no callback.
    @State private var dragEndWatch: Task<Void, Never>?
    @State private var renamingTabID: UUID?
    @State private var renameText = ""
    @State private var renamingWorkspaceID: UUID?
    /// A workspace with unsaved changes waiting for Save / Don't Save / Cancel before it closes.
    @State private var closingWorkspaceID: UUID?
    /// A workspace's first save: its name is asked for (prefilled) before it is saved.
    @State private var namingWorkspaceID: UUID?
    @State private var nameText = ""
    /// What happens once a first save (from a close prompt) is done.
    @State private var afterNaming: AfterNaming = .nothing
    /// A pane waiting for Save / Don't Save / Cancel: closing it would leave one pane.
    @State private var closingPaneID: UUID?
    @State private var templateToRename: WorkspaceTemplate?
    @State private var templateToDelete: WorkspaceTemplate?
    @State private var errorTitle = ""
    @State private var errorMessage = ""
    @State private var showsError = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(showsVaults ? navigation.tabs : [], id: \.self) { tab in
                TopTabPill(tab: tab, isSelected: sessions?.selectedTabID(inWindow: windowID) == nil, sync: sync) {
                    selectVaults()
                }
                .layoutPriority(1)
            }

            if let sessions, !sessions.strip(inWindow: windowID).isEmpty {
                let strip = sessions.strip(inWindow: windowID)
                EqualWidthTabsLayout(spacing: 8) {
                    ForEach(Array(strip.enumerated()), id: \.element.id) { index, item in
                        stripItem(item, index: index, strip: strip, sessions: sessions)
                    }
                }
                // Before the spacer, so the tabs get all the room they want (up to their maximum).
                .layoutPriority(0.5)
                // With very many tabs the last ones are cut off here, never drawn under "+" and the bell.
                .clipped()
            }

            if showsVaults {
                plusButton
            }

            Spacer(minLength: 0)

            Image(systemName: "bell")
                .font(.system(size: 15))
                .foregroundStyle(Theme.topBarForeground)
                .frame(width: 32, height: 32)
                .help("Notifications")
                .layoutPriority(1)
        }
        .padding(.leading, Theme.trafficLightInset)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.topBarHeight)
        .background {
            ZStack {
                Theme.topBarBackground
                WindowDragArea()
            }
        }
        // Shared, so the terminal area of the dragged tab itself refuses the drop (RootView).
        .onChange(of: draggingTabID) { sessions?.draggedTabID = draggingTabID }
        .alert("Rename Tab", isPresented: renameBinding) {
            TextField("Tab name", text: $renameText)
            Button("Rename") {
                if let id = renamingTabID { sessions?.rename(tabID: id, to: renameText) }
                renamingTabID = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                renamingTabID = nil
            }
        } message: {
            Text("Only this tab is renamed; the host keeps its name. Leave empty to use the host\u{2019}s name.")
        }
        .alert("Rename Workspace", isPresented: workspaceRenameBinding) {
            TextField("Workspace name", text: $renameText)
            Button("Rename") {
                if let id = renamingWorkspaceID, let workspace = sessions?.workspace(id) {
                    do {
                        try renameWorkspace(workspace, renameText)
                    } catch {
                        present(error, title: "The saved workspace couldn\u{2019}t be renamed")
                    }
                }
                renamingWorkspaceID = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                renamingWorkspaceID = nil
            }
        } message: {
            Text("A saved workspace is renamed in Saved Workspaces too.")
        }
        .alert(closingWorkspaceTitle, isPresented: closeWorkspaceBinding) {
            Button("Save") {
                if let workspace = closingWorkspace {
                    closingWorkspaceID = nil
                    if !hasSavedCopy(workspace) {
                        // After this alert has gone, so the name alert can show.
                        DispatchQueue.main.async { beginNaming(workspace, then: .closeWorkspace) }
                        return
                    }
                    do {
                        try saveWorkspace(workspace)
                        closeWorkspace(workspace.id)
                    } catch {
                        present(error, title: "The workspace couldn\u{2019}t be saved")
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Don\u{2019}t Save", role: .destructive) {
                if let id = closingWorkspaceID { closeWorkspace(id) }
                closingWorkspaceID = nil
            }
            Button("Cancel", role: .cancel) {
                closingWorkspaceID = nil
            }
        } message: {
            Text("Its layout, sizes and tab names can be reopened from Saved Workspaces. Closing ends all its sessions.")
        }
        .alert(closingPaneTitle, isPresented: closePaneBinding) {
            Button("Save") {
                guard let paneID = closingPaneID else { return }
                closingPaneID = nil
                guard let workspace = sessions?.workspace(containing: paneID) else {
                    closePaneNow(paneID)
                    return
                }
                if !hasSavedCopy(workspace) {
                    // After this alert has gone, so the name alert can show.
                    DispatchQueue.main.async { beginNaming(workspace, then: .closePane(paneID)) }
                    return
                }
                do {
                    try saveWorkspace(workspace)
                    closePaneNow(paneID)
                } catch {
                    present(error, title: "The workspace couldn\u{2019}t be saved")
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Don\u{2019}t Save", role: .destructive) {
                if let id = closingPaneID { closePaneNow(id) }
                closingPaneID = nil
            }
            Button("Cancel", role: .cancel) {
                closingPaneID = nil
            }
        } message: {
            Text("Closing this terminal leaves one, so the workspace becomes a plain tab. Save keeps its layout in Saved Workspaces.")
        }
        .alert("Save Workspace", isPresented: namingBinding) {
            TextField("Workspace name", text: $nameText)
            Button("Save") { finishNaming() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                namingWorkspaceID = nil
                afterNaming = .nothing
            }
        } message: {
            Text("Saved workspaces open again from \u{201C}+\u{201D} \u{2192} Saved Workspaces.")
        }
        .onChange(of: namingRequest) { takeNamingRequest() }
        .onAppear {
            takeNamingRequest()
            takeClosingPaneRequest()
        }
        .onChange(of: closingPaneRequest) { takeClosingPaneRequest() }
        .savedWorkspaceDialogs(store: workspaceTemplates, renaming: $templateToRename,
                               deleting: $templateToDelete) { error, title in
            present(error, title: title)
        }
        .alert(errorTitle, isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: Strip items

    @ViewBuilder
    private func stripItem(_ item: StripItem, index: Int, strip: [StripItem], sessions: SessionManager) -> some View {
        let selectedTabID = sessions.selectedTabID(inWindow: windowID)
        switch item {
        case .tab(let id):
            if let tab = sessions.tabs.first(where: { $0.id == id }) {
                SessionTabPill(
                    tab: tab,
                    isSelected: selectedTabID == tab.id,
                    select: { sessions.select(tabID: tab.id, inWindow: windowID) },
                    close: { closeTab(tab.id) }
                )
                .overlay(alignment: dropIndicatorEdge(for: index, in: strip)) {
                    if dropTargetID == tab.id, draggingTabID != tab.id {
                        DropIndicator()
                    }
                }
                .onDrag {
                    draggingTabID = tab.id
                    watchForDragEnd()
                    return NSItemProvider(object: TabDragPayload.string(for: tab.id) as NSString)
                }
                .onDrop(of: [.text], delegate: dropDelegate(targetID: tab.id, index: index, sessions: sessions))
                .contextMenu {
                    tabMenu(for: tab, sessions: sessions)
                }
            }
        case .workspace(let id):
            if let workspace = sessions.workspace(id) {
                WorkspaceTabPill(
                    workspace: workspace,
                    isSelected: selectedTabID.map { workspace.paneIDs.contains($0) } ?? false,
                    select: { selectItem(item) },
                    close: { requestClose(workspace) },
                    save: { save(workspace) }
                )
                .overlay(alignment: dropIndicatorEdge(for: index, in: strip)) {
                    if dropTargetID == workspace.id, draggingTabID != workspace.id {
                        DropIndicator()
                    }
                }
                // Dragged like a tab, but only to reorder: terminal areas take no workspace drop.
                .onDrag {
                    draggingTabID = workspace.id
                    watchForDragEnd()
                    return NSItemProvider(object: TabDragPayload.string(forWorkspace: workspace.id) as NSString)
                }
                .onDrop(of: [.text], delegate: dropDelegate(targetID: workspace.id, index: index, sessions: sessions))
                .contextMenu {
                    workspaceMenu(for: workspace)
                }
            }
        }
    }

    /// Reordering by strip position: the dragged tab or workspace takes the target item's place in the
    /// tab bar.
    private func dropDelegate(targetID: UUID, index: Int, sessions: SessionManager) -> TabDropDelegate {
        TabDropDelegate(
            targetID: targetID,
            targetIndex: index,
            dropTargetID: $dropTargetID,
            draggingTabID: $draggingTabID,
            move: { id, stripIndex in
                // Only items of this window's bar reorder here. `moveTab` counts tab-bar items, so
                // the target's strip position is the index (a workspace is one item).
                let strip = sessions.strip(inWindow: windowID)
                guard strip.contains(where: { $0.id == id }), strip.indices.contains(stripIndex) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    sessions.moveTab(id: id, toIndex: stripIndex)
                }
            }
        )
    }

    // MARK: "+"

    /// Click: a new connection (Vaults → Hosts). Its menu also holds the saved workspaces.
    private var plusButton: some View {
        Menu {
            Button("New Connection") { newConnection() }
            if let workspaceTemplates {
                Divider()
                Menu("Saved Workspaces") {
                    SavedWorkspacesMenuItems(store: workspaceTemplates,
                                             open: { open($0) },
                                             rename: { templateToRename = $0 },
                                             delete: { templateToDelete = $0 })
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.topBarForeground)
        } primaryAction: {
            newConnection()
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .tint(Theme.topBarForeground)
        .fixedSize()
        .frame(height: 32)
        .layoutPriority(1)
        .help("New connection: pick a host or type user@host. Hold for saved workspaces.")
    }

    private func newConnection() {
        selectVaults()
        navigation.sidebar = .hosts
    }

    // MARK: Actions

    private func open(_ template: WorkspaceTemplate) {
        do {
            try openTemplate(template)
        } catch {
            present(error, title: "The workspace couldn\u{2019}t be opened")
        }
    }

    /// Closes the workspace, first asking Save / Don't Save / Cancel when it has unsaved changes and
    /// the setting is on.
    private func requestClose(_ workspace: Workspace) {
        if asksToSaveWorkspaces() && workspace.hasUnsavedChanges {
            closingWorkspaceID = workspace.id
        } else {
            closeWorkspace(workspace.id)
        }
    }

    private var closingWorkspace: Workspace? {
        closingWorkspaceID.flatMap { sessions?.workspace($0) }
    }

    private var closingWorkspaceTitle: String {
        "Save \u{201C}\(closingWorkspace?.name ?? "Workspace")\u{201D} before closing?"
    }

    private var closeWorkspaceBinding: Binding<Bool> {
        Binding(get: { closingWorkspaceID != nil }, set: { if !$0 { closingWorkspaceID = nil } })
    }

    /// What follows a first save started from a close prompt.
    private enum AfterNaming: Equatable {
        case nothing
        /// Save before closing the whole workspace.
        case closeWorkspace
        /// Save before closing this pane (the workspace becomes a plain tab).
        case closePane(UUID)
    }

    /// Opens the name prompt for a workspace's first save.
    private func beginNaming(_ workspace: Workspace, then next: AfterNaming) {
        nameText = workspace.name
        afterNaming = next
        namingWorkspaceID = workspace.id
    }

    /// Saves under the typed name (blank keeps "Workspace"), then closes the workspace or the pane when
    /// a close prompt asked.
    private func finishNaming() {
        guard let id = namingWorkspaceID, let workspace = sessions?.workspace(id) else {
            namingWorkspaceID = nil
            return
        }
        let next = afterNaming
        namingWorkspaceID = nil
        afterNaming = .nothing
        do {
            try renameWorkspace(workspace, nameText)
            try saveWorkspace(workspace)
            switch next {
            case .nothing: break
            case .closeWorkspace: closeWorkspace(workspace.id)
            case .closePane(let paneID): closePaneNow(paneID)
            }
        } catch {
            present(error, title: "The workspace couldn\u{2019}t be saved")
        }
    }

    /// ⌘S from the menu on a never-saved workspace of this window (the one the request names).
    private func takeNamingRequest() {
        guard let request = namingRequest, isTarget(request),
              let workspace = sessions?.workspace(request.subjectID),
              workspace.windowID == windowID else { return }
        clearNamingRequest()
        beginNaming(workspace, then: .nothing)
    }

    /// A pane close (Cmd+W, its ×, its menu) waiting for Save / Don't Save / Cancel, in this window (the
    /// one the request names).
    private func takeClosingPaneRequest() {
        guard let request = closingPaneRequest, isTarget(request) else { return }
        let id = request.subjectID
        guard let workspace = sessions?.workspace(containing: id), workspace.windowID == windowID else { return }
        clearClosingPaneRequest()
        closingPaneID = id
    }

    private func isTarget(_ request: WindowTargetedRequest<ObjectIdentifier>) -> Bool {
        guard let window = request.window else { return false }
        return isThisWindow(window)
    }

    private var closingPaneTitle: String {
        let name = closingPaneID.flatMap { sessions?.workspace(containing: $0)?.name } ?? "Workspace"
        return "Save \u{201C}\(name)\u{201D} before closing this terminal?"
    }

    private var closePaneBinding: Binding<Bool> {
        Binding(get: { closingPaneID != nil }, set: { if !$0 { closingPaneID = nil } })
    }

    private var namingBinding: Binding<Bool> {
        Binding(get: { namingWorkspaceID != nil }, set: { if !$0 { namingWorkspaceID = nil } })
    }

    private func save(_ workspace: Workspace) {
        guard hasSavedCopy(workspace) else {
            beginNaming(workspace, then: .nothing)
            return
        }
        do {
            try saveWorkspace(workspace)
        } catch {
            present(error, title: "The workspace couldn\u{2019}t be saved")
        }
    }

    private func split(_ tabID: UUID, at edge: DropEdge) {
        do {
            try splitTab(tabID, edge)
        } catch {
            present(error, title: "The tab couldn\u{2019}t be split")
        }
    }

    private func present(_ error: any Error, title: String) {
        errorTitle = (error as? ConnectionPlanError)?.alertTitle ?? title
        errorMessage = error.localizedDescription
        showsError = true
    }

    // MARK: Tab menu

    @ViewBuilder
    private func tabMenu(for tab: TerminalTab, sessions: SessionManager) -> some View {
        Button("Change Theme\u{2026}") {
            changeTheme(tab.id)
        }
        Button("Snippets\u{2026}") {
            showSnippets(tab.id)
        }
        Button("History\u{2026}") {
            showHistory(tab.id)
        }
        Button("Rename\u{2026}") {
            renameText = tab.customTitle ?? tab.title
            renamingTabID = tab.id
        }
        Divider()
        Button("Split Right") {
            split(tab.id, at: .right)
        }
        Button("Split Down") {
            split(tab.id, at: .bottom)
        }
        Divider()
        Button("Duplicate") {
            sessions.duplicate(tabID: tab.id)
        }
        Button("Duplicate in New Window") {
            duplicateInNewWindow(tab.id)
        }
        Divider()
        Button("Close") {
            closeTab(tab.id)
        }
    }

    /// A workspace tab's menu. No "Duplicate in New Window" for workspaces (this round).
    @ViewBuilder
    private func workspaceMenu(for workspace: Workspace) -> some View {
        Button("Rename\u{2026}") {
            renameText = workspace.name
            renamingWorkspaceID = workspace.id
        }
        Button("Save Workspace") {
            save(workspace)
        }
        Divider()
        Button("Close Workspace") {
            requestClose(workspace)
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingTabID != nil }, set: { if !$0 { renamingTabID = nil } })
    }

    private var workspaceRenameBinding: Binding<Bool> {
        Binding(get: { renamingWorkspaceID != nil }, set: { if !$0 { renamingWorkspaceID = nil } })
    }

    // MARK: Reordering

    /// The indicator sits where the dragged tab or workspace will land: after the target when it comes
    /// from the left, before it otherwise (dropping on an item takes its place).
    private func dropIndicatorEdge(for index: Int, in strip: [StripItem]) -> Alignment {
        guard let draggingTabID, let from = strip.firstIndex(where: { $0.id == draggingTabID }) else {
            return .leading
        }
        return from < index ? .trailing : .leading
    }

    private func watchForDragEnd() {
        dragEndWatch?.cancel()
        dragEndWatch = Task { @MainActor in
            var upTicks = 0
            // Two readings with the button up, so a drop being performed on mouse-up finishes first.
            while upTicks < 2 {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
                upTicks = NSEvent.pressedMouseButtons == 0 ? upTicks + 1 : 0
            }
            draggingTabID = nil
            dropTargetID = nil
        }
    }
}

/// What a dragged tab bar item carries: its id, prefixed so text dragged from elsewhere is not taken
/// for one. A tab's text is the same as `WorkspaceDragPayload.tab`, so a tab dragged off the bar drops
/// into a terminal area; a workspace's prefix is one `WorkspaceDragPayload` doesn't read, so it only
/// reorders in the bar.
private enum TabDragPayload {
    static let prefix = "swiftssh-tab:"
    static let workspacePrefix = "swiftssh-workspace:"

    static func string(for id: UUID) -> String { prefix + id.uuidString }

    static func string(forWorkspace id: UUID) -> String { workspacePrefix + id.uuidString }

    /// The tab's or workspace's id; nil for any other text.
    static func itemID(from string: String) -> UUID? {
        for known in [prefix, workspacePrefix] where string.hasPrefix(known) {
            return UUID(uuidString: String(string.dropFirst(known.count)))
        }
        return nil
    }
}

/// Drops on a tab bar item: the dragged tab or workspace moves to the target's index. Shows the indicator while over it.
/// Only a drag that started in this bar is accepted (text from other apps, or a tab of another window, is
/// refused); the dropped payload must still name a tab of this window.
private struct TabDropDelegate: DropDelegate {
    let targetID: UUID
    let targetIndex: Int
    @Binding var dropTargetID: UUID?
    @Binding var draggingTabID: UUID?
    let move: @MainActor (UUID, Int) -> Void

    /// A tab of this bar is being dragged (read through the binding, so always current).
    private var isLocalDrag: Bool { draggingTabID != nil }

    func validateDrop(info: DropInfo) -> Bool {
        isLocalDrag && info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        guard isLocalDrag else { return }
        dropTargetID = targetID
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isLocalDrag ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        let local = isLocalDrag
        dropTargetID = nil
        draggingTabID = nil
        guard local, let provider = info.itemProviders(for: [.text]).first else { return false }
        let index = targetIndex
        let move = move
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? NSString, let id = TabDragPayload.itemID(from: string as String) else { return }
            Task { @MainActor in move(id, index) }
        }
        return true
    }
}

/// The accent bar shown at the edge of the tab where a dragged tab will land.
private struct DropIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Theme.accent)
            .frame(width: 3, height: 26)
            .allowsHitTesting(false)
    }
}

/// The tab bar items side by side, every one the same width: the room there is, shared equally, at most
/// `maximumWidth` each. They shrink together as more open; below `compactWidth` a pill shows only its
/// title (no badge, close button or marks), and they keep shrinking down to `minimumWidth`. The strip
/// never asks for more width than it is offered: past `minimumWidth` each, the last items are cut off
/// at the strip's end (the bar clips it) rather than running under "+" and the bell.
struct EqualWidthTabsLayout: Layout {
    static let maximumWidth: CGFloat = 220
    static let compactWidth: CGFloat = 60
    static let minimumWidth: CGFloat = 24

    var spacing: CGFloat

    /// Each item's width for `available` points (nil: as wide as they like).
    static func itemWidth(available: CGFloat?, count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        guard let available, available.isFinite else { return maximumWidth }
        let share = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        return min(max(share, minimumWidth), maximumWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = Self.itemWidth(available: proposal.width, count: subviews.count, spacing: spacing)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height }
            .max() ?? 0
        let total = width * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1)
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? total
        return CGSize(width: min(total, offered), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = Self.itemWidth(available: bounds.width, count: subviews.count, spacing: spacing)
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// A tab bar item's box: lighter when selected; an unselected one has a faint outline, so where one
/// tab ends and the next begins is clear even between two unselected tabs.
private struct TabPillBackground: View {
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous)
        shape
            .fill(isSelected ? Theme.tabBackground : Theme.tabInactiveBackground)
            .overlay {
                shape.strokeBorder(Color.white.opacity(isSelected ? 0 : 0.10), lineWidth: 1)
            }
    }
}

/// A top tab (Vaults). The Vaults tab also holds the sync cloud icon, a button of its own beside
/// the tab's button (so a click on the icon opens the sync popover rather than selecting the tab).
private struct TopTabPill: View {
    let tab: TopTab
    let isSelected: Bool
    let sync: SyncCoordinator?
    let action: () -> Void

    private var showsSyncIcon: Bool {
        guard tab == .vaults, let sync else { return false }
        return sync.phase.cloudSymbol != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: tab.systemImage)
                    Text(tab.title)
                        .font(.system(size: Theme.tabFontSize))
                }
                .padding(.leading, 12)
                .padding(.trailing, showsSyncIcon ? 6 : 12)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Vaults (\u{2318}1)")

            if showsSyncIcon, let sync {
                SyncCloudButton(sync: sync)
                    .padding(.trailing, 8)
            }
        }
        .foregroundStyle(Theme.topBarForeground)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous)
                .fill(isSelected ? Theme.tabBackground : Theme.tabInactiveBackground)
        )
    }
}

/// A terminal session tab, Termius layout: a leading slot, then the host label. The slot shows the
/// OS badge; on the selected tab and while the pointer is over the tab it shows the close button
/// instead (closing never asks). Titles shrink (truncating) when many tabs are open.
private struct SessionTabPill: View {
    let tab: TerminalTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false
    /// Narrower than `EqualWidthTabsLayout.compactWidth`: title only (close with ⌘W or the tab's menu).
    @State private var isCompact = false

    private static let slotSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            if !isCompact {
                leadingSlot
                    .frame(width: Self.slotSize, height: Self.slotSize)
            }

            Text(tab.displayTitle.isEmpty ? "Untitled host" : tab.displayTitle)
                .font(.system(size: Theme.tabFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, select)
        }
        .foregroundStyle(Theme.topBarForeground)
        .padding(.leading, isCompact ? 6 : 7)
        .padding(.trailing, isCompact ? 6 : 12)
        // Fills the width the bar gives every item (`EqualWidthTabsLayout`); the title truncates.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 34)
        .onGeometryChange(for: Bool.self) { $0.size.width < EqualWidthTabsLayout.compactWidth } action: {
            isCompact = $0
        }
        .background(TabPillBackground(isSelected: isSelected))
        // Nothing draws past the pill's edge, however narrow it gets.
        .clipShape(RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous))
        // Dragging the pill moves the tab, never the window.
        .background(WindowDragBlocker())
        // A click anywhere on the pill selects the tab; the close button in the leading slot
        // handles its own clicks first.
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Close tab", close)
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if isSelected || isHovering {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: Self.slotSize, height: Self.slotSize)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (\u{2318}W)")
            .accessibilityLabel("Close tab")
        } else {
            BadgeView(badge: tab.badge, size: Self.slotSize)
                .opacity(isLive ? 1 : 0.5)
        }
    }

    /// Dims the badge while the tab has no live session.
    private var isLive: Bool {
        switch tab.state {
        case .connected: true
        case .connecting, .awaitingHostKey, .awaitingPassword, .disconnected: false
        }
    }
}

/// A workspace tab: grid icon (the close button on the selected tab and while hovered, closing every
/// session of the workspace), its name, a broadcast mark while broadcasting, and a grey dot while it
/// differs from its saved template or was never saved; clicking the dot saves it (⌘S).
private struct WorkspaceTabPill: View {
    let workspace: Workspace
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let save: () -> Void

    @State private var isHovering = false
    /// Narrower than `EqualWidthTabsLayout.compactWidth`: name only (no close button, marks or dot).
    @State private var isCompact = false

    private static let slotSize: CGFloat = 20

    private var isUnsaved: Bool { workspace.hasUnsavedChanges || workspace.templateID == nil }

    var body: some View {
        HStack(spacing: 8) {
            if !isCompact {
                leadingSlot
                    .frame(width: Self.slotSize, height: Self.slotSize)
            }

            Text(workspace.name.isEmpty ? "Workspace" : workspace.name)
                .font(.system(size: Theme.tabFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, select)

            if !isCompact {
                marks
            }
        }
        .foregroundStyle(Theme.topBarForeground)
        .padding(.leading, isCompact ? 6 : 7)
        .padding(.trailing, isCompact ? 6 : 12)
        // Fills the width the bar gives every item (`EqualWidthTabsLayout`); the name truncates.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 34)
        .onGeometryChange(for: Bool.self) { $0.size.width < EqualWidthTabsLayout.compactWidth } action: {
            isCompact = $0
        }
        .background(TabPillBackground(isSelected: isSelected))
        // Nothing draws past the pill's edge, however narrow it gets.
        .clipShape(RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous))
        // Dragging the pill moves the tab, never the window.
        .background(WindowDragBlocker())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(workspace.name)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Close workspace", close)
    }

    /// The broadcast mark and the unsaved dot (hidden while compact).
    @ViewBuilder
    private var marks: some View {
        if workspace.isBroadcasting {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .help("Broadcasting input (\u{2318}B)")
                .accessibilityLabel("Broadcasting input")
        }

        if isUnsaved {
            Button(action: save) {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 7, height: 7)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(workspace.templateID == nil ? "Not saved: click to save this workspace (\u{2318}S)"
                                              : "Unsaved changes: click to save (\u{2318}S)")
            .accessibilityLabel("Save workspace")
        }
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if isSelected || isHovering {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: Self.slotSize, height: Self.slotSize)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Workspace (all its sessions)")
            .accessibilityLabel("Close workspace")
        } else {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13, weight: .semibold))
        }
    }
}

/// The saved workspaces as menu items: one submenu per template with Open, Rename… and Delete…
/// ("+" menu → Saved Workspaces, the Hosts toolbar's Workspaces menu). Rename and Delete only report the
/// template; the owner presents the dialogs (`savedWorkspaceDialogs`), since a menu can't.
struct SavedWorkspacesMenuItems: View {
    let store: WorkspaceTemplateStore
    let open: (WorkspaceTemplate) -> Void
    let rename: (WorkspaceTemplate) -> Void
    let delete: (WorkspaceTemplate) -> Void

    var body: some View {
        if store.templates.isEmpty {
            Button("No Saved Workspaces") {}
                .disabled(true)
        } else {
            ForEach(store.templates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { template in
                Menu(template.name.isEmpty ? "Workspace" : template.name) {
                    Button("Open") { open(template) }
                    Divider()
                    Button("Rename\u{2026}") { rename(template) }
                    Button("Delete\u{2026}") { delete(template) }
                }
            }
        }
    }
}

extension View {
    /// The Rename and Delete dialogs for `SavedWorkspacesMenuItems`. Deleting a template leaves open
    /// workspaces running (they just become unsaved).
    func savedWorkspaceDialogs(store: WorkspaceTemplateStore?, renaming: Binding<WorkspaceTemplate?>,
                               deleting: Binding<WorkspaceTemplate?>,
                               onError: @escaping (any Error, String) -> Void) -> some View {
        modifier(SavedWorkspaceDialogs(store: store, renaming: renaming, deleting: deleting, onError: onError))
    }
}

private struct SavedWorkspaceDialogs: ViewModifier {
    let store: WorkspaceTemplateStore?
    @Binding var renaming: WorkspaceTemplate?
    @Binding var deleting: WorkspaceTemplate?
    let onError: (any Error, String) -> Void

    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Saved Workspace", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Workspace name", text: $name)
                Button("Rename") {
                    if let template = renaming, let store {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            try store.rename(template.id, to: trimmed.isEmpty ? "Workspace" : trimmed)
                        } catch {
                            onError(error, "The workspace couldn\u{2019}t be renamed")
                        }
                    }
                    renaming = nil
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .onChange(of: renaming?.id) { _, _ in
                name = renaming?.name ?? ""
            }
            .confirmationDialog(
                "Delete \u{201C}\(deleting?.name ?? "")\u{201D}?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let template = deleting, let store {
                        do {
                            try store.delete(template.id)
                        } catch {
                            onError(error, "The workspace couldn\u{2019}t be deleted")
                        }
                    }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Only the saved layout is deleted. Open workspaces and their sessions stay.")
            }
    }
}

extension TopTab {
    var title: String {
        switch self {
        case .vaults: "Vaults"
        }
    }

    var systemImage: String {
        switch self {
        case .vaults: "square.stack.3d.up.fill"
        }
    }
}

/// The empty parts of the top bar act as the title bar: drag to move the window, double-click to zoom.
///
/// macOS's own title-bar dragging is turned off for the window (`isMovable = false`): the system title
/// bar sits above the app's views, so it would move the window from the top part of a tab. This view
/// turns moving on just for a drag that starts on it, and hands that drag to macOS (`performDrag`, so
/// edge snapping and tiling still work); the window is unmovable again once the button is released.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        private var isDragging = false

        override var mouseDownCanMoveWindow: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if !isDragging { window?.isMovable = false }
        }

        /// Over a tab, the tab gets the click (and its drag), not this view.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            let windowPoint = superview?.convert(point, to: nil) ?? point
            return WindowDragBlocker.covers(windowPoint, in: window) ? nil : hit
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return super.mouseDown(with: event) }
            if event.clickCount == 2 {
                window.performZoom(nil)
                return
            }
            isDragging = true
            window.isMovable = true
            window.performDrag(with: event)
            Task { @MainActor [weak self, weak window] in
                while NSEvent.pressedMouseButtons != 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self?.isDragging = false
                window?.isMovable = false
            }
        }
    }
}
