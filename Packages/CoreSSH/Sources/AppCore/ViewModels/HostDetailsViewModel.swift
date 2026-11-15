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
    private enum PortInput {
        /// Not a port in 1...65535; shown back with `portError`, stored port left alone.
        case invalid(String)
        /// Saved as `port`, but typed differently from its canonical form (e.g. "022").
        case nonCanonical(String, port: Int?)
    }

    /// What the user last typed into the port field, when it is not simply the stored port.
    private var portInput: PortInput?
    /// True after the user picked identity mode; honored only until an identity is linked.
    private var identityModePicked = false

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

    /// Empty (after trimming whitespace) means inherit (port nil); digits only in 1...65535 are
    /// saved as the port. Anything else is kept for display with `portError` set, and the stored
    /// port is left unchanged. Typed text is returned as typed (e.g. "022") while it still
    /// matches the stored port, so the field does not jump.
    public var portText: String {
        get {
            let stored = host?.port
            switch portInput {
            case .invalid(let text): return text
            case .nonCanonical(let text, let port) where port == stored: return text
            default: return stored.map(String.init) ?? ""
            }
        }
        set {
            guard !isDeleted else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let port: Int?
            if trimmed.isEmpty {
                port = nil
            } else if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let parsed = Int(trimmed), (1...65535).contains(parsed) {
                port = parsed
            } else {
                portInput = .invalid(newValue)
                return
            }
            portInput = newValue == (port.map(String.init) ?? "") ? nil : .nonCanonical(newValue, port: port)
            update { $0.port = port }
        }
    }

    /// The host's own terminal theme; nil = Default (inherit from its groups, then the app default).
    /// Saves at once, like the other fields. The username and credentials are not touched.
    public var themeID: String? {
        get { host?.themeID }
        set { update { $0.themeID = newValue } }
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

    /// True unless the user chose the OS (then the probe never changes it).
    public var isOSAutomatic: Bool {
        !(host?.osBadgeIsManual ?? false)
    }

    /// "Automatic": forgets the chosen OS, so the next connection detects it.
    public func useAutomaticOS() {
        vault.requestOSProbe(for: hostID)
        update {
            $0.osBadge = nil
            $0.osBadgeIsManual = false
        }
    }

    /// `.identity` when the host links an identity or prefers one (`prefersIdentity == true`); `.direct`
    /// when it prefers its own credentials (`false`). For older records (`nil`): `.identity` when the user
    /// picked identity mode here and the host has no direct password, key or agent key yet (the username
    /// is kept across modes, so it doesn't count), otherwise `.direct`. The choice is stored in
    /// `prefersIdentity` (synced). Switching to `.identity` clears the direct password, key and agent key,
    /// never the username; switching to `.direct` clears the identity and keeps the username.
    public var credentialMode: CredentialMode {
        get {
            guard let host else { return .direct }
            if host.identityID != nil || host.prefersIdentity == true { return .identity }
            if host.prefersIdentity == false { return .direct }
            let hasDirect = host.password != nil || host.sshKeyID != nil || host.agentKey != nil
            return identityModePicked && !hasDirect ? .identity : .direct
        }
        set {
            guard !isDeleted else { return }
            switch newValue {
            case .identity:
                identityModePicked = true
                update {
                    Self.clearDirectCredentials(&$0)
                    $0.prefersIdentity = true
                }
            case .direct:
                identityModePicked = false
                update {
                    $0.identityID = nil
                    $0.prefersIdentity = false
                }
            }
        }
    }

    /// The username is kept: switching the login method never clears it (an identity still wins over it).
    nonisolated private static func clearDirectCredentials(_ host: inout SavedHost) {
        host.password = nil
        host.sshKeyID = nil
        host.agentKey = nil
    }

    /// Linking an identity clears the direct password, key and agent key and records identity mode;
    /// the username is kept.
    public var identityID: UUID? {
        get { host?.identityID }
        set {
            update {
                $0.identityID = newValue
                if newValue != nil {
                    Self.clearDirectCredentials(&$0)
                    $0.prefersIdentity = true
                }
            }
        }
    }

    /// Sets a direct credential field; a non-empty value unlinks any identity and records direct mode
    /// (an older record without a recorded choice keeps none).
    private func updateDirect(isEmpty: Bool, _ change: (inout SavedHost) -> Void) {
        if !isEmpty { identityModePicked = false }
        update {
            change(&$0)
            if !isEmpty {
                $0.identityID = nil
                if $0.prefersIdentity == true { $0.prefersIdentity = false }
            }
        }
    }

    /// Empty text is stored as nil. Writing the value already stored does nothing (no unlink, no save).
    public var username: String {
        get { host?.username ?? "" }
        set {
            guard Self.nonEmpty(newValue) != host?.username else { return }
            updateDirect(isEmpty: newValue.isEmpty) { $0.username = Self.nonEmpty(newValue) }
        }
    }

    /// Empty text is stored as nil.
    public var password: String {
        get { host?.password ?? "" }
        set {
            guard Self.nonEmpty(newValue) != host?.password else { return }
            updateDirect(isEmpty: newValue.isEmpty) { $0.password = Self.nonEmpty(newValue) }
        }
    }

    public var sshKeyID: UUID? {
        get { host?.sshKeyID }
        set {
            guard newValue != host?.sshKeyID else { return }
            updateDirect(isEmpty: newValue == nil) { $0.sshKeyID = newValue }
        }
    }

    /// Non-nil = log in with the 1Password SSH agent (`publicKey` nil = any agent key). Setting a
    /// non-nil value unlinks any identity; the stored password and key are kept (the agent takes
    /// precedence while set), so setting nil again goes back to them.
    public var agentKey: AgentKeyChoice? {
        get { host?.agentKey }
        set { updateDirect(isEmpty: newValue == nil) { $0.agentKey = newValue } }
    }

    /// The saved secrets of this host's own (direct) credentials that `change` makes unnecessary.
    /// Empty when the host is missing or deleted.
    public func secretsReplaced(by change: CredentialChange) -> ReplacedSecrets {
        guard let host else { return ReplacedSecrets(password: false, keyLink: false) }
        return Self.loginFields(of: host).replaced(by: change)
    }

    /// Switches the host's direct login to `change` (unlinking any identity) and saves at once. With
    /// `removingReplaced`, the secrets `secretsReplaced(by:)` reports are removed too; otherwise they stay
    /// stored. The username is never touched, and a Keychain key item is never deleted.
    public func apply(_ change: CredentialChange, removingReplaced: Bool) {
        guard !isDeleted else { return }
        updateDirect(isEmpty: false) { host in
            var fields = Self.loginFields(of: host)
            fields.apply(change, removingReplaced: removingReplaced)
            host.password = fields.password
            host.sshKeyID = fields.sshKeyID
            host.agentKey = fields.agentKey
        }
    }

    nonisolated private static func loginFields(of host: SavedHost) -> LoginFields {
        LoginFields(password: host.password, sshKeyID: host.sshKeyID, agentKey: host.agentKey)
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

    /// What "Default" resolves to from the host's groups: a theme id this build knows, or nil = the
    /// app default. The host's own theme is not considered.
    public var inheritedThemeID: String? {
        guard var host else { return nil }
        host.themeID = nil
        let others = vault.all(SavedHost.self).filter { $0.id != hostID }
        return TerminalThemeResolver.inheritedThemeID(forHostID: hostID, hosts: others + [host],
                                                      groups: vault.all(HostGroup.self))
    }

    /// The stored theme id when this build's catalog doesn't know it (a newer build synced it).
    public var unknownThemeID: String? {
        guard let id = host?.themeID, !TerminalThemeCatalog.shared.contains(id) else { return nil }
        return id
    }

    public var portError: String? {
        if case .invalid = portInput { return "Port must be 1–65535" }
        return nil
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
    /// password and key (the username is kept). All changes are applied in memory in one pass, then persisted
    /// together; if that write fails the error is thrown and memory stays fully linked
    /// (a later write or `LocalVault.flush()` persists it).
    public func createIdentityFromReusedCredentials() async throws -> Identity {
        guard let group = reuseGroup, let first = group.first,
              let username = first.username, let password = first.password else {
            throw HostDetailsError.noReusedCredentials
        }
        let identity = vault.saveNow(Identity(label: "\(username) credentials",
                                              username: username, password: password))
        for member in group {
            guard var current = vault.get(SavedHost.self, id: member.id), current.identityID == nil,
                  current.username == username, current.password == password else { continue }
            // The identity becomes the host's single credential source.
            current.identityID = identity.id
            current.prefersIdentity = true
            current.password = nil
            current.sshKeyID = nil
            vault.saveNow(current)
        }
        try await vault.persistNow()
        return identity
    }

    public func delete() async throws {
        try await vault.delete(SavedHost.self, id: hostID)
    }
}
