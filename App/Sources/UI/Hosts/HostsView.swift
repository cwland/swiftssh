import SwiftUI
import AppKit
import AppCore
import CoreModels

/// The Hosts screen: search bar, toolbar, breadcrumbs, group and host cards, and the Host Details or
/// Group panel. All behavior comes from `HostsViewModel`.
///
/// Cards: click selects (⌘-click adds or removes a host, ⇧-click selects a range), double-click
/// connects or opens the group, the pencil (or E for one selected host) edits. Right-click shows
/// the card's actions; with several hosts selected they act on all of them. Host cards can be
/// dragged onto a terminal to open the host beside it. Saved workspaces are tiles in their own
/// section (top level): click selects, double-click opens, the pencil opens the Workspace panel.
struct HostsView: View {
    @Bindable var model: HostsViewModel
    let vault: LocalVault
    let sessions: SessionManager
    /// Per-Mac terminal settings, for the inherited "Default (…)" theme labels.
    let terminalSettings: TerminalSettings
    /// Saved workspaces, shown as the Workspaces section; nil hides it.
    var workspaceTemplates: WorkspaceTemplateStore? = nil
    /// Open in Workspace: one new connection per host, as one workspace (shown).
    var openWorkspace: ([UUID]) throws -> Void = { _ in }
    /// Opens a saved workspace (each pane connects).
    var openTemplate: (WorkspaceTemplate) throws -> Void = { _ in }
    /// Opens a saved workspace in a new window.
    var openTemplateInNewWindow: (WorkspaceTemplate) -> Void = { _ in }
    /// Connect in a New Window: a new window with one tab for the host.
    var connectInNewWindow: (UUID) throws -> Void = { _ in }

    @State private var showTagFilter = false
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var groupToRename: HostGroup?
    @State private var showRenameGroup = false
    @State private var renameText = ""
    @State private var groupToDelete: HostGroup?
    @State private var showDeleteGroup = false
    /// The group whose "Theme…" gallery popover is open.
    @State private var themeGroupID: UUID?
    /// The group whose "tmux…" sheet is open.
    @State private var tmuxGroup: HostGroup?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var errorTitle = "Something went wrong"
    @State private var templateToRename: WorkspaceTemplate?
    @State private var templateToDelete: WorkspaceTemplate?
    /// The highlighted workspace tile (a click).
    @State private var selectedTemplateID: UUID?
    /// The workspace whose panel is open (its pencil or Edit). One panel at a time with hosts/groups.
    @State private var editingTemplateID: UUID?
    /// Hosts waiting for the Remove confirmation.
    @State private var hostsToRemove: [UUID] = []
    @State private var showRemoveHosts = false

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let host = model.editingHost {
                Divider()
                HostDetailsPanel(vault: vault, terminalSettings: terminalSettings, hostID: host.id, onClose: {
                    model.closeEditor()
                }, onConnect: {
                    connect(hostID: host.id)
                })
                .id(host.id)
                .transition(.move(edge: .trailing))
            } else if let template = editingTemplate, let workspaceTemplates {
                Divider()
                WorkspaceDetailsPanel(store: workspaceTemplates, vault: vault, template: template,
                                      onClose: { editingTemplateID = nil },
                                      onOpen: { open(template) },
                                      onDelete: { templateToDelete = $0 },
                                      onError: { present($0) })
                    .id(template.id)
                    .transition(.move(edge: .trailing))
            } else if let group = model.editingGroup {
                Divider()
                GroupDetailsPanel(model: model, group: group, terminalSettings: terminalSettings,
                                  onClose: { model.closeEditor() },
                                  onDelete: { deleteGroup($0) },
                                  onError: { present($0) })
                    .id(group.id)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.editingHostID)
        .animation(.easeInOut(duration: 0.2), value: model.editingGroupID)
        .animation(.easeInOut(duration: 0.2), value: editingTemplateID)
        // One panel at a time; selecting a host or group clears the workspace tile's highlight.
        .onChange(of: model.editingHostID) { if model.editingHostID != nil { editingTemplateID = nil } }
        .onChange(of: model.editingGroupID) { if model.editingGroupID != nil { editingTemplateID = nil } }
        .onChange(of: model.selectedHostIDs) { if !model.selectedHostIDs.isEmpty { selectedTemplateID = nil } }
        .onChange(of: model.selectedGroupID) { if model.selectedGroupID != nil { selectedTemplateID = nil } }
        .background(Theme.contentBackground)
        .alert("New group", isPresented: $showNewGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") { createGroup() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename group", isPresented: $showRenameGroup) {
            TextField("Name", text: $renameText)
            Button("Rename") { renameGroup() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this group?",
            isPresented: $showDeleteGroup,
            titleVisibility: .visible,
            presenting: groupToDelete
        ) { group in
            Button("Delete \u{201C}\(group.name)\u{201D}", role: .destructive) {
                deleteGroup(group)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its hosts and subgroups move up one level. No hosts are deleted.")
        }
        .alert(errorTitle, isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog(
            hostsToRemove.count == 1 ? "Remove this host?" : "Remove \(hostsToRemove.count) hosts?",
            isPresented: $showRemoveHosts,
            titleVisibility: .visible
        ) {
            Button(hostsToRemove.count == 1 ? "Remove host" : "Remove \(hostsToRemove.count) hosts",
                   role: .destructive) {
                removeHosts(hostsToRemove)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
        .sheet(item: $tmuxGroup) { group in
            GroupTmuxSheet(model: model, group: group) { tmuxGroup = nil }
        }
        .savedWorkspaceDialogs(store: workspaceTemplates, renaming: $templateToRename,
                               deleting: $templateToDelete) { error, title in
            present(error, title: title)
        }
    }

    // MARK: Layout

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchBar
            toolbar
            if !model.breadcrumbs.isEmpty {
                breadcrumbBar
            }
            if model.visibleGroups.isEmpty && model.visibleHosts.isEmpty && visibleTemplates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !visibleTemplates.isEmpty {
                            workspacesSection
                        }
                        if !model.visibleGroups.isEmpty {
                            groupsSection
                        }
                        if !model.visibleHosts.isEmpty {
                            hostsSection
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find a host or ssh user@hostname…", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.searchFieldBackground)
            }

            Button("Connect", action: quickConnect)
                .controlSize(.large)
                .disabled(!model.canConnect)
                .help("Connect to the user@host typed in the search field")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("New host") { createHost() }
                Button("New group") {
                    newGroupName = "New group"
                    showNewGroup = true
                }
            } label: {
                Label("New host", systemImage: "plus")
            } primaryAction: {
                createHost()
            }
            .fixedSize()

            if model.selectedVisibleHostIDs.count >= 2 {
                Button {
                    openInWorkspace(model.selectedVisibleHostIDs)
                } label: {
                    Label("Open \(model.selectedVisibleHostIDs.count) in Workspace", systemImage: "rectangle.split.2x2")
                }
                .fixedSize()
                .help("Open the selected hosts side by side in one workspace")
            }

            Spacer(minLength: 0)

            Button {
                showTagFilter = true
            } label: {
                Image(systemName: model.selectedTags.isEmpty ? "tag" : "tag.fill")
                    .foregroundStyle(model.selectedTags.isEmpty ? Color.primary : Theme.accent)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Filter by tag")
            .popover(isPresented: $showTagFilter, arrowEdge: .bottom) {
                TagFilterPopover(model: model)
            }

            Picker("Layout", selection: $model.layout) {
                Image(systemName: "square.grid.2x2")
                    .tag(HostsViewModel.Layout.grid)
                Image(systemName: "list.bullet")
                    .tag(HostsViewModel.Layout.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Grid or list")
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            Button("Hosts") { model.openGroup(nil) }
                .buttonStyle(.link)
            ForEach(model.breadcrumbs) { group in
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if group.id == model.effectiveGroupID {
                    Text(group.name)
                        .foregroundStyle(Color.primary)
                } else {
                    Button(group.name) { model.openGroup(group.id) }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.system(size: 14))
    }

    private var columns: [GridItem] {
        switch model.layout {
        case .grid:
            Theme.cardGridColumns
        case .list:
            [GridItem(.flexible())]
        }
    }

    /// Saved workspaces, at the top level only, matching the search text by name.
    private var visibleTemplates: [WorkspaceTemplate] {
        guard let workspaceTemplates, model.breadcrumbs.isEmpty else { return [] }
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspaceTemplates.templates }
        return workspaceTemplates.templates.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var editingTemplate: WorkspaceTemplate? {
        editingTemplateID.flatMap { id in workspaceTemplates?.templates.first { $0.id == id } }
    }

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Workspaces")
            LazyVGrid(columns: columns, spacing: Theme.cardSpacing) {
                ForEach(visibleTemplates) { template in
                    WorkspaceTileView(template: template, isSelected: selectedTemplateID == template.id,
                                      onEdit: { editTemplate(template.id) })
                        .onTapGesture(count: 2) {
                            open(template)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            selectTemplate(template.id)
                        })
                        .contextMenu {
                            Button("Open") { open(template) }
                            Button("Open in a New Window") { openTemplateInNewWindow(template) }
                            Divider()
                            Button("Edit") { editTemplate(template.id) }
                            Button("Rename\u{2026}") { templateToRename = template }
                            Button("Duplicate") { duplicateTemplate(template.id) }
                            Divider()
                            Button("Remove", role: .destructive) { templateToDelete = template }
                        }
                        .help("Double-click to open")
                }
            }
        }
    }

    /// Highlights the tile (hosts and groups are deselected).
    private func selectTemplate(_ id: UUID) {
        model.clearSelection()
        selectedTemplateID = id
    }

    /// Opens the Workspace panel (closing Host Details or the Group panel).
    private func editTemplate(_ id: UUID) {
        model.closeEditor()
        selectTemplate(id)
        editingTemplateID = id
    }

    private func duplicateTemplate(_ id: UUID) {
        do {
            let copy = try workspaceTemplates?.duplicate(id)
            selectedTemplateID = copy?.id
        } catch {
            present(error)
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Groups")
            LazyVGrid(columns: columns, spacing: Theme.cardSpacing) {
                ForEach(model.visibleGroups) { group in
                    GroupCardView(group: group, hostCount: model.hostCount(in: group),
                                  isSelected: model.selectedGroupID == group.id,
                                  onEdit: { model.edit(groupID: group.id) })
                        .onTapGesture(count: 2) {
                            model.openGroup(group.id)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            model.select(groupID: group.id)
                        })
                        .popover(isPresented: themeGalleryBinding(for: group.id), arrowEdge: .bottom) {
                            groupThemeGallery(group)
                        }
                        .contextMenu {
                            groupMenu(group)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: HostGroup) -> some View {
        Button("Open") { model.openGroup(group.id) }
        Button("Edit Group") { model.edit(groupID: group.id) }
        Divider()
        Button("Theme\u{2026}") {
            // After the context menu has closed, so the popover can present.
            DispatchQueue.main.async { themeGroupID = group.id }
        }
        Button("tmux\u{2026}") {
            tmuxGroup = group
        }
        Divider()
        Button("New Host in Group") { createHost(inGroup: group.id) }
        Button("Rename") {
            groupToRename = group
            renameText = group.name
            showRenameGroup = true
        }
        Divider()
        Button("Remove", role: .destructive) {
            groupToDelete = group
            showDeleteGroup = true
        }
    }

    /// Open while `themeGroupID` is this group; closing it (Esc, a click outside) clears it.
    private func themeGalleryBinding(for groupID: UUID) -> Binding<Bool> {
        Binding(get: { themeGroupID == groupID },
                set: { isOpen in
                    if !isOpen && themeGroupID == groupID { themeGroupID = nil }
                })
    }

    /// The gallery for the group's default theme ("Default" = no group theme: its parents', then
    /// the app default). Each click saves at once and the popover stays open for comparing.
    private func groupThemeGallery(_ group: HostGroup) -> some View {
        let themeID = model.themeID(ofGroup: group.id)
        let name = group.name.isEmpty ? "Untitled group" : group.name
        return ThemeGalleryPopover(
            title: "Theme for group \u{201C}\(name)\u{201D}",
            selectedThemeID: themeID,
            inheritedTheme: model.defaultTheme(ofGroup: group.id, appDefaultThemeID: terminalSettings.defaultThemeID),
            unknownThemeID: themeID.flatMap { TerminalThemeCatalog.shared.contains($0) ? nil : $0 }
        ) { id in
            setTheme(id, forGroup: group.id)
        }
    }

    private var hostsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Hosts")
            LazyVGrid(columns: columns, spacing: Theme.cardSpacing) {
                ForEach(model.visibleHosts) { host in
                    HostCardView(
                        host: host,
                        subtitle: model.subtitle(for: host),
                        isSelected: model.isHostSelected(host.id),
                        onEdit: { model.edit(hostID: host.id) }
                    )
                    .onTapGesture(count: 2) {
                        connect(hostID: host.id)
                    }
                    // Simultaneous, so selecting doesn't wait for the double-click interval.
                    // ⌘ toggles, ⇧ extends (read from the click's modifier keys).
                    .simultaneousGesture(TapGesture().onEnded {
                        model.click(hostID: host.id, modifier: Self.clickModifier(NSEvent.modifierFlags))
                    })
                    // Onto a terminal: opens the host beside it, as a workspace.
                    .onDrag {
                        WorkspaceDragPayload.itemProvider(hostID: host.id)
                    }
                    .contextMenu {
                        hostMenu(host)
                    }
                    .help("Double-click to connect; \u{2318}-click to select several")
                }
            }
            // E edits the one selected host (as in Termius); typing in a text field is unaffected.
            .background {
                PlainKeyWatch(key: "e") { editSelectedHost() }
            }
        }
    }

    /// A host card's right-click menu. With several hosts selected and this one among them, Open in
    /// Workspace, Move to and Remove act on all of them.
    @ViewBuilder
    private func hostMenu(_ host: SavedHost) -> some View {
        let ids = model.hostIDs(forContextMenuOn: host.id)
        Button("Connect") { connect(hostID: host.id) }
        Button("Connect in a New Window") {
            do { try connectInNewWindow(host.id) } catch { present(error) }
        }
        if let workspaceIDs = model.workspaceHostIDs(forContextMenuOn: host.id) {
            Button("Open in Workspace (\(workspaceIDs.count) hosts)") {
                openInWorkspace(workspaceIDs)
            }
        }
        let openWorkspaces = sessions.workspaces(inWindow: nil)
        Menu("Add to Workspace") {
            if openWorkspaces.isEmpty {
                Text("No open workspaces")
            }
            ForEach(openWorkspaces, id: \.id) { workspace in
                Button(workspace.name.isEmpty ? "Workspace" : workspace.name) {
                    addToWorkspace(ids, workspaceID: workspace.id)
                }
            }
        }
        .disabled(openWorkspaces.isEmpty)
        Divider()
        Button("Edit Host Details") { model.edit(hostID: host.id) }
            .keyboardShortcut("e", modifiers: [])
        Divider()
        Menu("Move to") {
            Button("Hosts (top level)") { moveHosts(ids, toGroup: nil) }
            Divider()
            ForEach(model.groupDestinations()) { destination in
                Button(destination.name) { moveHosts(ids, toGroup: destination.id) }
            }
        }
        Button("Duplicate") { duplicateHost(host.id) }
        Divider()
        Button(ids.count == 1 ? "Remove" : "Remove \(ids.count) Hosts", role: .destructive) {
            hostsToRemove = ids
            showRemoveHosts = true
        }
    }

    private static func clickModifier(_ flags: NSEvent.ModifierFlags) -> HostsViewModel.ClickModifier {
        if flags.contains(.command) { return .toggle }
        if flags.contains(.shift) { return .extend }
        return .none
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && model.selectedTags.isEmpty {
                Text("No hosts yet — click New host")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            } else {
                Text("No matching hosts")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    /// Opens a terminal tab for the host (and shows it). Hosts that can't be planned (no address,
    /// no username) show why instead.
    private func connect(hostID: UUID) {
        do {
            try sessions.open(hostID: hostID)
        } catch {
            present(error)
        }
    }

    /// Opens a terminal tab for the `user@host` typed in the search field.
    private func quickConnect() {
        guard let target = model.quickConnectTarget else { return }
        sessions.open(quickConnect: target)
    }

    /// Open in Workspace: hosts that can't be planned show why; nothing opens then.
    private func openInWorkspace(_ hostIDs: [UUID]) {
        guard hostIDs.count >= 2 else { return }
        do {
            try openWorkspace(hostIDs)
        } catch {
            present(error)
        }
    }

    private func open(_ template: WorkspaceTemplate) {
        do {
            try openTemplate(template)
        } catch {
            present(error, title: "The workspace couldn\u{2019}t be opened")
        }
    }

    private func createHost() {
        Task {
            do {
                try await model.newHost()
            } catch {
                present(error)
            }
        }
    }

    private func createHost(inGroup groupID: UUID) {
        Task {
            do {
                try await model.newHost(inGroup: groupID)
            } catch {
                present(error)
            }
        }
    }

    /// E: Host Details for the one selected host.
    /// Whether a host was edited (otherwise the key press goes on as usual).
    private func editSelectedHost() -> Bool {
        let ids = model.selectedVisibleHostIDs
        guard ids.count == 1, let id = ids.first else { return false }
        model.edit(hostID: id)
        return true
    }

    private func duplicateHost(_ id: UUID) {
        Task {
            do {
                try await model.duplicateHost(id: id)
            } catch {
                present(error)
            }
        }
    }

    private func moveHosts(_ ids: [UUID], toGroup groupID: UUID?) {
        Task {
            do {
                try await model.moveHosts(ids, toGroup: groupID)
            } catch {
                present(error)
            }
        }
    }

    private func removeHosts(_ ids: [UUID]) {
        hostsToRemove = []
        Task {
            do {
                try await model.removeHosts(ids)
            } catch {
                present(error)
            }
        }
    }

    private var removeMessage: String {
        if hostsToRemove.count == 1, let id = hostsToRemove.first,
           let host = vault.get(SavedHost.self, id: id) {
            return "\u{201C}\(host.label.isEmpty ? "Untitled host" : host.label)\u{201D} will be removed from this vault and your other Macs. Open sessions stay open. You can restore it from Settings \u{2192} Recently Deleted."
        }
        return "They will be removed from this vault and your other Macs. Open sessions stay open. You can restore them from Settings \u{2192} Recently Deleted."
    }

    /// Add to Workspace: each host joins the open workspace as a new pane; the workspace is shown.
    private func addToWorkspace(_ hostIDs: [UUID], workspaceID: UUID) {
        do {
            for id in hostIDs {
                try sessions.addHost(id, toWorkspace: workspaceID)
            }
        } catch {
            present(error, title: "The host couldn\u{2019}t be added")
        }
    }

    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                try await model.newGroup(name: name)
            } catch {
                present(error)
            }
        }
    }

    private func renameGroup() {
        guard let groupID = groupToRename?.id else { return }
        let name = renameText
        groupToRename = nil
        Task {
            do {
                try await model.renameGroup(id: groupID, name: name)
            } catch {
                present(error)
            }
        }
    }

    /// Saves the group's theme; a failure closes the gallery and shows the error alert.
    private func setTheme(_ themeID: String?, forGroup groupID: UUID) {
        Task {
            do {
                try await model.setTheme(themeID, forGroup: groupID)
            } catch {
                themeGroupID = nil
                present(error)
            }
        }
    }

    private func deleteGroup(_ group: HostGroup) {
        groupToDelete = nil
        Task {
            do {
                try await model.deleteGroup(id: group.id)
            } catch {
                present(error)
            }
        }
    }

    private func present(_ error: any Error, title: String = "Something went wrong") {
        errorTitle = (error as? ConnectionPlanError)?.alertTitle ?? title
        errorMessage = error.localizedDescription
        showError = true
    }
}

/// Checkable list of every tag; checked tags filter the host list.
private struct TagFilterPopover: View {
    let model: HostsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filter by tag")
                .font(.system(size: 13, weight: .semibold))
            if model.allTags.isEmpty {
                Text("No tags yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.allTags, id: \.self) { tag in
                            TagToggleRow(tag: tag, isOn: model.selectedTags.contains(tag)) {
                                if model.selectedTags.contains(tag) {
                                    model.selectedTags.remove(tag)
                                } else {
                                    model.selectedTags.insert(tag)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
                Divider()
                Button("Clear filter") {
                    model.selectedTags = []
                }
                .disabled(model.selectedTags.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 220, alignment: .leading)
    }
}

/// A checkbox-style row: tapping it flips the tag in `selectedTags`.
private struct TagToggleRow: View {
    let tag: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Theme.accent : Color.secondary)
                Text(tag)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Calls `action` for a key press of `key` with no modifiers in this view's window, unless a text
/// field or text view has the keyboard focus (so typing is never taken). Consumes the press.
private struct PlainKeyWatch: NSViewRepresentable {
    let key: String
    /// Returns whether it handled the press (only then is it consumed).
    let action: @MainActor () -> Bool

    func makeNSView(context: Context) -> WatchView {
        let view = WatchView()
        view.key = key
        view.action = action
        return view
    }

    func updateNSView(_ view: WatchView, context: Context) {
        view.key = key
        view.action = action
    }

    final class WatchView: NSView {
        var key = ""
        var action: (@MainActor () -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    let eventWindow = event.window
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
                    let characters = event.charactersIgnoringModifiers?.lowercased()
                    guard let self, let window = self.window, eventWindow === window, window.isKeyWindow,
                          !self.isHiddenOrHasHiddenAncestor, flags.isEmpty, characters == self.key,
                          !(window.firstResponder is NSText) else { return false }
                    return self.action?() == true
                }
                return handled ? nil : event
            }
        }
    }
}
