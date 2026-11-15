import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Turns lines of `ssh -v -E <file>` into connection steps. Only a fixed set of debug lines is read, and
/// from those only host addresses, ports and auth method names are taken; every other debug line is
/// ignored and never shown anywhere.
struct SSHDebugLogParser {
    /// What a log line is.
    enum Line: Equatable {
        /// A whitelisted debug line: a connection step.
        case step(ConnectionStep)
        /// One of ssh's own messages (no `debug` prefix), e.g. "Permission denied (publickey)." — what
        /// ssh prints on stderr without `-E`. Used only to explain a failure.
        case message(String)
        /// Anything else (all other debug lines, ssh's version banner, verbose statistics): dropped.
        case ignored
    }

    /// Whether the plan signs in with an SSH agent (publickey then means "1Password agent").
    let agent: Bool
    private var lastAddress: String?
    private var lastStep: ConnectionStep?

    init(agent: Bool) {
        self.agent = agent
    }

    /// Classifies one line (without its line break). Repeats of the previous step are `.ignored`.
    mutating func consume(_ rawLine: String) -> Line {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .ignored }
        guard line.hasPrefix("debug") else {
            if line.hasPrefix("Authenticated to ") { return deduplicated(.authenticated) }
            return Self.isVerboseNoise(line) ? .ignored : .message(line)
        }
        guard line.hasPrefix("debug1: ") else { return .ignored }
        let text = line.dropFirst("debug1: ".count)
        guard let step = step(for: text) else { return .ignored }
        return deduplicated(step)
    }

    private mutating func deduplicated(_ step: ConnectionStep) -> Line {
        guard step != lastStep else { return .ignored }
        lastStep = step
        return .step(step)
    }

    private mutating func step(for text: Substring) -> ConnectionStep? {
        if text.hasPrefix("Connecting to ") {
            // "Connecting to <host> [<address>] port <port>."
            guard let open = text.lastIndex(of: "["), let close = text.lastIndex(of: "]"), open < close else { return nil }
            let address = String(text[text.index(after: open)..<close])
            let rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard Self.isAddress(address), rest.hasPrefix("port ") else { return nil }
            let digits = rest.dropFirst("port ".count).prefix { $0.isASCII && $0.isNumber }
            guard let port = Int(digits), (1...65_535).contains(port) else { return nil }
            lastAddress = address
            return .connecting(address: address, port: port)
        }
        if text.hasPrefix("Connection established") {
            guard let lastAddress else { return nil }
            return .connected(address: lastAddress)
        }
        if text.hasPrefix("Local version string") || text.hasPrefix("Remote protocol version") {
            return .handshake
        }
        if text.hasPrefix("Next authentication method: ") {
            let method = text.dropFirst("Next authentication method: ".count).trimmingCharacters(in: .whitespaces)
            return Self.methodName(method, agent: agent).map { .authenticating(method: $0) }
        }
        if text.hasPrefix("Authentication succeeded") {
            return .authenticated
        }
        if text.hasPrefix("Entering interactive session") || text.hasPrefix("Sending command")
            || (text.hasPrefix("Requesting") && text.contains("pty")) {
            return .openingShell
        }
        return nil
    }

    /// The step log's name for one of ssh's auth methods; nil for methods the app never uses.
    static func methodName(_ method: String, agent: Bool) -> String? {
        switch method {
        case "password": "password"
        case "keyboard-interactive": "keyboard"
        case "publickey": agent ? "1Password agent" : "key"
        default: nil
        }
    }

    /// An IPv4 or IPv6 address (with an optional zone), nothing else.
    static func isAddress(_ text: String) -> Bool {
        let allowed = Set("0123456789abcdefABCDEF.:%".unicodeScalars)
        return !text.isEmpty && text.count <= 64 && text.unicodeScalars.allSatisfy {
            allowed.contains($0) || ($0.properties.isAlphabetic && $0.isASCII) // zone names (`%en0`)
        } && (text.contains(".") || text.contains(":"))
    }

    /// ssh's verbose-level lines without a `debug` prefix that `-v` adds and plain ssh never prints.
    static func isVerboseNoise(_ line: String) -> Bool {
        line.hasPrefix("OpenSSH_") || line.hasPrefix("Transferred: ") || line.hasPrefix("Bytes per second")
    }
}

/// Reads the debug log that one ssh run writes (`-E`), as it grows. The file is created empty (0600) in
/// the private runtime directory before ssh starts and unlinked as soon as ssh has written to it (ssh
/// then holds it open), so it is on disk only for a moment; `close()` unlinks it in any case.
final class SSHDebugLogReader: Sendable {
    let url: URL
    private struct State {
        var fd: Int32
        var partial: [UInt8] = []
        var unlinked = false
    }
    private let state: Mutex<State>
    /// The most of one line kept; longer lines are cut (and are never whitelisted ones).
    static let lineLimit = 4_096

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SSHRuntimeError.failed("open \(url.lastPathComponent)", errno) }
        self.url = url
        state = Mutex(State(fd: fd))
    }

    /// The complete lines written since the last call; with `includePartial`, also an unfinished last line.
    func readLines(includePartial: Bool = false) -> [String] {
        state.withLock { state in
            guard state.fd >= 0 else { return [] }
            var lines: [String] = []
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(state.fd, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                if !state.unlinked {
                    // ssh has opened and written the file: nobody needs its name any more.
                    _ = unlink(url.path)
                    state.unlinked = true
                }
                for byte in buffer[0..<count] {
                    if byte == UInt8(ascii: "\n") {
                        lines.append(Self.text(state.partial))
                        state.partial = []
                    } else if state.partial.count < Self.lineLimit {
                        state.partial.append(byte)
                    }
                }
            }
            if includePartial, !state.partial.isEmpty {
                lines.append(Self.text(state.partial))
                state.partial = []
            }
            return lines
        }
    }

    /// Closes the file and removes it if it is still there.
    func close() {
        state.withLock { state in
            if state.fd >= 0 {
                _ = Glibc_or_Darwin_close(state.fd)
                state.fd = -1
            }
            if !state.unlinked {
                _ = unlink(url.path)
                state.unlinked = true
            }
            state.partial = []
        }
    }

    private static func text(_ bytes: [UInt8]) -> String {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}

private func Glibc_or_Darwin_close(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
    Glibc.close(fd)
    #else
    Darwin.close(fd)
    #endif
}
