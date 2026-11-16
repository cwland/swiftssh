import Foundation
import CoreModels

/// The numbers beside the sidebar's sections: live (not deleted) records of each kind, counted in
/// one pass over the vault's records without decoding them. Keychain counts identities and keys
/// together. Known Hosts has no number until its screen exists (it shows a placeholder).
///
/// Make one per render (`init` does the counting) and read every section from it. Reading it in
/// a view's body tracks the vault, so the numbers follow changes.
public struct SidebarCounts: Equatable, Sendable {
    public let hosts: Int
    public let keychain: Int
    public let snippets: Int
    public let logs: Int

    @MainActor
    public init(vault: LocalVault) {
        let live = vault.liveCounts()
        hosts = live[.host, default: 0]
        keychain = live[.identity, default: 0] + live[.sshKey, default: 0]
        snippets = live[.snippet, default: 0]
        logs = live[.connectionLog, default: 0]
    }

    /// The number shown beside `item`, or nil for none (Known Hosts, whose screen isn't built yet).
    public func count(for item: SidebarItem) -> Int? {
        switch item {
        case .hosts: hosts
        case .keychain: keychain
        case .snippets: snippets
        case .knownHosts: nil
        case .logs: logs
        }
    }
}
