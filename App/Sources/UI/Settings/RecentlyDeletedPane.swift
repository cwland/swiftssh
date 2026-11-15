import SwiftUI
import AppCore
import CoreModels

/// Settings → Recently Deleted: deleted hosts (from any of your Macs), newest first. Restore brings one
/// back with its details (and on your other Macs); Delete Permanently or Empty removes the details for
/// good. Both ask first only for permanent removal.
struct RecentlyDeletedPane: View {
    /// nil until the vault is open.
    let vault: LocalVault?

    @State private var model: RecentlyDeletedViewModel?
    @State private var pendingRemoval: [UUID] = []
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
                    if let model, !model.deletedHosts.isEmpty {
                        Button("Empty\u{2026}", role: .destructive) {
                            pendingRemoval = model.deletedHosts.map(\.id)
                            showRemoval = true
                        }
                    }
                }
                Text("Hosts you deleted, on this Mac or another of yours. Restore one to get it back with its address, login and settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let model {
                    if model.deletedHosts.isEmpty {
                        Text("No deleted hosts.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(model.deletedHosts) { host in
                                row(host, model: model)
                            }
                        }
                    }
                } else {
                    Text("Open your vault to see deleted hosts.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if model == nil, let vault { model = RecentlyDeletedViewModel(vault: vault) }
        }
        .confirmationDialog(pendingRemoval.count == 1 ? "Delete this host permanently?"
                                                      : "Delete \(pendingRemoval.count) hosts permanently?",
                            isPresented: $showRemoval, titleVisibility: .visible) {
            Button(pendingRemoval.count == 1 ? "Delete Permanently" : "Delete All Permanently", role: .destructive) {
                removePermanently(pendingRemoval)
            }
            Button("Cancel", role: .cancel) { pendingRemoval = [] }
        } message: {
            Text("Its address, login and settings are removed from all your Macs. This can\u{2019}t be undone.")
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func row(_ host: SavedHost, model: RecentlyDeletedViewModel) -> some View {
        HStack(spacing: Theme.cardPadding) {
            SymbolBadge(symbol: "server.rack", background: Color.secondary.opacity(0.5))
                .frame(width: Theme.cardBadgeSize, height: Theme.cardBadgeSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.label.isEmpty ? host.address : host.label)
                    .font(.system(size: Theme.cardTitleFontSize))
                    .lineLimit(1)
                Text("\(host.address) \u{00B7} deleted \(host.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: Theme.cardSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore") { run { try await model.restore(host.id) } }
            Button("Delete Permanently\u{2026}", role: .destructive) {
                pendingRemoval = [host.id]
                showRemoval = true
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .frame(height: Theme.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardBackground)
        }
    }

    private func removePermanently(_ ids: [UUID]) {
        pendingRemoval = []
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
