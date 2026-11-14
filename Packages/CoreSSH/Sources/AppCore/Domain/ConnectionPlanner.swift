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
    /// Builds the plan for a saved host. Any direct username, password or key on the host disables
    /// identity inheritance entirely (matching what the host details screen shows); credentials the
    /// host then lacks are left to the connection prompt. An empty password counts as none, and a
    /// missing or deleted referenced key counts as absent.
    @MainActor
    public static func plan(hostID: UUID, vault: LocalVault) throws -> ConnectionPlan {
        guard let host = vault.get(SavedHost.self, id: hostID) else { throw ConnectionPlanError.hostNotFound }
        let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw ConnectionPlanError.missingAddress }

        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))

        let hostUsername = nonEmpty(host.username)
        let hostPassword = nonEmpty(host.password)
        let hasDirect = hostUsername != nil || hostPassword != nil || host.sshKeyID != nil

        var username = hostUsername
        var password = hostPassword
        var keyID = host.sshKeyID
        if !hasDirect,
           let identityID = directory.effectiveIdentityID(for: host),
           let identity = vault.get(Identity.self, id: identityID) {
            username = nonEmpty(identity.username)
            password = nonEmpty(identity.password)
            keyID = identity.sshKeyID
        }
        guard let username else { throw ConnectionPlanError.missingUsername }

        let key = keyID.flatMap { vault.get(SSHKey.self, id: $0) }
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
