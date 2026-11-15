import Foundation
import SyncCore

/// What went wrong while setting up or running sync, as Settings shows it. Never carries the API
/// key, the passphrase, the vault key or record contents.
public enum SyncSetupError: Error, Equatable, Sendable {
    case invalidURL
    /// No HTTP answer; the associated text is a short fixed description ("the connection was refused").
    case unreachable(String)
    /// HTTP 401/403: the API key was rejected.
    case unauthorized
    /// Any other HTTP error status.
    case server(Int)
    case wrongPassphrase
    case vaultAlreadyExists
    case noVault
    case weakPassphrase
    /// The server's vault is gone or is a different vault than the one this Mac joined.
    case vaultChanged
    /// A pulled record failed its integrity check.
    case tampered
    case other(String)
    /// The server or a proxy answered with a redirect, which sync never follows.
    case redirected
    /// macOS (App Transport Security) refused a plain http:// connection.
    case insecureConnectionBlocked

    /// Short, user-facing.
    public var message: String {
        switch self {
        case .invalidURL: "Enter an http:// or https:// address with a host name."
        case .unreachable(let reason): "Can't reach the sync server: \(reason)."
        case .unauthorized: "The sync server rejected the API key."
        case .server(let status): "The sync server returned an error (HTTP \(status))."
        case .wrongPassphrase: "That passphrase is wrong."
        case .vaultAlreadyExists: "This server already has a vault. Join it instead."
        case .noVault: "This server has no vault yet."
        case .weakPassphrase: "Use a passphrase of at least 12 characters."
        case .vaultChanged: "The vault on the server was replaced. Disconnect and set up sync again."
        case .tampered: "A record on the server failed its integrity check, so syncing stopped."
        case .other(let message): message
        case .redirected:
            "The sync server redirected the request. Use the final address (check your proxy) in Settings → Sync."
        case .insecureConnectionBlocked: "macOS blocked a plain http:// connection. Use your https:// proxy address."
        }
    }

    /// Maps engine, transport and other errors without copying their descriptions.
    init(_ error: any Error) {
        switch error {
        case let error as SyncSetupError: self = error
        case let error as SyncTransportError:
            switch error {
            case .unauthorized: self = .unauthorized
            case .unreachable(let reason): self = .unreachable(reason)
            case .http(let status, _): self = .server(status)
            case .invalidResponse: self = .other("The sync server's answer wasn't understood.")
            case .redirected: self = .redirected
            case .insecureConnectionBlocked: self = .insecureConnectionBlocked
            }
        case let error as SyncError:
            switch error {
            case .wrongPassphrase: self = .wrongPassphrase
            case .noVault: self = .noVault
            case .vaultAlreadyExists: self = .vaultAlreadyExists
            case .vaultChanged: self = .vaultChanged
            case .tamperedRecord: self = .tampered
            case .locked: self = .other("Sync is locked. Enter the sync passphrase.")
            case .invalidVaultMetadata: self = .other("The vault settings on the server are invalid.")
            case .invalidServerResponse: self = .other("The sync server sent an inconsistent answer.")
            }
        case let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection:
            self = .insecureConnectionBlocked
        case let error as URLError:
            self = .unreachable(error.code == .timedOut ? "the request timed out" : "network error \(error.code.rawValue)")
        case is DecodingError: self = .other("The sync server's answer wasn't understood.")
        default: self = .other("Sync failed.")
        }
    }
}
