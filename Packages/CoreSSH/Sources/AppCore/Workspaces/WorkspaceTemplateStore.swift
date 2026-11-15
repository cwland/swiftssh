import Foundation
import Observation

/// A saved workspace (this Mac only, never synced).
public struct WorkspaceTemplate: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var layout: TemplateNode
    public var viewMode: Workspace.ViewMode
    public var savedAt: Date

    public init(id: UUID, name: String, layout: TemplateNode, viewMode: Workspace.ViewMode, savedAt: Date) {
        self.id = id
        self.name = name
        self.layout = layout
        self.viewMode = viewMode
        self.savedAt = savedAt
    }
}

/// A saved layout.
public indirect enum TemplateNode: Codable, Equatable, Sendable {
    case pane(TemplatePane)
    case split(SplitAxis, ratio: Double, TemplateNode, TemplateNode)
}

/// A saved pane: a saved host, or a quick connect target as `user@host:port`, and its tab title.
public struct TemplatePane: Codable, Equatable, Sendable {
    public var hostID: UUID?
    public var quickConnect: String?
    public var title: String?

    public init(hostID: UUID? = nil, quickConnect: String? = nil, title: String? = nil) {
        self.hostID = hostID
        self.quickConnect = quickConnect
        self.title = title
    }
}

/// Saved workspaces in one JSON file (Application Support on this Mac).
@MainActor @Observable
public final class WorkspaceTemplateStore {
    public private(set) var templates: [WorkspaceTemplate] = []
    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    @discardableResult
    public func save(_ workspace: Workspace, sessions: SessionManager) throws -> WorkspaceTemplate {
        WorkspaceTemplate(id: UUID(), name: workspace.name, layout: .pane(TemplatePane()), viewMode: workspace.viewMode,
                          savedAt: Date())
    }

    public func rename(_ id: UUID, to name: String) throws {}

    public func delete(_ id: UUID) throws {}
}
