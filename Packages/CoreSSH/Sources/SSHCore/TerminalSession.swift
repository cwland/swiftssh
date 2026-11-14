import CoreModels
import Foundation

public enum SSHEngine: Sendable, Equatable {
    case citadel
    case systemSSH
}

public enum SSHCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case password(String)
    case privateKey(type: KeyType, pem: String, passphrase: String?)
    case none

    /// Secrets are never printed.
    public var description: String {
        switch self {
        case .password:
            "password(<redacted>)"
        case .privateKey(let type, _, let passphrase):
            "privateKey(type: \(type.rawValue), pem: <redacted>, passphrase: \(passphrase == nil ? "nil" : "<redacted>"))"
        case .none:
            "none"
        }
    }

    public var debugDescription: String { description }
}

public struct ConnectionPlan: Sendable {
    public var hostID: UUID?
    public var label: String
    public var host: String
    public var port: Int
    public var username: String
    public var credential: SSHCredential
    public var engine: SSHEngine
    public var startupScript: String?

    public init(hostID: UUID?, label: String, host: String, port: Int, username: String,
                credential: SSHCredential, engine: SSHEngine, startupScript: String?) {
        self.hostID = hostID; self.label = label; self.host = host; self.port = port
        self.username = username; self.credential = credential; self.engine = engine
        self.startupScript = startupScript
    }
}
