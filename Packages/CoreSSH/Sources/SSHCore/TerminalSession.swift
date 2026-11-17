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
    /// Sign in with the first of these keys the server accepts, offered in order (built-in engine only,
    /// Ed25519; at most `SSHKeyCandidate.maxAttempts`). Used on iPhone/iPad for keys imported there.
    case privateKeys([SSHKeyCandidate])
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
        case .privateKeys(let keys):
            "privateKeys(\(keys.count) keys: <redacted>)"
        case .none:
            "none"
        }
    }

    private static func keyType(of publicKeyLine: String) -> String {
        publicKeyLine.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "?"
    }

    public var debugDescription: String { description }
}

/// A private key offered by `SSHCredential.privateKeys`. Neither the key nor its public half is ever printed.
public struct SSHKeyCandidate: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The most keys one connection offers: servers count each refused key as a failed login
    /// (OpenSSH's default `MaxAuthTries` is 6).
    public static let maxAttempts = 5

    public let type: KeyType
    /// The unencrypted private key (OpenSSH format).
    public let pem: String
    /// The name shown for the key (not secret, but not printed either).
    public let label: String
    /// The public key, "type base64" (a trailing comment is allowed), to match a host's pinned key.
    public let publicKey: String

    public init(type: KeyType, pem: String, label: String, publicKey: String) {
        self.type = type
        self.pem = pem
        self.label = label
        self.publicKey = publicKey
    }

    /// "type base64" of `publicKey` (or of any public key line), without a comment.
    public static func keyIdentity(_ publicKeyLine: String) -> String {
        publicKeyLine.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
    }

    public var description: String { "SSHKeyCandidate(type: \(type.rawValue), <redacted>)" }
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

    /// The app's policy: a probe every 5 seconds, dead after 2 missed in a row (about 10–15 seconds for
    /// a server that goes dark). Typed input without an echo, a network change and a wake from sleep
    /// check sooner (`TerminalSession.checkConnection`).
    public static let standard = KeepAlivePolicy(interval: .seconds(5), maxUnanswered: 2)
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
    /// `TERM` for the remote shell (both engines).
    public var terminalType: TerminalType
    /// How long reaching and signing in to the server may take. Shorter for automatic reconnect tries,
    /// so a server that is still booting fails fast and the next try comes sooner.
    public var connectTimeout: Duration = .seconds(15)
    /// The saved host's backup address (same port, username and credentials), tried by the session
    /// manager when `host` can't be reached; nil = none (always nil for quick connect). Engines ignore it.
    public var fallbackHost: String?
    /// How long reaching the server (looking up the name and opening the TCP connection) may take, within
    /// `connectTimeout`; nil = only `connectTimeout` applies. Set by the session manager when a backup
    /// address exists, so an unreachable main address gives way to it quickly.
    public var reachTimeout: Duration?

    /// An `.agent` credential always gets `.systemSSH`, whatever `engine` says.
    public init(hostID: UUID?, label: String, host: String, port: Int, username: String,
                credential: SSHCredential, engine: SSHEngine, startupScript: String?,
                keepAlive: KeepAlivePolicy = .standard, agentKey: AgentKeyChoice? = nil,
                terminalType: TerminalType = .default, fallbackHost: String? = nil) {
        self.hostID = hostID; self.label = label; self.host = host; self.port = port
        self.username = username; self.credential = credential; self.engine = engine
        self.startupScript = startupScript
        self.keepAlive = keepAlive
        self.agentKey = agentKey
        self.terminalType = terminalType
        self.fallbackHost = fallbackHost
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

/// A step of connecting, reported with `SessionEvent.progress` before `.connected` / `.ready`. Payloads
/// never contain secrets: only host names, addresses, ports and auth method names.
public enum ConnectionStep: Sendable, Equatable {
    /// Looking up the host name.
    case resolving(host: String)
    /// Opening the TCP connection.
    case connecting(address: String, port: Int)
    /// The TCP connection is up.
    case connected(address: String)
    /// The SSH protocol handshake (version exchange, key exchange, host key check).
    case handshake
    /// Signing in; `method` is a display name: "password", "key", "1Password agent" or "keyboard".
    case authenticating(method: String)
    case authenticated
    /// Opening the PTY and shell.
    case openingShell
    /// Attaching to a tmux session after the shell is ready (sent by the session manager, not engines).
    case attachingTmux(session: String)

    /// The line shown in the connection log.
    public var text: String {
        switch self {
        case .resolving(let host): "Resolving \(host)\u{2026}"
        case .connecting(let address, let port):
            "Connecting to \(address.contains(":") ? "[\(address)]" : address):\(port)\u{2026}"
        case .connected: "Connection established"
        case .handshake: "Starting SSH session\u{2026}"
        case .authenticating(let method): "Signing in with \(method)\u{2026}"
        case .authenticated: "Signed in"
        case .openingShell: "Opening terminal\u{2026}"
        case .attachingTmux(let session): "Attaching to tmux session \(session)\u{2026}"
        }
    }
}

public enum SessionEvent: Sendable, Equatable {
    /// A step of connecting; emitted (zero or more times) before `.connected` / `.ready`, never after `.closed`.
    case progress(ConnectionStep)
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
    /// The server couldn't be reached at all: the name wasn't found, the connection was refused, or there
    /// is no route to it. The payload is the message (shown like `connectionFailed`'s). A timeout while
    /// reaching the server stays `.timedOut`.
    case unreachable(String)
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
        case .connectionFailed(let reason), .unreachable(let reason):
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
    /// Single-consumer event stream: `.progress` steps, `.connected`, then `.ready` (at most once) and `.output` in order,
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
    /// Checks right away whether the server still answers (after a network change, a wake from sleep,
    /// or typed input without an echo); a dead connection ends the session as a failure. Engines that
    /// can't probe on demand rely on their keep-alive.
    func checkConnection() async
}

extension TerminalSession {
    public func checkConnection() async {}
}
