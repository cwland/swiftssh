#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The private directory for system ssh's temporary files: the askpass helper, one-time secret files,
/// temporary private keys and each session's generated `known_hosts` file. ssh's control sockets live in a separate,
/// short `controlDirectory` (`/tmp/tr-<uid>`), because Unix socket paths are limited to 104 bytes on macOS
/// and the app's run directory is far too deep for `<dir>/<40-character %C>`.
///
/// The directory is 0700 and every file is created 0600 (the helper 0700) with `O_EXCL | O_NOFOLLOW`,
/// so a file never exists with looser permissions and a planted link is never followed.
public struct SSHRuntimeDirectory: Sendable {
    public let root: URL
    /// Holds ssh's control sockets (`ControlPath=<controlDirectory>/%C`).
    public let controlDirectory: URL

    /// The app passes `~/Library/Application Support/TermiusReimagined/run`; tests inject `controlDirectory`.
    public init(root: URL, controlDirectory: URL = SSHRuntimeDirectory.defaultControlDirectory) {
        self.root = root.standardizedFileURL
        self.controlDirectory = controlDirectory
    }

    /// `/tmp/tr-<uid>`.
    public static var defaultControlDirectory: URL {
        URL(fileURLWithPath: "/tmp/tr-\(getuid())", isDirectory: true)
    }

    public var askpassURL: URL { root.appendingPathComponent("askpass") }

    /// The askpass helper. ssh runs it with the prompt as its argument; it prints the one-time secret
    /// (never the prompt) and deletes the file, so a second ask fails.
    static let askpassScript = """
    #!/bin/sh
    f="$TR_SECRET_FILE"
    [ -n "$f" ] && [ -f "$f" ] && cat "$f" && rm -f "$f"

    """

    /// Creates the directory (0700; an existing one is tightened to 0700) and (re)writes the askpass helper.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST {
            throw SSHRuntimeError.failed("create the runtime directory", errno)
        }
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw SSHRuntimeError.failed("inspect the runtime directory", errno) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), info.st_uid == getuid() else {
            throw SSHRuntimeError.unsafeDirectory
        }
        guard chmod(root.path, 0o700) == 0 else { throw SSHRuntimeError.failed("protect the runtime directory", errno) }
        try replace(askpassURL, contents: Data(Self.askpassScript.utf8), mode: 0o700)
    }

    /// Creates `controlDirectory` with mode 0700 when it is missing. An existing one must be a real
    /// directory (not a link) owned by this user with mode exactly 0700; anything else throws
    /// `.unsafeControlDirectory` and is left untouched (it may belong to someone else).
    public func prepareControlDirectory() throws {
        let path = controlDirectory.path
        if mkdir(path, 0o700) == 0 {
            // Ours, just created: undo any umask narrowing.
            guard chmod(path, 0o700) == 0 else { throw SSHRuntimeError.failed("protect the control socket directory", errno) }
        } else if errno != EEXIST {
            throw SSHRuntimeError.failed("create the control socket directory", errno)
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == getuid(),
              (info.st_mode & 0o7777) == 0o700 else {
            throw SSHRuntimeError.unsafeControlDirectory(path)
        }
    }

    /// Removes everything inside the directory (called at app launch). Does nothing if it doesn't exist.
    public func clean() throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return
        }
        for name in names {
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Writes a one-time secret (password or key passphrase) for the askpass helper, 0600, unique name.
    public func writeSecret(_ secret: String) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).secret")
        try create(url, contents: Data(secret.utf8), mode: 0o600)
        return url
    }

    /// Writes a private key for `ssh -i`, 0600, unique name. A missing final newline is added (OpenSSH
    /// rejects some key files without one); the key itself is written unchanged.
    public func writeKey(_ pem: String) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).key")
        try create(url, contents: Data((pem.hasSuffix("\n") ? pem : pem + "\n").utf8), mode: 0o600)
        return url
    }

    /// Writes a session's own known_hosts file, `<uuid>.known_hosts` (0600). Lines containing a line break
    /// are skipped, so a line can never smuggle in another entry.
    public func writeKnownHosts(_ lines: [String]) throws -> URL {
        let safe = lines.filter { !$0.contains(where: { $0 == "\n" || $0 == "\r" }) }
        let text = safe.map { $0 + "\n" }.joined()
        let url = root.appendingPathComponent("\(UUID().uuidString).known_hosts")
        try create(url, contents: Data(text.utf8), mode: 0o600)
        return url
    }

    /// Removes a file; a missing file is not an error.
    func remove(_ url: URL) {
        _ = unlink(url.path)
    }

    // MARK: Private

    /// Writes a temporary file next to `url`, then renames it over `url`.
    private func replace(_ url: URL, contents: Data, mode: mode_t) throws {
        let temporary = root.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try create(temporary, contents: contents, mode: mode)
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            remove(temporary)
            throw SSHRuntimeError.failed("write \(url.lastPathComponent)", code)
        }
    }

    /// Creates a new file (never an existing one, never through a link) with exactly `mode`.
    private func create(_ url: URL, contents: Data, mode: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw SSHRuntimeError.failed("create \(url.lastPathComponent)", errno) }
        var failure: Int32?
        if fchmod(fd, mode) != 0 { failure = errno } // the umask may have narrowed it
        if failure == nil {
            failure = contents.withUnsafeBytes { buffer -> Int32? in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return errno
                    }
                }
                return nil
            }
        }
        close(fd)
        if let failure {
            remove(url)
            throw SSHRuntimeError.failed("write \(url.lastPathComponent)", failure)
        }
    }
}

/// Runtime directory errors. They name files, never their contents.
public enum SSHRuntimeError: Error, Sendable, Equatable, LocalizedError {
    /// The path exists but is not a directory owned by this user (or is a link).
    case unsafeDirectory
    /// The control socket directory exists but is not a 0700 directory (not a link) owned by this user.
    case unsafeControlDirectory(String)
    case failed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            "The runtime directory is not a private directory owned by this user."
        case .unsafeControlDirectory(let path):
            "Unsafe control socket directory \(path)"
        case .failed(let action, let code):
            "Could not \(action): \(String(cString: strerror(code)))"
        }
    }
}
