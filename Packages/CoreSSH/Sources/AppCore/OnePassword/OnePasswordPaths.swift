#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import SSHCore

/// What was found where 1Password's SSH agent socket should be.
public enum AgentSocketStatus: Equatable, Sendable {
    /// The socket exists at this path.
    case available(String)
    /// Something is at this path, but the system refused to look (macOS protects 1Password's group
    /// container): ssh may still succeed once macOS allows access.
    case blocked(String)
    case notFound
}

/// Where 1Password's SSH agent socket and CLI (`op`) live on a Mac.
public enum OnePasswordPaths {
    /// The agent's real socket first, then the `~/.1password/agent.sock` link users often make.
    /// Expanded against a home directory.
    public static let agentSocketCandidates = [
        "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock",
        "~/.1password/agent.sock",
    ]

    /// 1Password's group container: the agent socket and the app's settings live here, and macOS 27
    /// guards it ("Data shared by 1Password" in Privacy & Security → Files & Folders).
    public static let groupContainer = "~/Library/Group Containers/2BUA8C4S2C.com.1password"

    /// The file `op` reads first to find the desktop app (research: "settings.json: operation not
    /// permitted" when macOS blocks the container). Only opened to see whether access is allowed;
    /// never read.
    public static let groupContainerProbeFile =
        groupContainer + "/Library/Application Support/1Password/Data/settings/settings.json"

    /// Homebrew on Apple silicon, then Homebrew on Intel / the official installer.
    public static let cliCandidates = ["/opt/homebrew/bin/op", "/usr/local/bin/op"]

    /// What a path check found.
    public enum Probe: Equatable, Sendable {
        case exists
        case missing
        /// The system refused to look (EPERM/EACCES).
        case denied

        /// The result of a failed `stat` with this errno.
        public init(statErrno: Int32) {
            self = statErrno == EPERM || statErrno == EACCES ? .denied : .missing
        }
    }

    /// Checks a path with `stat` (following links): exists, missing, or denied.
    public static func probe(_ path: String) -> Probe {
        var info = stat()
        return stat(path, &info) == 0 ? .exists : Probe(statErrno: errno)
    }

    /// Opens `path` read-only and closes it at once (nothing is read): exists, missing, or denied.
    /// Unlike `stat`, this is refused when macOS guards the folder the file is in.
    public static func probeOpen(_ path: String) -> Probe {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return .exists
        }
        return Probe(statErrno: errno)
    }

    /// Whether this app may look into 1Password's group container (`groupContainerProbeFile`). macOS
    /// may ask the user to allow access the first time.
    public static func groupContainerAccess(home: String, probe: (String) -> Probe = probeOpen) -> Probe {
        probe(expandTilde(groupContainerProbeFile, home: home))
    }

    /// `groupContainerAccess(home:)` on a global queue: the open can wait behind macOS's "would like
    /// to access data from other apps" prompt, which must not stall the main thread or a Swift
    /// concurrency thread.
    public static func groupContainerAccessInBackground(home: String) async -> Probe {
        await inBackground { groupContainerAccess(home: home) }
    }

    /// Runs `work` on a global dispatch queue (never the caller's thread) and returns its result.
    public static func inBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    /// The agent socket: a non-blank `override` (tilde-expanded against `home`) is the only path looked
    /// at; otherwise the first candidate that exists. nil when nothing is found.
    public static func agentSocket(home: String, override: String?, fileExists: (String) -> Bool) -> String? {
        socketPaths(home: home, override: override).first(where: fileExists)
    }

    /// The agent socket's path when it is `.available` or `.blocked` (see `agentSocketStatus`).
    public static func agentSocket(home: String, override: String?, probe: (String) -> Probe) -> String? {
        switch agentSocketStatus(home: home, override: override, probe: probe) {
        case .available(let path), .blocked(let path): path
        case .notFound: nil
        }
    }

    /// With a non-blank `override` (tilde-expanded against `home`), only that path decides. Otherwise the
    /// first candidate that exists is `.available`; failing that, the first one the system refused to
    /// look at is `.blocked`; else `.notFound`.
    public static func agentSocketStatus(home: String, override: String?, probe: (String) -> Probe) -> AgentSocketStatus {
        let results = socketPaths(home: home, override: override).map { ($0, probe($0)) }
        if let found = results.first(where: { $0.1 == .exists }) { return .available(found.0) }
        if let refused = results.first(where: { $0.1 == .denied }) { return .blocked(refused.0) }
        return .notFound
    }

    /// The `op` executable: a non-blank `override` is the only path looked at; otherwise the first
    /// candidate that is executable.
    public static func cli(override: String?, isExecutable: (String) -> Bool) -> String? {
        if let override = nonBlank(override) { return isExecutable(override) ? override : nil }
        return cliCandidates.first(where: isExecutable)
    }

    private static func socketPaths(home: String, override: String?) -> [String] {
        if let override = nonBlank(override) { return [expandTilde(override, home: home)] }
        return agentSocketCandidates.map { expandTilde($0, home: home) }
    }

    /// "~" and "~/…" against `home`; anything else unchanged.
    static func expandTilde(_ path: String, home: String) -> String {
        var base = home
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        if path == "~" { return base }
        if path.hasPrefix("~/") { return base + path.dropFirst() }
        return path
    }

    /// Whether a socket path override can be handed to ssh (`IdentityAgent="…"`): nil when it can (a blank
    /// one, meaning no override, included), otherwise the message to show. Rejects `"`, `\`, control
    /// characters and `${` (ssh would expand it from the environment); `%` is fine. The same check runs
    /// again before ssh starts.
    public static func validateSocketOverride(_ path: String) -> String? {
        guard let path = nonBlank(path) else { return nil }
        return SystemSSHSession.agentSocketProblem(path)
    }

    static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
