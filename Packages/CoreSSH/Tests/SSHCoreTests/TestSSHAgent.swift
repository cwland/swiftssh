import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A real OpenSSH `ssh-agent` on its own socket, for tests. Skips the test when the tools are missing.
final class TestSSHAgent: @unchecked Sendable {
    static let agentPath = "/usr/bin/ssh-agent"
    static let addPath = "/usr/bin/ssh-add"
    static let keygenPath = "/usr/bin/ssh-keygen"

    /// Holds the socket and generated keys; short (Unix socket paths are limited) and with a space.
    let directory: URL
    let socketPath: String
    private let pid: pid_t

    private init(directory: URL, socketPath: String, pid: pid_t) {
        self.directory = directory
        self.socketPath = socketPath
        self.pid = pid
    }

    static func start() throws -> TestSSHAgent {
        for tool in [agentPath, addPath, keygenPath] where !FileManager.default.isExecutableFile(atPath: tool) {
            throw XCTSkip("\(tool) is not installed")
        }
        let directory = URL(fileURLWithPath: "/tmp/tr a-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("agent.sock").path
        // In the foreground (-D), so the test owns the process; its output goes nowhere.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: agentPath)
        process.arguments = ["-D", "-a", socketPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        let agent = TestSSHAgent(directory: directory, socketPath: socketPath, pid: pid)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socketPath) {
            guard Date() < deadline else {
                agent.stop()
                throw TestSSHServerError.didNotStart("ssh-agent socket never appeared")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return agent
    }

    struct Key {
        let privateKeyFile: URL
        /// The `.pub` file's line, trimmed ("type base64 comment").
        let publicKeyLine: String
        /// `ssh-keygen -l` fingerprint ("SHA256:…").
        let fingerprint: String
    }

    /// Generates an unencrypted key (`ssh-keygen -t <type>`), without adding it.
    func generateKey(type: String = "ed25519", comment: String) throws -> Key {
        let file = directory.appendingPathComponent("k-\(UUID().uuidString.prefix(8))")
        var arguments = ["-q", "-t", type, "-N", "", "-C", comment, "-f", file.path]
        if type == "rsa" { arguments += ["-b", "2048"] }
        try TestSSHServer.run(Self.keygenPath, arguments)
        let line = try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = try TestSSHServer.run(Self.keygenPath, ["-l", "-E", "sha256", "-f", file.appendingPathExtension("pub").path])
        let fingerprint = try XCTUnwrap(listing.split(separator: " ").first { $0.hasPrefix("SHA256:") }).description
        return Key(privateKeyFile: file, publicKeyLine: line, fingerprint: fingerprint)
    }

    /// Generates a key and `ssh-add`s it.
    @discardableResult
    func addKey(type: String = "ed25519", comment: String) throws -> Key {
        let key = try generateKey(type: type, comment: comment)
        try TestSSHServer.run("/usr/bin/env", ["SSH_AUTH_SOCK=\(socketPath)", Self.addPath, "-q", key.privateKeyFile.path])
        return key
    }

    func stop() {
        // SIGKILL: a foreground ssh-agent started from the test process may not act on SIGTERM.
        kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        try? FileManager.default.removeItem(at: directory)
    }
}
