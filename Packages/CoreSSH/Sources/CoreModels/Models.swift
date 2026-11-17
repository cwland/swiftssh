import Foundation


public enum KeyType: String, Codable, Sendable, CaseIterable {
    case ed25519, rsa
}

public enum AIProvider: String, Codable, Sendable, CaseIterable {
    case openAICompatible, anthropic
}

/// Logging in with 1Password's SSH agent instead of a stored password or key.
public struct AgentKeyChoice: Codable, Hashable, Sendable {
    /// Public key line ("ssh-ed25519 AAAA… comment") to pin; nil = let the agent offer any key.
    public var publicKey: String?

    public init(publicKey: String?) {
        self.publicKey = publicKey
    }
}

/// Attaching to a tmux session after login ("Attach to tmux"). Stored on hosts and groups as an
/// optional, where nil means the same as `.inherit` (older records have no value).
///
/// Encoded as `{"kind": "inherit" | "off" | "session", "name": …}`. A kind this build doesn't know,
/// or a session without a name, decodes as `.inherit`, so a newer build's value never makes the whole
/// record unreadable.
public enum TmuxChoice: Codable, Hashable, Sendable {
    /// Use the nearest group's choice; off when no group has one.
    case inherit
    /// Never attach (also stops the walk up the groups).
    case off
    /// Run `tmux new -A -s <name>` after login.
    case session(String)

    /// The name used when the user switches attaching on.
    public static let defaultSessionName = "main"

    /// `[A-Za-z0-9_-]{1,64}`: safe on a command line and kept as-is by tmux (which rewrites "." and ":").
    public static func isValidSessionName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count) else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }

    /// The session name for `.session`, else nil.
    public var sessionName: String? {
        if case .session(let name) = self { return name }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        switch kind {
        case "off":
            self = .off
        case "session":
            if let name = try? container.decodeIfPresent(String.self, forKey: .name) {
                self = .session(name)
            } else {
                self = .inherit
            }
        default:
            self = .inherit
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inherit:
            try container.encode("inherit", forKey: .kind)
        case .off:
            try container.encode("off", forKey: .kind)
        case .session(let name):
            try container.encode("session", forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }
}

public struct HostGroup: SyncableModel {
    public static let recordType = SyncRecordType.hostGroup
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var defaultIdentityID: UUID?
    public var defaultPort: Int?
    public var defaultThemeID: String?
    /// Attach to tmux for the group's hosts that inherit; nil (or `.inherit`) = the parent's choice.
    public var defaultTmuxSession: TmuxChoice?
    /// The snippet typed after login for the group's hosts that have none of their own; nil (or a
    /// missing snippet) = the parent's. Absent on records written before v0.11.0 (decodes as nil).
    public var startupSnippetID: UUID?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, defaultIdentityID: UUID? = nil,
                defaultPort: Int? = nil, defaultThemeID: String? = nil, defaultTmuxSession: TmuxChoice? = nil,
                startupSnippetID: UUID? = nil, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.name = name; self.parentID = parentID
        self.defaultIdentityID = defaultIdentityID; self.defaultPort = defaultPort
        self.defaultThemeID = defaultThemeID; self.defaultTmuxSession = defaultTmuxSession
        self.startupSnippetID = startupSnippetID
        self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct Host: SyncableModel {
    public static let recordType = SyncRecordType.host
    public var id: UUID
    public var label: String
    public var address: String
    /// A second address (typically a Tailscale IP or MagicDNS name), tried when `address` can't be
    /// reached; same port, username and credentials. nil = none. Absent on records written before
    /// v1.2.0 (decodes as nil); older versions keep it when they rewrite the host (unknown fields are kept).
    public var fallbackAddress: String?
    /// nil = inherit from group; effective default is 22.
    public var port: Int?
    public var groupID: UUID?
    public var tags: [String]
    public var username: String?
    public var identityID: UUID?
    public var password: String?
    public var sshKeyID: UUID?
    /// Non-nil = log in with the 1Password SSH agent (wins over `sshKeyID` and `password`).
    public var agentKey: AgentKeyChoice?
    /// The login method the user chose: true = an identity (the explicit one, else the group's default;
    /// the host's own username and secrets are kept but not used), false = the host's own credentials,
    /// nil = not recorded (older records): inferred from which fields are set.
    public var prefersIdentity: Bool?
    public var osBadge: OSBadge?
    public var osBadgeIsManual: Bool
    public var themeID: String?
    /// The snippet typed after login; nil (or a missing snippet) = the nearest group's, unless
    /// `startupSnippetOff`.
    public var startupSnippetID: UUID?
    /// true = "None": run no startup snippet, not even a group's. A snippet in `startupSnippetID`
    /// still wins. nil/false = Default. Absent on records written before v0.11.0.
    public var startupSnippetOff: Bool?
    public var lastConnectedAt: Date?
    /// nil/false = built-in engine unless the credential forces system ssh; true = always use /usr/bin/ssh.
    public var useSystemSSH: Bool?
    /// Attach to tmux after login; nil (or `.inherit`) = the nearest group's choice, else off.
    public var tmuxSession: TmuxChoice?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), label: String, address: String, fallbackAddress: String? = nil,
                port: Int? = nil, groupID: UUID? = nil,
                tags: [String] = [], username: String? = nil, identityID: UUID? = nil, password: String? = nil,
                sshKeyID: UUID? = nil, agentKey: AgentKeyChoice? = nil, prefersIdentity: Bool? = nil,
                osBadge: OSBadge? = nil, osBadgeIsManual: Bool = false,
                themeID: String? = nil, startupSnippetID: UUID? = nil, startupSnippetOff: Bool? = nil,
                lastConnectedAt: Date? = nil,
                useSystemSSH: Bool? = nil, tmuxSession: TmuxChoice? = nil,
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.label = label; self.address = address; self.fallbackAddress = fallbackAddress
        self.port = port
        self.groupID = groupID; self.tags = tags; self.username = username
        self.identityID = identityID; self.password = password; self.sshKeyID = sshKeyID
        self.agentKey = agentKey; self.prefersIdentity = prefersIdentity
        self.osBadge = osBadge; self.osBadgeIsManual = osBadgeIsManual; self.themeID = themeID
        self.startupSnippetID = startupSnippetID; self.startupSnippetOff = startupSnippetOff
        self.lastConnectedAt = lastConnectedAt
        self.useSystemSSH = useSystemSSH; self.tmuxSession = tmuxSession
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
    /// Non-nil = log in with the 1Password SSH agent (wins over `sshKeyID` and `password`).
    public var agentKey: AgentKeyChoice?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), label: String, username: String, password: String? = nil,
                sshKeyID: UUID? = nil, agentKey: AgentKeyChoice? = nil, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.label = label; self.username = username; self.password = password
        self.sshKeyID = sshKeyID; self.agentKey = agentKey; self.updatedAt = updatedAt; self.deleted = deleted
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
    /// The hosts "Run on several hosts" remembers ("Save targets"); nil = none saved. Absent on
    /// records written before v0.8.0 (decodes as nil).
    public var targetHostIDs: [UUID]?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), name: String, script: String, package: String? = nil,
                targetHostIDs: [UUID]? = nil,
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.name = name; self.script = script; self.package = package
        self.targetHostIDs = targetHostIDs
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

/// The AI assistant's provider settings (not used by the app yet).
///
/// Warning: the `.aiSettings` record type is shared. The custom highlighting rules are stored as
/// one record of this type too (`TerminalHighlightRules`, id `TerminalHighlightRules.singletonID`),
/// so that app versions before v0.11 don't fail a pull on an unknown type. Code for AI settings
/// must therefore never treat "the" `.aiSettings` record as a singleton or count/delete records by
/// type alone: read with `LocalVault.all(AISettings.self)` (which skips the rules record, as it
/// doesn't decode as `AISettings`), and exclude `TerminalHighlightRules.singletonID` from any
/// count (`liveCounts()`), "Reset AI" delete or other per-type operation. Planned follow-up: once
/// every app version in use skips unknown record types, give the rules a type of their own.
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
