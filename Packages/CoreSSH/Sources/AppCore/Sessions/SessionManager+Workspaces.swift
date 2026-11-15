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

extension SessionManager {
    public func strip(inWindow windowID: UUID?) -> [StripItem] { tabs(inWindow: windowID).map { .tab($0.id) } }
    public func workspace(_ id: UUID) -> Workspace? { nil }
    public func workspace(containing tabID: UUID) -> Workspace? { nil }
    @discardableResult
    public func makeWorkspace(from tabIDs: [UUID], name: String?) -> Workspace? { nil }
    @discardableResult
    public func openWorkspace(hostIDs: [UUID], name: String?) throws -> Workspace { throw WorkspaceError.notEnoughPanes }
    public func addPane(tabID: UUID, to workspaceID: UUID, beside target: UUID, at edge: DropEdge) {}
    public func addPane(hostID: UUID, to workspaceID: UUID, beside target: UUID, at edge: DropEdge) throws {}
    @discardableResult
    public func splitTab(_ tabID: UUID, at edge: DropEdge) throws -> Workspace { throw WorkspaceError.unknownTab }
    public func movePane(_ paneID: UUID, beside target: UUID, at edge: DropEdge, in workspaceID: UUID) {}
    public func setRatio(_ ratio: Double, atPath path: [Int], in workspaceID: UUID) {}
    public func popOutPane(_ paneID: UUID) {}
    public func closePane(_ paneID: UUID) {}
    public func closeWorkspace(_ id: UUID) {}
    public func focusPane(_ paneID: UUID) {}
    public func setViewMode(_ mode: Workspace.ViewMode, for workspaceID: UUID) {}
    public func toggleBroadcast(in workspaceID: UUID) {}
    public func setPane(_ paneID: UUID, includedInBroadcast: Bool) {}
    public func sendInput(fromTab tabID: UUID, _ bytes: [UInt8]) { send(tabID: tabID, bytes) }
    public func noteOutput(tabID: UUID) {}
    @discardableResult
    public func openTemplate(_ template: WorkspaceTemplate) throws -> Workspace { throw WorkspaceError.notEnoughPanes }

    // Extras beyond the shared API (W1 report documents them).
    public func selectedItem(inWindow windowID: UUID?) -> StripItem? { nil }
    @discardableResult
    public func openWorkspace(hostIDs: [UUID], name: String?, inWindow windowID: UUID?) throws -> Workspace {
        throw WorkspaceError.notEnoughPanes
    }
    @discardableResult
    public func openTemplate(_ template: WorkspaceTemplate, inWindow windowID: UUID?) throws -> Workspace {
        throw WorkspaceError.notEnoughPanes
    }
    public func renameWorkspace(_ id: UUID, to name: String) {}
    public func movePane(_ paneID: UUID, toIndex index: Int, in workspaceID: UUID) {}
    @discardableResult
    public func deliverToAllPanes(_ text: String, as delivery: SnippetDelivery, inWorkspace workspaceID: UUID) -> Int { 0 }
    public func connectablePaneCount(inWorkspace workspaceID: UUID) -> Int { 0 }
}
