import Foundation
import Observation
import CoreModels

/// The iPhone/iPad app's sections: the iPad sidebar, and the screens the iPhone pushes from Hosts.
public enum CompanionSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case hosts, snippets, knownHosts, keys, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hosts: "Hosts"
        case .snippets: "Snippets"
        case .knownHosts: "Known Hosts"
        case .keys: "Keys"
        case .settings: "Settings"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .hosts: "server.rack"
        case .snippets: "text.alignleft"
        case .knownHosts: "checkmark.shield"
        case .keys: "key"
        case .settings: "gearshape"
        }
    }
}

/// The numbers beside the iPad sidebar's sections: live records from the vault (as the Mac's
/// `SidebarCounts`) and the keys imported on this device. Settings has none.
public struct CompanionSidebarCounts: Equatable, Sendable {
    public let hosts: Int
    public let snippets: Int
    public let knownHosts: Int
    public let keys: Int

    @MainActor
    public init(vault: LocalVault, importedKeyCount: Int) {
        let counts = SidebarCounts(vault: vault)
        hosts = counts.hosts
        snippets = counts.snippets
        knownHosts = counts.knownHosts
        keys = importedKeyCount
    }

    public func count(for section: CompanionSection) -> Int? {
        switch section {
        case .hosts: hosts
        case .snippets: snippets
        case .knownHosts: knownHosts
        case .keys: keys
        case .settings: nil
        }
    }
}

/// Where the iPhone/iPad app is: the section shown (iPad sidebar selection; on iPhone the screen
/// pushed over Hosts, `phonePath`), and requests from keyboard shortcuts and other screens (search
/// the hosts, quick connect, import a key). Sessions are selected through `SessionManager`
/// (`selectedTabID` nil = these screens).
@MainActor @Observable
public final class CompanionNavigation {
    public var section: CompanionSection = .hosts
    /// The iPhone navigation stack over Hosts: empty, or the one section shown.
    public var phonePath: [CompanionSection] = []
    /// ⌘K: the quick connect sheet is up.
    public var isQuickConnectShown = false
    /// Bumped by ⌘F; the Hosts screen focuses its search field on each change.
    public private(set) var searchRequests = 0

    public init() {}

    /// Shows `section` (on iPhone: pushes it over Hosts, or pops back to Hosts).
    public func show(_ section: CompanionSection) {
        self.section = section
        phonePath = section == .hosts ? [] : [section]
    }

    /// ⌘F: shows Hosts and asks it to focus its search field.
    public func requestSearch() {
        show(.hosts)
        searchRequests += 1
    }
}
