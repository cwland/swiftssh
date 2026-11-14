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

    /// Title for the alert that shows this error.
    public var alertTitle: String { "Can't connect" }

    public var errorDescription: String? {
        switch self {
        case .hostNotFound: "This host no longer exists."
        case .missingAddress: "This host has no address."
        case .missingUsername(.identity(let label)):
            "The identity \u{201C}\(label)\u{201D} has no username. Add one in Keychain, or set Direct credentials on this host."
        case .missingUsername(.host(let label)):
            "\u{201C}\(label)\u{201D} has no username. Add one in Host Details."
        }
    }
}

public enum ConnectionPlanner {
    /// Builds the plan for a saved host. Credentials come from `CredentialResolution` (explicit
    /// identity > host's direct credentials > group default identity); whatever is still missing is
    /// left to the connection prompt.
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

        let script = host.startupSnippetID.flatMap { vault.get(Snippet.self, id: $0)?.script }

        return ConnectionPlan(hostID: host.id, label: host.label, host: address,
                              port: directory.effectivePort(for: host), username: username,
                              credential: credential, engine: engine, startupScript: script)
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
