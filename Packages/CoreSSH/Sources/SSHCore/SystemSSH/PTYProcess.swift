// Mac-only (and Linux, where the package tests run): iOS has no child processes (Process, forkpty).
#if os(macOS) || os(Linux)
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
///   and `TERM` (`terminalType`, xterm-256color unless given; a `TERM` in the given environment wins).
///   It closes every descriptor from 3 up to `RLIMIT_NOFILE`, and its signal mask and common signal
///   dispositions are reset to the defaults.
/// - Output is read on a dedicated thread and delivered in order. The stream ends when the terminal's
///   last slave descriptor is closed (EIO or EOF on the master), after which the child is reaped and
///   `exitStatus` is set.
/// - The master descriptor is non-blocking. Reads and writes wait with `poll` and never hold the state
///   lock while waiting, so `terminate()`, `kill()` and `resize` are never stuck behind a full terminal.
///   A use count keeps the descriptor open while a write is in progress.
public final class PTYProcess: Sendable {
    /// Terminal output, in order. Finishes after the child exited and was reaped.
    public let output: AsyncStream<[UInt8]>
    /// The child's process ID (also its process group and session ID).
    public let pid: pid_t

    private let masterFD: Int32
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let state = Mutex(State())
    /// Serializes writers (never taken by signalling or resizing).
    private let writeLock = NSLock()

    /// What `terminalMode` found.
    enum TerminalMode: Sendable, Equatable {
        /// Line mode (the default; ssh before its session starts).
        case canonical
        /// Canonical mode is off (ssh's session has started).
        case raw
        /// The child is gone.
        case exited
        /// The mode could not be read (`tcgetattr` failed).
        case unavailable
    }

    private struct State {
        /// The child's terminal is still usable (false once the reader saw the end of the stream).
        var fdOpen = true
        /// Writers currently using the descriptor; it is closed when the last one is done.
        var fdUsers = 0
        var fdClosed = false
        /// The child exited (it may not be reaped yet, but its process ID is still reserved).
        var exited = false
        var exitStatus: Int32?
    }

    public convenience init(executable: String, arguments: [String], environment: [String: String],
                            terminalType: TerminalType = .default,
                            cols: Int, rows: Int) throws {
        try self.init(executable: executable, arguments: arguments, environment: environment,
                      terminalType: terminalType, cols: cols, rows: rows, rawMode: false)
    }

    /// `rawMode` starts the terminal without line discipline processing (no echo, no `\n` → `\r\n`),
    /// for capturing a command's output byte for byte.
    init(executable: String, arguments: [String], environment: [String: String],
         terminalType: TerminalType = .default,
         cols: Int, rows: Int, rawMode: Bool) throws {
        // Everything the child needs is prepared before fork: after fork, only async-signal-safe calls.
        let path = CStringArray([executable])
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(Self.childEnvironment(environment, terminalType: terminalType.rawValue).map { "\($0.key)=\($0.value)" }.sorted())
        let descriptorLimit = Self.descriptorLimit()
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
            var fd: Int32 = 3
            while fd < descriptorLimit {
                close(fd)
                fd += 1
            }
            #if os(Linux)
            closefrom(descriptorLimit) // anything above the loop's cap
            #endif
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
        // Not inherited by later children (other sessions' processes); never blocks.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

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

    /// Writes all bytes to the terminal (the child's input), waiting while the terminal is full. Gives up
    /// once the child has ended. Concurrent writers are serialized.
    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, acquireDescriptor() else { return }
        defer { releaseDescriptor() }
        writeLock.lock()
        defer { writeLock.unlock() }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { systemWrite(masterFD, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                guard state.withLock({ $0.fdOpen }) else { return }
                let events = waitForDescriptor(Int16(POLLOUT), milliseconds: 50)
                if events & Int16(POLLHUP | POLLERR) != 0 { return } // the child closed its terminal
            } else {
                return // EIO: the child closed its terminal
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

    /// The terminal's line mode. Programs that take over the terminal, such as ssh once its session has
    /// started, switch canonical mode off.
    var terminalMode: TerminalMode {
        state.withLock { state -> TerminalMode in
            guard state.fdOpen else { return .exited }
            var attributes = termios()
            guard tcgetattr(masterFD, &attributes) == 0 else { return .unavailable }
            return (attributes.c_lflag & tcflag_t(ICANON)) != 0 ? .canonical : .raw
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
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                _ = waitForDescriptor(Int16(POLLIN), milliseconds: 100)
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
            if state.fdUsers == 0 { closeDescriptor(&state) }
        }
        continuation.finish()
    }

    private func acquireDescriptor() -> Bool {
        state.withLock { state in
            guard state.fdOpen else { return false }
            state.fdUsers += 1
            return true
        }
    }

    private func releaseDescriptor() {
        state.withLock { state in
            state.fdUsers -= 1
            if !state.fdOpen && state.fdUsers == 0 { closeDescriptor(&state) }
        }
    }

    private func closeDescriptor(_ state: inout State) {
        guard !state.fdClosed else { return }
        state.fdClosed = true
        close(masterFD)
    }

    /// Waits until the descriptor is ready or the time is up. Where `poll` can't watch a terminal device,
    /// it sleeps briefly instead, so callers simply retry. Returns the reported events.
    private func waitForDescriptor(_ events: Int16, milliseconds: Int32) -> Int16 {
        var entry = pollfd(fd: masterFD, events: events, revents: 0)
        let result = poll(&entry, 1, milliseconds)
        if (result < 0 && errno != EINTR) || (result > 0 && (entry.revents & Int16(POLLNVAL)) != 0) {
            usleep(10_000)
            return 0
        }
        return result > 0 ? entry.revents : 0
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func clamp(_ value: Int) -> UInt16 {
        UInt16(clamping: max(value, 1))
    }

    private static func childEnvironment(_ given: [String: String], terminalType: String) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for name in ["PATH", "HOME", "USER", "LANG"] {
            if let value = parent[name] { environment[name] = value }
        }
        environment["TERM"] = terminalType
        environment.merge(given) { _, new in new }
        return environment
    }

    /// The soft `RLIMIT_NOFILE`, capped at 65536 for the close loop (on Linux, `closefrom` covers the rest).
    private static func descriptorLimit() -> Int32 {
        var limit = rlimit()
        #if canImport(Darwin)
        let result = getrlimit(RLIMIT_NOFILE, &limit)
        #else
        let result = getrlimit(__rlimit_resource_t(RLIMIT_NOFILE.rawValue), &limit)
        #endif
        guard result == 0 else { return 4096 }
        return Int32(min(limit.rlim_cur, 65_536))
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
#endif
