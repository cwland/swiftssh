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
    /// Builds the plan for a saved host. Precedence: (a) the host's explicit `identityID`, if it
    /// resolves to a live identity, always applies; (b) otherwise, if the host has any direct
    /// credential (username, non-empty password or a live key), the host's own fields are used and
    /// whatever they lack is left to the connection prompt; (c) otherwise the group-inherited
    /// default identity applies. A deleted or missing identity or key counts as absent.
    @MainActor
    public static func plan(hostID: UUID, vault: LocalVault) throws -> ConnectionPlan {
        guard let host = vault.get(SavedHost.self, id: hostID) else { throw ConnectionPlanError.hostNotFound }
        let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw ConnectionPlanError.missingAddress }

        let directory = HostDirectory(hosts: vault.all(SavedHost.self), groups: vault.all(HostGroup.self))

        let hostKey = host.sshKeyID.flatMap { vault.get(SSHKey.self, id: $0) }
        let hostUsername = nonEmpty(host.username)
        let hostPassword = nonEmpty(host.password)

        var username: String?
        var password: String?
        var key: SSHKey?
        if let explicit = host.identityID.flatMap({ vault.get(Identity.self, id: $0) }) {
            username = nonEmpty(explicit.username)
            password = nonEmpty(explicit.password)
            key = explicit.sshKeyID.flatMap { vault.get(SSHKey.self, id: $0) }
        } else if hostUsername != nil || hostPassword != nil || hostKey != nil {
            username = hostUsername
            password = hostPassword
            key = hostKey
        } else if let inherited = inheritedIdentity(for: host, directory: directory, vault: vault) {
            username = nonEmpty(inherited.username)
            password = nonEmpty(inherited.password)
            key = inherited.sshKeyID.flatMap { vault.get(SSHKey.self, id: $0) }
        }
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

    /// The group-inherited default identity, ignoring the host's own (dead) explicit link.
    @MainActor
    private static func inheritedIdentity(for host: SavedHost, directory: HostDirectory, vault: LocalVault) -> Identity? {
        var inheriting = host
        inheriting.identityID = nil
        return directory.effectiveIdentityID(for: inheriting).flatMap { vault.get(Identity.self, id: $0) }
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
