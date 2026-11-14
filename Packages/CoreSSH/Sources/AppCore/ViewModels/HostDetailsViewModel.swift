import Foundation
import Observation
import CoreModels

public enum CredentialMode: Sendable, Equatable {
    case identity, direct
}

public enum HostDetailsError: Error, Equatable, Sendable {
    case noReusedCredentials
}

/// Edits one saved host. Every property read comes from the vault and every set saves at once
/// through `LocalVault.saveNow`, applied to the currently stored host, so nothing is kept that
/// could go stale. Once the host is missing or deleted, sets do nothing and `isDeleted` is true.
@MainActor @Observable
public final class HostDetailsViewModel {
    public let hostID: UUID

    @ObservationIgnored private let vault: LocalVault
    /// Port text that did not parse to 1...65535; shown back to the user instead of the stored port.
    private var invalidPortText: String?
    /// The mode the user picked; until then it is derived from the host.
    private var chosenCredentialMode: CredentialMode?

    public init(vault: LocalVault, hostID: UUID) {
        self.vault = vault
        self.hostID = hostID
    }

    private var host: SavedHost? {
        _ = vault.revision
        return vault.get(SavedHost.self, id: hostID)
    }

    /// Applies one change to the stored host and saves it if anything changed.
    private func update(_ change: (inout SavedHost) -> Void) {
        guard var host = vault.get(SavedHost.self, id: hostID) else { return }
        let before = host
        change(&host)
        if host != before { vault.saveNow(host) }
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    public var isDeleted: Bool { host == nil }

    // MARK: Editable

    public var label: String {
        get { host?.label ?? "" }
        set { update { $0.label = newValue } }
    }

    public var address: String {
        get { host?.address ?? "" }
        set { update { $0.address = newValue } }
    }

    public var groupID: UUID? {
        get { host?.groupID }
        set { update { $0.groupID = newValue } }
    }

    /// Trimmed, deduplicated (first occurrence kept), empties dropped.
    public var tags: [String] {
        get { host?.tags ?? [] }
        set {
            var seen: Set<String> = []
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            update { $0.tags = cleaned }
        }
    }

    /// Empty means inherit (port nil). Text that is not a port in 1...65535 is kept for display
    /// with `portError` set, and the stored port is left unchanged.
    public var portText: String {
        get { invalidPortText ?? host?.port.map(String.init) ?? "" }
        set {
            guard !isDeleted else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                invalidPortText = nil
                update { $0.port = nil }
            } else if let port = Int(trimmed), (1...65535).contains(port) {
                invalidPortText = nil
                update { $0.port = port }
            } else {
                invalidPortText = newValue
            }
        }
    }

    /// Setting a badge marks it as chosen by the user.
    public var osBadge: OSBadge? {
        get { host?.osBadge }
        set {
            update {
                $0.osBadge = newValue
                $0.osBadgeIsManual = true
            }
        }
    }

    /// Switching to `.identity` clears the direct username, password and key; switching to
    /// `.direct` clears the identity.
    public var credentialMode: CredentialMode {
        get { chosenCredentialMode ?? (host?.identityID != nil ? .identity : .direct) }
        set {
            guard !isDeleted else { return }
            chosenCredentialMode = newValue
            switch newValue {
            case .identity:
                update {
                    $0.username = nil
                    $0.password = nil
                    $0.sshKeyID = nil
                }
            case .direct:
                update { $0.identityID = nil }
            }
        }
    }

    public var identityID: UUID? {
        get { host?.identityID }
        set { update { $0.identityID = newValue } }
    }

    /// Empty text is stored as nil.
    public var username: String {
        get { host?.username ?? "" }
        set { update { $0.username = Self.nonEmpty(newValue) } }
    }

    /// Empty text is stored as nil.
    public var password: String {
        get { host?.password ?? "" }
        set { update { $0.password = Self.nonEmpty(newValue) } }
    }

    public var sshKeyID: UUID? {
        get { host?.sshKeyID }
        set { update { $0.sshKeyID = newValue } }
    }

    // MARK: Read-only

    private var directory: HostDirectory {
        _ = vault.revision
        return HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
    }

    public var effectivePort: Int {
        guard let host else { return 22 }
        return directory.effectivePort(for: host)
    }

    /// Where an inherited port comes from, e.g. "22 (default)" or "2222 (from group Proxmox)";
    /// nil when the host sets its own port.
    public var inheritedPortHint: String? {
        guard let host, host.port == nil else { return nil }
        let groups = Dictionary(vault.all(HostGroup.self).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<UUID> = []
        var next = host.groupID
        while let id = next, visited.insert(id).inserted, let group = groups[id] {
            if let port = group.defaultPort { return "\(port) (from group \(group.name))" }
            next = group.parentID
        }
        return "22 (default)"
    }

    public var portError: String? {
        invalidPortText == nil ? nil : "Port must be 1–65535"
    }

    /// The `CredentialReuse` group this host belongs to, if any.
    private var reuseGroup: [SavedHost]? {
        _ = vault.revision
        return CredentialReuse.groups(in: vault.all(SavedHost.self))
            .first { group in group.contains { $0.id == hostID } }
    }

    public var reuseHint: String? {
        reuseGroup.map { "\($0.count) hosts reuse credentials. Merge them for easy updates." }
    }

    public var availableIdentities: [Identity] {
        _ = vault.revision
        return vault.all(Identity.self)
    }

    public var availableKeys: [SSHKey] {
        _ = vault.revision
        return vault.all(SSHKey.self)
    }

    /// All non-deleted groups, sorted by name.
    public var availableGroups: [HostGroup] {
        _ = vault.revision
        return vault.all(HostGroup.self).sorted { a, b in
            switch a.name.localizedCaseInsensitiveCompare(b.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.id.uuidString < b.id.uuidString
            }
        }
    }

    // MARK: Actions

    /// Creates an identity (label "<username> credentials") from the credentials this host shares
    /// with others, and links every host in the reuse group to it, clearing their direct
    /// username and password.
    public func createIdentityFromReusedCredentials() async throws -> Identity {
        guard let group = reuseGroup, let first = group.first,
              let username = first.username, let password = first.password else {
            throw HostDetailsError.noReusedCredentials
        }
        let identity = try await vault.save(Identity(label: "\(username) credentials",
                                                     username: username, password: password))
        for member in group {
            guard var current = vault.get(SavedHost.self, id: member.id) else { continue }
            current.identityID = identity.id
            current.username = nil
            current.password = nil
            try await vault.save(current)
        }
        chosenCredentialMode = .identity
        return identity
    }

    public func delete() async throws {
        try await vault.delete(SavedHost.self, id: hostID)
    }
}
