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
        }
    }

    /// The label, or `fallback` when it is blank (as the cards show it).
    private static func display(_ label: String, fallback: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : label
    }
}

public enum ConnectionPlanner {
    /// Builds the plan for a saved host. Credentials come from `CredentialResolution` (explicit
    /// identity > host's direct credentials > group default identity); whatever is still missing is
    /// left to the connection prompt. With a 1Password agent key the plan's `agentKey` is set, its
    /// credential is `.none` and its engine `.systemSSH`.
    @MainActor
    public static func plan(hostID: UUID, vault: LocalVault) throws -> ConnectionPlan {
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

        // A snippet with {{placeholders}} can't be filled at startup: don't type it with the braces.
        // The host's own snippet, else its nearest group's (see `HostDirectory.effectiveStartupSnippetID`).
        let script = directory.effectiveStartupSnippetID(for: host) { vault.get(Snippet.self, id: $0) != nil }
            .flatMap { vault.get(Snippet.self, id: $0)?.script }
            .flatMap { SnippetTemplate($0).hasPlaceholders ? nil : $0 }

        return ConnectionPlan(hostID: host.id, label: host.label, host: address,
                              port: directory.effectivePort(for: host), username: username,
                              credential: credential, engine: engine, startupScript: script,
                              agentKey: resolved.agentKey)
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
