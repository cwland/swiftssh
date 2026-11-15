import Foundation
import Observation

public enum SidebarItem: String, CaseIterable, Sendable {
    case hosts, keychain, snippets, knownHosts, logs
}

public enum TopTab: Hashable, Sendable {
    case vaults
}

@MainActor @Observable
public final class AppNavigation {
    public var sidebar: SidebarItem = .hosts
    /// A snippet the Snippets screen should select when it next shows (Edit / New Snippet from a
    /// terminal's snippets panel); the screen clears it once taken.
    public var snippetToSelect: UUID?
    public var tabs: [TopTab] = [.vaults]
    public var selectedTab: TopTab = .vaults

    public init() {}
}
