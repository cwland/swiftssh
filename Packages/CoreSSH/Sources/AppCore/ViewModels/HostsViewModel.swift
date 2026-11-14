import Foundation
import Observation
import CoreModels

public enum HostsError: Error, Equatable, Sendable, LocalizedError {
    case emptyGroupName

    public var errorDescription: String? {
        switch self {
        case .emptyGroupName: "A group name can't be empty."
        }
    }
}

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

    /// `currentGroupID` while that group is live; otherwise root (nil).
    public var effectiveGroupID: UUID? {
        _ = vault.revision
        guard let id = currentGroupID, vault.get(HostGroup.self, id: id) != nil else { return nil }
        return id
    }

    /// The selected host, nil if none is selected or it is missing or deleted.
    public var selectedHost: SavedHost? {
        _ = vault.revision
        return selectedHostID.flatMap { vault.get(SavedHost.self, id: $0) }
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
        var next = effectiveGroupID
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
            .filter { $0.parentID == effectiveGroupID }
            .sorted { Self.ordered($0.name, $0.id, $1.name, $1.id) }
    }

    public var visibleHosts: [SavedHost] {
        let directory = self.directory
        let inGroup = Set(directory.hosts(inGroup: effectiveGroupID).map(\.id))
        return directory.filter(tags: selectedTags, search: searchText)
            .filter { inGroup.contains($0.id) }
            .sorted { Self.ordered($0.label, $0.id, $1.label, $1.id) }
    }

    /// "ssh, <user>" naming the user a connection to the host would log in as (the same
    /// resolution `ConnectionPlanner` uses), or "ssh" when there is none.
    public func subtitle(for host: SavedHost) -> String {
        let username = CredentialResolution.resolve(host: host, directory: directory, vault: vault).username
        return username.map { "ssh, \($0)" } ?? "ssh"
    }

    /// Hosts in the group, including those in descendant groups.
    public func hostCount(in group: HostGroup) -> Int {
        directory.hosts(inGroup: group.id).count
    }

    private static func ordered(_ a: String, _ aID: UUID, _ b: String, _ bID: UUID) -> Bool {
        switch a.localizedCaseInsensitiveCompare(b) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: aID.uuidString < bID.uuidString
        }
    }

    public func openGroup(_ id: UUID?) {
        currentGroupID = id
    }

    @discardableResult
    public func newHost() async throws -> SavedHost {
        let host = try await vault.save(SavedHost(label: "New host", address: "", groupID: effectiveGroupID))
        selectedHostID = host.id
        return host
    }

    @discardableResult
    public func newGroup(name: String) async throws -> HostGroup {
        try await vault.save(HostGroup(name: name, parentID: effectiveGroupID))
    }

    /// Trims the name; an empty result throws `HostsError.emptyGroupName`. A missing or deleted
    /// group is left alone.
    public func renameGroup(id: UUID, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HostsError.emptyGroupName }
        guard var group = vault.get(HostGroup.self, id: id) else { return }
        group.name = trimmed
        try await vault.save(group)
    }

    /// Moves the group's hosts and subgroups up one level, then deletes the group.
    public func deleteGroup(id: UUID) async throws {
        try await vault.deleteGroup(id: id)
    }

    public var quickConnectTarget: QuickConnectTarget? {
        QuickConnect.parse(searchText)
    }

    /// True when the search text is a quick-connect target (`[ssh] [user@]host[:port]`).
    public var canConnect: Bool { quickConnectTarget != nil }
}
