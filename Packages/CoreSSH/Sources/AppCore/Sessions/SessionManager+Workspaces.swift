import Foundation

/// One tab bar item: a plain terminal tab or a workspace.
public enum StripItem: Identifiable, Equatable, Hashable, Sendable {
    case tab(UUID), workspace(UUID)

    public var id: UUID {
        switch self {
        case .tab(let id), .workspace(let id): id
        }
    }
}

/// Why a workspace could not be made or opened.
public enum WorkspaceError: Error, Equatable, LocalizedError {
    /// A workspace needs at least 2 panes.
    case notEnoughPanes
    /// A workspace holds at most 16 panes.
    case tooManyPanes
    case unknownTab
    case unknownWorkspace

    public var errorDescription: String? {
        switch self {
        case .notEnoughPanes: "A workspace needs at least 2 terminals."
        case .tooManyPanes: "A workspace holds at most 16 terminals."
        case .unknownTab: "That terminal is no longer open."
        case .unknownWorkspace: "That workspace is no longer open."
        }
    }
}

/// Workspaces: 2–16 tabs of one window shown together as one tab bar item.
///
/// Order: a workspace's panes stay in `tabs`, together, in reading order, at the workspace's place, so
/// `strip(inWindow:)` (derived from `tabs`) lists a workspace where its first pane sits. Every change
/// that adds, removes or reorders panes rewrites the window's order that way (`applyOrder`).
///
/// Dissolving: a workspace left with one pane (closing or popping out a pane, or a pane taken into
/// another workspace) becomes that plain tab, at the workspace's place, selected if the workspace was.
///
/// Broadcast: typed input (`sendInput`) and snippets (`deliver`) from the focused pane of a broadcasting
/// workspace also go to each other pane of that workspace that is included and connected. Never to a
/// pane of another workspace, a plain tab, or another window.
extension SessionManager {
    // MARK: Lookup

    /// The window's tab bar items in order; a workspace's panes are not listed on their own.
    public func strip(inWindow windowID: UUID?) -> [StripItem] {
        var items: [StripItem] = []
        var listed: Set<UUID> = []
        for tab in tabs where tab.windowID == windowID {
            if let workspace = workspace(containing: tab.id) {
                if listed.insert(workspace.id).inserted { items.append(.workspace(workspace.id)) }
            } else {
                items.append(.tab(tab.id))
            }
        }
        return items
    }

    /// The window's selected strip item; nil = Vaults.
    public func selectedItem(inWindow windowID: UUID?) -> StripItem? {
        guard let id = selections[windowID] else { return nil }
        return workspacesByID[id] != nil ? .workspace(id) : .tab(id)
    }

    public func workspace(_ id: UUID) -> Workspace? { workspacesByID[id] }

    public func workspace(containing tabID: UUID) -> Workspace? {
        workspacesByID.values.first { $0.contains(tabID) }
    }

    // MARK: Making workspaces

    /// A workspace of open tabs (2–16, each once, all plain tabs of the same window), in a balanced
    /// layout in the given order, focused on the first. It takes the first tab's place in the strip and
    /// is selected. Nil, changing nothing, when the tabs don't qualify.
    @discardableResult
    public func makeWorkspace(from tabIDs: [UUID], name: String?) -> Workspace? {
        guard Workspace.paneLimit.contains(tabIDs.count), Set(tabIDs).count == tabIDs.count else { return nil }
        let members = tabIDs.compactMap { tab($0) }
        guard members.count == tabIDs.count else { return nil }
        let window = members[0].windowID
        guard members.allSatisfy({ $0.windowID == window && self.workspace(containing: $0.id) == nil }) else { return nil }
        var items = strip(inWindow: window)
        let workspace = register(Workspace(name: Self.workspaceName(name), root: PaneNode.balanced(tabIDs)!,
                                           focusedPaneID: tabIDs[0], windowID: window))
        let others = Set(tabIDs.dropFirst())
        items = items.compactMap { item in
            if item == .tab(tabIDs[0]) { return .workspace(workspace.id) }
            return others.contains(item.id) ? nil : item
        }
        applyOrder(items, inWindow: window)
        selections[window] = workspace.id
        return workspace
    }

    /// Opens a new connection per host (in order; a host may appear more than once) as a workspace in a
    /// balanced layout at the end of the main window's strip, selected. Every host is planned first: when
    /// one can't be, its error is thrown and nothing opens. Throws `WorkspaceError` for fewer than 2 or
    /// more than 16 hosts.
    @discardableResult
    public func openWorkspace(hostIDs: [UUID], name: String?) throws -> Workspace {
        try openWorkspace(hostIDs: hostIDs, name: name, inWindow: nil)
    }

    /// The same in the window `windowID`.
    @discardableResult
    public func openWorkspace(hostIDs: [UUID], name: String?, inWindow windowID: UUID?) throws -> Workspace {
        try Self.checkPaneCount(hostIDs.count)
        let plans = try hostIDs.map { try plan(hostID: $0) }
        let panes = zip(hostIDs, plans).map { appendTab(hostID: $0, plan: $1, inWindow: windowID) }
        let ids = panes.map(\.id)
        let workspace = register(Workspace(name: Self.workspaceName(name), root: PaneNode.balanced(ids)!,
                                           focusedPaneID: ids[0], windowID: windowID))
        normalizeOrder(inWindow: windowID)
        selections[windowID] = workspace.id
        return workspace
    }

    /// Opens a saved workspace in the main window: one new connection per pane, with its layout,
    /// ratios, view mode, name and tab titles, selected and with no unsaved changes. A pane whose saved
    /// host is gone opens disconnected (showing why); a pane with neither a host nor a quick connect
    /// target that parses is left out. Throws `WorkspaceError` (nothing opens) when fewer than 2 or more
    /// than 16 panes are left.
    @discardableResult
    public func openTemplate(_ template: WorkspaceTemplate) throws -> Workspace {
        try openTemplate(template, inWindow: nil)
    }

    /// The same in the window `windowID`.
    @discardableResult
    public func openTemplate(_ template: WorkspaceTemplate, inWindow windowID: UUID?) throws -> Workspace {
        let usable = template.layout.panes.filter { Self.isUsable($0) }
        try Self.checkPaneCount(usable.count)
        var skipped = false
        guard let root = buildRoot(template.layout, inWindow: windowID, skipped: &skipped) else {
            throw WorkspaceError.notEnoughPanes // unreachable: usable panes were counted
        }
        let workspace = register(Workspace(name: Self.workspaceName(template.name), root: root,
                                           viewMode: template.viewMode, focusedPaneID: root.paneIDs[0],
                                           windowID: windowID))
        workspace.templateID = template.id
        if !skipped { workspace.markSaved() }
        normalizeOrder(inWindow: windowID)
        selections[windowID] = workspace.id
        return workspace
    }

    private nonisolated static func isUsable(_ pane: TemplatePane) -> Bool {
        pane.hostID != nil || pane.quickConnect.flatMap(QuickConnect.parse) != nil
    }

    /// Opens the template's usable panes and returns their tree (ratios clamped); nil when none is usable.
    private func buildRoot(_ node: TemplateNode, inWindow windowID: UUID?, skipped: inout Bool) -> PaneNode? {
        switch node {
        case .pane(let pane):
            let tab: TerminalTab
            if let hostID = pane.hostID {
                tab = appendTab(hostID: hostID, fallbackTitle: pane.title ?? "Missing host", inWindow: windowID)
            } else if let target = pane.quickConnect.flatMap(QuickConnect.parse) {
                tab = appendTab(quickConnect: target, inWindow: windowID)
            } else {
                skipped = true
                return nil
            }
            if let title = pane.title { rename(tabID: tab.id, to: title) }
            return .pane(tab.id)
        case .split(let axis, let ratio, let first, let second):
            let f = buildRoot(first, inWindow: windowID, skipped: &skipped)
            let s = buildRoot(second, inWindow: windowID, skipped: &skipped)
            switch (f, s) {
            case (let f?, let s?): return .split(axis, ratio: PaneNode.clamped(ratio) ?? 0.5, f, s)
            case (let only?, nil), (nil, let only?): return only
            case (nil, nil): return nil
            }
        }
    }

    /// Splits a plain tab: it becomes a workspace (at its place, selected) with a new connection to the
    /// same host or quick connect target on its `edge` half, focused. A pane is split inside its own
    /// workspace. Throws `WorkspaceError` for an unknown tab or a full workspace.
    @discardableResult
    public func splitTab(_ tabID: UUID, at edge: DropEdge) throws -> Workspace {
        guard let source = tab(tabID) else { throw WorkspaceError.unknownTab }
        let window = source.windowID
        if let workspace = workspace(containing: tabID) {
            guard workspace.paneIDs.count < Workspace.paneLimit.upperBound else { throw WorkspaceError.tooManyPanes }
            let items = strip(inWindow: window)
            let copy = appendCopy(of: source)
            workspace.setRoot(workspace.root.inserting(copy.id, beside: tabID, at: edge))
            workspace.focusedPaneID = copy.id
            applyOrder(items, inWindow: window)
            return workspace
        }
        var items = strip(inWindow: window)
        let copy = appendCopy(of: source)
        let workspace = register(Workspace(name: Workspace.defaultName,
                                           root: PaneNode.pane(tabID).inserting(copy.id, beside: tabID, at: edge),
                                           focusedPaneID: copy.id, windowID: window))
        items = items.map { $0 == .tab(tabID) ? .workspace(workspace.id) : $0 }
        applyOrder(items, inWindow: window)
        selections[window] = workspace.id
        return workspace
    }

    // MARK: Adding and moving panes

    /// Moves an open tab of the workspace's window into the workspace beside the pane `target`, on its
    /// `edge` half, focused; it leaves the strip (a selected tab hands the selection to the workspace).
    /// A pane of the same workspace is moved (`movePane`); a pane of another workspace leaves that one
    /// (the dissolve rule applies there). Ignored for unknown ids, another window, or a full workspace.
    public func addPane(tabID: UUID, to workspaceID: UUID, beside target: UUID, at edge: DropEdge) {
        guard let workspace = workspacesByID[workspaceID], let tab = tab(tabID), workspace.contains(target),
              tab.windowID == workspace.windowID else { return }
        if workspace.contains(tabID) {
            movePane(tabID, beside: target, at: edge, in: workspaceID)
            return
        }
        guard workspace.paneIDs.count < Workspace.paneLimit.upperBound else { return }
        let window = workspace.windowID
        if let other = self.workspace(containing: tabID) { takePane(tabID, outOf: other) }
        let wasSelected = selections[window] == tabID
        let items = strip(inWindow: window).filter { $0 != .tab(tabID) }
        workspace.setRoot(workspace.root.inserting(tabID, beside: target, at: edge))
        workspace.focusedPaneID = tabID
        applyOrder(items, inWindow: window)
        if wasSelected { selections[window] = workspace.id }
    }

    /// Opens a new connection to the host in the workspace beside the pane `target`, on its `edge` half,
    /// focused. Throws the planner's error, or `WorkspaceError` (unknown workspace or target, full).
    public func addPane(hostID: UUID, to workspaceID: UUID, beside target: UUID, at edge: DropEdge) throws {
        guard let workspace = workspacesByID[workspaceID] else { throw WorkspaceError.unknownWorkspace }
        guard workspace.contains(target) else { throw WorkspaceError.unknownTab }
        guard workspace.paneIDs.count < Workspace.paneLimit.upperBound else { throw WorkspaceError.tooManyPanes }
        let plan = try plan(hostID: hostID)
        let window = workspace.windowID
        let items = strip(inWindow: window)
        let tab = appendTab(hostID: hostID, plan: plan, inWindow: window)
        workspace.setRoot(workspace.root.inserting(tab.id, beside: target, at: edge))
        workspace.focusedPaneID = tab.id
        applyOrder(items, inWindow: window)
    }

    /// Hosts screen "Add to Workspace": a new connection to the host in the workspace, beside its
    /// focused pane (right half), focused, with the workspace shown in its window. Throws as
    /// `addPane(hostID:to:beside:at:)` does.
    @discardableResult
    public func addHost(_ hostID: UUID, toWorkspace workspaceID: UUID) throws -> TerminalTab {
        guard let workspace = workspacesByID[workspaceID] else { throw WorkspaceError.unknownWorkspace }
        try addPane(hostID: hostID, to: workspaceID, beside: workspace.focusedPaneID, at: .right)
        selections[workspace.windowID] = workspace.id
        guard let tab = tab(workspace.focusedPaneID) else { throw WorkspaceError.unknownTab }
        return tab
    }

    /// The window's workspaces, in tab bar order.
    public func workspaces(inWindow windowID: UUID?) -> [Workspace] {
        strip(inWindow: windowID).compactMap { item in
            if case .workspace(let id) = item { return workspacesByID[id] }
            return nil
        }
    }

    /// Moves a pane beside another pane of the same workspace. Ignored for unknown ids.
    public func movePane(_ paneID: UUID, beside target: UUID, at edge: DropEdge, in workspaceID: UUID) {
        guard let workspace = workspacesByID[workspaceID], workspace.contains(paneID), workspace.contains(target) else { return }
        workspace.setRoot(workspace.root.moving(paneID, beside: target, at: edge))
        normalizeOrder(inWindow: workspace.windowID)
    }

    /// Moves a pane to `index` in reading order (clamped), keeping the layout's shape and ratios: the
    /// panes trade places (Focus mode's list reorder). Ignored for unknown ids.
    public func movePane(_ paneID: UUID, toIndex index: Int, in workspaceID: UUID) {
        guard let workspace = workspacesByID[workspaceID] else { return }
        var ids = workspace.paneIDs
        guard let from = ids.firstIndex(of: paneID) else { return }
        ids.remove(at: from)
        ids.insert(paneID, at: max(0, min(index, ids.count)))
        workspace.setRoot(workspace.root.reordered(ids))
        normalizeOrder(inWindow: workspace.windowID)
    }

    /// Sets the ratio of the split at `path` (see `PaneNode.settingRatio`).
    public func setRatio(_ ratio: Double, atPath path: [Int], in workspaceID: UUID) {
        guard let workspace = workspacesByID[workspaceID] else { return }
        workspace.setRoot(workspace.root.settingRatio(ratio, atPath: path))
    }

    /// A blank name becomes "Workspace".
    public func renameWorkspace(_ id: UUID, to name: String) {
        workspacesByID[id]?.name = Self.workspaceName(name)
    }

    // MARK: Removing panes

    /// Moves the pane to its own tab right after its workspace, selected; its session keeps running.
    /// The dissolve rule applies. Ignored for a tab that is not a pane.
    public func popOutPane(_ paneID: UUID) {
        guard let workspace = workspace(containing: paneID) else { return }
        let window = workspace.windowID
        var items = strip(inWindow: window)
        guard let place = items.firstIndex(of: .workspace(workspace.id)) else { return }
        let remaining = takePane(paneID, outOf: workspace)
        if let remaining { items[place] = .tab(remaining) }
        items.insert(.tab(paneID), at: place + 1)
        applyOrder(items, inWindow: window)
        selections[window] = paneID
    }

    /// Ends the pane's session and removes it (as `close(tabID:)`); the dissolve rule applies.
    public func closePane(_ paneID: UUID) {
        close(tabID: paneID)
    }

    /// Ends every session of the workspace and removes it; if it was selected, the strip item that took
    /// its place (else the one before it, else Vaults) is selected.
    public func closeWorkspace(_ id: UUID) {
        guard let workspace = workspacesByID[id] else { return }
        let window = workspace.windowID
        let place = strip(inWindow: window).firstIndex(of: .workspace(id))
        let panes = tabs.filter { workspace.contains($0.id) }
        workspacesByID[id] = nil
        tabs.removeAll { workspace.contains($0.id) }
        for pane in panes { endSession(of: pane) }
        reselect(afterRemoving: id, at: place, inWindow: window)
    }

    /// `close(tabID:)` of a pane: removes the tab, ends its session, applies the dissolve rule.
    func removeClosedPane(_ tab: TerminalTab, from workspace: Workspace) {
        takePane(tab.id, outOf: workspace)
        tabs.removeAll { $0 === tab }
        endSession(of: tab)
    }

    /// Takes the pane out of the workspace's layout. Left with one pane, the workspace dissolves into
    /// that tab (it keeps its place in `tabs`, so the strip shows it where the workspace was, and it
    /// takes over the workspace's selection); returns its id then.
    @discardableResult
    private func takePane(_ paneID: UUID, outOf workspace: Workspace) -> UUID? {
        guard let newRoot = workspace.root.removing(paneID) else {
            workspacesByID[workspace.id] = nil
            return nil
        }
        workspace.setRoot(newRoot)
        guard workspace.paneIDs.count == 1, let remaining = workspace.paneIDs.first else { return nil }
        workspacesByID[workspace.id] = nil
        if selections[workspace.windowID] == workspace.id { selections[workspace.windowID] = remaining }
        return remaining
    }

    // MARK: Focus, view mode, broadcast, status

    /// Focuses the pane (keyboard input goes there) and clears its new-output dot.
    public func focusPane(_ paneID: UUID) {
        guard let workspace = workspace(containing: paneID) else { return }
        if workspace.focusedPaneID != paneID { workspace.focusedPaneID = paneID }
    }

    public func setViewMode(_ mode: Workspace.ViewMode, for workspaceID: UUID) {
        guard let workspace = workspacesByID[workspaceID], workspace.viewMode != mode else { return }
        workspace.viewMode = mode
    }

    public func toggleBroadcast(in workspaceID: UUID) {
        guard let workspace = workspacesByID[workspaceID] else { return }
        workspace.setBroadcasting(!workspace.isBroadcasting)
    }

    public func setPane(_ paneID: UUID, includedInBroadcast: Bool) {
        workspace(containing: paneID)?.setIncluded(paneID, includedInBroadcast)
    }

    /// The one entry point for typed input. When the tab is the focused pane of a broadcasting workspace
    /// and is itself included, the bytes also go to the workspace's other included, connected panes (same
    /// window by construction, checked again). Otherwise exactly `send(tabID:_:)`.
    public func sendInput(fromTab tabID: UUID, _ bytes: [UInt8]) {
        send(tabID: tabID, bytes)
        for target in broadcastTargets(fromTab: tabID) { sendIfConnected(tabID: target, bytes) }
    }

    /// The other panes broadcast input from `tabID` reaches now (not yet checked for being connected);
    /// empty unless `tabID` is the included, focused pane of a broadcasting workspace.
    func broadcastTargets(fromTab tabID: UUID) -> [UUID] {
        guard let workspace = workspace(containing: tabID), workspace.isBroadcasting,
              workspace.focusedPaneID == tabID, workspace.isIncludedInBroadcast(tabID),
              let source = tab(tabID) else { return [] }
        return workspace.paneIDs.filter { id in
            id != tabID && workspace.isIncludedInBroadcast(id) && tab(id)?.windowID == source.windowID
        }
    }

    /// Marks a pane's new output (green dot) unless it is focused. Called for every output chunk of a
    /// session (also by the manager itself); cheap and idempotent.
    public func noteOutput(tabID: UUID) {
        guard !workspacesByID.isEmpty else { return }
        workspace(containing: tabID)?.noteOutput(tabID)
    }

    // MARK: Snippets in a workspace

    /// "Run in all panes": delivers `text` to every connected pane of the workspace that is included in
    /// broadcast (excluded panes are left alone). Returns how many panes it was typed into.
    @discardableResult
    public func deliverToAllPanes(_ text: String, as delivery: SnippetDelivery, inWorkspace workspaceID: UUID) -> Int {
        guard let workspace = workspacesByID[workspaceID] else { return 0 }
        let typed = Array(Self.deliveryText(text, as: delivery).utf8)
        return workspace.paneIDs.filter { id in
            workspace.isIncludedInBroadcast(id) && (typed.isEmpty ? isConnected(id) : sendIfConnected(tabID: id, typed))
        }.count
    }

    /// How many panes `deliverToAllPanes` would type into now.
    public func connectablePaneCount(inWorkspace workspaceID: UUID) -> Int {
        guard let workspace = workspacesByID[workspaceID] else { return 0 }
        return workspace.paneIDs.filter { workspace.isIncludedInBroadcast($0) && isConnected($0) }.count
    }

    private func isConnected(_ tabID: UUID) -> Bool {
        tab(tabID)?.state == .connected
    }

    // MARK: Order

    /// Rewrites the window's order in `tabs` to `items` (a workspace: its panes in reading order); the
    /// window's tabs fill the same places in `tabs`. Ignored unless `items` covers the window's tabs.
    func applyOrder(_ items: [StripItem], inWindow windowID: UUID?) {
        var ordered: [TerminalTab] = []
        for item in items {
            switch item {
            case .tab(let id):
                if let tab = tab(id) { ordered.append(tab) }
            case .workspace(let id):
                guard let workspace = workspacesByID[id] else { continue }
                ordered += workspace.paneIDs.compactMap { tab($0) }
            }
        }
        let current = tabs(inWindow: windowID)
        guard ordered.count == current.count, Set(ordered.map(\.id)) == Set(current.map(\.id)) else { return }
        guard ordered.map(\.id) != current.map(\.id) else { return }
        var next = ordered.makeIterator()
        tabs = tabs.map { $0.windowID == windowID ? next.next()! : $0 }
    }

    /// Puts every workspace's panes of the window together, in reading order, where the strip shows it.
    func normalizeOrder(inWindow windowID: UUID?) {
        applyOrder(strip(inWindow: windowID), inWindow: windowID)
    }

    private func register(_ workspace: Workspace) -> Workspace {
        workspace.sessions = self
        workspacesByID[workspace.id] = workspace
        return workspace
    }

    private static func workspaceName(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? Workspace.defaultName : trimmed
    }

    private static func checkPaneCount(_ count: Int) throws {
        if count < Workspace.paneLimit.lowerBound { throw WorkspaceError.notEnoughPanes }
        if count > Workspace.paneLimit.upperBound { throw WorkspaceError.tooManyPanes }
    }
}

extension TemplateNode {
    /// The saved panes in reading order.
    var panes: [TemplatePane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }
}
