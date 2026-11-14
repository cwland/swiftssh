import Foundation

public enum OSBadge: String, Codable, Sendable, CaseIterable {
    case ubuntu, debian, raspberryPiOS, fedora, rhel, alpine, arch, macOS, freeBSD, linux, synology, homeAssistant
}

public enum KeyType: String, Codable, Sendable, CaseIterable {
    case ed25519, rsa
}

public enum AIProvider: String, Codable, Sendable, CaseIterable {
    case openAICompatible, anthropic
}

public struct HostGroup: SyncableModel {
    public static let recordType = SyncRecordType.hostGroup
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var defaultIdentityID: UUID?
    public var defaultPort: Int?
    public var defaultThemeID: String?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, defaultIdentityID: UUID? = nil,
                defaultPort: Int? = nil, defaultThemeID: String? = nil,
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.name = name; self.parentID = parentID
        self.defaultIdentityID = defaultIdentityID; self.defaultPort = defaultPort
        self.defaultThemeID = defaultThemeID; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct Host: SyncableModel {
    public static let recordType = SyncRecordType.host
    public var id: UUID
    public var label: String
    public var address: String
    /// nil = inherit from group; effective default is 22.
    public var port: Int?
    public var groupID: UUID?
    public var tags: [String]
    public var username: String?
    public var identityID: UUID?
    public var password: String?
    public var sshKeyID: UUID?
    public var osBadge: OSBadge?
    public var osBadgeIsManual: Bool
    public var themeID: String?
    public var startupSnippetID: UUID?
    public var lastConnectedAt: Date?
    /// nil/false = built-in engine unless the credential forces system ssh; true = always use /usr/bin/ssh.
    public var useSystemSSH: Bool?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), label: String, address: String, port: Int? = nil, groupID: UUID? = nil,
                tags: [String] = [], username: String? = nil, identityID: UUID? = nil, password: String? = nil,
                sshKeyID: UUID? = nil, osBadge: OSBadge? = nil, osBadgeIsManual: Bool = false,
                themeID: String? = nil, startupSnippetID: UUID? = nil, lastConnectedAt: Date? = nil,
                useSystemSSH: Bool? = nil, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.label = label; self.address = address; self.port = port
        self.groupID = groupID; self.tags = tags; self.username = username
        self.identityID = identityID; self.password = password; self.sshKeyID = sshKeyID
        self.osBadge = osBadge; self.osBadgeIsManual = osBadgeIsManual; self.themeID = themeID
        self.startupSnippetID = startupSnippetID; self.lastConnectedAt = lastConnectedAt
        self.useSystemSSH = useSystemSSH
        self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct Identity: SyncableModel {
    public static let recordType = SyncRecordType.identity
    public var id: UUID
    public var label: String
    public var username: String
    public var password: String?
    public var sshKeyID: UUID?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), label: String, username: String, password: String? = nil,
                sshKeyID: UUID? = nil, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.label = label; self.username = username; self.password = password
        self.sshKeyID = sshKeyID; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct SSHKey: SyncableModel {
    public static let recordType = SyncRecordType.sshKey
    public var id: UUID
    public var label: String
    public var keyType: KeyType
    public var publicKey: String
    public var privateKey: String
    public var passphrase: String?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), label: String, keyType: KeyType, publicKey: String, privateKey: String,
                passphrase: String? = nil, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.label = label; self.keyType = keyType; self.publicKey = publicKey
        self.privateKey = privateKey; self.passphrase = passphrase
        self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct Snippet: SyncableModel {
    public static let recordType = SyncRecordType.snippet
    public var id: UUID
    public var name: String
    public var script: String
    public var package: String?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), name: String, script: String, package: String? = nil,
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.name = name; self.script = script; self.package = package
        self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct KnownHost: SyncableModel {
    public static let recordType = SyncRecordType.knownHost
    public var id: UUID
    public var hostPort: String
    public var keyType: String
    public var fingerprintSHA256: String
    /// Base64 of the public key wire blob; absent on records created before it was stored.
    public var publicKeyBase64: String?
    public var firstSeen: Date
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), hostPort: String, keyType: String, fingerprintSHA256: String,
                publicKeyBase64: String? = nil,
                firstSeen: Date = Date(), updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.hostPort = hostPort; self.keyType = keyType
        self.fingerprintSHA256 = fingerprintSHA256; self.publicKeyBase64 = publicKeyBase64
        self.firstSeen = firstSeen
        self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct ConnectionLog: SyncableModel {
    public static let recordType = SyncRecordType.connectionLog
    public var id: UUID
    public var hostID: UUID?
    public var hostLabel: String
    public var username: String
    public var deviceName: String
    public var startedAt: Date
    public var endedAt: Date?
    public var saved: Bool
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), hostID: UUID? = nil, hostLabel: String, username: String,
                deviceName: String, startedAt: Date = Date(), endedAt: Date? = nil, saved: Bool = false,
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.hostID = hostID; self.hostLabel = hostLabel; self.username = username
        self.deviceName = deviceName; self.startedAt = startedAt; self.endedAt = endedAt
        self.saved = saved; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct ShellHistoryEntry: SyncableModel {
    public static let recordType = SyncRecordType.shellHistory
    public var id: UUID
    public var command: String
    public var hostID: UUID?
    public var executedAt: Date
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), command: String, hostID: UUID? = nil, executedAt: Date = Date(),
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.command = command; self.hostID = hostID; self.executedAt = executedAt
        self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct AISettings: SyncableModel {
    public static let recordType = SyncRecordType.aiSettings
    public var id: UUID
    public var provider: AIProvider
    public var baseURL: String
    public var model: String
    public var apiKey: String?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), provider: AIProvider = .openAICompatible, baseURL: String, model: String,
                apiKey: String? = nil, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.provider = provider; self.baseURL = baseURL; self.model = model
        self.apiKey = apiKey; self.updatedAt = updatedAt; self.deleted = deleted
    }
}
