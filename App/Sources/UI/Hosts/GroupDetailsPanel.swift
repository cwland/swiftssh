import SwiftUI
import AppCore
import CoreModels

/// The right-hand Group panel (a group card's pencil, or Edit Group): name, parent group, theme
/// and tmux for the group's hosts, and Delete. Each change saves at once through `HostsViewModel`.
/// Create one panel per group (`.id(groupID)`).
struct GroupDetailsPanel: View {
    let model: HostsViewModel
    let group: HostGroup
    let terminalSettings: TerminalSettings
    let onClose: () -> Void
    let onDelete: (HostGroup) -> Void
    let onError: (any Error) -> Void

    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var showThemeGallery = false
    @State private var showTmux = false
    @State private var confirmDelete = false

    private var displayName: String { group.name.isEmpty ? "Untitled group" : group.name }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DetailsCard {
                        FieldColumn(title: "Name") {
                            TextField("Group name", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .focused($nameFocused)
                                .onSubmit(saveName)
                        }
                        FieldColumn(title: "Parent group") {
                            parentPicker
                        }
                    }
                    DetailsCard {
                        themeField
                        FieldColumn(title: "Attach to tmux") {
                            HStack {
                                Text(tmuxSummary)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Button("Change\u{2026}") { showTmux = true }
                            }
                        }
                    }
                    Text("Hosts in this group that use Default take its theme and tmux setting.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Text("Delete group")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: Theme.detailsPanelWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebarBackground)
        .onAppear { name = group.name }
        .onChange(of: nameFocused) { if !nameFocused { saveName() } }
        .onDisappear(perform: saveName)
        .sheet(isPresented: $showTmux) {
            GroupTmuxSheet(model: model, group: group) { showTmux = false }
        }
        .confirmationDialog("Delete \u{201C}\(displayName)\u{201D}?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete group", role: .destructive) { onDelete(group) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its hosts and groups move up one level; nothing else is deleted.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Group")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                onClose()
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    /// "Hosts (top level)" or any group outside this one's own subtree.
    private var parentPicker: some View {
        Picker("Parent group", selection: Binding(
            get: { group.parentID },
            set: { parent in
                Task {
                    do { try await model.moveGroup(id: group.id, toParent: parent) } catch { onError(error) }
                }
            }
        )) {
            Text("Hosts (top level)").tag(UUID?.none)
            ForEach(model.groupDestinations(excludingSubtreeOf: group.id)) { destination in
                Text(destination.name).tag(UUID?.some(destination.id))
            }
        }
        .labelsHidden()
    }

    private var themeField: some View {
        let themeID = model.themeID(ofGroup: group.id)
        let inherited = model.defaultTheme(ofGroup: group.id, appDefaultThemeID: terminalSettings.defaultThemeID)
        let chosen = themeID.flatMap { TerminalThemeCatalog.shared.theme(id: $0) }
        let summary: String = if let themeID {
            chosen?.name ?? "Unknown theme (\(themeID))"
        } else {
            "Default (\(inherited?.name ?? "Automatic"))"
        }
        return FieldColumn(title: "Theme") {
            ThemeRowButton(title: summary, swatchTheme: chosen ?? inherited) {
                showThemeGallery = true
            }
            .popover(isPresented: $showThemeGallery, arrowEdge: .leading) {
                ThemeGalleryPopover(
                    title: "Theme for group \u{201C}\(displayName)\u{201D}",
                    selectedThemeID: themeID,
                    inheritedTheme: inherited,
                    unknownThemeID: themeID.flatMap { TerminalThemeCatalog.shared.contains($0) ? nil : $0 }
                ) { id in
                    Task {
                        do { try await model.setTheme(id, forGroup: group.id) } catch { onError(error) }
                    }
                }
            }
        }
    }

    private var tmuxSummary: String {
        switch model.tmuxChoice(ofGroup: group.id) {
        case .inherit: model.inheritedTmuxSummary(ofGroup: group.id)
        case .off: "Off"
        case .session(let name): "On (\(name))"
        }
    }

    /// Saves a changed name; an empty one goes back to the stored name.
    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != group.name else { return }
        guard !trimmed.isEmpty else {
            name = group.name
            return
        }
        Task {
            do { try await model.renameGroup(id: group.id, name: trimmed) } catch { onError(error) }
        }
    }
}
