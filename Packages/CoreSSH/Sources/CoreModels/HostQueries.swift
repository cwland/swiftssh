import Foundation

public struct HostDirectory: Sendable {
    private let hosts: [Host]
    private let groupsByID: [UUID: HostGroup]

    public init(hosts: [Host], groups: [HostGroup]) {
        self.hosts = hosts.filter { !$0.deleted }
        self.groupsByID = Dictionary(groups.filter { !$0.deleted }.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
    }

    public func effectivePort(for host: Host) -> Int {
        host.port ?? firstInChain(of: host) { $0.defaultPort } ?? 22
    }

    public func effectiveIdentityID(for host: Host) -> UUID? {
        host.identityID ?? firstInChain(of: host) { $0.defaultIdentityID }
    }

    public func effectiveThemeID(for host: Host) -> String? {
        host.themeID ?? firstInChain(of: host) { $0.defaultThemeID }
    }

    /// nil = all hosts; otherwise hosts in the group and all its descendants.
    public func hosts(inGroup groupID: UUID?) -> [Host] {
        guard let groupID else { return hosts }
        var included: Set<UUID> = [groupID]
        var changed = true
        while changed {
            changed = false
            for group in groupsByID.values where !included.contains(group.id) {
                if let parent = group.parentID, included.contains(parent) {
                    included.insert(group.id)
                    changed = true
                }
            }
        }
        return hosts.filter { host in host.groupID.map(included.contains) ?? false }
    }

    /// All `tags` are required; `search` is case-insensitive over label, address,
    /// username and tags. Empty search matches everything.
    public func filter(tags: Set<String>, search: String) -> [Host] {
        let needle = search.lowercased()
        return hosts.filter { host in
            guard tags.isSubset(of: Set(host.tags)) else { return false }
            if needle.isEmpty { return true }
            let fields = [host.label, host.address, host.username ?? ""] + host.tags
            return fields.contains { $0.lowercased().contains(needle) }
        }
    }

    private func firstInChain<T>(of host: Host, _ value: (HostGroup) -> T?) -> T? {
        var visited: Set<UUID> = []
        var next = host.groupID
        while let id = next, visited.insert(id).inserted, let group = groupsByID[id] {
            if let found = value(group) { return found }
            next = group.parentID
        }
        return nil
    }
}
