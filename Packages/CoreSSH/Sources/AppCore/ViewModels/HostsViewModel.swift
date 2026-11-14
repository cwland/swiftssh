import Foundation
import Observation
import CoreModels

@MainActor @Observable
public final class HostsViewModel {
    public enum Layout: Sendable { case grid, list }

    public var searchText = ""
    public var selectedTags: Set<String> = []
    public var layout: Layout = .grid
    public var currentGroupID: UUID?
    public var selectedHostID: UUID?

    @ObservationIgnored private let vault: LocalVault

    public init(vault: LocalVault) {
        self.vault = vault
    }

    private var directory: HostDirectory {
        _ = vault.revision
        return HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedTags.isEmpty
    }

    /// Sorted, unique tags across non-deleted hosts.
    public var allTags: [String] {
        _ = vault.revision
        return Array(Set(vault.all(SavedHost.self).flatMap(\.tags))).sorted()
    }

    /// Groups from the root to the current group.
    public var breadcrumbs: [HostGroup] {
        _ = vault.revision
        let groups = Dictionary(vault.all(HostGroup.self).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [HostGroup] = []
        var visited: Set<UUID> = []
        var next = currentGroupID
        while let id = next, visited.insert(id).inserted, let group = groups[id] {
            chain.append(group)
            next = group.parentID
        }
        return chain.reversed()
    }

    /// Direct children of the current group; hidden while searching or filtering by tag.
    public var visibleGroups: [HostGroup] {
        _ = vault.revision
        guard !isFiltering else { return [] }
        return vault.all(HostGroup.self)
            .filter { $0.parentID == currentGroupID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var visibleHosts: [SavedHost] {
        let directory = self.directory
        let inGroup = Set(directory.hosts(inGroup: currentGroupID).map(\.id))
        return directory.filter(tags: selectedTags, search: searchText)
            .filter { inGroup.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public func subtitle(for host: SavedHost) -> String {
        let directory = self.directory
        let username = host.username
            ?? directory.effectiveIdentityID(for: host)
                .flatMap { vault.get(Identity.self, id: $0)?.username }
        return username.map { "ssh, \($0)" } ?? "ssh"
    }

    /// Hosts in the group, including those in descendant groups.
    public func hostCount(in group: HostGroup) -> Int {
        directory.hosts(inGroup: group.id).count
    }

    public func openGroup(_ id: UUID?) {
        currentGroupID = id
    }

    @discardableResult
    public func newHost() async throws -> SavedHost {
        let host = try await vault.save(SavedHost(label: "New host", address: "", groupID: currentGroupID))
        selectedHostID = host.id
        return host
    }

    @discardableResult
    public func newGroup(name: String) async throws -> HostGroup {
        try await vault.save(HostGroup(name: name, parentID: currentGroupID))
    }

    public var quickConnectTarget: QuickConnectTarget? {
        QuickConnect.parse(searchText)
    }

    /// Connecting is not available this milestone.
    public var canConnect: Bool { false }
}
