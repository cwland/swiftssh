import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// Settings → Recently Deleted: deleted hosts, host groups and snippets (from any of your Macs), in
/// sections (empty ones hidden), newest first. Restore brings one back with its details (and on your
/// other Macs); Delete Permanently or Empty removes the details for good. Both ask first only for
/// permanent removal.
struct RecentlyDeletedPane: View {
    /// nil until the vault is open.
    let vault: LocalVault?

    /// What the "delete permanently" confirmation is about.
    private struct Removal {
        var ids: [UUID]
        var title: String
        var message: String
    }

    @State private var model: RecentlyDeletedViewModel?
    @State private var pendingRemoval: Removal?
    @State private var showRemoval = false
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Recently Deleted")
                        .font(.system(size: 22, weight: .semibold))
                    Spacer(minLength: 0)
                    if let model, !model.isEmpty {
                        Button("Empty\u{2026}", role: .destructive) {
                            let ids = model.deletedHosts.map(\.id) + model.deletedGroups.map(\.id)
                                + model.deletedSnippets.map(\.id)
                            confirm(Removal(
                                ids: ids,
                                title: ids.count == 1 ? "Delete this item permanently?"
                                                      : "Delete all \(ids.count) items permanently?",
                                message: "They\u{2019}re removed from all your Macs. This can\u{2019}t be undone."))
                        }
                    }
                }
                Text("Hosts, groups and snippets you deleted, on this Mac or another of yours. Restore one to get it back with its settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let model {
                    if model.isEmpty {
                        Text("Nothing deleted.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else {
                        sections(model)
                    }
                } else {
                    Text("Open your vault to see deleted items.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // The vault may open after the pane appears.
        .task(id: vault != nil) {
            if model == nil, let vault { model = RecentlyDeletedViewModel(vault: vault) }
        }
        .confirmationDialog(pendingRemoval?.title ?? "", isPresented: $showRemoval, titleVisibility: .visible,
                            presenting: pendingRemoval) { removal in
            Button(removal.ids.count == 1 ? "Delete Permanently" : "Delete All Permanently", role: .destructive) {
                removePermanently(removal.ids)
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { removal in
            Text(removal.message)
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @ViewBuilder
    private func sections(_ model: RecentlyDeletedViewModel) -> some View {
        if !model.deletedHosts.isEmpty {
            section("Hosts") {
                ForEach(model.deletedHosts) { host in
                    row(symbol: "server.rack",
                        title: host.label.isEmpty ? host.address : host.label,
                        detail: host.address, deletedAt: host.updatedAt, model: model, id: host.id,
                        removal: Removal(ids: [host.id], title: "Delete this host permanently?",
                                         message: "Its address, login and settings are removed from all your Macs. This can\u{2019}t be undone."))
                }
            }
        }
        if !model.deletedGroups.isEmpty {
            section("Groups") {
                ForEach(model.deletedGroups) { group in
                    row(symbol: "folder.fill",
                        title: group.name.isEmpty ? "Untitled group" : group.name,
                        detail: "Host group", deletedAt: group.updatedAt, model: model, id: group.id,
                        removal: Removal(ids: [group.id], title: "Delete this group permanently?",
                                         message: "Its name and settings are removed from all your Macs. Its hosts aren\u{2019}t affected. This can\u{2019}t be undone."))
                }
            }
        }
        if !model.deletedSnippets.isEmpty {
            section("Snippets") {
                ForEach(model.deletedSnippets) { snippet in
                    row(symbol: "curlybraces",
                        title: snippet.name.isEmpty ? "Untitled snippet" : snippet.name,
                        detail: snippet.package.map { "Snippet group: \($0)" } ?? "Snippet",
                        deletedAt: snippet.updatedAt, model: model, id: snippet.id,
                        removal: Removal(ids: [snippet.id], title: "Delete this snippet permanently?",
                                         message: "Its script is removed from all your Macs. This can\u{2019}t be undone."))
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            rows()
        }
    }

    private func row(symbol: String, title: String, detail: String, deletedAt: Date,
                     model: RecentlyDeletedViewModel, id: UUID, removal: Removal) -> some View {
        HStack(spacing: Theme.cardPadding) {
            SymbolBadge(symbol: symbol, background: Color.secondary.opacity(0.5))
                .frame(width: Theme.cardBadgeSize, height: Theme.cardBadgeSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.cardTitleFontSize))
                    .lineLimit(1)
                Text("\(detail) \u{00B7} deleted \(deletedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: Theme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore") { run { try await model.restore(id) } }
            Button("Delete Permanently\u{2026}", role: .destructive) { confirm(removal) }
        }
        .padding(.horizontal, Theme.cardPadding)
        .frame(height: Theme.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
        }
    }

    private func confirm(_ removal: Removal) {
        pendingRemoval = removal
        showRemoval = true
    }

    private func removePermanently(_ ids: [UUID]) {
        pendingRemoval = nil
        guard let model else { return }
        run {
            for id in ids { try await model.deletePermanently(id) }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}
