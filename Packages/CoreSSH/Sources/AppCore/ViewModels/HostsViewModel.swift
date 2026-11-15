import Foundation
import Observation
import CoreModels

public enum HostsError: Error, Equatable, Sendable, LocalizedError {
    case emptyGroupName
    case invalidTmuxSessionName
    case groupCycle
    case hostNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyGroupName: "A group name can't be empty."
        case .hostNotFound: "The host no longer exists."
        case .groupCycle: "A group can't be moved into itself or one of its own groups."
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
    /// The host whose Host Details panel is open: opened only by `edit(hostID:)` (the card's pencil,
    /// Edit Host Details, E) or New host, never by a click. Opening it makes that host the only
    /// selected one; closing it keeps the selection.
    public private(set) var editingHostID: UUID?
    /// The group whose Group panel is open (its pencil or Edit Group). One panel at a time.
    public private(set) var editingGroupID: UUID?
    /// Every selected host card (click, ⌘-click, ⇧-click).
    public private(set) var selectedHostIDs: Set<UUID> = []
    /// The highlighted group card (a click); selecting hosts clears it.
    public private(set) var selectedGroupID: UUID?

    /// How a host card was clicked: plain, ⌘ (toggle) or ⇧ (extend a range from the last clicked).
    public enum ClickModifier: Sendable { case none, toggle, extend }

    @ObservationIgnored private var selectionAnchor: UUID?

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

    /// The host whose details are open, nil if none or it is missing or deleted.
    public var editingHost: SavedHost? {
        _ = vault.revision
        return editingHostID.flatMap { vault.get(SavedHost.self, id: $0) }
    }

    /// The group whose panel is open, nil if none or it is missing or deleted.
    public var editingGroup: HostGroup? {
        _ = vault.revision
        return editingGroupID.flatMap { vault.get(HostGroup.self, id: $0) }
    }

    /// Opens Host Details for the host and makes it the only selected one.
    public func edit(hostID: UUID) {
        editingGroupID = nil
        editingHostID = hostID
        selectedGroupID = nil
        selectedHostIDs = [hostID]
        selectionAnchor = hostID
    }

    /// Opens the group's panel (and highlights the group).
    public func edit(groupID: UUID) {
        editingHostID = nil
        editingGroupID = groupID
        select(groupID: groupID)
    }

    /// Closes whichever panel is open; the selection stays.
    public func closeEditor() {
        editingHostID = nil
        editingGroupID = nil
    }

    /// Nothing selected (another kind of card, e.g. a workspace tile, was clicked); an open panel stays.
    public func clearSelection() {
        selectedHostIDs = []
        selectedGroupID = nil
        selectionAnchor = nil
    }

    /// A click on a group card: highlights it (double-click opens it, `openGroup`).
    public func select(groupID: UUID) {
        selectedGroupID = groupID
        selectedHostIDs = []
        selectionAnchor = nil
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

    /// A click on a host card. Plain: that host only. ⌘: adds or removes it. ⇧: the hosts from the
    /// last plain- or ⌘-clicked one to it, in the shown order (replacing the selection; without such
    /// a host, just this one). A click never opens Host Details (`edit(hostID:)` does).
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
        selectedGroupID = nil
        selectedHostIDs = selection
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
        try await newHost(inGroup: effectiveGroupID)
    }

    /// A new host in `groupID` (nil = top level), with its details open.
    @discardableResult
    public func newHost(inGroup groupID: UUID?) async throws -> SavedHost {
        let host = try await vault.save(SavedHost(label: "New host", address: "", groupID: groupID))
        edit(hostID: host.id)
        return host
    }

    // MARK: Right-click actions

    /// The hosts a right-click on a card acts on: the shown selection when the card is in it, else
    /// just that card.
    public func hostIDs(forContextMenuOn id: UUID) -> [UUID] {
        let selected = selectedVisibleHostIDs
        return selected.contains(id) ? selected : [id]
    }

    /// A copy of the host (all its settings, a new id, "<label> copy", never connected), selected.
    @discardableResult
    public func duplicateHost(id: UUID) async throws -> SavedHost {
        guard var copy = vault.get(SavedHost.self, id: id) else { throw HostsError.hostNotFound }
        copy.id = UUID()
        copy.label = copy.label.isEmpty ? "Untitled host copy" : copy.label + " copy"
        copy.lastConnectedAt = nil
        let saved = try await vault.save(copy)
        click(hostID: saved.id, modifier: .none)
        return saved
    }

    /// Moves the hosts into `groupID` (nil = top level). Missing hosts are skipped.
    public func moveHosts(_ ids: [UUID], toGroup groupID: UUID?) async throws {
        for id in ids {
            guard var host = vault.get(SavedHost.self, id: id), host.groupID != groupID else { continue }
            host.groupID = groupID
            try await vault.save(host)
        }
    }

    /// Deletes the hosts (kept as tombstones, so the deletion syncs); closes their details panel and
    /// drops them from the selection.
    public func removeHosts(_ ids: [UUID]) async throws {
        for id in ids {
            try await vault.delete(SavedHost.self, id: id)
            selectedHostIDs.remove(id)
            if editingHostID == id { editingHostID = nil }
        }
    }

    /// One entry of a "Move to" menu or a parent picker: a group and its path ("Prod › Web").
    public struct GroupDestination: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
    }

    /// Every group, by path, in path order (case-insensitive). With `excludingSubtreeOf`, that group
    /// and the groups below it are left out (where a group can move).
    public func groupDestinations(excludingSubtreeOf excluded: UUID? = nil) -> [GroupDestination] {
        _ = vault.revision
        let groups = vault.all(HostGroup.self)
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func path(_ group: HostGroup) -> [String]? {
            var names: [String] = []
            var current: HostGroup? = group
            var seen: Set<UUID> = []
            while let g = current {
                if g.id == excluded || !seen.insert(g.id).inserted { return nil }
                names.insert(g.name.isEmpty ? "Untitled group" : g.name, at: 0)
                current = g.parentID.flatMap { byID[$0] }
            }
            return names
        }
        return groups.compactMap { group in path(group).map { (group.id, $0) } }
            .sorted { a, b in
                a.1.lexicographicallyPrecedes(b.1) { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
            .map { GroupDestination(id: $0.0, name: $0.1.joined(separator: " \u{203A} ")) }
    }

    /// Makes `parentID` (nil = top level) the group's parent. Throws `HostsError.groupCycle` when
    /// the parent is the group itself or below it.
    public func moveGroup(id: UUID, toParent parentID: UUID?) async throws {
        guard var group = vault.get(HostGroup.self, id: id) else { return }
        if let parentID {
            var current: UUID? = parentID
            var seen: Set<UUID> = []
            while let check = current, seen.insert(check).inserted {
                if check == id { throw HostsError.groupCycle }
                current = vault.get(HostGroup.self, id: check)?.parentID
            }
        }
        guard group.parentID != parentID else { return }
        group.parentID = parentID
        try await vault.save(group)
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

    // MARK: Startup snippet

    /// The group's own startup snippet; nil = Default (also for a deleted snippet or a missing group).
    public func startupSnippetID(ofGroup id: UUID) -> UUID? {
        _ = vault.revision
        guard let snippetID = vault.get(HostGroup.self, id: id)?.startupSnippetID,
              vault.get(Snippet.self, id: snippetID) != nil else { return nil }
        return snippetID
    }

    /// What "Default" means for the group: its parents' snippet, e.g. "Default (from group “Ops”: Update)".
    public func inheritedStartupSnippetSummary(ofGroup id: UUID) -> String {
        _ = vault.revision
        let directory = HostDirectory(hosts: [], groups: vault.all(HostGroup.self))
        let parentID = vault.get(HostGroup.self, id: id)?.parentID
        let inherited = directory.inheritedStartupSnippet(fromGroup: parentID) { vault.get(Snippet.self, id: $0) != nil }
        return StartupSnippetLabels.defaultSummary(
            inherited, snippetName: inherited.flatMap { vault.get(Snippet.self, id: $0.snippetID)?.name })
    }

    /// nil = Default (the parent's). Saves through the vault (syncs) only when it changes; a missing
    /// group is left alone.
    public func setStartupSnippet(_ snippetID: UUID?, forGroup id: UUID) async throws {
        guard var group = vault.get(HostGroup.self, id: id), group.startupSnippetID != snippetID else { return }
        group.startupSnippetID = snippetID
        try await vault.save(group)
    }

    /// Snippets that can be a startup snippet (no placeholders), A–Z.
    public func startupCandidates() -> [Snippet] {
        _ = vault.revision
        return SnippetsViewModel(vault: vault).startupCandidates()
    }

    /// Snippets left out of `startupCandidates()` because they have placeholders.
    public var hiddenStartupSnippetCount: Int {
        _ = vault.revision
        return vault.all(Snippet.self).filter { SnippetTemplate($0.script).hasPlaceholders }.count
    }

    /// Moves the group's hosts and subgroups up one level, then deletes the group.
    public func deleteGroup(id: UUID) async throws {
        try await vault.deleteGroup(id: id)
        if editingGroupID == id { editingGroupID = nil }
        if selectedGroupID == id { selectedGroupID = nil }
    }

    public var quickConnectTarget: QuickConnectTarget? {
        QuickConnect.parse(searchText)
    }

    /// True when the search text is a quick-connect target (`[ssh] [user@]host[:port]`).
    public var canConnect: Bool { quickConnectTarget != nil }
}
