import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// ⌘K: type part of a host's name or address, Return connects to the best match (or tap one).
struct QuickConnectSheet: View {
    @Environment(IOSEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(matches) { host in
                    Button {
                        connect(host.id)
                    } label: {
                        HStack(spacing: 12) {
                            OSBadgeTile(badge: environment.sessions?.detectedBadge(hostID: host.id) ?? host.osBadge,
                                        size: 30, cornerRadius: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.label.isEmpty ? "Untitled host" : host.label)
                                    .foregroundStyle(Color.primary)
                                Text(host.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Host name or address")
            .searchFocused($searchFocused)
            .onSubmit(of: .search) {
                if let first = matches.first { connect(first.id) }
            }
            .navigationTitle("Quick Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .onAppear { searchFocused = true }
        }
    }

    private var matches: [SavedHost] {
        guard let vault = environment.vault else { return [] }
        _ = vault.revision
        return HostQuickFilter.matches(query, in: vault.all(SavedHost.self))
    }

    private func connect(_ hostID: UUID) {
        dismiss()
        Task { await environment.connect(hostID: hostID) }
    }
}
