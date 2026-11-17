import CoreModels
import Foundation
import SSHCore

/// Where the missing username should have come from.
public enum UsernameSource: Equatable, Sendable {
    /// The identity in effect (the host's own or its group's default) has an empty username.
    case identity(label: String)
    /// The host's own direct credentials have no username.
    case host(label: String)
}

public enum ConnectionPlanError: Error, Equatable, LocalizedError {
    case hostNotFound
    case missingAddress
    case missingUsername(UsernameSource)
    /// The host is set to use an identity, but none is in effect (none chosen, or the chosen one is gone).
    case identityNotChosen(hostLabel: String)
    /// iPhone/iPad: the host signs in with a 1Password SSH key, and no usable key is imported on this device.
    case noImportedKeys(hostLabel: String)
    /// iPhone/iPad: the host signs in with an RSA key, which the built-in engine can't use.
    case rsaUnsupported(hostLabel: String)
    /// iPhone/iPad: the host's key has its passphrase in 1Password, which the app can't read there.
    case passphraseInOnePassword(hostLabel: String)
    /// iPhone/iPad: reading the imported keys needs Face ID / the passcode, which wasn't given.
    case importedKeysLocked(hostLabel: String)

    /// Title for the alert that shows this error.
    public var alertTitle: String { "Can't connect" }

    public var errorDescription: String? {
        switch self {
        case .hostNotFound: "This host no longer exists."
        case .missingAddress: "This host has no address."
        case .missingUsername(.identity(let label)):
            "The identity \u{201C}\(Self.display(label, fallback: "Untitled identity"))\u{201D} has no username. Add one in Keychain, or set Direct credentials on this host."
        case .identityNotChosen(let label):
            "\u{201C}\(Self.display(label, fallback: "Untitled host"))\u{201D} is set to use an identity, but none is chosen. Choose an identity in Host Details."
        case .missingUsername(.host(let label)):
            "\u{201C}\(Self.display(label, fallback: "Untitled host"))\u{201D} has no username. Add one in Host Details."
        case .noImportedKeys(let label):
            "\u{201C}\(Self.display(label, fallback: "Untitled host"))\u{201D} signs in with an SSH key from 1Password. Import that key on this device first: export it from 1Password, then use Import Key in Keys."
        case .rsaUnsupported:
            "RSA keys aren't supported on iPhone/iPad yet; use an Ed25519 key."
        case .passphraseInOnePassword(let label):
            "\u{201C}\(Self.display(label, fallback: "Untitled host"))\u{201D} signs in with a key whose passphrase is in 1Password, which SwiftSSH can\u{2019}t read on iPhone/iPad. Connect to this host from your Mac."
        case .importedKeysLocked(let label):
            "\u{201C}\(Self.display(label, fallback: "Untitled host"))\u{201D} signs in with a key imported on this device, and SwiftSSH needs Face ID or your passcode to use it. Tap Start Over to try again."
        }
    }

    /// The label, or `fallback` when it is blank (as the cards show it).
    private static func display(_ label: String, fallback: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : label
    }
}

/// Which app a plan is for: the Mac (both engines, 1Password's agent) or iPhone/iPad (the built-in
/// engine only, keys imported on the device instead of an agent, no RSA keys).
public enum ConnectionPlatform: Sendable, Equatable {
    case mac, ios
}

public enum ConnectionPlanner {
    /// Builds the plan for a saved host. The host's backup address, if any, goes into `fallbackHost`
    /// (see `ConnectionFallback.backupAddress`) on both platforms. Credentials come from `CredentialResolution` (explicit
    /// identity > host's direct credentials > group default identity); whatever is still missing is
    /// left to the connection prompt. With a 1Password agent key the plan's `agentKey` is set, its
    /// credential is `.none` and its engine `.systemSSH`.
    @MainActor
    public static func plan(hostID: UUID, vault: LocalVault) throws -> ConnectionPlan {
        try plan(hostID: hostID, vault: vault, platform: .mac, importedKeys: [])
    }

    /// The plan for `platform`. `.mac` is `plan(hostID:vault:)` (`importedKeys` unused). `.ios` always uses
    /// the built-in engine (`useSystemSSH` is ignored) and:
    /// - a host or identity using a 1Password agent key gets `.privateKeys` from `importedKeys` (Ed25519
    ///   only): the one matching the pinned public key first, then the others in order, at most
    ///   `SSHKeyCandidate.maxAttempts`; `agentKey` stays nil. None usable → `.noImportedKeys`.
    /// - an RSA private key → `.rsaUnsupported`.
    /// - a password that is a 1Password reference → `.none` (the app asks for it; iOS AutoFill can
    ///   fill it from 1Password): there is no `op` CLI to read it.
    /// - a key whose passphrase is a 1Password reference → `.passphraseInOnePassword`.
    @MainActor
    public static func plan(hostID: UUID, vault: LocalVault, platform: ConnectionPlatform,
                            importedKeys: [SSHKeyCandidate]) throws -> ConnectionPlan {
        guard let host = vault.get(SavedHost.self, id: hostID) else { throw ConnectionPlanError.hostNotFound }
        let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw ConnectionPlanError.missingAddress }

        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))
        let resolved = CredentialResolution.resolve(host: host, directory: directory, vault: vault)
        let username = resolved.username
        let password = resolved.password
        let key = resolved.key
        if host.prefersIdentity == true, resolved.identity == nil {
            throw ConnectionPlanError.identityNotChosen(hostLabel: host.label)
        }
        guard let username else {
            if let identity = resolved.identity {
                throw ConnectionPlanError.missingUsername(.identity(label: identity.label))
            }
            throw ConnectionPlanError.missingUsername(.host(label: host.label))
        }

        if platform == .ios {
            return try iosPlan(host: host, address: address, username: username, resolved: resolved,
                               directory: directory, vault: vault, importedKeys: importedKeys)
        }

        let credential: SSHCredential
        if let key {
            credential = .privateKey(type: key.keyType, pem: key.privateKey, passphrase: key.passphrase)
        } else if let password {
            credential = .password(password)
        } else {
            credential = .none
        }

        var engine = SSHEngine.citadel
        if host.useSystemSSH == true { engine = .systemSSH }
        if case .privateKey(.rsa, _, _) = credential { engine = .systemSSH }
        // Only system ssh signs with an agent; the session manager fills in the socket at connect time.
        if resolved.agentKey != nil { engine = .systemSSH }

        return ConnectionPlan(hostID: host.id, label: host.label, host: address,
                              port: directory.effectivePort(for: host), username: username,
                              credential: credential, engine: engine,
                              startupScript: startupScript(for: host, directory: directory, vault: vault),
                              agentKey: resolved.agentKey,
                              fallbackHost: ConnectionFallback.backupAddress(main: address, backup: host.fallbackAddress))
    }

    @MainActor
    private static func iosPlan(host: SavedHost, address: String, username: String, resolved: CredentialResolution,
                                directory: HostDirectory, vault: LocalVault,
                                importedKeys: [SSHKeyCandidate]) throws -> ConnectionPlan {
        let credential: SSHCredential
        if let agentKey = resolved.agentKey {
            let usable = importedKeys.filter { $0.type == .ed25519 }
            guard !usable.isEmpty else { throw ConnectionPlanError.noImportedKeys(hostLabel: host.label) }
            credential = .privateKeys(Array(ordered(usable, pinned: agentKey.publicKey).prefix(SSHKeyCandidate.maxAttempts)))
        } else if let key = resolved.key {
            guard key.keyType != .rsa else { throw ConnectionPlanError.rsaUnsupported(hostLabel: host.label) }
            if let passphrase = key.passphrase, SecretReference.isReference(passphrase) {
                throw ConnectionPlanError.passphraseInOnePassword(hostLabel: host.label)
            }
            credential = .privateKey(type: key.keyType, pem: key.privateKey, passphrase: key.passphrase)
        } else if let password = resolved.password, !SecretReference.isReference(password) {
            credential = .password(password)
        } else {
            credential = .none
        }
        return ConnectionPlan(hostID: host.id, label: host.label, host: address,
                              port: directory.effectivePort(for: host), username: username,
                              credential: credential, engine: .citadel,
                              startupScript: startupScript(for: host, directory: directory, vault: vault),
                              fallbackHost: ConnectionFallback.backupAddress(main: address, backup: host.fallbackAddress))
    }

    /// The key matching `pinned` (by type and key, ignoring comments) first, then the rest in order.
    static func ordered(_ keys: [SSHKeyCandidate], pinned: String?) -> [SSHKeyCandidate] {
        guard let pinned else { return keys }
        let identity = SSHKeyCandidate.keyIdentity(pinned)
        let isPinned: (SSHKeyCandidate) -> Bool = { SSHKeyCandidate.keyIdentity($0.publicKey) == identity }
        return keys.filter(isPinned) + keys.filter { !isPinned($0) }
    }

    /// A snippet with {{placeholders}} can't be filled at startup: don't type it with the braces.
    /// The host's own snippet, else its nearest group's (see `HostDirectory.effectiveStartupSnippetID`).
    @MainActor
    private static func startupScript(for host: SavedHost, directory: HostDirectory, vault: LocalVault) -> String? {
        directory.effectiveStartupSnippetID(for: host) { vault.get(Snippet.self, id: $0) != nil }
            .flatMap { vault.get(Snippet.self, id: $0)?.script }
            .flatMap { SnippetTemplate($0).hasPlaceholders ? nil : $0 }
    }

    public static func plan(quickConnect target: QuickConnectTarget, defaultUsername: String) -> ConnectionPlan {
        ConnectionPlan(hostID: nil, label: target.host, host: target.host, port: target.port ?? 22,
                       username: nonEmpty(target.username) ?? defaultUsername, credential: .none,
                       engine: .citadel, startupScript: nil)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
