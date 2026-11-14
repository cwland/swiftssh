import Foundation

/// Descriptions of records that hold secrets. Passwords, private keys, passphrases and API keys
/// are printed as `<redacted>` so they can't leak into logs, test failures or `print` output.
/// Stored values, equality and coding are unchanged.
enum Redaction {
    static let placeholder = "<redacted>"

    /// `<redacted>` when a secret is present, `nil` otherwise.
    static func secret(_ value: String?) -> String {
        value == nil ? "nil" : placeholder
    }

    static func quoted(_ value: String?) -> String {
        value.map { String(reflecting: $0) } ?? "nil"
    }

    static func plain<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "nil"
    }
}

extension Host: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "Host(id: \(id), label: \(Redaction.quoted(label)), address: \(Redaction.quoted(address)), "
            + "port: \(Redaction.plain(port)), groupID: \(Redaction.plain(groupID)), "
            + "username: \(Redaction.quoted(username)), identityID: \(Redaction.plain(identityID)), "
            + "password: \(Redaction.secret(password)), sshKeyID: \(Redaction.plain(sshKeyID)), "
            + "updatedAt: \(updatedAt), deleted: \(deleted))"
    }

    public var debugDescription: String { description }
}

extension Identity: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "Identity(id: \(id), label: \(Redaction.quoted(label)), username: \(Redaction.quoted(username)), "
            + "password: \(Redaction.secret(password)), sshKeyID: \(Redaction.plain(sshKeyID)), "
            + "updatedAt: \(updatedAt), deleted: \(deleted))"
    }

    public var debugDescription: String { description }
}

extension SSHKey: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "SSHKey(id: \(id), label: \(Redaction.quoted(label)), keyType: \(keyType.rawValue), "
            + "publicKey: \(Redaction.quoted(publicKey)), privateKey: \(Redaction.placeholder), "
            + "passphrase: \(Redaction.secret(passphrase)), updatedAt: \(updatedAt), deleted: \(deleted))"
    }

    public var debugDescription: String { description }
}

extension AISettings: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "AISettings(id: \(id), provider: \(provider.rawValue), baseURL: \(Redaction.quoted(baseURL)), "
            + "model: \(Redaction.quoted(model)), apiKey: \(Redaction.secret(apiKey)), "
            + "updatedAt: \(updatedAt), deleted: \(deleted))"
    }

    public var debugDescription: String { description }
}
