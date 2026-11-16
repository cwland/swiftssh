import Foundation
import CoreModels

/// What a terminal tab draws with: the resolved theme, the text size in points, the font family
/// (nil = SF Mono) and the behaviour settings. `TerminalSettings.appearance(theme:)` fills all four.
public struct TerminalAppearance: Equatable, Sendable {
    public var theme: TerminalTheme
    public var fontSize: Int
    public var fontName: String?
    public var behaviour: TerminalBehaviour

    public init(theme: TerminalTheme, fontSize: Int, fontName: String? = nil,
                behaviour: TerminalBehaviour = TerminalBehaviour()) {
        self.theme = theme
        self.fontSize = fontSize
        self.fontName = fontName
        self.behaviour = behaviour
    }
}

/// Picks a tab's theme: the host's own, then its groups' up the parent chain, then the app default,
/// then Automatic. Ids this build's catalog doesn't know (a newer build on another Mac, a removed
/// theme) are skipped, so resolution never breaks. Pure; cheap enough to run in a view's body.
public enum TerminalThemeResolver {
    /// First id in the host's chain that the catalog knows, else `defaultThemeID` if known,
    /// else `catalog.automatic(prefersDark:)`. A nil, missing or deleted host uses the default.
    public static func theme(forHostID hostID: UUID?, hosts: [SavedHost], groups: [HostGroup],
                             defaultThemeID: String?, prefersDark: Bool,
                             catalog: TerminalThemeCatalog = .shared) -> TerminalTheme {
        if let hostID, let host = liveHost(hostID, in: hosts),
           let known = firstKnown(HostDirectory(hosts: hosts, groups: groups).themeIDChain(for: host), catalog) {
            return known
        }
        if let defaultThemeID, let theme = catalog.theme(id: defaultThemeID) { return theme }
        return catalog.automatic(prefersDark: prefersDark)
    }

    /// The first id in the chain of the host's *group* (the host's own id ignored) that the
    /// catalog knows; nil = the app default. For "Default (…)" labels.
    public static func inheritedThemeID(forHostID hostID: UUID, hosts: [SavedHost], groups: [HostGroup],
                                        catalog: TerminalThemeCatalog = .shared) -> String? {
        guard var host = liveHost(hostID, in: hosts) else { return nil }
        host.themeID = nil
        return firstKnown(HostDirectory(hosts: hosts, groups: groups).themeIDChain(for: host), catalog)?.id
    }

    /// The same for a group: the first known id among its *parents* (its own ignored).
    /// Missing or deleted groups give nil; a cycle back to the group stops the walk.
    public static func inheritedThemeID(forGroupID groupID: UUID, groups: [HostGroup],
                                        catalog: TerminalThemeCatalog = .shared) -> String? {
        let live = Dictionary(groups.filter { !$0.deleted }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let group = live[groupID] else { return nil }
        var visited: Set<UUID> = [groupID]
        var next = group.parentID
        while let id = next, visited.insert(id).inserted, let parent = live[id] {
            if let themeID = parent.defaultThemeID, catalog.contains(themeID) { return themeID }
            next = parent.parentID
        }
        return nil
    }

    private static func liveHost(_ id: UUID, in hosts: [SavedHost]) -> SavedHost? {
        hosts.first { $0.id == id && !$0.deleted }
    }

    private static func firstKnown(_ chain: [String], _ catalog: TerminalThemeCatalog) -> TerminalTheme? {
        chain.lazy.compactMap { catalog.theme(id: $0) }.first
    }
}
