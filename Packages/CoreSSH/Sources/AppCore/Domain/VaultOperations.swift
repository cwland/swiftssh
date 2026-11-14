import Foundation
import CoreModels


extension LocalVault {
    // MARK: Usage queries (direct references from non-deleted records)

    public func hostsUsing(identityID: UUID) -> [CoreModels.Host] {
        all(CoreModels.Host.self).filter { $0.identityID == identityID }
    }

    public func hostsUsing(sshKeyID: UUID) -> [CoreModels.Host] {
        all(CoreModels.Host.self).filter { $0.sshKeyID == sshKeyID }
    }

    public func identitiesUsing(sshKeyID: UUID) -> [Identity] {
        all(Identity.self).filter { $0.sshKeyID == sshKeyID }
    }

    public func groupsUsing(identityID: UUID) -> [HostGroup] {
        all(HostGroup.self).filter { $0.defaultIdentityID == identityID }
    }

    // MARK: Safe deletes
    // Referencing records are saved first and the target is tombstoned last, so a failure
    // midway leaves the target visible instead of leaving dangling references.

    /// Moves the group's hosts and subgroups to the group's parent, then deletes the group.
    public func deleteGroup(id: UUID) async throws {
        guard let group = get(HostGroup.self, id: id) else { return }
        for var child in all(HostGroup.self) where child.parentID == id {
            child.parentID = group.parentID
            try await save(child)
        }
        for var host in all(CoreModels.Host.self) where host.groupID == id {
            host.groupID = group.parentID
            try await save(host)
        }
        try await delete(HostGroup.self, id: id)
    }

    public func deleteIdentity(id: UUID) async throws {
        for var host in hostsUsing(identityID: id) {
            host.identityID = nil
            try await save(host)
        }
        for var group in groupsUsing(identityID: id) {
            group.defaultIdentityID = nil
            try await save(group)
        }
        try await delete(Identity.self, id: id)
    }

    public func deleteSSHKey(id: UUID) async throws {
        for var host in hostsUsing(sshKeyID: id) {
            host.sshKeyID = nil
            try await save(host)
        }
        for var identity in identitiesUsing(sshKeyID: id) {
            identity.sshKeyID = nil
            try await save(identity)
        }
        try await delete(SSHKey.self, id: id)
    }
}

public enum CredentialReuse {
    /// Groups of two or more hosts without an identity that share the same non-empty
    /// username and password. Largest group first; ties keep first-seen order.
    public static func groups(in hosts: [CoreModels.Host]) -> [[CoreModels.Host]] {
        struct Key: Hashable { var username: String; var password: String }
        var order: [Key] = []
        var buckets: [Key: [CoreModels.Host]] = [:]
        for host in hosts where host.identityID == nil {
            guard let username = host.username, !username.isEmpty,
                  let password = host.password, !password.isEmpty else { continue }
            let key = Key(username: username, password: password)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(host)
        }
        let groups = order.compactMap { buckets[$0] }.filter { $0.count >= 2 }
        return groups.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element)
    }
}
