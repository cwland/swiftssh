import Foundation
import CoreModels
import SSHCore

/// "Show Details" for a host on iPhone/iPad (read-only: hosts are edited on the Mac): where it
/// connects and, in plain words, how it signs in. Never contains a secret: a password is described,
/// never shown; a 1Password reference shows only its item name.
public struct CompanionHostDetails: Equatable, Sendable {
    public let label: String
    public let address: String
    /// The backup address tried when `address` can't be reached; nil = none (or one that would never be
    /// used: blank, or the same as `address`).
    public let fallbackAddress: String?
    public let port: Int
    /// nil = no username (connecting will say so).
    public let username: String?
    /// The host's groups from the top, joined with " › "; nil at the top level.
    public let groupPath: String?
    public let signIn: String

    /// nil when the host is missing or deleted.
    @MainActor
    public init?(hostID: UUID, vault: LocalVault) {
        guard let host = vault.get(SavedHost.self, id: hostID) else { return nil }
        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
        let resolved = CredentialResolution.resolve(host: host, directory: directory, vault: vault)
        let trimmedLabel = host.label.trimmingCharacters(in: .whitespacesAndNewlines)
        label = trimmedLabel.isEmpty ? "Untitled host" : host.label
        address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        fallbackAddress = ConnectionFallback.backupAddress(main: address, backup: host.fallbackAddress)
        port = directory.effectivePort(for: host)
        username = resolved.username
        groupPath = Self.groupPath(of: host, groups: vault.all(HostGroup.self))
        var signIn = Self.method(resolved)
        if let identity = resolved.identity {
            signIn = "Identity \u{201C}\(identity.label)\u{201D}: " + signIn
        }
        self.signIn = signIn
    }

    private static func method(_ resolved: CredentialResolution) -> String {
        if resolved.agentKey != nil {
            return "SSH key from 1Password (uses the keys imported on this device)"
        }
        if let key = resolved.key {
            if key.keyType == .rsa {
                return "SSH key \u{201C}\(key.label)\u{201D} (RSA keys aren\u{2019}t supported on iPhone/iPad yet)"
            }
            return "SSH key \u{201C}\(key.label)\u{201D}"
        }
        if let password = resolved.password {
            if SecretReference.isReference(password) {
                if let item = SecretReference.itemName(password) {
                    return "Password from 1Password (\u{201C}\(item)\u{201D}), filled with AutoFill"
                }
                return "Password from 1Password, filled with AutoFill"
            }
            return "Saved password"
        }
        return "Password, asked when connecting"
    }

    private static func groupPath(of host: SavedHost, groups: [HostGroup]) -> String? {
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = []
        var visited: Set<UUID> = []
        var next = host.groupID
        while let id = next, visited.insert(id).inserted, let group = byID[id] {
            names.append(group.name)
            next = group.parentID
        }
        return names.isEmpty ? nil : names.reversed().joined(separator: " \u{203A} ")
    }
}

extension SecretReference {
    /// The item part of `op://vault/item/[section/]field` (as written: a name or an ID); nil when
    /// `reference` isn't one.
    public static func itemName(_ reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("op://") else { return nil }
        let parts = trimmed.dropFirst("op://".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }
}

/// ⌘K quick connect on iPhone/iPad: hosts whose name or address contains the text, best first:
/// name starts with it, a word of the name starts with it, the name contains it, then the address
/// contains it (A–Z within each). Empty text lists every host A–Z. Deleted hosts never show.
public enum HostQuickFilter {
    public static func matches(_ query: String, in hosts: [SavedHost], limit: Int = 50) -> [SavedHost] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let live = hosts.filter { !$0.deleted }
        let ranked: [(rank: Int, host: SavedHost)] = live.compactMap { host in
            guard let rank = rank(of: host, needle: needle) else { return nil }
            return (rank, host)
        }
        return ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            switch a.host.label.localizedCaseInsensitiveCompare(b.host.label) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.host.id.uuidString < b.host.id.uuidString
            }
        }
        .prefix(max(0, limit))
        .map(\.host)
    }

    private static func rank(of host: SavedHost, needle: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        let label = host.label.lowercased()
        if label.hasPrefix(needle) { return 0 }
        let words = label.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(needle) }) { return 1 }
        if label.contains(needle) { return 2 }
        if host.address.lowercased().contains(needle) { return 3 }
        return nil
    }
}
