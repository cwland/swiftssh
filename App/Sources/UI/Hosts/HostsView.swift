import SwiftUI
import AppCore
import CoreModels

/// The Hosts screen: search bar, toolbar, breadcrumbs, group and host cards, and the Host
/// Details panel for the selected host. All behavior comes from `HostsViewModel`.
struct HostsView: View {
    @Bindable var model: HostsViewModel
    let vault: LocalVault
    let sessions: SessionManager

    @State private var showTagFilter = false
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var groupToRename: HostGroup?
    @State private var showRenameGroup = false
    @State private var renameText = ""
    @State private var groupToDelete: HostGroup?
    @State private var showDeleteGroup = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var errorTitle = "Something went wrong"

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let hostID = model.selectedHostID, model.selectedHost != nil {
                Divider()
                HostDetailsPanel(vault: vault, hostID: hostID, onClose: {
                    model.selectedHostID = nil
                }, onConnect: {
                    connect(hostID: hostID)
                })
                .id(hostID)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.selectedHostID)
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
    }

    // MARK: Layout

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchBar
            toolbar
            if !model.breadcrumbs.isEmpty {
                breadcrumbBar
            }
            if model.visibleGroups.isEmpty && model.visibleHosts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
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
            Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
        case .list:
            [GridItem(.flexible())]
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Groups")
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.visibleGroups) { group in
                    GroupCardView(group: group, hostCount: model.hostCount(in: group))
                        .onTapGesture(count: 2) {
                            model.openGroup(group.id)
                        }
                        .contextMenu {
                            Button("Rename") {
                                groupToRename = group
                                renameText = group.name
                                showRenameGroup = true
                            }
                            Button("Delete", role: .destructive) {
                                groupToDelete = group
                                showDeleteGroup = true
                            }
                        }
                }
            }
        }
    }

    private var hostsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Hosts")
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.visibleHosts) { host in
                    HostCardView(
                        host: host,
                        subtitle: model.subtitle(for: host),
                        isSelected: host.id == model.selectedHostID
                    )
                    .onTapGesture(count: 2) {
                        connect(hostID: host.id)
                    }
                    // Simultaneous, so selecting doesn't wait for the double-click interval.
                    .simultaneousGesture(TapGesture().onEnded {
                        model.selectedHostID = host.id
                    })
                    .help("Double-click to connect")
                }
            }
        }
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

    private func createHost() {
        Task {
            do {
                try await model.newHost()
            } catch {
                present(error)
            }
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

    private func present(_ error: any Error) {
        errorTitle = (error as? ConnectionPlanError)?.alertTitle ?? "Something went wrong"
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
