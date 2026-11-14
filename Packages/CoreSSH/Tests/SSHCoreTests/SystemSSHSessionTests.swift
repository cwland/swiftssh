import AppCore
import CoreModels
import Foundation
import XCTest
@testable import SSHCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Integration tests for the system ssh engine against a real OpenSSH server (`TestSSHServer`).
final class SystemSSHSessionTests: XCTestCase {
    private var server: TestSSHServer!
    private var scratch: URL!
    private var runtime: SSHRuntimeDirectory!

    override func setUpWithError() throws {
        server = try TestSSHServer.start()
        // Short (Unix socket paths are limited) and with a space, like "Application Support" on macOS.
        scratch = URL(fileURLWithPath: "/tmp/tr s-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        runtime = SSHRuntimeDirectory(root: scratch.appendingPathComponent("run", isDirectory: true),
                                      controlDirectory: scratch.appendingPathComponent("ctl", isDirectory: true))
    }

    override func tearDown() {
        // Stop any control master left behind (ControlPersist), then remove the scratch area.
        if let root = runtime?.controlDirectory, let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for name in entries {
                _ = try? TestSSHServer.run("/usr/bin/ssh", ["-o", "ControlPath=\"\(root.path)/\(name)\"", "-O", "exit", "x"])
            }
        }
        server?.stop()
        server = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: Runtime directory

    func testRuntimeDirectoryPermissionsAndAskpassHelper() throws {
        try runtime.prepare()
        XCTAssertEqual(try permissions(runtime.root), 0o700)
        let askpass = runtime.root.appendingPathComponent("askpass")
        XCTAssertEqual(try permissions(askpass), 0o700)
        XCTAssertEqual(try String(contentsOf: askpass, encoding: .utf8), """
        #!/bin/sh
        f="$TR_SECRET_FILE"
        [ -n "$f" ] && [ -f "$f" ] && cat "$f" && rm -f "$f"

        """)

        let secret = try runtime.writeSecret("s3cret value")
        XCTAssertEqual(try permissions(secret), 0o600)
        let other = try runtime.writeSecret("x")
        XCTAssertNotEqual(secret, other, "unique names")
        let key = try runtime.writeKey("-----BEGIN KEY-----\nabc\n-----END KEY-----\n")
        XCTAssertEqual(try permissions(key), 0o600)
        XCTAssertEqual(try String(contentsOf: key, encoding: .utf8), "-----BEGIN KEY-----\nabc\n-----END KEY-----\n")
        let knownHosts = try runtime.writeKnownHosts(["a ssh-ed25519 AAAA", "b ssh-ed25519 BBBB", "c ssh-ed25519 C\nd x y"])
        XCTAssertTrue(knownHosts.lastPathComponent.hasSuffix(".known_hosts"), knownHosts.path)
        XCTAssertEqual(try permissions(knownHosts), 0o600)
        XCTAssertNotEqual(try runtime.writeKnownHosts([]), knownHosts, "one file per session")
        XCTAssertEqual(try String(contentsOf: knownHosts, encoding: .utf8), "a ssh-ed25519 AAAA\nb ssh-ed25519 BBBB\n")

        // The helper prints the secret once (no prompt echo, no newline added) and deletes the file.
        let first = try TestSSHServer.run("/usr/bin/env", ["TR_SECRET_FILE=\(secret.path)", askpass.path, "Password: "])
        XCTAssertEqual(first, "s3cret value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secret.path))
        XCTAssertThrowsError(try TestSSHServer.run("/usr/bin/env", ["TR_SECRET_FILE=\(secret.path)", askpass.path, "Password: "]),
                             "a second ask finds no file and fails")

        try runtime.clean()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtime.root.path), [])
        try runtime.prepare() // idempotent; restores the helper
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: askpass.path))
    }

    func testRuntimeDirectoryTightensLoosePermissions() throws {
        try FileManager.default.createDirectory(at: runtime.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try runtime.prepare()
        XCTAssertEqual(try permissions(runtime.root), 0o700)
    }

    // MARK: Control socket directory

    func testControlDirectoryIsCreatedPrivate() throws {
        try runtime.prepareControlDirectory()
        XCTAssertEqual(try permissions(runtime.controlDirectory), 0o700)
        try runtime.prepareControlDirectory() // an existing safe directory is fine
    }

    func testDefaultControlDirectoryKeepsSocketPathsShort() {
        let mac = SSHRuntimeDirectory(root: URL(fileURLWithPath:
            "/Users/corylanders/Library/Application Support/TermiusReimagined/run"))
        XCTAssertEqual(mac.controlDirectory.path, "/tmp/tr-\(getuid())")
        let socket = mac.controlDirectory.appendingPathComponent(String(repeating: "f", count: 40)).path
        XCTAssertLessThan(socket.utf8.count, 104, "macOS sun_path limit")
        // ssh binds a temporary name (path + "." + 16 characters) before renaming it into place.
        XCTAssertLessThan(socket.utf8.count + 17, 104)
        let args = SystemSSHSession.sshArguments(host: "h", port: 22, username: "u", runtime: mac,
                                                 knownHosts: mac.root.appendingPathComponent("s.known_hosts"),
                                                 auth: .none, hostKeyAlgorithms: "ssh-ed25519")
        XCTAssertTrue(args.contains("ControlPath=\"/tmp/tr-\(getuid())/%C\""), "\(args)")
    }

    func testUnsafeControlDirectoriesAreRefused() throws {
        let control = runtime.controlDirectory
        let expected = SSHRuntimeError.unsafeControlDirectory(control.path)

        // Wrong mode: refused and left alone.
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try runtime.prepareControlDirectory()) { XCTAssertEqual($0 as? SSHRuntimeError, expected) }
        XCTAssertEqual(try permissions(control), 0o755, "never chmod an existing directory")

        // Owned by someone else.
        if geteuid() == 0, let other = getpwnam(TestSSHServer.username) {
            chmod(control.path, 0o700)
            chown(control.path, other.pointee.pw_uid, other.pointee.pw_gid)
            XCTAssertThrowsError(try runtime.prepareControlDirectory()) { XCTAssertEqual($0 as? SSHRuntimeError, expected) }
        }
        try FileManager.default.removeItem(at: control)

        // A symbolic link, even to a private directory of ours.
        let target = scratch.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: control, withDestinationURL: target)
        XCTAssertThrowsError(try runtime.prepareControlDirectory()) { XCTAssertEqual($0 as? SSHRuntimeError, expected) }

        // A plain file.
        try FileManager.default.removeItem(at: control)
        _ = FileManager.default.createFile(atPath: control.path, contents: Data())
        XCTAssertThrowsError(try runtime.prepareControlDirectory()) { XCTAssertEqual($0 as? SSHRuntimeError, expected) }
    }

    func testUnsafeControlDirectoryFailsTheConnection() async throws {
        let control = runtime.controlDirectory
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o777])
        let evaluator = TestEvaluator(decision: .trusted)
        let session = makeSession(.password(server.password), evaluator: evaluator)
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForFinish()
        XCTAssertEqual(recorder.nonOutputEvents,
                       [.closed(.failed(.connectionFailed("Unsafe control socket directory \(control.path)")))])
        XCTAssertTrue(evaluator.candidates.isEmpty, "stopped before anything else")
        XCTAssertEqual(secretFiles(), [])
    }

    // MARK: Pure helpers

    func testSSHArgumentsAreExact() {
        let root = URL(fileURLWithPath: "/a b/run")
        let directory = SSHRuntimeDirectory(root: root, controlDirectory: URL(fileURLWithPath: "/tmp/tr-501"))
        let knownHosts = root.appendingPathComponent("S.known_hosts")
        let common = [
            "-tt", "-F", "/dev/null", "-p", "2200", "-l", "cory",
            "-o", "UserKnownHostsFile=\"/a b/run/S.known_hosts\"",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\"/tmp/tr-501/%C\"",
            "-o", "ControlPersist=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
        ]
        func args(_ auth: SystemSSHSession.AuthArguments, _ algorithms: String = "ssh-ed25519") -> [String] {
            SystemSSHSession.sshArguments(host: "example.com", port: 2200, username: "cory", runtime: directory,
                                          knownHosts: knownHosts, auth: auth, hostKeyAlgorithms: algorithms)
        }
        XCTAssertEqual(args(.key(root.appendingPathComponent("K.key"))), common + [
            "-o", "IdentitiesOnly=yes", "-i", "/a b/run/K.key",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "HostKeyAlgorithms=ssh-ed25519",
            "--", "example.com",
        ])
        XCTAssertEqual(args(.password, "rsa-sha2-512,rsa-sha2-256"), common + [
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "HostKeyAlgorithms=rsa-sha2-512,rsa-sha2-256",
            "--", "example.com",
        ])
        XCTAssertEqual(args(.none), common + ["-o", "HostKeyAlgorithms=ssh-ed25519", "--", "example.com"])

        let command = SystemSSHSession.commandArguments(host: "example.com", port: 2200, username: "cory",
                                                        runtime: directory, knownHosts: knownHosts,
                                                        controlSocket: "/tmp/tr-501/abc", hostKeyAlgorithms: "ssh-ed25519",
                                                        command: "uname -s")
        XCTAssertEqual(command, [
            "-F", "/dev/null", "-p", "2200", "-l", "cory",
            "-o", "UserKnownHostsFile=\"/a b/run/S.known_hosts\"",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\"/tmp/tr-501/abc\"",
            "-o", "ControlPersist=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
            "-o", "HostKeyAlgorithms=ssh-ed25519",
            "-T", "-o", "BatchMode=yes", "--", "example.com", "uname -s",
        ])
    }

    func testKeepAliveArgumentsForEachPreset() {
        let root = URL(fileURLWithPath: "/r")
        let directory = SSHRuntimeDirectory(root: root, controlDirectory: URL(fileURLWithPath: "/tmp/tr-501"))
        let knownHosts = root.appendingPathComponent("S.known_hosts")
        func alive(_ policy: KeepAlivePolicy) -> [String] {
            let interactive = SystemSSHSession.sshArguments(host: "h", port: 22, username: "u", runtime: directory,
                                                            knownHosts: knownHosts, auth: .none,
                                                            hostKeyAlgorithms: "ssh-ed25519", keepAlive: policy)
            let command = SystemSSHSession.commandArguments(host: "h", port: 22, username: "u", runtime: directory,
                                                            knownHosts: knownHosts, controlSocket: "/tmp/s",
                                                            hostKeyAlgorithms: "ssh-ed25519", command: "x",
                                                            keepAlive: policy)
            let pick = { (args: [String]) in args.filter { $0.hasPrefix("ServerAlive") } }
            XCTAssertEqual(pick(interactive), pick(command))
            return pick(interactive)
        }
        XCTAssertEqual(alive(.fast), ["ServerAliveInterval=15", "ServerAliveCountMax=2"])
        XCTAssertEqual(alive(.normal), ["ServerAliveInterval=30", "ServerAliveCountMax=3"])
        XCTAssertEqual(alive(.relaxed), ["ServerAliveInterval=60", "ServerAliveCountMax=5"])
        XCTAssertEqual(alive(.off), ["ServerAliveInterval=0"])
    }

    func testKnownHostsLinesReplaceEveryLineForTheHost() {
        let vault = [
            "other.example ssh-ed25519 AAAA",
            "EXAMPLE.com ssh-ed25519 OLD1",
            "alias,Example.COM ecdsa-sha2-nistp256 OLD2",
            "[example.com]:2200 ssh-ed25519 OTHERPORT",
        ]
        let candidate = HostKeyCandidate(host: "example.com", port: 22, keyType: "ssh-ed25519", publicKeyBlob: wire("ssh-ed25519"))
        XCTAssertEqual(SystemSSHSession.knownHostsFile(vault: vault, trusted: candidate), [
            "other.example ssh-ed25519 AAAA",
            "[example.com]:2200 ssh-ed25519 OTHERPORT",
            "example.com ssh-ed25519 \(wire("ssh-ed25519").base64EncodedString())",
        ])
    }

    func testHostNamesAreValidated() async throws {
        for host in ["attacker.example,*", "a b", "-oProxyCommand=x", "h*st", "h?st", "!h", "#h", "|1|x", "@cert", "hö.example", "", "a\tb"] {
            XCTAssertFalse(SystemSSHSession.isSafeHost(host), host)
        }
        for host in ["example.com", "10.0.0.5", "::1", "fe80::1%en0", "my_host-1.local"] {
            XCTAssertTrue(SystemSSHSession.isSafeHost(host), host)
        }
        var p = plan(.password(server.password))
        p.host = "attacker.example,*"
        let evaluator = TestEvaluator(decision: .trusted)
        let session = SystemSSHSession(plan: p, hostKeys: evaluator, knownHostsLines: { [] }, runtime: runtime)
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForFinish()
        XCTAssertEqual(recorder.nonOutputEvents, [.closed(.failed(.connectionFailed("Invalid host name")))])
        XCTAssertTrue(evaluator.candidates.isEmpty)
        XCTAssertFalse(server.log().contains("Connection from"), "keyscan never ran")
    }

    func testKeyscanParsingAndPreference() throws {
        let ed = wire("ssh-ed25519"), ec = wire("ecdsa-sha2-nistp256"), rsa = wire("ssh-rsa")
        let output = """
        # 10.0.0.5:22 SSH-2.0-OpenSSH_9.6\r
        10.0.0.5 ssh-rsa \(rsa.base64EncodedString())\r
        # 10.0.0.5:22 SSH-2.0-OpenSSH_9.6\r
        10.0.0.5 ecdsa-sha2-nistp256 \(ec.base64EncodedString())\r
        10.0.0.5 ssh-ed25519 \(ed.base64EncodedString())\r
        10.0.0.5 ssh-ed25519 not-base64!\r
        10.0.0.5 ssh-ed25519 \(rsa.base64EncodedString())\r
        garbage
        """
        let all = SystemSSHSession.parseKeyscan(output, host: "10.0.0.5", port: 22)
        XCTAssertEqual(all.map(\.keyType), ["ssh-rsa", "ecdsa-sha2-nistp256", "ssh-ed25519"],
                       "comments, bad base64 and blobs of another type are ignored")
        XCTAssertEqual(SystemSSHSession.preferredCandidate(all)?.keyType, "ssh-ed25519")
        XCTAssertEqual(SystemSSHSession.preferredCandidate(all.filter { $0.keyType != "ssh-ed25519" })?.keyType,
                       "ecdsa-sha2-nistp256")
        XCTAssertEqual(SystemSSHSession.preferredCandidate(all.filter { $0.keyType == "ssh-rsa" })?.keyType, "ssh-rsa")
        XCTAssertNil(SystemSSHSession.preferredCandidate([]))
        XCTAssertEqual(all.first?.hostPort, "10.0.0.5")
        XCTAssertEqual(SystemSSHSession.hostKeyAlgorithms(for: "ssh-rsa"), "rsa-sha2-512,rsa-sha2-256")
        XCTAssertEqual(SystemSSHSession.hostKeyAlgorithms(for: "ecdsa-sha2-nistp384"), "ecdsa-sha2-nistp384")
    }

    func testFailureClassification() {
        let secrets = ["hunter2"]
        func classify(_ s: String) -> SessionError { SystemSSHSession.classifyFailure(Array(s.utf8), secrets: secrets) }
        XCTAssertEqual(classify("Permission denied, please try again.\r\r\nu@h: Permission denied (publickey,password).\r\r\n"),
                       .authenticationFailed)
        XCTAssertEqual(classify("No ED25519 host key is known for h.\r\nHost key verification failed.\r\n"), .hostKeyRejected)
        XCTAssertEqual(classify("Load key \"/r/x.key\": invalid format\r\nu@h: Permission denied (publickey).\r\n"),
                       .keyUnreadable)
        XCTAssertEqual(classify("\u{1B}[1mssh: connect to host h port 22: Connection refused\u{1B}[0m\r\n\r\n"),
                       .connectionFailed("ssh: connect to host h port 22: Connection refused"))
        XCTAssertEqual(classify("weird hunter2 thing\r\n"), .connectionFailed("weird <redacted> thing"))
        XCTAssertEqual(classify(""), .connectionFailed("ssh exited before the session started"))
    }

    // MARK: Connecting

    func testPasswordLoginThroughAskpass() async throws {
        let evaluator = TestEvaluator(decision: .trusted)
        let session = makeSession(.password(server.password), evaluator: evaluator)
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForEvents([.connected, .ready])
        await session.send(Array("echo hi-$((40+2))\n".utf8))
        try await recorder.waitForOutput(containing: "hi-42")
        XCTAssertFalse(recorder.outputText.contains(server.password))

        let candidates = evaluator.candidates
        XCTAssertEqual(candidates.count, 1, "one evaluation")
        XCTAssertEqual(candidates.first?.keyType, server.hostKeyType)
        XCTAssertEqual(candidates.first?.publicKeyBlob, server.hostKeyBlob)
        XCTAssertEqual(candidates.first?.hostPort, "[127.0.0.1]:\(server.port)")
        let root = runtime.root
        try await waitUntil(timeout: 2) { Self.secretFiles(in: root).isEmpty } // incl. known_hosts
        await session.close()
        try await recorder.waitForFinish()
        XCTAssertEqual(recorder.nonOutputEvents, [.connected, .ready, .closed(.userClosed)])
    }

    func testRSAKeyLoginWorks() async throws {
        // PKCS#1 "RSA PRIVATE KEY" PEM, as produced by the app's own generator.
        let generated = try SSHKeyGenerator.rsa4096(comment: "system-ssh-test")
        XCTAssertTrue(generated.privateKey.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"))
        try server.authorize(publicKeyLine: generated.publicKey)
        try await assertShellWorks(.privateKey(type: .rsa, pem: generated.privateKey, passphrase: nil))
        XCTAssertTrue(server.log().contains("Accepted publickey"), server.log())
    }

    func testEncryptedKeyPassphraseThroughAskpass() async throws {
        let keyFile = scratch.appendingPathComponent("client_rsa")
        try TestSSHServer.run("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "2048", "-N", "correct horse", "-f", keyFile.path])
        let pem = try String(contentsOf: keyFile, encoding: .utf8)
        try server.authorize(publicKeyLine: String(contentsOf: keyFile.appendingPathExtension("pub"), encoding: .utf8))
        try await assertShellWorks(.privateKey(type: .rsa, pem: pem, passphrase: "correct horse"))

        // A wrong passphrase: the key is skipped, the second ask finds no secret, the server says no.
        let session = makeSession(.privateKey(type: .rsa, pem: pem, passphrase: "wrong horse"))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForFinish()
        XCTAssertEqual(recorder.nonOutputEvents, [.closed(.failed(.authenticationFailed))])
    }

    func testWrongPasswordIsAuthenticationFailed() async throws {
        let session = makeSession(.password("not-the-password-91b2"))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForFinish()
        XCTAssertEqual(recorder.nonOutputEvents, [.closed(.failed(.authenticationFailed))])
        XCTAssertTrue(recorder.output.isEmpty, "pre-session ssh messages are not shown as terminal output")
    }

    func testNoStoredSecretPromptsInTheTerminal() async throws {
        let session = makeSession(.none)
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForEvents([.connected]) // early: ssh's own prompt must be visible
        try await recorder.waitForOutput(containing: "password:")
        // ssh's readpassphrase flushes pending terminal input (TCSAFLUSH) around the prompt, so type like a
        // person: after the prompt has settled, and the command once the shell is there.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(recorder.nonOutputEvents, [.connected], "not ready while ssh waits for the password")
        do {
            _ = try await session.runCommand("true")
            XCTFail("runCommand before login must throw")
        } catch let error as SessionError {
            XCTAssertEqual(error, .connectionFailed("The session is not connected."))
        }
        await session.send(Array("\(server.password)\n".utf8))
        try await recorder.waitForEvents([.connected, .ready])
        try await recorder.waitForOutput(containing: "$ ")
        await session.send(Array("echo typed-$((2*21))\n".utf8))
        try await recorder.waitForOutput(containing: "typed-42")
        let probe = try await session.runCommand("echo via-master")
        XCTAssertEqual(probe, "via-master\n", "commands work once the typed login succeeded")
        await session.close()
        try await recorder.waitForFinish()
    }

    func testUnknownHostKeyRejectedNeverLaunchesSSH() async throws {
        let marker = scratch.appendingPathComponent("ssh-was-launched")
        let fakeSSH = scratch.appendingPathComponent("fake-ssh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: fakeSSH, atomically: true, encoding: .utf8)
        chmod(fakeSSH.path, 0o755)

        let evaluator = TestEvaluator(decision: .rejected)
        let session = SystemSSHSession(plan: plan(.password(server.password)), hostKeys: evaluator,
                                       knownHostsLines: { [] }, runtime: runtime, sshPath: fakeSSH.path)
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForFinish()
        XCTAssertEqual(recorder.nonOutputEvents, [.closed(.failed(.hostKeyRejected))])
        XCTAssertEqual(evaluator.candidates.count, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "ssh must not run")
        XCTAssertEqual(secretFiles(), [], "no secret written for a rejected host")
        for marker in ["Accepted ", "Failed password", "Postponed"] {
            XCTAssertFalse(server.log().contains(marker), server.log())
        }
    }

    func testChangedHostKeyIsReported() async throws {
        let store = try await Self.makeKnownHostsStore()
        // The vault trusts a different ed25519 key for this host.
        let other = SSHKeyGenerator.ed25519(comment: "old")
        let otherBlob = try XCTUnwrap(Data(base64Encoded: String(other.publicKey.split(separator: " ")[1])))
        let old = HostKeyCandidate(host: server.host, port: server.port, keyType: "ssh-ed25519", publicKeyBlob: otherBlob)
        let trusted = await MainActor.run { store.trust(old) }
        XCTAssertTrue(trusted)

        let asked = CheckRecorder()
        let lines: @Sendable () async -> [String] = { await MainActor.run { store.knownHostsFileLines() } }
        let rejecting = PromptingHostKeyEvaluator(store: store) { _, check in asked.append(check); return .rejected }
        let blocked = SystemSSHSession(plan: plan(.password(server.password)), hostKeys: rejecting,
                                       knownHostsLines: lines, runtime: runtime)
        let blockedEvents = EventRecorder(blocked.events)
        await blocked.start(cols: 80, rows: 24)
        try await blockedEvents.waitForFinish()
        XCTAssertEqual(blockedEvents.nonOutputEvents, [.closed(.failed(.hostKeyRejected))])
        XCTAssertEqual(asked.checks, [.changed(previousFingerprint: old.fingerprint)])
        XCTAssertFalse(server.log().contains("Accepted "))

        // "Remove old key and trust new": the store replaces the record and ssh accepts the new key.
        let replacing = PromptingHostKeyEvaluator(store: store) { _, check in asked.append(check); return .trusted }
        let session = SystemSSHSession(plan: plan(.password(server.password)), hostKeys: replacing,
                                       knownHostsLines: lines, runtime: runtime)
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForEvents([.connected, .ready])
        // ssh (StrictHostKeyChecking=yes) accepted the new key: the old line was replaced.
        await session.close()
        try await recorder.waitForFinish()
    }

    func testUnreachableHostIsConnectionFailed() async throws {
        let port = try TestSSHServer.freePort()
        var p = plan(.password("x"))
        p.port = port
        let evaluator = TestEvaluator(decision: .trusted)
        let session = SystemSSHSession(plan: p, hostKeys: evaluator, knownHostsLines: { [] }, runtime: runtime)
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForFinish()
        XCTAssertEqual(recorder.nonOutputEvents, [.closed(.failed(.connectionFailed("Could not reach 127.0.0.1:\(port)")))])
        XCTAssertTrue(evaluator.candidates.isEmpty)
    }

    func testSecretsNeverInArgumentsOrEnvironment() async throws {
        #if !os(Linux)
        throw XCTSkip("reads /proc")
        #else
        // Password session.
        let session = makeSession(.password(server.password))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForEvents([.connected, .ready])
        assertNoProcessExposes([server.password])
        await session.close()
        try await recorder.waitForFinish()

        // Encrypted key session.
        let keyFile = scratch.appendingPathComponent("leak_rsa")
        try TestSSHServer.run("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "2048", "-N", "pass phrase 7", "-f", keyFile.path])
        let pem = try String(contentsOf: keyFile, encoding: .utf8)
        try server.authorize(publicKeyLine: String(contentsOf: keyFile.appendingPathExtension("pub"), encoding: .utf8))
        let pemLine = try XCTUnwrap(pem.split(separator: "\n").dropFirst(3).first.map(String.init))
        try FileManager.default.removeItem(at: keyFile)
        let keySession = makeSession(.privateKey(type: .rsa, pem: pem, passphrase: "pass phrase 7"))
        let keyRecorder = EventRecorder(keySession.events)
        await keySession.start(cols: 80, rows: 24)
        try await keyRecorder.waitForEvents([.connected, .ready])
        _ = try await keySession.runCommand("true")
        assertNoProcessExposes(["pass phrase 7", pemLine])
        await keySession.close()
        try await keyRecorder.waitForFinish()
        #endif
    }

    func testTempFilesRemovedAfterConnectAndAfterFailure() async throws {
        let generated = try SSHKeyGenerator.rsa4096(comment: "temp-files")
        try server.authorize(publicKeyLine: generated.publicKey)
        let session = makeSession(.privateKey(type: .rsa, pem: generated.privateKey, passphrase: "unused-but-stored"))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForEvents([.connected, .ready])
        let root = runtime.root
        try await waitUntil(timeout: 2) { Self.secretFiles(in: root).isEmpty }
        await session.close()
        try await recorder.waitForFinish()
        XCTAssertEqual(secretFiles(), [])

        let failing = makeSession(.password("wrong-password-x"))
        let failingEvents = EventRecorder(failing.events)
        await failing.start(cols: 80, rows: 24)
        try await failingEvents.waitForFinish()
        XCTAssertEqual(failingEvents.nonOutputEvents, [.closed(.failed(.authenticationFailed))])
        XCTAssertEqual(secretFiles(), [])

        // Closing before ssh connects also removes them.
        let closing = makeSession(.password(server.password), evaluator: TestEvaluator(decision: .trusted, delay: .milliseconds(300)))
        let closingEvents = EventRecorder(closing.events)
        let starting = Task { await closing.start(cols: 80, rows: 24) }
        try await Task.sleep(for: .milliseconds(100))
        await closing.close()
        await starting.value
        try await closingEvents.waitForFinish()
        XCTAssertEqual(closingEvents.nonOutputEvents, [.closed(.userClosed)])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(secretFiles(), [])
    }

    func testRunCommandReusesConnection() async throws {
        let session = makeSession(.password(server.password))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForEvents([.connected, .ready])

        let probe = try await session.runCommand(OSDetector.probeCommand)
        XCTAssertTrue(probe.contains("Linux"), probe)
        let merged = try await session.runCommand("echo out; echo err >&2; exit 3")
        XCTAssertEqual(merged, "out\nerr\n")
        XCTAssertEqual(server.log().components(separatedBy: "Accepted password").count - 1, 1, "one login only")

        await session.send(Array("echo still-$((1+1))\n".utf8))
        try await recorder.waitForOutput(containing: "still-2")
        await session.close()
        try await recorder.waitForFinish()
        do {
            _ = try await session.runCommand("true")
            XCTFail("runCommand after close must throw")
        } catch let error as SessionError {
            XCTAssertEqual(error, .connectionFailed("Session closed"))
        }
    }

    func testRunCommandOutputCapAndTimeout() async throws {
        let session = SystemSSHSession(plan: plan(.password(server.password)), hostKeys: TestEvaluator(decision: .trusted),
                                       knownHostsLines: { [] }, runtime: runtime, sshPath: "/usr/bin/ssh",
                                       keyscanPath: "/usr/bin/ssh-keyscan", commandTimeout: .seconds(2))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        let clock = ContinuousClock()
        var started = clock.now
        do {
            _ = try await session.runCommand("yes")
            XCTFail("expected the output cap")
        } catch let error as SessionError {
            XCTAssertEqual(error, .connectionFailed("Command output too large"))
        }
        XCTAssertLessThan(clock.now - started, .seconds(10))
        started = clock.now
        do {
            _ = try await session.runCommand("sleep 30")
            XCTFail("expected the timeout")
        } catch let error as SessionError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(clock.now - started, .seconds(4))
        let echoed = try await session.runCommand("echo ok")
        XCTAssertEqual(echoed, "ok\n", "the connection still works")
        await session.close()
        try await recorder.waitForFinish()
    }

    func testRemoteExitIsRemoteClosed() async throws {
        for script in ["exit\n", "false; exit 3\n"] {
            let session = makeSession(.password(server.password))
            let recorder = EventRecorder(session.events)
            await session.start(cols: 80, rows: 24)
            await session.send(Array(script.utf8))
            try await recorder.waitForFinish()
            XCTAssertEqual(recorder.nonOutputEvents, [.connected, .ready, .closed(.remoteClosed)], script)
            await session.close() // after the end: does nothing
            XCTAssertEqual(recorder.nonOutputEvents, [.connected, .ready, .closed(.remoteClosed)])
        }
    }

    func testCloseEndsSSHAndControlMaster() async throws {
        let session = makeSession(.password(server.password))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForEvents([.connected, .ready])
        let root = runtime.root
        let control = runtime.controlDirectory
        try await waitUntil(timeout: 5) { Self.controlSockets(in: control).count == 1 }
        await session.close()
        await session.close()
        try await recorder.waitForFinish()
        XCTAssertEqual(recorder.nonOutputEvents, [.connected, .ready, .closed(.userClosed)])
        try await waitUntil(timeout: 3) { Self.controlSockets(in: control).isEmpty }
        try await waitUntil(timeout: 5) { !Self.anySSHProcess(mentioning: root.path) }
    }

    func testClosingOneSessionKeepsAnotherOnTheSameHost() async throws {
        let first = makeSession(.password(server.password))
        let firstEvents = EventRecorder(first.events)
        await first.start(cols: 80, rows: 24)
        let second = makeSession(.password(server.password))
        let secondEvents = EventRecorder(second.events)
        await second.start(cols: 80, rows: 24)
        try await secondEvents.waitForEvents([.connected, .ready])
        await first.close()
        try await firstEvents.waitForFinish()
        try await Task.sleep(for: .milliseconds(500))
        await second.send(Array("echo alive-$((3*3))\n".utf8))
        try await secondEvents.waitForOutput(containing: "alive-9")
        let probe = try await second.runCommand("echo still-shared")
        XCTAssertEqual(probe, "still-shared\n")
        XCTAssertEqual(secondEvents.nonOutputEvents, [.connected, .ready])
        // The last session to close stops the control master.
        await second.close()
        try await secondEvents.waitForFinish()
        let control = runtime.controlDirectory
        try await waitUntil(timeout: 3) { Self.controlSockets(in: control).isEmpty }
    }

    func testKeyCredentialNeverFallsBackToPassword() async throws {
        // An unencrypted key the server doesn't know, with a passphrase stored anyway.
        let stranger = SSHKeyGenerator.ed25519(comment: "not-authorized")
        let session = makeSession(.privateKey(type: .ed25519, pem: stranger.privateKey, passphrase: server.password))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForFinish()
        XCTAssertEqual(recorder.nonOutputEvents, [.closed(.failed(.authenticationFailed))])
        try await Task.sleep(for: .milliseconds(300))
        let log = server.log()
        for marker in ["Failed password", "keyboard-interactive", "Accepted password"] {
            XCTAssertFalse(log.contains(marker), "\(marker) in:\n\(log)")
        }
        XCTAssertEqual(secretFiles(), [])
    }

    #if os(Linux)
    // These two tests write into the real ~/.ssh (ssh reads it through the passwd entry, not $HOME),
    // so they only run as root in the Linux sandbox, never touch a file that already exists, and
    // remove exactly what they created.

    func testPasswordIsNotSpentOnDefaultKeys() async throws {
        let keyFile = scratch.appendingPathComponent("id_ed25519")
        try TestSSHServer.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "some passphrase", "-f", keyFile.path])
        let privateKey = try Data(contentsOf: keyFile)
        let publicKey = try Data(contentsOf: keyFile.appendingPathExtension("pub"))
        try await withHomeSSHFiles(["id_ed25519": (privateKey, 0o600), "id_ed25519.pub": (publicKey, 0o644)]) {
            try server.authorize(publicKeyLine: String(decoding: publicKey, as: UTF8.self))
            try await assertShellWorks(.password(server.password))
            XCTAssertTrue(server.log().contains("Accepted password"), server.log())
        }
    }

    func testUserSSHConfigIsIgnored() async throws {
        try await withHomeSSHFiles(["config": (Data("Host *\n  ProxyCommand /bin/false\n".utf8), 0o600)]) {
            let session = makeSession(.password(server.password))
            let recorder = EventRecorder(session.events)
            await session.start(cols: 80, rows: 24)
            try await recorder.waitForEvents([.connected, .ready])
            _ = try await session.runCommand("true")
            await session.close()
            try await recorder.waitForFinish()
        }
    }

    /// Runs `body` with `files` (name: contents, mode) present in the passwd home's `.ssh`. Skips
    /// unless running as root or when any of the files already exists. Files are created with
    /// O_EXCL; afterwards only the files created here are removed, and `.ssh` too if created here.
    private func withHomeSSHFiles(_ files: [String: (Data, mode_t)], _ body: () async throws -> Void) async throws {
        guard getuid() == 0 else { throw XCTSkip("writes to ~/.ssh only as root in the Linux sandbox") }
        let home = try XCTUnwrap(getpwuid(getuid())).pointee.pw_dir.map { String(cString: $0) } ?? ""
        let directory = URL(fileURLWithPath: home).appendingPathComponent(".ssh", isDirectory: true)
        for name in files.keys where FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            throw XCTSkip("~/.ssh/\(name) already exists")
        }
        var createdDirectory = false
        if mkdir(directory.path, 0o700) == 0 {
            createdDirectory = true
        } else if errno != EEXIST {
            return XCTFail("mkdir ~/.ssh: errno \(errno)")
        }
        var created: [URL] = []
        defer {
            for file in created { unlink(file.path) }
            if createdDirectory { try? FileManager.default.removeItem(at: directory) }
        }
        for (name, (contents, mode)) in files.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(name)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode)
            guard fd >= 0 else {
                if errno == EEXIST { throw XCTSkip("~/.ssh/\(name) appeared meanwhile") }
                return XCTFail("create ~/.ssh/\(name): errno \(errno)")
            }
            created.append(url)
            let written = contents.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            guard written == contents.count else { return XCTFail("short write to ~/.ssh/\(name)") }
        }
        try await body()
    }
    #endif

    func testSessionStartFallbackWhenTerminalModeIsUnavailable() async throws {
        // Password through askpass: started once the helper consumed the secret and output followed.
        let session = SystemSSHSession(plan: plan(.password(server.password)), hostKeys: TestEvaluator(decision: .trusted),
                                       knownHostsLines: { [] }, runtime: runtime, sshPath: "/usr/bin/ssh",
                                       keyscanPath: "/usr/bin/ssh-keyscan", commandTimeout: .seconds(15),
                                       terminalModeProbe: { _ in .unavailable })
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForEvents([.connected, .ready])
        XCTAssertEqual(secretFiles(), [])
        await session.send(Array("echo fb-$((5*5))\n".utf8))
        try await recorder.waitForOutput(containing: "fb-25")
        await session.close()
        try await recorder.waitForFinish()

        // No askpass (unencrypted key): started on the first output after 2 s.
        let generated = SSHKeyGenerator.ed25519(comment: "fallback")
        try server.authorize(publicKeyLine: generated.publicKey)
        let keySession = SystemSSHSession(plan: plan(.privateKey(type: .ed25519, pem: generated.privateKey, passphrase: nil)),
                                          hostKeys: TestEvaluator(decision: .trusted), knownHostsLines: { [] },
                                          runtime: runtime, sshPath: "/usr/bin/ssh", keyscanPath: "/usr/bin/ssh-keyscan",
                                          commandTimeout: .seconds(15), terminalModeProbe: { _ in .unavailable })
        let keyEvents = EventRecorder(keySession.events)
        let clock = ContinuousClock()
        let launched = clock.now
        await keySession.start(cols: 80, rows: 24)
        try await keyEvents.waitForEvents([.connected])
        // Output after the 2 s mark (the shell answers this) marks the start.
        try await Task.sleep(for: .milliseconds(2200))
        await keySession.send(Array("echo key-fb\n".utf8))
        try await keyEvents.waitForEvents([.connected, .ready])
        XCTAssertGreaterThanOrEqual(clock.now - launched, .seconds(2))
        XCTAssertEqual(secretFiles(), [])
        await keySession.close()
        try await keyEvents.waitForFinish()
    }

    func testRunCommandNeverOpensAFreshConnection() async throws {
        let session = makeSession(.password(server.password))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForEvents([.connected, .ready])
        _ = try await session.runCommand("true")
        let connectionsBefore = server.log().components(separatedBy: "Connection from").count
        // The socket disappears while the master keeps running.
        let control = runtime.controlDirectory
        for name in Self.controlSockets(in: control) {
            try FileManager.default.removeItem(at: control.appendingPathComponent(name))
        }
        do {
            _ = try await session.runCommand("true")
            XCTFail("expected Session closed")
        } catch let error as SessionError {
            XCTAssertEqual(error, .connectionFailed("Session closed"))
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.log().components(separatedBy: "Connection from").count, connectionsBefore, "no new connection")
        await session.close()
        try await recorder.waitForFinish()
    }

    func testCloseWhileSSHIsStartingRemovesFilesAndProcess() async throws {
        let fakeSSH = scratch.appendingPathComponent("slow-ssh")
        try "#!/bin/sh\nexec sleep 29.123\n".write(to: fakeSSH, atomically: true, encoding: .utf8)
        chmod(fakeSSH.path, 0o755)
        let generated = SSHKeyGenerator.ed25519(comment: "slow")
        let session = SystemSSHSession(plan: plan(.privateKey(type: .ed25519, pem: generated.privateKey, passphrase: "pp")),
                                       hostKeys: TestEvaluator(decision: .trusted), knownHostsLines: { [] },
                                       runtime: runtime, sshPath: fakeSSH.path)
        let recorder = EventRecorder(session.events)
        let starting = Task { await session.start(cols: 80, rows: 24) }
        let root = runtime.root
        try await waitUntil(timeout: 5) { Self.secretFiles(in: root).count == 3 } // key, secret, known_hosts
        await session.close()
        await starting.value
        try await recorder.waitForFinish()
        XCTAssertEqual(recorder.nonOutputEvents, [.closed(.userClosed)])
        XCTAssertEqual(secretFiles(), [])
        #if os(Linux)
        try await waitUntil(timeout: 4) { !Self.processTexts().contains { $0.text.hasPrefix("sleep 29.123") } }
        #endif
    }

    func testResizeChangesRemoteSize() async throws {
        let session = makeSession(.password(server.password))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        await session.send(Array("stty size\n".utf8))
        try await recorder.waitForOutput(containing: "24 80")
        await session.resize(cols: 100, rows: 40)
        await session.send(Array("stty size\n".utf8))
        try await recorder.waitForOutput(containing: "40 100")
        await session.close()
    }

    func testLargeOutputArrivesCompleteAndInOrder() async throws {
        let session = makeSession(.password(server.password))
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        await session.send(Array("seq 1 700000\n".utf8))

        let lastLine = Array("\r\n700000\r\n".utf8)
        try await recorder.waitForOutput(timeout: 60) { bytes in
            bytes.count > 4_000_000 && bytes.suffix(1024).contains(subsequence: lastLine)
        }
        let lines = recorder.outputText.components(separatedBy: "\r\n")
        let first = try XCTUnwrap(lines.indices.first {
            lines[$0].hasSuffix("1") && lines.indices.contains($0 + 1) && lines[$0 + 1] == "2"
        })
        let rest = lines[(first + 1)..<min(first + 700_000, lines.count)]
        XCTAssertEqual(rest.count, 699_999)
        XCTAssertTrue(rest.elementsEqual((2...700_000).lazy.map(String.init)), "lines are exactly 1…700000 in order")
        await session.close()
    }

    // MARK: Helpers

    @MainActor
    private static func makeKnownHostsStore() async throws -> KnownHostsStore {
        let vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        return KnownHostsStore(vault: vault)
    }

    private func plan(_ credential: SSHCredential) -> ConnectionPlan {
        ConnectionPlan(hostID: nil, label: "test", host: server.host, port: server.port,
                       username: server.username, credential: credential, engine: .systemSSH, startupScript: nil)
    }

    private func makeSession(_ credential: SSHCredential,
                             evaluator: TestEvaluator = TestEvaluator(decision: .trusted)) -> SystemSSHSession {
        SystemSSHSession(plan: plan(credential), hostKeys: evaluator, knownHostsLines: { [] }, runtime: runtime)
    }

    private func assertShellWorks(_ credential: SSHCredential, file: StaticString = #filePath, line: UInt = #line) async throws {
        let session = makeSession(credential)
        let recorder = EventRecorder(session.events)
        await session.start(cols: 80, rows: 24)
        try await recorder.waitForEvents([.connected, .ready], file: file, line: line)
        await session.send(Array("echo key-$((6*7))\n".utf8))
        try await recorder.waitForOutput(containing: "key-42", file: file, line: line)
        await session.close()
        try await recorder.waitForFinish(file: file, line: line)
        XCTAssertEqual(recorder.nonOutputEvents, [.connected, .ready, .closed(.userClosed)], file: file, line: line)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Key and secret files in the runtime directory.
    private func secretFiles() -> [String] { Self.secretFiles(in: runtime.root) }

    private static func secretFiles(in root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".key") || $0.hasSuffix(".secret") || $0.hasSuffix(".known_hosts") }.sorted()
    }

    private static func controlSockets(in root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
    }

    private func wire(_ type: String) -> Data {
        let t = Array(type.utf8)
        return Data([0, 0, 0, UInt8(t.count)] + t + [1, 2, 3, 4])
    }

    #if os(Linux)
    /// Every process's command line and environment, NUL bytes turned into spaces.
    private static func processTexts() -> [(pid: String, text: String)] {
        let pids = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).filter { Int($0) != nil }
        return pids.compactMap { pid in
            let parts = ["cmdline", "environ"].compactMap { FileManager.default.contents(atPath: "/proc/\(pid)/\($0)") }
            guard !parts.isEmpty else { return nil }
            let text = parts.map { String(decoding: $0.map { $0 == 0 ? UInt8(ascii: " ") : $0 }, as: UTF8.self) }
            return (pid, text.joined(separator: " "))
        }
    }

    private func assertNoProcessExposes(_ secrets: [String], file: StaticString = #filePath, line: UInt = #line) {
        let texts = Self.processTexts()
        XCTAssertTrue(texts.contains { $0.text.contains("/usr/bin/ssh") && $0.text.contains(runtime.root.path) },
                      "the ssh process was found", file: file, line: line)
        for (pid, text) in texts {
            for secret in secrets where text.contains(secret) {
                XCTFail("process \(pid) exposes a secret in its arguments or environment", file: file, line: line)
            }
        }
    }
    #endif

    private static func anySSHProcess(mentioning path: String) -> Bool {
        #if os(Linux)
        processTexts().contains { $0.text.hasPrefix("/usr/bin/ssh ") && $0.text.contains(path) }
        #else
        false
        #endif
    }
}

final class CheckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HostKeyCheck] = []
    func append(_ check: HostKeyCheck) { lock.withLock { recorded.append(check) } }
    var checks: [HostKeyCheck] { lock.withLock { recorded } }
}
