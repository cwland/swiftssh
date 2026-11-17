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
        themeIDChain(for: host).first
    }

    /// The host's own theme id, then each group's `defaultThemeID` up the parent chain
    /// (nearest first, cycle-safe; the walk ends at a deleted or missing group, as for the other
    /// inherited settings). nil levels are left out.
    /// A resolver walks this to skip ids its catalog doesn't know.
    public func themeIDChain(for host: Host) -> [String] {
        var chain: [String] = host.themeID.map { [$0] } ?? []
        var visited: Set<UUID> = []
        var next = host.groupID
        while let id = next, visited.insert(id).inserted, let group = groupsByID[id] {
            if let theme = group.defaultThemeID { chain.append(theme) }
            next = group.parentID
        }
        return chain
    }

    /// The tmux session to attach to after login, or nil = don't attach: the host's own `.session` or
    /// `.off`, else (nil or `.inherit`) `inheritedTmux(for:)`. The name is returned as stored; callers
    /// check it with `TmuxChoice.isValidSessionName` before using it.
    public func effectiveTmuxSession(for host: Host) -> String? {
        switch host.tmuxSession ?? .inherit {
        case .session(let name): name
        case .off: nil
        case .inherit: inheritedTmux(for: host).choice.sessionName
        }
    }

    /// What "Default" means for the host's tmux setting: its groups' choice, the host's own left out.
    public func inheritedTmux(for host: Host) -> InheritedTmux {
        inheritedTmux(fromGroup: host.groupID)
    }

    /// The first group from `groupID` up the parent chain whose choice is `.off` or `.session`
    /// (cycle-safe; the walk ends at a deleted or missing group). `.inherit` with no group = none set.
    public func inheritedTmux(fromGroup groupID: UUID?) -> InheritedTmux {
        var visited: Set<UUID> = []
        var next = groupID
        while let id = next, visited.insert(id).inserted, let group = groupsByID[id] {
            switch group.defaultTmuxSession ?? .inherit {
            case .inherit: next = group.parentID
            case let choice: return InheritedTmux(choice: choice, groupName: group.name)
            }
        }
        return InheritedTmux(choice: .inherit, groupName: nil)
    }

    // MARK: Startup snippet

    /// The snippet to type after login, or nil = none: the host's own when `isAvailable` (the snippet
    /// exists), else nothing when the host chose None (`startupSnippetOff`), else
    /// `inheritedStartupSnippet(for:isAvailable:)`. Whether its script can run (no placeholders) is
    /// for the caller to check.
    public func effectiveStartupSnippetID(for host: Host, isAvailable: (UUID) -> Bool) -> UUID? {
        if let own = host.startupSnippetID, isAvailable(own) { return own }
        if host.startupSnippetOff == true { return nil }
        return inheritedStartupSnippet(for: host, isAvailable: isAvailable)?.snippetID
    }

    /// What "Default" means for the host's startup snippet: its groups' choice, the host's own left out.
    public func inheritedStartupSnippet(for host: Host, isAvailable: (UUID) -> Bool) -> InheritedStartupSnippet? {
        inheritedStartupSnippet(fromGroup: host.groupID, isAvailable: isAvailable)
    }

    /// How many hosts use Default for their startup snippet and get it from `groupID`, or would
    /// once it has one: hosts in the group or its subgroups without an available snippet of their
    /// own and not set to None, for which no group closer to them has an available snippet.
    /// Cycle-safe, like `inheritedStartupSnippet(fromGroup:isAvailable:)`.
    public func hostsUsingDefaultStartupSnippet(ofGroup groupID: UUID, isAvailable: (UUID) -> Bool) -> Int {
        hosts.reduce(0) { count, host in
            if let own = host.startupSnippetID, isAvailable(own) { return count }
            if host.startupSnippetOff == true { return count }
            var visited: Set<UUID> = []
            var next = host.groupID
            while let id = next, visited.insert(id).inserted, let group = groupsByID[id] {
                if id == groupID { return count + 1 }
                if let snippetID = group.startupSnippetID, isAvailable(snippetID) { return count }
                next = group.parentID
            }
            return count
        }
    }

    /// The first group from `groupID` up the parent chain whose `startupSnippetID` is available (a
    /// missing snippet counts as unset, so the walk goes on), with that group's name; nil = none.
    /// Cycle-safe; the walk ends at a deleted or missing group, as for tmux.
    public func inheritedStartupSnippet(fromGroup groupID: UUID?,
                                        isAvailable: (UUID) -> Bool) -> InheritedStartupSnippet? {
        var visited: Set<UUID> = []
        var next = groupID
        while let id = next, visited.insert(id).inserted, let group = groupsByID[id] {
            if let snippetID = group.startupSnippetID, isAvailable(snippetID) {
                return InheritedStartupSnippet(snippetID: snippetID, groupName: group.name)
            }
            next = group.parentID
        }
        return nil
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

    /// All `tags` are required; `search` is case-insensitive over label, address, backup address,
    /// username and tags. Empty search matches everything.
    public func filter(tags: Set<String>, search: String) -> [Host] {
        let needle = search.lowercased()
        return hosts.filter { host in
            guard tags.isSubset(of: Set(host.tags)) else { return false }
            if needle.isEmpty { return true }
            let fields = [host.label, host.address, host.fallbackAddress ?? "", host.username ?? ""] + host.tags
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

/// A tmux choice inherited from a group: `.off` or `.session` with the deciding group's name, or
/// `.inherit` with no name when no group sets one (which means off).
public struct InheritedTmux: Equatable, Sendable {
    public var choice: TmuxChoice
    public var groupName: String?

    public init(choice: TmuxChoice, groupName: String?) {
        self.choice = choice
        self.groupName = groupName
    }
}

/// A startup snippet inherited from a group: the snippet and the name of the group that sets it.
public struct InheritedStartupSnippet: Equatable, Sendable {
    public var snippetID: UUID
    public var groupName: String

    public init(snippetID: UUID, groupName: String) {
        self.snippetID = snippetID
        self.groupName = groupName
    }
}
