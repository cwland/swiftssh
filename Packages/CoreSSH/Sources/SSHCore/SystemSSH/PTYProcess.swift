#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

/// A child process running in a pseudo-terminal (`forkpty`).
///
/// - The child gets only the given environment plus `PATH`, `HOME`, `USER`, `LANG` (inherited when set)
///   and `TERM=xterm-256color`. It inherits no file descriptors besides the terminal, and its signal
///   mask and common signal dispositions are reset to the defaults.
/// - Output is read on a dedicated thread and delivered in order. The stream ends when the terminal's
///   last slave descriptor is closed (EIO or EOF on the master), after which the child is reaped and
///   `exitStatus` is set.
public final class PTYProcess: Sendable {
    /// Terminal output, in order. Finishes after the child exited and was reaped.
    public let output: AsyncStream<[UInt8]>
    /// The child's process ID (also its process group and session ID).
    public let pid: pid_t

    private let masterFD: Int32
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let state = Mutex(State())

    private struct State {
        /// The master descriptor is still open (it is closed once, by the reader, after the child exited).
        var fdOpen = true
        /// The child exited (it may not be reaped yet, but its process ID is still reserved).
        var exited = false
        var exitStatus: Int32?
    }

    public convenience init(executable: String, arguments: [String], environment: [String: String],
                            cols: Int, rows: Int) throws {
        try self.init(executable: executable, arguments: arguments, environment: environment,
                      cols: cols, rows: rows, rawMode: false)
    }

    /// `rawMode` starts the terminal without line discipline processing (no echo, no `\n` → `\r\n`),
    /// for capturing a command's output byte for byte.
    init(executable: String, arguments: [String], environment: [String: String],
         cols: Int, rows: Int, rawMode: Bool) throws {
        // Everything the child needs is prepared before fork: after fork, only async-signal-safe calls.
        let path = CStringArray([executable])
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(Self.childEnvironment(environment).map { "\($0.key)=\($0.value)" }.sorted())
        let inherited = Self.openDescriptors().filter { $0 > 2 }
        let closeList = UnsafeMutablePointer<Int32>.allocate(capacity: max(inherited.count, 1))
        closeList.initialize(from: inherited, count: inherited.count)
        defer { closeList.deallocate() }
        let closeCount = inherited.count
        guard let pathPointer = path.pointer[0] else { throw POSIXError(.ENOMEM) }
        let argvPointer = argv.pointer
        let envpPointer = envp.pointer
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)

        var size = winsize(ws_row: Self.clamp(rows), ws_col: Self.clamp(cols), ws_xpixel: 0, ws_ypixel: 0)
        var terminal = termios()
        cfmakeraw(&terminal)
        var master: Int32 = -1
        let child = rawMode ? forkpty(&master, nil, &terminal, &size) : forkpty(&master, nil, nil, &size)
        if child == 0 {
            // Child.
            var i = 0
            while i < closeCount {
                close(closeList[i])
                i += 1
            }
            signal(SIGPIPE, SIG_DFL)
            signal(SIGHUP, SIG_DFL)
            signal(SIGINT, SIG_DFL)
            signal(SIGQUIT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
            signal(SIGCHLD, SIG_DFL)
            sigprocmask(SIG_SETMASK, &emptyMask, nil)
            execve(pathPointer, argvPointer, envpPointer)
            _exit(127)
        }
        withExtendedLifetime((path, argv, envp)) {}
        guard child > 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Not inherited by later children (other sessions' processes).
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        pid = child
        masterFD = master
        (output, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .unbounded)
        let reader = Thread { [self] in readLoop() }
        reader.name = "PTYProcess reader"
        reader.start()
    }

    /// The exit code, or 128 + signal number when the child was killed by a signal. Set once the output
    /// stream has ended.
    public var exitStatus: Int32? { state.withLock { $0.exitStatus } }

    /// Writes all bytes to the terminal (the child's input). Does nothing after the child ended.
    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        state.withLock { state in
            guard state.fdOpen else { return }
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { systemWrite(masterFD, $0.baseAddress, $0.count) }
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// Sets the terminal size (`TIOCSWINSZ`); the child gets `SIGWINCH`.
    public func resize(cols: Int, rows: Int) {
        var size = winsize(ws_row: Self.clamp(rows), ws_col: Self.clamp(cols), ws_xpixel: 0, ws_ypixel: 0)
        state.withLock { state in
            guard state.fdOpen else { return }
            _ = ioctl(masterFD, UInt(TIOCSWINSZ), &size)
        }
    }

    /// Sends `SIGHUP` to the child's process group, then `SIGKILL` 2 s later if it is still running.
    public func terminate() {
        signalGroup(SIGHUP)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            signalGroup(SIGKILL)
        }
    }

    /// Sends `SIGKILL` to the child's process group at once.
    func kill() {
        signalGroup(SIGKILL)
    }

    /// True while the terminal is in canonical (line) mode. Programs that take over the terminal, such
    /// as ssh once its session has started, switch canonical mode off.
    var isCanonicalMode: Bool? {
        state.withLock { state -> Bool? in
            guard state.fdOpen else { return nil }
            var attributes = termios()
            guard tcgetattr(masterFD, &attributes) == 0 else { return nil }
            return (attributes.c_lflag & tcflag_t(ICANON)) != 0
        }
    }

    // MARK: Private

    private func signalGroup(_ signal: Int32) {
        state.withLock { state in
            // While the child is not reaped its process ID cannot be reused, so this never hits a stranger.
            guard !state.exited else { return }
            _ = systemKill(-pid, signal)
            _ = systemKill(pid, signal)
        }
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, $0.count) }
            if count > 0 {
                continuation.yield(Array(buffer[0..<count]))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break // EIO (Linux) or EOF (macOS): every slave descriptor is closed.
            }
        }
        // Wait for the exit without reaping, so that signalGroup can never signal a reused process ID.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        state.withLock { $0.exited = true }
        var status: Int32 = 0
        var reaped = waitpid(pid, &status, 0)
        while reaped == -1 && errno == EINTR { reaped = waitpid(pid, &status, 0) }
        let code: Int32? = reaped == pid ? Self.exitCode(status) : nil
        state.withLock { state in
            state.exitStatus = code
            state.fdOpen = false
            close(masterFD)
        }
        continuation.finish()
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func clamp(_ value: Int) -> UInt16 {
        UInt16(clamping: max(value, 1))
    }

    private static func childEnvironment(_ given: [String: String]) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for name in ["PATH", "HOME", "USER", "LANG"] {
            if let value = parent[name] { environment[name] = value }
        }
        environment["TERM"] = "xterm-256color"
        environment.merge(given) { _, new in new }
        return environment
    }

    /// The process's open file descriptors, so the child can close them (it must not inherit other
    /// sessions' terminals, sockets or pipes).
    private static func openDescriptors() -> [Int32] {
        #if os(Linux)
        let directory = "/proc/self/fd"
        #else
        let directory = "/dev/fd"
        #endif
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let listed = names.compactMap { Int32($0) }
        if !listed.isEmpty { return listed }
        // Fallback: every descriptor number below a sane limit.
        let limit = min(Int32(clamping: sysconf(Int32(_SC_OPEN_MAX))), 4096)
        return Array(0..<max(limit, 3))
    }
}

private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buffer, count)
}

private func systemKill(_ pid: pid_t, _ signal: Int32) -> Int32 {
    kill(pid, signal)
}

/// A NULL-terminated C string array allocated before fork and freed when it goes out of scope.
private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { pointer[index] = strdup(string) }
        pointer[strings.count] = nil
    }

    deinit {
        for index in 0..<count { free(pointer[index]) }
        pointer.deallocate()
    }
}
