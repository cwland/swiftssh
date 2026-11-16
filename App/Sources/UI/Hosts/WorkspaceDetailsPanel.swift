import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// The right-hand Workspace panel (a workspace tile's pencil, or Edit): its name, the view mode it opens
/// in, its terminals (remove one; at least two stay), Open, and Delete. Each change saves at once to
/// the saved workspace (this Mac only). Changing the layout itself is done by opening it, arranging
/// the panes, and saving (⌘S). Create one panel per workspace (`.id(templateID)`).
struct WorkspaceDetailsPanel: View {
    let store: WorkspaceTemplateStore
    let vault: LocalVault
    let template: WorkspaceTemplate
    let onClose: () -> Void
    let onOpen: () -> Void
    let onDelete: (WorkspaceTemplate) -> Void
    let onError: (any Error) -> Void

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DetailsCard {
                        FieldColumn(title: "Name") {
                            TextField("Workspace name", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .focused($nameFocused)
                                .onSubmit(saveName)
                        }
                        FieldColumn(title: "Opens in") {
                            Picker("Opens in", selection: Binding(
                                get: { template.viewMode },
                                set: { mode in perform { try store.setViewMode(mode, for: template.id) } }
                            )) {
                                Text("Split view").tag(Workspace.ViewMode.split)
                                Text("Focus mode").tag(Workspace.ViewMode.focus)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                    DetailsCard {
                        FieldColumn(title: "Terminals") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(template.layout.panes.enumerated()), id: \.offset) { index, pane in
                                    paneRow(pane, index: index)
                                }
                            }
                        }
                    }
                    Text("To change the layout, open the workspace, arrange its terminals and save it (\u{2318}S).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            VStack(spacing: 10) {
                Button(action: onOpen) {
                    Text("Open")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.accent)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the workspace; each terminal connects")
                Button(role: .destructive) {
                    onDelete(template)
                } label: {
                    Text("Delete workspace")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(16)
        }
        .frame(width: Theme.detailsPanelWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebarBackground)
        .onAppear { name = template.name }
        .onChange(of: nameFocused) { if !nameFocused { saveName() } }
        .onDisappear(perform: saveName)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Workspace")
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

    private func paneRow(_ pane: TemplatePane, index: Int) -> some View {
        let (title, subtitle) = describe(pane)
        let canRemove = template.layout.panes.count > 2
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                perform { try store.removePane(at: index, from: template.id) }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(canRemove ? Color.red : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .help(canRemove ? "Remove from this workspace" : "A workspace needs at least two terminals")
            .accessibilityLabel("Remove \(title)")
        }
        .padding(.vertical, 2)
    }

    /// The pane's tab title (or the host's label), and what it connects to.
    private func describe(_ pane: TemplatePane) -> (String, String) {
        if let hostID = pane.hostID {
            guard let host = vault.get(SavedHost.self, id: hostID) else {
                return (pane.title ?? "Missing host", "This host was deleted")
            }
            let label = host.label.isEmpty ? host.address : host.label
            return (pane.title ?? label, host.address)
        }
        if let target = pane.quickConnect {
            return (pane.title ?? target, "Quick connect")
        }
        return (pane.title ?? "Terminal", "")
    }

    /// Saves a changed name; an empty one goes back to the stored name.
    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != template.name else { return }
        guard !trimmed.isEmpty else {
            name = template.name
            return
        }
        perform { try store.rename(template.id, to: trimmed) }
    }

    private func perform(_ change: () throws -> Void) {
        do { try change() } catch { onError(error) }
    }
}
