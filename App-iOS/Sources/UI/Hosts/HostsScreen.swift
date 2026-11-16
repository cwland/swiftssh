import SwiftUI
import UIKit
import AppCore
import CoreModels
import SwiftSSHUI

/// Hosts, as on the Mac: the open group's groups (tap to open) and hosts (tap to connect) as cards
/// with OS badges, a path back up, and search by name or address (all hosts while searching).
/// Long-press a host: Connect, Copy Address, Show Details (read-only). Nothing is edited here.
struct HostsScreen: View {
    @Bindable var model: HostsViewModel
    let sessions: SessionManager
    let vault: LocalVault
    @Environment(IOSEnvironment.self) private var environment
    @State private var details: HostRef?
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.breadcrumbs.isEmpty, model.searchText.isEmpty {
                    breadcrumbBar
                }
                let groups = model.visibleGroups
                if !groups.isEmpty {
                    section("Groups") {
                        LazyVGrid(columns: Theme.cardGridColumns, spacing: Theme.cardSpacing) {
                            ForEach(groups) { group in
                                Button {
                                    model.openGroup(group.id)
                                } label: {
                                    GroupCard(name: group.name, hostCount: model.hostCount(in: group))
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the group")
                            }
                        }
                    }
                }
                let hosts = model.visibleHosts
                if !hosts.isEmpty {
                    section("Hosts") {
                        LazyVGrid(columns: Theme.cardGridColumns, spacing: Theme.cardSpacing) {
                            ForEach(hosts) { host in
                                hostCard(host)
                            }
                        }
                    }
                }
                if groups.isEmpty, hosts.isEmpty {
                    emptyState
                }
            }
            .padding(16)
        }
        .background(Theme.contentBackground)
        .navigationTitle(title)
        .searchable(text: $model.searchText, prompt: "Search hosts")
        .searchFocused($searchFocused)
        .onChange(of: environment.navigation.searchRequests) {
            searchFocused = true
        }
        .toolbar {
            if model.effectiveGroupID != nil, model.searchText.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.openGroup(model.breadcrumbs.dropLast().last?.id)
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .accessibilityLabel("Up one group")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.navigation.isQuickConnectShown = true
                } label: {
                    Image(systemName: "bolt.horizontal")
                }
                .accessibilityLabel("Quick connect")
            }
        }
        .sheet(item: $details) { ref in
            HostDetailsSheet(hostID: ref.id, vault: vault)
        }
    }

    private var title: String {
        guard model.searchText.isEmpty, let group = model.breadcrumbs.last else { return "Hosts" }
        return group.name.isEmpty ? "Untitled group" : group.name
    }

    // MARK: Parts

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button("Hosts") { model.openGroup(nil) }
                ForEach(model.breadcrumbs) { group in
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Button(group.name.isEmpty ? "Untitled group" : group.name) { model.openGroup(group.id) }
                        .disabled(group.id == model.effectiveGroupID)
                }
            }
            .font(.subheadline)
        }
    }

    private func hostCard(_ host: SavedHost) -> some View {
        Button {
            Task { await environment.connect(hostID: host.id) }
        } label: {
            CardRow(title: host.label.isEmpty ? "Untitled host" : host.label, subtitle: model.subtitle(for: host)) {
                OSBadgeTile(badge: sessions.detectedBadge(hostID: host.id) ?? host.osBadge,
                            size: Theme.cardBadgeSize, cornerRadius: Theme.cardBadgeCornerRadius)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Connects")
        .contextMenu {
            Button {
                Task { await environment.connect(hostID: host.id) }
            } label: {
                Label("Connect", systemImage: "play.fill")
            }
            Button {
                UIPasteboard.general.string = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            Button {
                details = HostRef(id: host.id)
            } label: {
                Label("Show Details", systemImage: "info.circle")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.effectiveGroupID != nil {
            ContentUnavailableView("No Hosts in This Group", systemImage: "folder",
                                   description: Text("Add hosts to it on your Mac."))
        } else {
            ContentUnavailableView("No Hosts Yet", systemImage: "server.rack",
                                   description: Text("Add hosts on your Mac; they arrive here through sync."))
        }
    }
}

/// A host id for `.sheet(item:)`.
struct HostRef: Identifiable, Hashable {
    let id: UUID
}
