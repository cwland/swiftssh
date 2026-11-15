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
/// file and a log file (LogLevel VERBOSE), all inside a per-run directory under
/// `<tmp>/tr-sshd-tests/`. A local test user is created once (`useradd -m`); its password is random
/// and set with `chpasswd` on every start. Requires root; tests are skipped otherwise.
///
/// Processes are started with `posix_spawn` and reaped with `waitpid`: Foundation's
/// `Process.waitUntilExit()` can hang on Linux when called from a Swift concurrency thread.
final class TestSSHServer: @unchecked Sendable {
    static let username = "trtestuser"
    static let sshdPath = "/usr/sbin/sshd"
    static let baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tr-sshd-tests", isDirectory: true)

    let host = "127.0.0.1"
    let port: Int
    let username = TestSSHServer.username
    let password: String
    /// OpenSSH key type name, e.g. `ssh-ed25519`.
    let hostKeyType: String
    /// Public key wire blob of the server's host key.
    let hostKeyBlob: Data
    let directory: URL
    let logFile: URL
    let authorizedKeysFile: URL
    private let pid: pid_t
    private let stopped = NSLock()
    private let suspended = NSLock()
    private var suspendedPIDs: Set<pid_t> = []
    private var isStopped = false

    /// Run directories of servers started by this process (never treated as stale).
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var liveDirectories: Set<String> = []

    private init(port: Int, password: String, hostKeyType: String, hostKeyBlob: Data, directory: URL, pid: pid_t) {
        self.port = port
        self.password = password
        self.hostKeyType = hostKeyType
        self.hostKeyBlob = hostKeyBlob
        self.directory = directory
        self.logFile = directory.appendingPathComponent("sshd.log")
        self.authorizedKeysFile = directory.appendingPathComponent("authorized_keys")
        self.pid = pid
    }

    /// Starts a server, or throws `XCTSkip` when not running as root or sshd is missing.
    static func start() throws -> TestSSHServer {
        guard geteuid() == 0 else { throw XCTSkip("TestSSHServer needs root") }
        guard FileManager.default.isExecutableFile(atPath: sshdPath) else { throw XCTSkip("sshd not installed") }
        try FileManager.default.createDirectory(atPath: "/run/sshd", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        killStaleServers()

        let password = "Tr-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        try ensureTestUser(password: password)

        var lastError: Error = TestSSHServerError.didNotStart("no attempt")
        for _ in 1...3 {
            do {
                return try startOnce(password: password)
            } catch TestSSHServerError.portInUse(let log) {
                lastError = TestSSHServerError.portInUse(log) // another process took the port; try a new one
            }
        }
        throw lastError
    }

    private static func startOnce(password: String) throws -> TestSSHServer {
        let dir = baseDirectory.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        liveLock.withLock { _ = liveDirectories.insert(dir.path) }
        var started = false
        defer {
            if !started {
                liveLock.withLock { _ = liveDirectories.remove(dir.path) }
                try? FileManager.default.removeItem(at: dir)
            }
        }

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
        // StrictModes no: the authorized_keys path is under world-writable /tmp.
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
        let pid = try spawnDetached(sshdPath, ["-D", "-f", configFile.path, "-p", String(port), "-E", log.path])
        let server = TestSSHServer(port: port, password: password, hostKeyType: String(fields[0]),
                                   hostKeyBlob: blob, directory: dir, pid: pid)
        let deadline = Date().addingTimeInterval(10)
        while !server.log().contains("Server listening on") {
            var status: Int32 = 0
            let exited = waitpid(pid, &status, WNOHANG) == pid
            if exited || Date() > deadline {
                let text = server.log()
                if !exited { server.stop() }
                if text.contains("Bind to port") || text.contains("Cannot bind any address") {
                    throw TestSSHServerError.portInUse(text)
                }
                throw TestSSHServerError.didNotStart(text)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        started = true
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

    /// Freezes (SIGSTOP) every per-connection sshd process and its children, so open connections stay
    /// up at the TCP level but the server never answers again — like a hung or vanished host.
    /// Linux only (reads /proc). `stop()` resumes them before shutting down.
    func suspendSessions() {
        let pids = descendants(of: pid)
        suspended.withLock { suspendedPIDs.formUnion(pids) }
        for child in pids { kill(child, SIGSTOP) }
    }

    /// Kills (SIGKILL) every per-connection sshd process and its children, without letting them say
    /// goodbye: they are frozen first, so no channel close or exit status reaches the client, then killed.
    /// The kernel closes their sockets — like a server that crashed or a connection that was cut.
    /// Linux only (reads /proc). The listening server keeps running.
    func killSessions() {
        let pids = descendants(of: pid)
        for child in pids { kill(child, SIGSTOP) }
        for child in pids { kill(child, SIGKILL) }
    }

    private func resumeSessions() {
        let pids = suspended.withLock { () -> Set<pid_t> in
            defer { suspendedPIDs = [] }
            return suspendedPIDs
        }
        for child in pids { kill(child, SIGCONT) }
    }

    /// All processes below `root` (children, grandchildren, ...), from /proc/<pid>/stat.
    private func descendants(of root: pid_t) -> Set<pid_t> {
        var parents: [pid_t: pid_t] = [:]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        for entry in entries {
            guard let child = pid_t(entry),
                  let stat = try? String(contentsOfFile: "/proc/\(child)/stat", encoding: .utf8),
                  let close = stat.lastIndex(of: ")") else { continue }
            // Fields after the command name: state ppid ...
            let fields = stat[stat.index(after: close)...].split(separator: " ")
            if fields.count >= 2, let ppid = pid_t(fields[1]) { parents[child] = ppid }
        }
        var result: Set<pid_t> = []
        var frontier: Set<pid_t> = [root]
        while !frontier.isEmpty {
            let next = Set(parents.filter { frontier.contains($0.value) }.map(\.key)).subtracting(result)
            result.formUnion(next)
            frontier = next
        }
        return result
    }

    func stop() {
        resumeSessions()
        let first = stopped.withLock { () -> Bool in
            defer { isStopped = true }
            return !isStopped
        }
        guard first else { return }
        kill(pid, SIGTERM)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        Self.liveLock.withLock { _ = Self.liveDirectories.remove(directory.path) }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Stale servers

    /// Kills sshd processes left by an earlier, crashed test run, but only those whose PID file lives
    /// in our own `tr-sshd-tests` area and whose command line names that run directory.
    private static func killStaleServers() {
        let live = liveLock.withLock { liveDirectories }
        let entries = (try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
        for dir in entries where dir.lastPathComponent.hasPrefix("run-") && !live.contains(dir.path) {
            let pidText = (try? String(contentsOf: dir.appendingPathComponent("sshd.pid"), encoding: .utf8)) ?? ""
            if let stale = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), stale > 1,
               commandLine(of: stale).contains(dir.path) {
                kill(stale, SIGTERM)
                let deadline = Date().addingTimeInterval(2)
                while kill(stale, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if kill(stale, 0) == 0 { kill(stale, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static func commandLine(of pid: pid_t) -> String {
        #if os(Linux)
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else { return "" }
        return String(decoding: data.map { $0 == 0 ? UInt8(ascii: " ") : $0 }, as: UTF8.self)
        #else
        return ""
        #endif
    }

    // MARK: Helpers

    private static func ensureTestUser(password: String) throws {
        if getpwnam(username) == nil {
            try run("/usr/sbin/useradd", ["-m", "-s", "/bin/bash", username])
        }
        try run("/usr/sbin/chpasswd", [], stdin: "\(username):\(password)\n")
    }

    /// Spawns a long-running process with stdin/stdout/stderr on /dev/null; reap it with `waitpid`.
    private static func spawnDetached(_ path: String, _ arguments: [String]) throws -> pid_t {
        try withFileActions { actions in
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
            return try spawn(path, arguments, actions: &actions)
        }
    }

    /// Runs a tool and returns its combined output; arguments never carry secrets (chpasswd reads them
    /// from stdin).
    @discardableResult
    static func run(_ path: String, _ arguments: [String], stdin: String? = nil) throws -> String {
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        guard pipe(&input) == 0, pipe(&output) == 0 else { throw TestSSHServerError.socket("pipe") }
        let pid: pid_t
        do {
            pid = try withFileActions { actions in
                posix_spawn_file_actions_adddup2(&actions, input[0], 0)
                posix_spawn_file_actions_adddup2(&actions, output[1], 1)
                posix_spawn_file_actions_adddup2(&actions, output[1], 2)
                posix_spawn_file_actions_addclose(&actions, input[1])
                posix_spawn_file_actions_addclose(&actions, output[0])
                return try spawn(path, arguments, actions: &actions)
            }
        } catch {
            [input[0], input[1], output[0], output[1]].forEach { close($0) }
            throw error
        }
        close(input[0])
        close(output[1])
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

    #if os(Linux)
    private typealias FileActions = posix_spawn_file_actions_t
    #else
    private typealias FileActions = posix_spawn_file_actions_t?
    #endif

    private static func withFileActions<T>(_ body: (inout FileActions) throws -> T) throws -> T {
        #if os(Linux)
        var actions = FileActions()
        #else
        var actions: FileActions = nil  // Darwin: an opaque pointer that init allocates
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        return try body(&actions)
    }

    private static func spawn(_ path: String, _ arguments: [String], actions: inout FileActions) throws -> pid_t {
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, nil, argv, environ)
        guard result == 0 else { throw TestSSHServerError.commandFailed(path, result, "posix_spawn failed") }
        return pid
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
    case portInUse(String)
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
