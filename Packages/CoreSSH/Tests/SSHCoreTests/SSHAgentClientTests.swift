import Foundation
import XCTest
@testable import SSHCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class SSHAgentClientTests: XCTestCase {
    // MARK: Parser

    private func string(_ bytes: [UInt8]) -> [UInt8] {
        let n = UInt32(bytes.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + bytes
    }

    private func uint32(_ n: UInt32) -> [UInt8] {
        [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
    }

    private func blob(_ type: String, _ rest: [UInt8] = [1, 2, 3, 4]) -> [UInt8] {
        string(Array(type.utf8)) + string(rest)
    }

    func testParsesIdentitiesAnswer() throws {
        let ed = blob("ssh-ed25519", Array(repeating: 7, count: 32))
        let rsa = blob("ssh-rsa")
        var body: [UInt8] = [12]
        body += uint32(2)
        body += string(ed)
        body += string(Array("me@mac".utf8))
        body += string(rsa)
        body += string([])
        let keys = try SSHAgentClient.parseIdentitiesAnswer(body)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0].type, "ssh-ed25519")
        XCTAssertEqual(keys[0].comment, "me@mac")
        XCTAssertEqual(keys[0].publicKeyLine, "ssh-ed25519 \(Data(ed).base64EncodedString()) me@mac")
        XCTAssertEqual(keys[0].fingerprint, HostKeyFormat.fingerprintSHA256(publicKeyBlob: Data(ed)))
        XCTAssertEqual(keys[1].type, "ssh-rsa")
        XCTAssertEqual(keys[1].comment, "")
        XCTAssertEqual(keys[1].publicKeyLine, "ssh-rsa \(Data(rsa).base64EncodedString())", "no trailing space without a comment")
        XCTAssertEqual(try SSHAgentClient.parseIdentitiesAnswer([12] + uint32(0)), [])
    }

    func testMalformedRepliesAreRejected() {
        let good = blob("ssh-ed25519")
        let cases: [(String, [UInt8])] = [
            ("empty", []),
            ("unexpected message type", [13] + uint32(0)),
            ("missing count", [12, 0, 0]),
            ("count larger than the keys present", [12] + uint32(2) + string(good) + string([])),
            ("truncated blob", [12] + uint32(1) + uint32(100) + [1, 2]),
            ("missing comment", [12] + uint32(1) + string(good)),
            ("trailing bytes", [12] + uint32(0) + [0]),
            ("blob without a key type", [12] + uint32(1) + string([0, 0]) + string([])),
            ("absurd count", [12] + uint32(0xFFFF_FFFF)),
        ]
        for (name, body) in cases {
            XCTAssertThrowsError(try SSHAgentClient.parseIdentitiesAnswer(body), name) { error in
                XCTAssertEqual(error as? SSHAgentError, .malformedReply, name)
            }
        }
        XCTAssertThrowsError(try SSHAgentClient.parseIdentitiesAnswer([5])) { error in
            XCTAssertEqual(error as? SSHAgentError, .agentFailure)
        }
    }

    func testConnectErrnoMapping() {
        XCTAssertEqual(SSHAgentClient.connectError(errno: ENOENT), .socketNotFound)
        XCTAssertEqual(SSHAgentClient.connectError(errno: EPERM), .permissionDenied)
        XCTAssertEqual(SSHAgentClient.connectError(errno: EACCES), .permissionDenied)
        guard case .connectionFailed = SSHAgentClient.connectError(errno: ECONNREFUSED) else {
            return XCTFail("refused is a connection failure")
        }
    }

    func testErrorMessages() {
        for error: SSHAgentError in [.socketNotFound, .permissionDenied, .connectionFailed("x"), .timedOut,
                                     .agentFailure, .malformedReply] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error)")
        }
    }

    // MARK: Real agent

    func testListsKeysOfARealAgent() async throws {
        let agent = try TestSSHAgent.start()
        defer { agent.stop() }
        let none = try await SSHAgentClient.listKeys(socketPath: agent.socketPath)
        XCTAssertEqual(none, [], "empty agent")

        let ed = try agent.addKey(type: "ed25519", comment: "cory@mini")
        let rsa = try agent.addKey(type: "rsa", comment: "old rsa key")
        let keys = try await SSHAgentClient.listKeys(socketPath: agent.socketPath)
        XCTAssertEqual(keys.map(\.type), ["ssh-ed25519", "ssh-rsa"])
        XCTAssertEqual(keys.map(\.comment), ["cory@mini", "old rsa key"])
        XCTAssertEqual(keys.map(\.publicKeyLine), [ed.publicKeyLine, rsa.publicKeyLine])
        XCTAssertEqual(keys.map(\.fingerprint), [ed.fingerprint, rsa.fingerprint])
    }

    func testMissingSocketIsSocketNotFound() async throws {
        do {
            _ = try await SSHAgentClient.listKeys(socketPath: "/tmp/swiftssh-no-such-\(UUID().uuidString.prefix(8)).sock")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SSHAgentError, .socketNotFound)
        }
    }

    func testNotASocketIsConnectionFailed() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tr-notsock-\(UUID().uuidString.prefix(8))")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await SSHAgentClient.listKeys(socketPath: file.path)
            XCTFail("expected an error")
        } catch {
            guard case .connectionFailed = error as? SSHAgentError else { return XCTFail("\(error)") }
        }
    }

    func testSilentAgentTimesOut() async throws {
        // A listening socket that never accepts: connect succeeds (backlog), the reply never comes.
        let path = "/tmp/swiftssh-silent-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM_VALUE), 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in path.utf8.enumerated() { buffer[i] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { posixBind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 4), 0)

        let started = Date()
        do {
            _ = try await SSHAgentClient.listKeys(socketPath: path, timeout: .milliseconds(300))
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SSHAgentError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

/// Inside an XCTestCase (an NSObject on macOS), plain `bind` resolves to Cocoa's bindings method.
private func posixBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Glibc)
    Glibc.bind(fd, address, length)
    #else
    Darwin.bind(fd, address, length)
    #endif
}

#if canImport(Glibc)
private let SOCK_STREAM_VALUE = SOCK_STREAM.rawValue
#else
private let SOCK_STREAM_VALUE = SOCK_STREAM
#endif
