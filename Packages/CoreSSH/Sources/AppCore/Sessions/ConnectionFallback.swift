import Foundation
import SSHCore

/// The backup address rule (a saved host's `fallbackAddress`): the main address is tried first with
/// `reachTimeout` on reaching it; when it can't be reached at all, the backup address is tried at once.
/// A connection that reached the server and then failed (sign-in, host key, the user cancelling, a
/// timeout during the handshake) never moves on to the backup.
public enum ConnectionFallback {
    /// The limit on reaching the main address (name lookup and TCP connect) when a backup exists.
    public static let reachTimeout: Duration = .seconds(5)

    /// The backup address to plan with: trimmed; nil when blank or the same host as `main` (case and a
    /// trailing dot ignored, as for known hosts).
    public static func backupAddress(main: String, backup: String?) -> String? {
        guard let backup = backup?.trimmingCharacters(in: .whitespacesAndNewlines), !backup.isEmpty else { return nil }
        let mainKey = HostKeyFormat.hostPort(host: main.trimmingCharacters(in: .whitespacesAndNewlines), port: 22)
        return HostKeyFormat.hostPort(host: backup, port: 22) == mainKey ? nil : backup
    }

    /// Whether a reported step means the server answered: the TCP connection is up, or a later step.
    public static func reachesServer(_ step: ConnectionStep) -> Bool {
        switch step {
        case .resolving, .connecting: false
        case .connected, .handshake, .authenticating, .authenticated, .openingShell, .attachingTmux: true
        }
    }

    /// Whether an attempt on the main address that ended with `reason` moves on to the backup: only
    /// when it failed with `.timedOut` or `.unreachable` before the server was reached.
    public static func shouldTryBackup(after reason: SessionEndReason, reachedServer: Bool) -> Bool {
        guard !reachedServer, case .failed(let error) = reason else { return false }
        switch error {
        case .timedOut, .unreachable: return true
        case .hostKeyRejected, .hostKeyChanged, .authenticationFailed, .keyUnreadable, .connectionFailed,
             .unsupportedKey, .agentUnavailable:
            return false
        }
    }

    /// Why the main address couldn't be reached, in a few words for the log: "timed out", the socket
    /// error in the message's last parentheses ("connection refused"), the part after ssh's last
    /// colon ("No route to host"), else the whole message.
    public static func reason(of error: SessionError) -> String {
        switch error {
        case .timedOut:
            return "timed out"
        case .unreachable(let message):
            if message.hasSuffix(")"), let open = message.range(of: " (", options: .backwards) {
                return String(message[open.upperBound..<message.index(before: message.endIndex)])
            }
            if message.hasPrefix("ssh: "), let colon = message.range(of: ": ", options: .backwards) {
                return String(message[colon.upperBound...])
            }
            return message
        default:
            return error.localizedDescription
        }
    }

    /// The connection log's line between the two attempts.
    public static func note(main: String, reason: String, backup: String) -> String {
        "Main address \(main) unreachable (\(reason)); trying backup address \(backup)\u{2026}"
    }
}
