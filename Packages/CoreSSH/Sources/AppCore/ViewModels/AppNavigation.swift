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
    public var tabs: [TopTab] = [.vaults]
    public var selectedTab: TopTab = .vaults

    public init() {}
}
