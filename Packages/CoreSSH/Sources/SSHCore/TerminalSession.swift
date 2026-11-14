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

// MARK: - Terminal sessions

/// Why a terminal session ended. Every session emits exactly one `.closed` event.
public enum SessionEndReason: Sendable, Equatable {
    /// The remote shell exited or the server closed the connection: a normal disconnect.
    case remoteClosed
    /// `close()` was called.
    case userClosed
    case failed(SessionError)
}

public enum SessionEvent: Sendable, Equatable {
    /// The connection is authenticated and the PTY is open.
    case connected
    /// Terminal output (stdout and stderr), in order.
    case output([UInt8])
    /// The last event; the stream finishes after it.
    case closed(SessionEndReason)
}

/// Connection errors. Messages never contain secrets (passwords, keys, passphrases).
public enum SessionError: Error, Sendable, Equatable, LocalizedError {
    case hostKeyRejected
    case hostKeyChanged(previous: String, presented: String)
    /// The server rejected the credentials.
    case authenticationFailed
    /// The private key could not be decoded locally (wrong or missing passphrase, corrupt key);
    /// decided before connecting.
    case keyUnreadable
    case connectionFailed(String)
    case unsupportedKey(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .hostKeyRejected:
            "The server's host key was not trusted, so the connection was stopped before signing in."
        case .hostKeyChanged(let previous, let presented):
            "The server's host key has changed. Previously trusted: \(previous). Presented now: \(presented)."
        case .authenticationFailed:
            "Authentication failed. Check the username and credentials."
        case .keyUnreadable:
            "The private key couldn't be opened. Check the passphrase."
        case .connectionFailed(let reason):
            "The connection failed: \(reason)"
        case .unsupportedKey(let type):
            "The built-in SSH engine does not support \(type) keys."
        case .timedOut:
            "The connection timed out."
        }
    }
}

/// An interactive SSH terminal: one PTY shell plus optional one-off commands on the same connection.
public protocol TerminalSession: AnyObject, Sendable {
    /// Single-consumer event stream: `.connected`, then `.output` in order, then exactly one `.closed`.
    var events: AsyncStream<SessionEvent> { get }
    /// Connects, authenticates and opens the PTY. Returns once the PTY is open or `.closed` was emitted.
    func start(cols: Int, rows: Int) async
    /// Writes bytes to the remote PTY, in call order.
    func send(_ bytes: [UInt8]) async
    /// Forwards a terminal size change, ordered with `send`.
    func resize(cols: Int, rows: Int) async
    /// Runs a command on a separate exec channel, stdout and stderr merged, output capped at 1 MB.
    func runCommand(_ command: String) async throws -> String
    /// Ends the session; emits `.closed(.userClosed)` unless the session already ended.
    func close() async
}
