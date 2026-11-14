import CoreModels
import Foundation
import SSHCore

public enum ConnectionPlanError: Error, Equatable, LocalizedError {
    case hostNotFound
    case missingAddress
    case missingUsername

    public var errorDescription: String? {
        switch self {
        case .hostNotFound: "This host no longer exists."
        case .missingAddress: "This host has no address."
        case .missingUsername: "This host has no username."
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
        guard let username else { throw ConnectionPlanError.missingUsername }

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
