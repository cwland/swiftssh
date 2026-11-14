#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A key an SSH agent holds (public part only).
public struct AgentKey: Equatable, Sendable {
    /// "type base64 comment" (no trailing space when the comment is empty), as in a `.pub` file.
    public let publicKeyLine: String
    /// The key type, e.g. "ssh-ed25519".
    public let type: String
    public let comment: String
    /// `SHA256:` + unpadded base64, like `ssh-keygen -l` (`HostKeyFormat.fingerprintSHA256`).
    public let fingerprint: String

    public init(publicKeyLine: String, type: String, comment: String, fingerprint: String) {
        self.publicKeyLine = publicKeyLine
        self.type = type
        self.comment = comment
        self.fingerprint = fingerprint
    }
}

public enum SSHAgentError: Error, Equatable, Sendable, LocalizedError {
    /// Nothing exists at the socket path.
    case socketNotFound
    /// The operating system refused access to the socket (EPERM/EACCES), e.g. macOS protecting
    /// another app's data.
    case permissionDenied
    case connectionFailed(String)
    case timedOut
    /// The agent answered SSH_AGENT_FAILURE.
    case agentFailure
    /// The agent's reply didn't follow the protocol.
    case malformedReply

    public var errorDescription: String? {
        switch self {
        case .socketNotFound: "The SSH agent's socket wasn't found."
        case .permissionDenied: "macOS didn't allow access to the SSH agent's socket."
        case .connectionFailed(let reason): "Couldn't talk to the SSH agent: \(reason)"
        case .timedOut: "The SSH agent didn't answer in time."
        case .agentFailure: "The SSH agent refused to list its keys."
        case .malformedReply: "The SSH agent sent a reply that couldn't be read."
        }
    }
}

/// A minimal SSH agent protocol client (draft-miller-ssh-agent) over a Unix socket: lists the agent's keys.
/// It never asks the agent to sign anything.
public enum SSHAgentClient {
    static let requestIdentities: UInt8 = 11 // SSH2_AGENTC_REQUEST_IDENTITIES
    static let identitiesAnswer: UInt8 = 12  // SSH2_AGENT_IDENTITIES_ANSWER
    static let failure: UInt8 = 5            // SSH_AGENT_FAILURE
    /// Replies longer than this are refused (real answers are a few KB).
    static let maxReplyLength = 256 * 1024

    /// The agent's keys, in the agent's order. Throws `SSHAgentError`. The whole exchange (connect, request,
    /// reply) is bounded by `timeout`.
    public static func listKeys(socketPath: String, timeout: Duration = .seconds(5)) async throws -> [AgentKey] {
        let body = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try exchange(socketPath: socketPath, request: [requestIdentities], timeout: timeout)
                })
            }
        }
        return try parseIdentitiesAnswer(body)
    }

    // MARK: Parsing

    /// Parses an agent message body (type byte and payload, without the length prefix) that should be
    /// SSH2_AGENT_IDENTITIES_ANSWER: uint32 count, then per key string blob and string comment.
    static func parseIdentitiesAnswer(_ body: [UInt8]) throws -> [AgentKey] {
        var reader = WireReader(body)
        guard let type = reader.byte() else { throw SSHAgentError.malformedReply }
        if type == failure { throw SSHAgentError.agentFailure }
        guard type == identitiesAnswer, let count = reader.uint32() else { throw SSHAgentError.malformedReply }
        // Every key takes at least 8 bytes (two empty strings); a larger count can't be honest.
        guard Int(count) <= reader.remaining / 8 else { throw SSHAgentError.malformedReply }
        var keys: [AgentKey] = []
        for _ in 0..<count {
            guard let blob = reader.string(), let comment = reader.string(),
                  let keyType = keyType(ofBlob: blob) else { throw SSHAgentError.malformedReply }
            let text = sanitized(String(decoding: comment, as: UTF8.self))
            let base64 = Data(blob).base64EncodedString()
            keys.append(AgentKey(publicKeyLine: text.isEmpty ? "\(keyType) \(base64)" : "\(keyType) \(base64) \(text)",
                                 type: keyType, comment: text,
                                 fingerprint: HostKeyFormat.fingerprintSHA256(publicKeyBlob: Data(blob))))
        }
        guard reader.remaining == 0 else { throw SSHAgentError.malformedReply }
        return keys
    }

    /// The key type string at the start of a key blob: non-empty printable ASCII without spaces.
    private static func keyType(ofBlob blob: [UInt8]) -> String? {
        var reader = WireReader(blob)
        guard let name = reader.string(), !name.isEmpty, name.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return String(decoding: name, as: UTF8.self)
    }

    /// Control characters (line breaks included) become spaces, so a comment can't break a key line.
    private static func sanitized(_ comment: String) -> String {
        String(String.UnicodeScalarView(comment.unicodeScalars.map {
            $0.value < 0x20 || $0.value == 0x7F ? " " : $0
        })).trimmingCharacters(in: .whitespaces)
    }

    static func connectError(errno code: Int32) -> SSHAgentError {
        switch code {
        case ENOENT, ENOTDIR: .socketNotFound
        case EPERM, EACCES: .permissionDenied
        case ECONNREFUSED: .connectionFailed("Nothing is listening on the agent's socket.")
        default: .connectionFailed(String(cString: strerror(code)))
        }
    }

    // MARK: Socket

    /// Sends one request and returns the reply's body. Blocking; bounded by `timeout`.
    private static func exchange(socketPath: String, request: [UInt8], timeout: Duration) throws -> [UInt8] {
        let deadline = ContinuousClock.now + timeout
        var address = sockaddr_un()
        let path = Array(socketPath.utf8)
        guard !path.isEmpty, path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SSHAgentError.connectionFailed("The socket path is too long.")
        }
        let fd = socket(AF_UNIX, socketStream, 0)
        guard fd >= 0 else { throw SSHAgentError.connectionFailed(String(cString: strerror(errno))) }
        defer { close(fd) }
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.enumerated() { buffer[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            let code = errno
            guard code == EINPROGRESS else { throw connectError(errno: code) }
            try wait(fd, events: Int16(POLLOUT), until: deadline)
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
            if failure != 0 { throw connectError(errno: failure) }
        }

        let count = UInt32(request.count)
        try writeAll(fd, [UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
            + request, until: deadline)
        let header = try readExactly(fd, 4, until: deadline)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= maxReplyLength else { throw SSHAgentError.malformedReply }
        return try readExactly(fd, length, until: deadline)
    }

    private static func wait(_ fd: Int32, events: Int16, until deadline: ContinuousClock.Instant) throws {
        while true {
            let remaining = deadline - .now
            guard remaining > .zero else { throw SSHAgentError.timedOut }
            let (seconds, attoseconds) = remaining.components
            let milliseconds = Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000 + 1)
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&entry, 1, milliseconds)
            if result > 0 { return } // ready, or an error/hang-up the next call reports
            if result < 0 && errno != EINTR {
                throw SSHAgentError.connectionFailed(String(cString: strerror(errno)))
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], until deadline: ContinuousClock.Instant) throws {
        var offset = 0
        while offset < bytes.count {
            try wait(fd, events: Int16(POLLOUT), until: deadline)
            let written = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, sendFlags) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                throw SSHAgentError.connectionFailed(String(cString: strerror(errno)))
            }
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int, until deadline: ContinuousClock.Instant) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 65_536))
        while result.count < count {
            try wait(fd, events: Int16(POLLIN), until: deadline)
            let wanted = min(buffer.count, count - result.count)
            let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, wanted, 0) }
            if received > 0 {
                result.append(contentsOf: buffer[0..<received])
            } else if received == 0 {
                throw SSHAgentError.connectionFailed("The agent closed the connection.")
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw SSHAgentError.connectionFailed(String(cString: strerror(errno)))
            }
        }
        return result
    }

    #if canImport(Darwin)
    private static let socketStream = SOCK_STREAM
    private static let sendFlags: Int32 = 0
    #else
    private static let socketStream = Int32(SOCK_STREAM.rawValue)
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif
}

/// Reads SSH wire format values (RFC 4251): bytes, uint32 and length-prefixed strings.
private struct WireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func byte() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string() -> [UInt8]? {
        let start = offset
        guard let length = uint32(), Int(length) <= remaining else {
            offset = start
            return nil
        }
        defer { offset += Int(length) }
        return Array(bytes[offset..<offset + Int(length)])
    }
}
