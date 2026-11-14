import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A throwaway OpenSSH server for integration tests.
///
/// Starts `/usr/sbin/sshd -D` on 127.0.0.1 with a fresh ed25519 host key, its own `authorized_keys`
/// file and a log file (LogLevel VERBOSE), all inside a temporary directory. A local test user is
/// created once (`useradd -m` + `chpasswd`). Requires root; tests are skipped otherwise.
final class TestSSHServer: @unchecked Sendable {
    static let username = "trtestuser"
    static let password = "Tr-test-pw-7f3c9"
    static let sshdPath = "/usr/sbin/sshd"

    let host = "127.0.0.1"
    let port: Int
    var username: String { Self.username }
    var password: String { Self.password }
    /// OpenSSH key type name, e.g. `ssh-ed25519`.
    let hostKeyType: String
    /// Public key wire blob of the server's host key.
    let hostKeyBlob: Data
    let directory: URL
    let logFile: URL
    let authorizedKeysFile: URL
    private let process: Process

    private init(port: Int, hostKeyType: String, hostKeyBlob: Data, directory: URL, process: Process) {
        self.port = port
        self.hostKeyType = hostKeyType
        self.hostKeyBlob = hostKeyBlob
        self.directory = directory
        self.logFile = directory.appendingPathComponent("sshd.log")
        self.authorizedKeysFile = directory.appendingPathComponent("authorized_keys")
        self.process = process
    }

    /// Starts a server, or throws `XCTSkip` when not running as root or sshd is missing.
    static func start() throws -> TestSSHServer {
        guard geteuid() == 0 else { throw XCTSkip("TestSSHServer needs root") }
        guard FileManager.default.isExecutableFile(atPath: sshdPath) else { throw XCTSkip("sshd not installed") }
        try ensureTestUser()
        try FileManager.default.createDirectory(atPath: "/run/sshd", withIntermediateDirectories: true)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tr-sshd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let hostKey = dir.appendingPathComponent("ssh_host_ed25519_key")
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
        let pubLine = try String(contentsOf: hostKey.appendingPathExtension("pub"), encoding: .utf8)
        let fields = pubLine.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
            throw TestSSHServerError.badHostKey
        }

        let authorized = dir.appendingPathComponent("authorized_keys")
        _ = FileManager.default.createFile(atPath: authorized.path, contents: Data(),
                                           attributes: [.posixPermissions: 0o644])
        let log = dir.appendingPathComponent("sshd.log")
        let config = """
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        PidFile \(dir.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(authorized.path)
        PubkeyAuthentication yes
        PasswordAuthentication yes
        KbdInteractiveAuthentication no
        UsePAM yes
        StrictModes no
        PermitRootLogin no
        AllowUsers \(username)
        LogLevel VERBOSE

        """
        let configFile = dir.appendingPathComponent("sshd_config")
        try config.write(to: configFile, atomically: true, encoding: .utf8)

        let port = try freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshdPath)
        process.arguments = ["-D", "-f", configFile.path, "-p", String(port), "-E", log.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let server = TestSSHServer(port: port, hostKeyType: String(fields[0]), hostKeyBlob: blob,
                                   directory: dir, process: process)
        let deadline = Date().addingTimeInterval(10)
        while !server.log().contains("Server listening on") {
            guard process.isRunning, Date() < deadline else {
                let log = server.log()
                server.stop()
                throw TestSSHServerError.didNotStart(log)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return server
    }

    /// Appends a public key line (`ssh-ed25519 AAAA… comment`) to the server's authorized_keys file.
    func authorize(publicKeyLine: String) throws {
        let handle = try FileHandle(forWritingTo: authorizedKeysFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((publicKeyLine.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
    }

    /// The sshd log so far.
    func log() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private static func ensureTestUser() throws {
        if getpwnam(username) == nil {
            try run("/usr/sbin/useradd", ["-m", "-s", "/bin/bash", username])
        }
        // Always (re)set the password so a user left over from an older run still matches.
        try run("/usr/sbin/chpasswd", [], stdin: "\(username):\(password)\n")
    }

    /// Runs a tool and returns its combined output; arguments never carry secrets (chpasswd reads them
    /// from stdin). Uses posix_spawn + waitpid: Foundation's `Process.waitUntilExit` can hang on Linux
    /// when called from a Swift concurrency thread (the child is never reaped).
    @discardableResult
    static func run(_ path: String, _ arguments: [String], stdin: String? = nil) throws -> String {
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        guard pipe(&input) == 0, pipe(&output) == 0 else { throw TestSSHServerError.socket("pipe") }
        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        #else
        var actions: posix_spawn_file_actions_t?
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, output[1], 2)
        posix_spawn_file_actions_addclose(&actions, input[1])
        posix_spawn_file_actions_addclose(&actions, output[0])

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, nil, argv, environ)
        close(input[0])
        close(output[1])
        guard spawned == 0 else {
            close(input[1])
            close(output[0])
            throw TestSSHServerError.commandFailed(path, spawned, "posix_spawn failed")
        }
        if let stdin {
            let bytes = Array(stdin.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { write(input[1], $0.baseAddress, $0.count) }
                if written <= 0 { break }
                offset += written
            }
        }
        close(input[1])

        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(output[0], $0.baseAddress, $0.count) }
            if count <= 0 { break }
            collected.append(contentsOf: buffer[0..<count])
        }
        close(output[0])

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let text = String(decoding: collected, as: UTF8.self)
        let exitedNormally = (status & 0x7f) == 0
        let exitCode = (status >> 8) & 0xff
        guard exitedNormally, exitCode == 0 else {
            throw TestSSHServerError.commandFailed(path, status, text)
        }
        return text
    }

    /// Binds port 0 on 127.0.0.1 to let the kernel pick a free port, then releases it.
    static func freePort() throws -> Int {
        let fd = try ListeningSocket.makeBoundSocket()
        defer { close(fd) }
        return try ListeningSocket.localPort(of: fd)
    }
}

enum TestSSHServerError: Error {
    case badHostKey
    case didNotStart(String)
    case commandFailed(String, Int32, String)
    case socket(String)
}

/// A TCP socket that accepts connections into the kernel backlog but never reads or writes:
/// an SSH client connecting to it waits forever for the server banner.
final class ListeningSocket {
    let fd: Int32
    let port: Int

    init() throws {
        fd = try Self.makeBoundSocket()
        guard listen(fd, 8) == 0 else { close(fd); throw TestSSHServerError.socket("listen") }
        port = try Self.localPort(of: fd)
    }

    deinit { close(fd) }

    static func makeBoundSocket() throws -> Int32 {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw TestSSHServerError.socket("socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(fd); throw TestSSHServerError.socket("bind") }
        return fd
    }

    static func localPort(of fd: Int32) throws -> Int {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard result == 0 else { throw TestSSHServerError.socket("getsockname") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
