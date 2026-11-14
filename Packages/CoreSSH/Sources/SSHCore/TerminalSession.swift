import CoreModels
import Foundation

public enum SSHEngine: Sendable, Equatable {
    case citadel
    case systemSSH
}

public enum SSHCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case password(String)
    case privateKey(type: KeyType, pem: String, passphrase: String?)
    /// Sign in with the keys of an SSH agent (1Password's) at `socketPath`, through system ssh only.
    /// `publicKey` ("type base64 comment") pins one agent key; nil lets the agent offer any key.
    case agent(socketPath: String, publicKey: String?)
    case none

    /// Secrets are never printed; of a pinned agent key only its type is.
    public var description: String {
        switch self {
        case .password:
            "password(<redacted>)"
        case .privateKey(let type, _, let passphrase):
            "privateKey(type: \(type.rawValue), pem: <redacted>, passphrase: \(passphrase == nil ? "nil" : "<redacted>"))"
        case .agent(let socketPath, let publicKey):
            "agent(socketPath: \(socketPath), publicKey: \(publicKey.map { Self.keyType(of: $0) + " <pinned>" } ?? "nil"))"
        case .none:
            "none"
        }
    }

    private static func keyType(of publicKeyLine: String) -> String {
        publicKeyLine.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "?"
    }

    public var debugDescription: String { description }
}

/// How a session detects a dropped connection: a keep-alive probe every `interval`; after
/// `maxUnanswered` unanswered probes in a row the session is declared dead.
public struct KeepAlivePolicy: Sendable, Equatable {
    /// nil = keep-alive off.
    public var interval: Duration?
    /// Unanswered probes in a row before the session is declared dead.
    public var maxUnanswered: Int

    public init(interval: Duration?, maxUnanswered: Int) {
        self.interval = interval
        self.maxUnanswered = maxUnanswered
    }

    public static let fast = KeepAlivePolicy(interval: .seconds(15), maxUnanswered: 2)
    public static let normal = KeepAlivePolicy(interval: .seconds(30), maxUnanswered: 3)
    public static let relaxed = KeepAlivePolicy(interval: .seconds(60), maxUnanswered: 5)
    public static let off = KeepAlivePolicy(interval: nil, maxUnanswered: 0)
}

public struct ConnectionPlan: Sendable {
    public var hostID: UUID?
    public var label: String
    public var host: String
    public var port: Int
    public var username: String
    /// Setting an `.agent` credential also switches `engine` to `.systemSSH`: only system ssh can sign
    /// with an agent.
    public var credential: SSHCredential {
        didSet { if case .agent = credential { engine = .systemSSH } }
    }
    public var engine: SSHEngine
    public var startupScript: String?
    public var keepAlive: KeepAlivePolicy
    /// Non-nil = the host signs in with 1Password's SSH agent. The planner can't know the agent's socket,
    /// so `credential` stays `.none` until the session manager turns this into `.agent(socketPath:publicKey:)`
    /// at connect time.
    public var agentKey: AgentKeyChoice?

    /// An `.agent` credential always gets `.systemSSH`, whatever `engine` says.
    public init(hostID: UUID?, label: String, host: String, port: Int, username: String,
                credential: SSHCredential, engine: SSHEngine, startupScript: String?,
                keepAlive: KeepAlivePolicy = .normal, agentKey: AgentKeyChoice? = nil) {
        self.hostID = hostID; self.label = label; self.host = host; self.port = port
        self.username = username; self.credential = credential; self.engine = engine
        self.startupScript = startupScript
        self.keepAlive = keepAlive
        self.agentKey = agentKey
        if case .agent = credential { self.engine = .systemSSH }
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
    /// The terminal is live: from here on output is shown and input reaches the PTY. Citadel emits it once
    /// authenticated with the PTY open. System ssh emits it when ssh runs; without a stored secret that is
    /// before authentication, so ssh's own prompts appear as output.
    case connected
    /// The remote shell is running and the session is authenticated: safe to send a startup script or run
    /// commands. Emitted at most once, after `.connected` and never after `.closed`. May be missing when
    /// the session ended before it could be observed.
    case ready
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
    /// The SSH agent (1Password) couldn't be reached or refused to sign; the payload is the message shown.
    case agentUnavailable(String)

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
        case .agentUnavailable(let message):
            message
        }
    }
}

/// An interactive SSH terminal: one PTY shell plus optional one-off commands on the same connection.
public protocol TerminalSession: AnyObject, Sendable {
    /// Single-consumer event stream: `.connected`, then `.ready` (at most once) and `.output` in order,
    /// then exactly one `.closed`.
    var events: AsyncStream<SessionEvent> { get }
    /// Connects, authenticates and opens the PTY. Returns once `.connected` (or `.closed`) was emitted;
    /// when the engine authenticates without the user, after `.ready`.
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
