import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore

/// The navy tab strip that replaces the window's title bar: Vaults, then one item per terminal tab or
/// workspace of this window (`SessionManager.strip(inWindow:)`; a workspace's panes are not listed on
/// their own). The traffic lights sit over its leading inset; empty parts of the bar drag the window.
/// Plain terminal tabs can be dragged to reorder them (Vaults stays first) or onto a terminal area to
/// build a workspace; both kinds of item have a right-click menu (Cmd+Shift+[ and Cmd+Shift+] in the
/// Session menu follow the bar order). A workspace item shows a grid icon, its name, and a grey dot
/// while it differs from its saved template (a click on the dot saves). "+" opens a new connection; its
/// menu also lists the saved workspaces. A terminal window's bar has no Vaults tab and no "+".
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
    /// Opens a saved workspace (each pane connects).
    var openTemplate: (WorkspaceTemplate) throws -> Void = { _ in }

    /// The tab being dragged, for the drop indicator; the drop itself trusts only the dragged payload.
    @State private var draggingTabID: UUID?
    @State private var dropTargetID: UUID?
    /// Clears `draggingTabID` once the mouse is up: a drag that is cancelled or ends outside the bar
    /// gets no callback.
    @State private var dragEndWatch: Task<Void, Never>?
    @State private var renamingTabID: UUID?
    @State private var renameText = ""
    @State private var renamingWorkspaceID: UUID?
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

            if let sessions {
                let strip = sessions.strip(inWindow: windowID)
                ForEach(Array(strip.enumerated()), id: \.element.id) { index, item in
                    stripItem(item, index: index, strip: strip, sessions: sessions)
                }
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
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    workspace.name = trimmed.isEmpty ? "Workspace" : trimmed
                }
                renamingWorkspaceID = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                renamingWorkspaceID = nil
            }
        } message: {
            Text("Save the workspace (\u{2318}S) to keep the new name in its template.")
        }
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
                    close: { closeWorkspace(workspace.id) },
                    save: { save(workspace) }
                )
                .overlay(alignment: dropIndicatorEdge(for: index, in: strip)) {
                    if dropTargetID == workspace.id {
                        DropIndicator()
                    }
                }
                // Plain tabs can be dropped before or after a workspace; a workspace itself isn't dragged.
                .onDrop(of: [.text], delegate: dropDelegate(targetID: workspace.id, index: index, sessions: sessions))
                .contextMenu {
                    workspaceMenu(for: workspace)
                }
            }
        }
    }

    /// Reordering by strip position: the dragged tab takes the target item's place in the tab bar.
    private func dropDelegate(targetID: UUID, index: Int, sessions: SessionManager) -> TabDropDelegate {
        TabDropDelegate(
            targetID: targetID,
            targetIndex: index,
            dropTargetID: $dropTargetID,
            draggingTabID: $draggingTabID,
            move: { id, stripIndex in
                // Only plain tabs of this window reorder here. `moveTab` counts tab-bar items, so
                // the target's strip position is the index (a workspace is one item).
                let strip = sessions.strip(inWindow: windowID)
                guard strip.contains(.tab(id)), strip.indices.contains(stripIndex) else { return }
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

    private func save(_ workspace: Workspace) {
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
            closeWorkspace(workspace.id)
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingTabID != nil }, set: { if !$0 { renamingTabID = nil } })
    }

    private var workspaceRenameBinding: Binding<Bool> {
        Binding(get: { renamingWorkspaceID != nil }, set: { if !$0 { renamingWorkspaceID = nil } })
    }

    // MARK: Reordering

    /// The indicator sits where the dragged tab will land: after the target when it comes from the
    /// left, before it otherwise (dropping on an item takes its place).
    private func dropIndicatorEdge(for index: Int, in strip: [StripItem]) -> Alignment {
        guard let draggingTabID, let from = strip.firstIndex(of: .tab(draggingTabID)) else {
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

/// What a dragged tab carries: its id, prefixed so text dragged from elsewhere is not taken for a tab.
/// The same text as `WorkspaceDragPayload.tab`, so a tab dragged off the bar drops into a terminal area.
private enum TabDragPayload {
    static let prefix = "termius-reimagined-tab:"

    static func string(for id: UUID) -> String { prefix + id.uuidString }

    static func tabID(from string: String) -> UUID? {
        guard string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }
}

/// Drops on a terminal tab: the dragged tab moves to the target's index. Shows the indicator while over it.
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
            guard let string = object as? NSString, let id = TabDragPayload.tabID(from: string as String) else { return }
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
                .fill(isSelected ? Theme.tabBackground : Color.clear)
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

    private static let slotSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            leadingSlot
                .frame(width: Self.slotSize, height: Self.slotSize)

            Text(tab.displayTitle.isEmpty ? "Untitled host" : tab.displayTitle)
                .font(.system(size: Theme.tabFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, select)
        }
        .foregroundStyle(Theme.topBarForeground)
        .padding(.leading, 7)
        .padding(.trailing, 12)
        // Only a maximum: the pill hugs its content up to 220 pt (the title truncates beyond that)
        // and shrinks when the bar is crowded.
        .frame(maxWidth: 220, alignment: .leading)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous)
                .fill(isSelected ? Theme.tabBackground : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous))
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

    private static let slotSize: CGFloat = 20

    private var isUnsaved: Bool { workspace.hasUnsavedChanges || workspace.templateID == nil }

    var body: some View {
        HStack(spacing: 8) {
            leadingSlot
                .frame(width: Self.slotSize, height: Self.slotSize)

            Text(workspace.name.isEmpty ? "Workspace" : workspace.name)
                .font(.system(size: Theme.tabFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, select)

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
        .foregroundStyle(Theme.topBarForeground)
        .padding(.leading, 7)
        .padding(.trailing, 12)
        .frame(maxWidth: 240, alignment: .leading)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous)
                .fill(isSelected ? Theme.tabBackground : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.tabCornerRadius, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(workspace.name)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Close workspace", close)
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

/// An AppKit view that moves the window when dragged and zooms it on double-click, so the custom top bar behaves like a
/// title bar.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if let window {
                if event.clickCount == 2 {
                    window.performZoom(nil)
                } else {
                    window.performDrag(with: event)
                }
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}
