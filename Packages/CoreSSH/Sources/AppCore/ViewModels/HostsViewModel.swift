import Foundation
import Observation
import CoreModels

public enum HostsError: Error, Equatable, Sendable, LocalizedError {
    case emptyGroupName
    case invalidTmuxSessionName

    public var errorDescription: String? {
        switch self {
        case .emptyGroupName: "A group name can't be empty."
        case .invalidTmuxSessionName: TmuxLabels.invalidNameMessage
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
    /// The host whose Host Details panel is open. Setting it (New host, "Edit host", closing the
    /// panel) makes it the only selected host (none for nil).
    public var selectedHostID: UUID? {
        didSet {
            guard !isApplyingClick else { return }
            selectedHostIDs = selectedHostID.map { [$0] } ?? []
            selectionAnchor = selectedHostID
        }
    }
    /// Every selected host card (⌘-click, ⇧-click). Host Details shows only while exactly one is selected.
    public private(set) var selectedHostIDs: Set<UUID> = []

    /// How a host card was clicked: plain, ⌘ (toggle) or ⇧ (extend a range from the last clicked).
    public enum ClickModifier: Sendable { case none, toggle, extend }

    @ObservationIgnored private var selectionAnchor: UUID?
    @ObservationIgnored private var isApplyingClick = false

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

    // MARK: Selection

    /// A click on a host card. Plain: that host only (its details open). ⌘: adds or removes it.
    /// ⇧: the hosts from the last plain- or ⌘-clicked one to it, in the shown order (replacing the
    /// selection; without such a host, just this one). Host Details shows while exactly one host is
    /// selected.
    public func click(hostID: UUID, modifier: ClickModifier) {
        var selection = selectedHostIDs
        switch modifier {
        case .none:
            selection = [hostID]
            selectionAnchor = hostID
        case .toggle:
            if selection.remove(hostID) == nil { selection.insert(hostID) }
            selectionAnchor = hostID
        case .extend:
            let order = visibleHosts.map(\.id)
            if let anchor = selectionAnchor, let from = order.firstIndex(of: anchor),
               let to = order.firstIndex(of: hostID) {
                selection = Set(order[min(from, to)...max(from, to)])
            } else {
                selection = [hostID]
                selectionAnchor = hostID
            }
        }
        isApplyingClick = true
        selectedHostIDs = selection
        selectedHostID = selection.count == 1 ? selection.first : nil
        isApplyingClick = false
    }

    /// Whether the card shows as selected.
    public func isHostSelected(_ id: UUID) -> Bool {
        selectedHostIDs.contains(id)
    }

    /// The selected hosts that are shown now (search and tag filter applied), in the shown order.
    public var selectedVisibleHostIDs: [UUID] {
        visibleHosts.map(\.id).filter(selectedHostIDs.contains)
    }

    /// "Open in Workspace" on the right-clicked card: the shown selected hosts, in order, when at least
    /// two are selected and the clicked one is among them; nil otherwise (no such menu item).
    public func workspaceHostIDs(forContextMenuOn id: UUID) -> [UUID]? {
        let ids = selectedVisibleHostIDs
        guard ids.count >= 2, ids.contains(id) else { return nil }
        return ids
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

    /// The group's own default theme id; nil = Default (or a missing or deleted group).
    public func themeID(ofGroup id: UUID) -> String? {
        _ = vault.revision
        return vault.get(HostGroup.self, id: id)?.defaultThemeID
    }

    /// What "Default" resolves to from the group's parents: a theme id this build knows, or nil =
    /// the app default.
    public func inheritedThemeID(ofGroup id: UUID) -> String? {
        _ = vault.revision
        return TerminalThemeResolver.inheritedThemeID(forGroupID: id, groups: vault.all(HostGroup.self))
    }

    /// The theme "Default" draws with for the group: its parents' theme, else the app default
    /// (`appDefaultThemeID`, when this build knows it), else nil = Automatic.
    public func defaultTheme(ofGroup id: UUID, appDefaultThemeID: String?,
                             catalog: TerminalThemeCatalog = .shared) -> TerminalTheme? {
        if let inherited = inheritedThemeID(ofGroup: id), let theme = catalog.theme(id: inherited) { return theme }
        return appDefaultThemeID.flatMap { catalog.theme(id: $0) }
    }

    /// nil = Default. Saves through the vault (syncs). A missing or deleted group is left alone.
    public func setTheme(_ themeID: String?, forGroup id: UUID) async throws {
        guard var group = vault.get(HostGroup.self, id: id), group.defaultThemeID != themeID else { return }
        group.defaultThemeID = themeID
        try await vault.save(group)
    }

    // MARK: Attach to tmux

    /// The group's own choice; `.inherit` for none (or a missing or deleted group).
    public func tmuxChoice(ofGroup id: UUID) -> TmuxChoice {
        _ = vault.revision
        return vault.get(HostGroup.self, id: id)?.defaultTmuxSession ?? .inherit
    }

    /// What "Default" means for the group: its parents' choice, e.g. "Default (group: on, ops)".
    public func inheritedTmuxSummary(ofGroup id: UUID) -> String {
        _ = vault.revision
        let directory = HostDirectory(hosts: [], groups: vault.all(HostGroup.self))
        let parentID = vault.get(HostGroup.self, id: id)?.parentID
        return TmuxLabels.defaultSummary(directory.inheritedTmux(fromGroup: parentID))
    }

    /// `.inherit` is stored as nil. A session name is trimmed and must pass
    /// `TmuxChoice.isValidSessionName`, else `HostsError.invalidTmuxSessionName` is thrown and nothing
    /// is saved. Saves through the vault (syncs) only when it changes; a missing group is left alone.
    public func setTmux(_ choice: TmuxChoice, forGroup id: UUID) async throws {
        let stored: TmuxChoice?
        switch choice {
        case .inherit: stored = nil
        case .off: stored = .off
        case .session(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard TmuxChoice.isValidSessionName(trimmed) else { throw HostsError.invalidTmuxSessionName }
            stored = .session(trimmed)
        }
        guard var group = vault.get(HostGroup.self, id: id), group.defaultTmuxSession != stored else { return }
        group.defaultTmuxSession = stored
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
