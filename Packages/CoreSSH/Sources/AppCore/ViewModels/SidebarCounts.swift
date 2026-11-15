import Foundation
import CoreModels

/// The numbers beside the sidebar's sections: live (not deleted) records of each kind. Keychain
/// counts identities and keys together. Reads the vault's records without decoding them.
@MainActor
public struct SidebarCounts {
    private let vault: LocalVault

    public init(vault: LocalVault) {
        self.vault = vault
    }

    public func count(for item: SidebarItem) -> Int {
        switch item {
        case .hosts: vault.liveCount(of: [.host])
        case .keychain: vault.liveCount(of: [.identity, .sshKey])
        case .snippets: vault.liveCount(of: [.snippet])
        case .knownHosts: vault.liveCount(of: [.knownHost])
        case .logs: vault.liveCount(of: [.connectionLog])
        }
    }
}
