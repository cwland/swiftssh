import Foundation
import XCTest
@testable import SSHCore

final class SSHDebugLogTests: XCTestCase {
    /// A real OpenSSH 9.6 `-v` log of a password login (trimmed), plus lines that must never surface.
    private let passwordLog = """
    OpenSSH_9.6p1 Ubuntu-3ubuntu13.20, OpenSSL 3.0.13 30 Jan 2024
    debug1: Reading configuration data /dev/null
    debug1: Connecting to 127.0.0.1 [127.0.0.1] port 54109.
    debug1: Connection established.
    debug1: identity file /root/.ssh/id_rsa type -1
    debug1: Local version string SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20
    debug1: Remote protocol version 2.0, remote software version OpenSSH_9.6p1 Ubuntu-3ubuntu13.20
    debug1: Authenticating to 127.0.0.1:54109 as 'trtestuser'
    debug1: Server host key: ssh-ed25519 SHA256:KBBtg/KZXZPAwoKbrf6GzEak3sdbRVmOzQQpeOaxJI8
    debug1: Found key in /tmp/p1probe/kh:1
    debug1: Authentications that can continue: publickey,password
    debug1: Next authentication method: password
    debug1: read_passphrase: requested to askpass
    debug2: we sent a password packet, wait for reply
    debug3: send packet: type 50 secret-looking-payload
    Authenticated to 127.0.0.1 ([127.0.0.1]:54109) using "password".
    debug1: channel 0: new session [client-session] (inactive timeout: 0)
    debug1: Entering interactive session.
    debug1: pledge: network
    debug1: Sending command: echo hi
    Transferred: sent 3224, received 3132 bytes, in 0.1 seconds
    Bytes per second: sent 36576.8, received 35533.0
    debug1: Exit status 0
    """

    func testPasswordLoginStepsInOrder() {
        var parser = SSHDebugLogParser(agent: false)
        let lines = passwordLog.split(separator: "\n").map { parser.consume(String($0)) }
        let steps = lines.compactMap { if case .step(let step) = $0 { step } else { nil } }
        XCTAssertEqual(steps, [
            .connecting(address: "127.0.0.1", port: 54109),
            .connected(address: "127.0.0.1"),
            .handshake,
            .authenticating(method: "password"),
            .authenticated,
            .openingShell,
        ])
        let messages = lines.compactMap { if case .message(let text) = $0 { text } else { nil } }
        XCTAssertEqual(messages, [], "no debug or verbose line is ever a message")
    }

    func testErrorsAreMessagesAndUnknownDebugLinesAreIgnored() {
        var parser = SSHDebugLogParser(agent: false)
        XCTAssertEqual(parser.consume("ssh: connect to host 127.0.0.1 port 1: Connection refused"),
                       .message("ssh: connect to host 127.0.0.1 port 1: Connection refused"))
        XCTAssertEqual(parser.consume("trtestuser@127.0.0.1: Permission denied (publickey,password)."),
                       .message("trtestuser@127.0.0.1: Permission denied (publickey,password)."))
        XCTAssertEqual(parser.consume("debug1: Offering public key: /x/y.key ED25519 SHA256:abc explicit"), .ignored)
        XCTAssertEqual(parser.consume("debug2: Connecting to evil [1.2.3.4] port 22."), .ignored, "only debug1")
        XCTAssertEqual(parser.consume("debug1: Connecting to h [not an address] port 22."), .ignored)
        XCTAssertEqual(parser.consume("debug1: Connecting to h [10.0.0.1] port 99999."), .ignored)
        XCTAssertEqual(parser.consume("debug1: Connection established."), .ignored, "no address seen yet")
        XCTAssertEqual(parser.consume("debug1: Next authentication method: gssapi-with-mic"), .ignored)
        XCTAssertEqual(parser.consume(""), .ignored)
    }

    func testMethodsAndIPv6() {
        var parser = SSHDebugLogParser(agent: false)
        XCTAssertEqual(parser.consume("debug1: Connecting to example.com [2001:db8::1] port 2222."),
                       .step(.connecting(address: "2001:db8::1", port: 2222)))
        XCTAssertEqual(parser.consume("debug1: Connection established."), .step(.connected(address: "2001:db8::1")))
        XCTAssertEqual(parser.consume("debug1: Next authentication method: publickey"), .step(.authenticating(method: "key")))
        XCTAssertEqual(parser.consume("debug1: Next authentication method: publickey"), .ignored, "repeats are dropped")
        XCTAssertEqual(parser.consume("debug1: Next authentication method: keyboard-interactive"),
                       .step(.authenticating(method: "keyboard")))
        XCTAssertEqual(parser.consume("debug1: Authentication succeeded (keyboard-interactive)."), .step(.authenticated))
        XCTAssertEqual(parser.consume("debug1: Requesting pty."), .step(.openingShell))

        var agent = SSHDebugLogParser(agent: true)
        XCTAssertEqual(agent.consume("debug1: Next authentication method: publickey"),
                       .step(.authenticating(method: "1Password agent")))
    }

    func testReaderReadsGrowingFileAndUnlinksItOnceWritten() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = SSHRuntimeDirectory(root: directory, controlDirectory: directory)
        let url = try runtime.writeDebugLog()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        let reader = try SSHDebugLogReader(url: url)
        // Like ssh: opened for appending before anything is read.
        let writer = try FileHandle(forWritingTo: url)
        XCTAssertEqual(reader.readLines(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "kept until ssh wrote to it")

        writer.write(Data("debug1: one\r\ndebug1: tw".utf8))
        XCTAssertEqual(reader.readLines(), ["debug1: one"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "unlinked once ssh has it open")
        writer.write(Data("o\nthree".utf8))
        XCTAssertEqual(reader.readLines(), ["debug1: two"])
        XCTAssertEqual(reader.readLines(includePartial: true), ["three"])
        try writer.close()
        reader.close()
        XCTAssertEqual(reader.readLines(), [])
    }

    func testReaderCloseRemovesAnUnreadFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try SSHRuntimeDirectory(root: directory, controlDirectory: directory).writeDebugLog()
        let reader = try SSHDebugLogReader(url: url)
        reader.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
