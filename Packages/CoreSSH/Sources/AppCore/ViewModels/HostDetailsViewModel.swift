import Foundation
import Observation
import CoreModels

public enum CredentialMode: Sendable, Equatable {
    case identity, direct
}

/// The "Attach to tmux" setting as the Host Details row (and the group sheet) shows it.
public enum TmuxMode: Sendable, Equatable, CaseIterable {
    /// Default: the nearest group's choice (stored as nil).
    case inherit
    case on
    case off
}

public enum TmuxLabels {
    /// "Default (group: on, ops)", "Default (group: off)", or "Default (off)" when no group sets one.
    public static func defaultSummary(_ inherited: InheritedTmux) -> String {
        switch inherited.choice {
        case .session(let name): "Default (group: on, \(name))"
        case .off: "Default (group: off)"
        case .inherit: "Default (off)"
        }
    }

    public static let invalidNameMessage = "Use 1\u{2013}64 letters, digits, underscores or hyphens"
}

/// The "Startup snippet" picker on a host: Default (the nearest group's), None, or one snippet.
public enum StartupSnippetSelection: Hashable, Sendable {
    /// Stored as no snippet and no None flag.
    case inherit
    /// Stored as `startupSnippetOff = true`: no snippet, not even a group's.
    case none
    case snippet(UUID)
}

public enum StartupSnippetLabels {
    /// "Default (from group “Ops”: Go to app)", or "Default (none)" when no group sets one.
    /// `snippetName` is the inherited snippet's name ("Untitled snippet" when blank).
    public static func defaultSummary(_ inherited: InheritedStartupSnippet?, snippetName: String?) -> String {
        guard let inherited else { return "Default (none)" }
        let group = inherited.groupName.isEmpty ? "Untitled group" : inherited.groupName
        let name = (snippetName ?? "").isEmpty ? "Untitled snippet" : snippetName!
        return "Default (from group \u{201C}\(group)\u{201D}: \(name))"
    }
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
    /// A tmux session name typed that is not valid (shown back with `tmuxNameError`, not saved).
    private var invalidTmuxName: String?
    /// The last session name used while on, so switching off and on again keeps it.
    private var lastTmuxName: String?

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

    /// The backup address, tried when `address` can't be reached (`Host.fallbackAddress`). Saved as
    /// typed, like `address`; blank (only whitespace) removes it. "" = none.
    public var fallbackAddress: String {
        get { host?.fallbackAddress ?? "" }
        set {
            let blank = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            update { $0.fallbackAddress = blank ? nil : newValue }
        }
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

    // MARK: Startup snippet

    /// The snippet typed after login; nil = none (also when the stored one is missing or deleted).
    /// Saves at once; setting the stored value again does nothing (nil clears a stale stored id).
    public var startupSnippetID: UUID? {
        get {
            guard let id = host?.startupSnippetID, vault.get(Snippet.self, id: id) != nil else { return nil }
            return id
        }
        set { update { $0.startupSnippetID = newValue } }
    }

    /// Default / None / a snippet. `.snippet` while the host's own snippet exists; else `.none` for the
    /// None flag; else `.inherit`. Saves at once; choosing a snippet or Default clears the None flag.
    public var startupSnippetSelection: StartupSnippetSelection {
        get {
            if let id = startupSnippetID { return .snippet(id) }
            return host?.startupSnippetOff == true ? .none : .inherit
        }
        set {
            update { host in
                switch newValue {
                case .inherit: host.startupSnippetID = nil; host.startupSnippetOff = nil
                case .none: host.startupSnippetID = nil; host.startupSnippetOff = true
                case .snippet(let id): host.startupSnippetID = id; host.startupSnippetOff = nil
                }
            }
        }
    }

    /// The snippet typed after login (the host's own, else its groups'), or nil = none.
    public var effectiveStartupSnippetID: UUID? {
        guard let host else { return nil }
        return directory.effectiveStartupSnippetID(for: host) { vault.get(Snippet.self, id: $0) != nil }
    }

    /// What "Default" means for this host, e.g. "Default (from group “Ops”: Go to app)".
    public var inheritedStartupSnippetSummary: String {
        guard let host else { return StartupSnippetLabels.defaultSummary(nil, snippetName: nil) }
        let inherited = directory.inheritedStartupSnippet(for: host) { vault.get(Snippet.self, id: $0) != nil }
        return StartupSnippetLabels.defaultSummary(
            inherited, snippetName: inherited.flatMap { vault.get(Snippet.self, id: $0.snippetID)?.name })
    }

    /// Snippets that can be a startup snippet: those without placeholders, A–Z (as
    /// `SnippetsViewModel.startupCandidates()`).
    public func startupCandidates() -> [Snippet] {
        _ = vault.revision
        return SnippetsViewModel(vault: vault).startupCandidates()
    }

    /// Snippets left out of `startupCandidates()` because they have placeholders (for the picker's note).
    public var hiddenStartupSnippetCount: Int {
        _ = vault.revision
        return vault.all(Snippet.self).filter { SnippetTemplate($0.script).hasPlaceholders }.count
    }

    // MARK: Attach to tmux

    /// `.inherit` for nil (older records) and a stored `.inherit`. Saves at once; the username and
    /// credentials are never touched. Switching on keeps a stored name, else uses the last name used
    /// here, else the groups' session name, else "main". An invalid typed name is dropped on any change.
    public var tmuxMode: TmuxMode {
        get {
            switch host?.tmuxSession ?? .inherit {
            case .inherit: .inherit
            case .off: .off
            case .session: .on
            }
        }
        set {
            guard let host else { return }
            invalidTmuxName = nil
            if let name = host.tmuxSession?.sessionName { lastTmuxName = name }
            let choice: TmuxChoice?
            switch newValue {
            case .inherit: choice = nil
            case .off: choice = .off
            case .on:
                if case .session = host.tmuxSession { return }
                choice = .session(lastTmuxName ?? directory.inheritedTmux(for: host).choice.sessionName
                                  ?? TmuxChoice.defaultSessionName)
            }
            update { $0.tmuxSession = choice }
        }
    }

    /// The session name field (shown while `.on`): what was typed when it is invalid, else the stored
    /// name. A valid name (whitespace trimmed) is saved at once, only while on.
    public var tmuxNameText: String {
        get { invalidTmuxName ?? host?.tmuxSession?.sessionName ?? "" }
        set {
            guard let host, case .session = host.tmuxSession else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard TmuxChoice.isValidSessionName(trimmed) else {
                invalidTmuxName = newValue
                return
            }
            invalidTmuxName = nil
            lastTmuxName = trimmed
            update { $0.tmuxSession = .session(trimmed) }
        }
    }

    public var tmuxNameError: String? {
        invalidTmuxName == nil ? nil : TmuxLabels.invalidNameMessage
    }

    /// The session attached to after login, or nil = off (what the host and its groups add up to).
    public var effectiveTmuxSession: String? {
        guard let host else { return nil }
        return directory.effectiveTmuxSession(for: host)
    }

    /// What "Default" means for this host, e.g. "Default (group: on, ops)".
    public var inheritedTmuxSummary: String {
        guard let host else { return TmuxLabels.defaultSummary(InheritedTmux(choice: .inherit, groupName: nil)) }
        return TmuxLabels.defaultSummary(directory.inheritedTmux(for: host))
    }

    /// The row's text: "On (main)", "Off", or `inheritedTmuxSummary`.
    public var tmuxSummary: String {
        switch host?.tmuxSession ?? .inherit {
        case .session(let name): "On (\(name))"
        case .off: "Off"
        case .inherit: inheritedTmuxSummary
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

    /// The login method in use, stored in `prefersIdentity` (synced): `.identity` when true, `.direct`
    /// when false. For older records (`nil`): `.identity` when an identity is linked, or when the user
    /// picked identity mode here and the host has no direct password, key or agent key yet (the username
    /// doesn't count); otherwise `.direct`.
    ///
    /// Switching never clears anything: the identity link and the host's own username, password, key
    /// and agent key are all kept, so switching back needs no re-entry. Connecting uses only the side
    /// that is chosen (`CredentialResolution`).
    public var credentialMode: CredentialMode {
        get {
            guard let host else { return .direct }
            if host.prefersIdentity == true { return .identity }
            if host.prefersIdentity == false { return .direct }
            if host.identityID != nil { return .identity }
            let hasDirect = host.password != nil || host.sshKeyID != nil || host.agentKey != nil
            return identityModePicked && !hasDirect ? .identity : .direct
        }
        set {
            guard !isDeleted else { return }
            switch newValue {
            case .identity:
                identityModePicked = true
                update { $0.prefersIdentity = true }
            case .direct:
                identityModePicked = false
                update { $0.prefersIdentity = false }
            }
        }
    }

    /// Linking an identity records identity mode; the host's own credentials are kept (unused).
    public var identityID: UUID? {
        get { host?.identityID }
        set {
            update {
                $0.identityID = newValue
                if newValue != nil { $0.prefersIdentity = true }
            }
        }
    }

    /// Sets a direct credential field; a non-empty value records direct mode. A linked identity is
    /// kept (unused), for switching back.
    private func updateDirect(isEmpty: Bool, _ change: (inout SavedHost) -> Void) {
        if !isEmpty { identityModePicked = false }
        update {
            change(&$0)
            if !isEmpty { $0.prefersIdentity = false }
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

    /// Switches the host's direct login to `change` (direct mode; a linked identity is kept) and saves at once. With
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
        guard let host else { return nil }
        // Only this host's group chain matters, so the other hosts are not read.
        return TerminalThemeResolver.inheritedThemeID(forHostID: hostID, hosts: [host],
                                                      groups: vault.all(HostGroup.self))
    }

    /// The theme "Default" draws with for this host: the groups' theme, else the app default
    /// (`appDefaultThemeID`, when this build knows it), else nil = Automatic.
    public func defaultTheme(appDefaultThemeID: String?,
                             catalog: TerminalThemeCatalog = .shared) -> TerminalTheme? {
        if let id = inheritedThemeID, let theme = catalog.theme(id: id) { return theme }
        return appDefaultThemeID.flatMap { catalog.theme(id: $0) }
    }

    /// What "Default" means for this host: "Nord — from group", the app default's name, or
    /// "Automatic".
    public func defaultThemeLabel(appDefaultThemeID: String?,
                                  catalog: TerminalThemeCatalog = .shared) -> String {
        if let id = inheritedThemeID, let theme = catalog.theme(id: id) {
            return "\(theme.name) \u{2014} from group"
        }
        return appDefaultThemeID.flatMap { catalog.theme(id: $0) }?.name ?? "Automatic"
    }

    /// The Theme row's text: the host's own theme name, "Unknown theme (<id>)" for an id this
    /// build doesn't know, or "Default (<defaultThemeLabel>)".
    public func themeSummary(appDefaultThemeID: String?,
                             catalog: TerminalThemeCatalog = .shared) -> String {
        if let id = themeID {
            return catalog.theme(id: id)?.name ?? "Unknown theme (\(id))"
        }
        return "Default (\(defaultThemeLabel(appDefaultThemeID: appDefaultThemeID, catalog: catalog)))"
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
            guard var current = vault.get(SavedHost.self, id: member.id), CredentialReuse.usesDirect(current),
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
