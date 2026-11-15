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

/// A saved layout. Stored as `{"pane": {...}}` or
/// `{"split": {"axis": "horizontal", "ratio": 0.5, "first": ..., "second": ...}}`; a ratio is clamped
/// to 0.1…0.9 when read.
public indirect enum TemplateNode: Codable, Equatable, Sendable {
    case pane(TemplatePane)
    case split(SplitAxis, ratio: Double, TemplateNode, TemplateNode)

    private enum CodingKeys: String, CodingKey { case pane, split }
    private enum SplitKeys: String, CodingKey { case axis, ratio, first, second }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try container.decodeIfPresent(TemplatePane.self, forKey: .pane) {
            self = .pane(pane)
            return
        }
        let split = try container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
        let ratio = try split.decode(Double.self, forKey: .ratio)
        self = .split(try split.decode(SplitAxis.self, forKey: .axis), ratio: PaneNode.clamped(ratio) ?? 0.5,
                      try split.decode(TemplateNode.self, forKey: .first),
                      try split.decode(TemplateNode.self, forKey: .second))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode(pane, forKey: .pane)
        case .split(let axis, let ratio, let first, let second):
            var split = container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            try split.encode(axis, forKey: .axis)
            try split.encode(ratio, forKey: .ratio)
            try split.encode(first, forKey: .first)
            try split.encode(second, forKey: .second)
        }
    }
}

/// A saved pane: a saved host, or a quick connect target as `user@host:port` (`QuickConnect.parse`
/// reads it back), and its tab title (the custom title; nil = the host's label).
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

/// Saved workspaces in one JSON file (Application Support on this Mac; the app passes the URL). A file
/// that can't be read starts the store empty and is kept beside it as `<name>.corrupt` when the store
/// next writes; a template entry that can't be read is skipped.
@MainActor @Observable
public final class WorkspaceTemplateStore {
    public private(set) var templates: [WorkspaceTemplate] = []
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var fileIsCorrupt = false

    private struct FileContents: Codable {
        var version: Int
        var templates: [Lenient]
    }

    /// A template, or nil for an entry that can't be read.
    private struct Lenient: Codable {
        var template: WorkspaceTemplate?

        init(_ template: WorkspaceTemplate) { self.template = template }

        init(from decoder: any Decoder) throws {
            template = try? WorkspaceTemplate(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            try template?.encode(to: encoder)
        }
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            templates = try JSONDecoder().decode(FileContents.self, from: data).templates.compactMap(\.template)
        } catch {
            fileIsCorrupt = true
        }
    }

    /// Saves the workspace: over its template (`templateID`) when that is still saved, else as a new one.
    /// The workspace then has the template's id and no unsaved changes. Throws when the file can't be
    /// written (nothing changes then).
    @discardableResult
    public func save(_ workspace: Workspace, sessions: SessionManager) throws -> WorkspaceTemplate {
        let template = WorkspaceTemplate(id: workspace.templateID ?? UUID(), name: workspace.name,
                                         layout: Self.layout(of: workspace.root, sessions: sessions),
                                         viewMode: workspace.viewMode, savedAt: Date())
        var updated = templates
        if let index = updated.firstIndex(where: { $0.id == template.id }) {
            updated[index] = template
        } else {
            updated.append(template)
        }
        try write(updated)
        workspace.templateID = template.id
        workspace.markSaved()
        return template
    }

    /// Renames a template; a blank name is ignored. Unknown ids are ignored.
    public func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = templates.firstIndex(where: { $0.id == id }),
              templates[index].name != trimmed else { return }
        var updated = templates
        updated[index].name = trimmed
        try write(updated)
    }

    /// Deletes a template. Unknown ids are ignored. Open workspaces made from it are left alone.
    public func delete(_ id: UUID) throws {
        guard templates.contains(where: { $0.id == id }) else { return }
        try write(templates.filter { $0.id != id })
    }

    public func template(_ id: UUID) -> WorkspaceTemplate? {
        templates.first { $0.id == id }
    }

    private func write(_ updated: [WorkspaceTemplate]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileIsCorrupt {
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileContents(version: 1, templates: updated.map(Lenient.init)))
        try data.write(to: fileURL, options: .atomic)
        fileIsCorrupt = false
        templates = updated
    }

    private static func layout(of node: PaneNode, sessions: SessionManager) -> TemplateNode {
        switch node {
        case .pane(let id):
            let tab = sessions.tab(id)
            return .pane(TemplatePane(hostID: tab?.savedHostID,
                                      quickConnect: tab?.quickConnectTarget.map { Self.quickConnectText($0) },
                                      title: tab?.customTitle))
        case .split(let axis, let ratio, let first, let second):
            return .split(axis, ratio: ratio, layout(of: first, sessions: sessions), layout(of: second, sessions: sessions))
        }
    }

    /// `[user@]host[:port]`, an IPv6 host in brackets.
    nonisolated static func quickConnectText(_ target: QuickConnectTarget) -> String {
        var host = target.host
        if host.contains(":") { host = "[\(host)]" }
        var text = target.username.map { "\($0)@" } ?? ""
        text += host
        if let port = target.port { text += ":\(port)" }
        return text
    }
}
