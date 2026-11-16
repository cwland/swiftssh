import XCTest
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import AppCore

/// A fake `op`: a shell script in a temporary folder that records its arguments (one per line) to
/// `argv` and its environment to `env`, then runs `body` (which prints canned output and exits).
private struct FakeOP {
    let dir: URL
    var path: String { dir.appendingPathComponent("op").path }

    init(body: String) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-op-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        d=\(dir.path)
        for a in "$@"; do printf '%s\\n' "$a"; done > "$d/argv"
        env > "$d/env"
        echo $$ > "$d/pid"
        \(body)
        """
        let url = dir.appendingPathComponent("op")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Writes `text` to a file the body can `cat`.
    func put(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    var argv: [String]? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    var env: [String: String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8)) ?? ""
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            result[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return result
    }

    var pid: pid_t? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }
}

private let baseEnvironment = [
    "HOME": "/Users/tester", "USER": "tester", "LOGNAME": "tester", "TMPDIR": "/tmp/tester-tmp/",
    "PATH": "/opt/homebrew/bin:/usr/bin", "SECRET_TOKEN": "do-not-pass", "SSH_AUTH_SOCK": "/tmp/agent",
    "OP_SERVICE_ACCOUNT_TOKEN": "nope",
]

/// A realistic `op item list --format json` answer (shape per research.md §1).
private let itemListJSON = """
[
  {
    "id": "u3xkqzq2ozhl4ye6ojxbs5ycyy",
    "title": "web.example root",
    "version": 3,
    "vault": { "id": "kzz3xbmyq5ezlnuojlf4ddmtmu", "name": "Private" },
    "category": "LOGIN",
    "last_edited_by": "XGF3QWDNKRH3ZOOBDUNMZBBVEA",
    "created_at": "2025-03-11T09:12:44Z",
    "updated_at": "2026-10-02T17:01:09Z",
    "additional_information": "root",
    "urls": [ { "label": "website", "primary": true, "href": "ssh://web.example" } ]
  },
  {
    "id": "7kb2tbkqrnbx5aq3yzz5yrgkfe",
    "title": "Homelab key",
    "version": 1,
    "vault": { "id": "zr4rnryd5wfhpxjsdlvx2cdh5e", "name": "Homelab" },
    "category": "SSH_KEY",
    "last_edited_by": "XGF3QWDNKRH3ZOOBDUNMZBBVEA",
    "created_at": "2026-01-20T08:00:00Z",
    "updated_at": "2026-01-20T08:00:00Z",
    "additional_information": "SHA256:4m1Q2xZbGEXAMPLEfingerprintAAAAAAAAAAAAAAAAA"
  },
  {
    "id": "c4iuvvprq4ct6d3ma2aaaaaaaa",
    "title": "NAS",
    "version": 2,
    "vault": { "id": "zr4rnryd5wfhpxjsdlvx2cdh5e" },
    "category": "SERVER",
    "created_at": "2026-01-20T08:00:00Z",
    "updated_at": "2026-01-20T08:00:00Z"
  }
]
"""

final class OnePasswordCLITests: XCTestCase {
    private var fakes: [FakeOP] = []

    override func tearDown() {
        for fake in fakes { fake.cleanUp() }
        fakes = []
    }

    private func fake(_ body: String) throws -> FakeOP {
        let f = try FakeOP(body: body)
        fakes.append(f)
        return f
    }

    private func cli(_ fake: FakeOP, timeout: Duration = .seconds(10), stdoutLimit: Int = 1 << 20,
                     stderrLimit: Int = 64 * 1024,
                     containerAccess: @escaping @Sendable () -> OnePasswordPaths.Probe = { .missing }) -> ProcessOnePasswordCLI {
        ProcessOnePasswordCLI(executablePath: fake.path, timeout: timeout, environment: baseEnvironment,
                              stdoutLimit: stdoutLimit, stderrLimit: stderrLimit, containerAccess: containerAccess)
    }

    private func readError(_ cli: ProcessOnePasswordCLI, _ reference: String = "op://Private/web/password",
                           file: StaticString = #filePath, line: UInt = #line) async -> OnePasswordError? {
        do {
            _ = try await cli.read(reference: reference)
            XCTFail("expected an error", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    // MARK: SecretReference

    func testIsReference() {
        XCTAssertTrue(SecretReference.isReference("op://Private/web/password"))
        XCTAssertTrue(SecretReference.isReference("  op://Private/web/password\n"))
        XCTAssertFalse(SecretReference.isReference("hunter2"))
        XCTAssertFalse(SecretReference.isReference(""))
        XCTAssertFalse(SecretReference.isReference("xop://a/b/c"))
        XCTAssertFalse(SecretReference.isReference("op:/a/b"))
    }

    // MARK: read

    func testReadPassesNoNewlineAndReturnsTheExactValue() async throws {
        let op = try fake("printf '%s' ' s3cret with space '")
        let value = try await cli(op).read(reference: "  op://Private/web.example root/password ")
        XCTAssertEqual(value, " s3cret with space ")
        XCTAssertEqual(op.argv, ["read", "--no-newline", "op://Private/web.example root/password"])
    }

    func testReadOfSomethingElseRunsNothing() async throws {
        let op = try fake("exit 0")
        let error = await readError(cli(op), "hunter2")
        guard case .failed = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertNil(op.argv, "op was not run")
        XCTAssertFalse(error!.message.contains("hunter2"))
    }

    func testMinimalEnvironment() async throws {
        let op = try fake("printf x")
        _ = try await cli(op).read(reference: "op://a/b/c")
        let env = op.env
        XCTAssertEqual(env["HOME"], "/Users/tester")
        XCTAssertEqual(env["USER"], "tester")
        XCTAssertEqual(env["LOGNAME"], "tester")
        XCTAssertEqual(env["TMPDIR"], "/tmp/tester-tmp/")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:\(op.dir.path)")
        let allowed: Set = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "PWD", "SHLVL", "_", "OLDPWD",
                             "__CF_USER_TEXT_ENCODING"] // added by the shell / macOS itself
        XCTAssertEqual(Set(env.keys).subtracting(allowed), [], "nothing else is passed")
    }

    func testPathDoesNotRepeatAStandardDirectory() {
        XCTAssertEqual(ProcessOnePasswordCLI.environment(executablePath: "/usr/bin/op", from: baseEnvironment)["PATH"],
                       "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(ProcessOnePasswordCLI.environment(executablePath: "/opt/homebrew/bin/op", from: [:]),
                       ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"])
    }

    func testDefaultTimeoutLeavesTimeForTouchID() {
        XCTAssertGreaterThanOrEqual(ProcessOnePasswordCLI(executablePath: "/x/op").timeout, .seconds(90))
    }

    func testMissingOrNonExecutableCLI() async throws {
        let missing = ProcessOnePasswordCLI(executablePath: "/nonexistent/op", environment: baseEnvironment)
        let e1 = await readError(missing)
        XCTAssertEqual(e1, .cliNotFound)
        let op = try fake("exit 0")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: op.path)
        let e2 = await readError(cli(op))
        XCTAssertEqual(e2, .cliNotFound)
    }

    func testTimeoutKillsTheProcess() async throws {
        let op = try fake("exec sleep 30")
        let started = Date()
        let error = await readError(cli(op, timeout: .milliseconds(300)))
        XCTAssertEqual(error, .timedOut(details: nil))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let pid = try XCTUnwrap(op.pid)
        XCTAssertFalse(isAlive(pid), "op was killed")
    }

    func testCancellationKillsTheProcess() async throws {
        let op = try fake("exec sleep 30")
        let client = cli(op)
        let task = Task { () -> OnePasswordError? in
            do throws(OnePasswordError) {
                _ = try await client.read(reference: "op://a/b/c")
                return nil
            } catch {
                return error
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while op.pid == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try XCTUnwrap(op.pid)
        try await Task.sleep(for: .milliseconds(50)) // let the script exec sleep
        let started = Date()
        task.cancel()
        let error = await task.value
        XCTAssertEqual(error, .cancelled(details: nil))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertFalse(isAlive(pid))
    }

    func testAlreadyCancelledTaskRunsNothing() async throws {
        let op = try fake("exit 0")
        let client = cli(op)
        let task = Task { () -> OnePasswordError? in
            while !Task.isCancelled { await Task.yield() }
            do throws(OnePasswordError) {
                _ = try await client.read(reference: "op://a/b/c")
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        let error = await task.value
        XCTAssertEqual(error, .cancelled(details: nil))
    }

    func testStdoutCapKillsARunawayProcess() async throws {
        let op = try fake("exec yes")
        let started = Date()
        let error = await readError(cli(op, stdoutLimit: 64 * 1024))
        guard case .failed = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(isAlive(try XCTUnwrap(op.pid)))
    }

    func testStderrIsCappedAndShortenedInTheError() async throws {
        let op = try fake("head -c 200000 /dev/zero | tr '\\0' 'e' >&2; exit 1")
        let error = await readError(cli(op, stderrLimit: 4096))
        guard case .failed(let detail) = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(detail.count, 500)
        XCTAssertTrue(detail.hasPrefix("eee"))
        XCTAssertTrue(detail.hasSuffix("\u{2026}"))
        XCTAssertEqual(error?.details, detail)
    }

    func testReadOutputNeverAppearsInErrors() async throws {
        let op = try fake("printf 'TOPSECRET'; echo 'something broke' >&2; exit 1")
        let maybeError = await readError(cli(op))
        let error = try XCTUnwrap(maybeError)
        XCTAssertEqual(error, .failed("something broke"))
        XCTAssertFalse(error.message.contains("TOPSECRET"))
        XCTAssertFalse("\(error)".contains("TOPSECRET"))
    }

    // MARK: Error mapping

    func testKnownErrorStrings() async throws {
        let cases: [(String, OnePasswordError)] = [
            ("[ERROR] 2025/07/11 10:16:41 authorization timeout", .timedOut(details: "authorization timeout")),
            ("[ERROR] 2025/07/11 10:16:41 authorization prompt dismissed, please try again",
             .cancelled(details: "authorization prompt dismissed, please try again")),
            ("[ERROR] 2025/07/11 10:16:41 error initializing client: connecting to desktop app: read: connection reset, make sure the CLI is correctly installed and CLI Biometric Unlock is enabled in the 1Password app",
             .integrationOff(details: "error initializing client: connecting to desktop app: read: connection reset, make sure the CLI is correctly installed and CLI Biometric Unlock is enabled in the 1Password app")),
            ("[ERROR] 2025/07/11 10:16:41 LostConnectionToApp", .integrationOff(details: "LostConnectionToApp")),
            ("[ERROR] 2025/07/11 10:16:41 You are not currently signed in. Please run `op signin --help` for instructions",
             .appLocked(details: "You are not currently signed in. Please run `op signin --help` for instructions")),
            ("[ERROR] 2025/07/11 10:16:41 No accounts configured for use with 1Password CLI.",
             .integrationOff(details: "No accounts configured for use with 1Password CLI.")),
            ("[ERROR] 2025/07/11 10:16:41 1Password app is locked", .appLocked(details: "1Password app is locked")),
            ("[ERROR] 2025/07/11 10:16:41 could not read secret op://Private/web/password: \"Private\" isn't a vault in this account. Specify the vault with its ID or name.",
             .notFound("could not read secret op://Private/web/password: \"Private\" isn't a vault in this account. Specify the vault with its ID or name.")),
            ("[ERROR] 2025/07/11 10:16:41 could not find item APP_ENV in vault Env_Server_Local, because it has been deleted or archived.",
             .notFound("could not find item APP_ENV in vault Env_Server_Local, because it has been deleted or archived.")),
            ("[ERROR] 2025/07/11 10:16:41 \"web\" isn't an item. Specify the item with its UUID, name, or domain.",
             .notFound("\"web\" isn't an item. Specify the item with its UUID, name, or domain.")),
            ("[ERROR] 2025/07/11 10:16:41 something unexpected\nsecond line", .failed("something unexpected second line")),
        ]
        for (stderr, expected) in cases {
            let op = try fake("cat \"$d/err\" >&2; exit 1")
            try op.put("err", stderr + "\n")
            let error = await readError(cli(op))
            XCTAssertEqual(error, expected, stderr)
        }
    }

    func testNonZeroExitWithoutStderr() async throws {
        let op = try fake("exit 3")
        let error = await readError(cli(op))
        XCTAssertEqual(error, .failed("op exited with status 3"))
    }

    func testMessages() {
        let all: [OnePasswordError] = [.cliNotFound, .appLocked(details: nil), .cancelled(details: nil),
                                       .integrationOff(details: nil), .timedOut(details: nil),
                                       .containerBlocked(details: nil), .appNotRunning(details: nil),
                                       .notFound("x"), .failed("y")]
        for error in all { XCTAssertFalse(error.message.isEmpty) }
        XCTAssertTrue(OnePasswordError.notFound("could not find item X").message.contains("could not find item X"))
        XCTAssertTrue(OnePasswordError.failed("boom").message.contains("boom"))
        XCTAssertEqual(OnePasswordError.timedOut(details: nil).localizedDescription,
                       OnePasswordError.timedOut(details: nil).message)
    }

    func testIntegrationOffMessageIsExact() {
        let expected = "The 1Password CLI isn't connected to the 1Password app. In 1Password, select your account at the top of the sidebar, then open Settings \u{2192} Developer and turn on \u{201C}Integrate with 1Password CLI\u{201D}. Keep 1Password in the menu bar."
        XCTAssertEqual(OnePasswordError.integrationOff(details: nil).message, expected)
        XCTAssertEqual(OnePasswordError.integrationOff(details: "op's own words").message, expected,
                       "the details are shown separately, never in the message")
    }

    func testDetailsProperty() {
        XCTAssertNil(OnePasswordError.cliNotFound.details)
        XCTAssertEqual(OnePasswordError.appLocked(details: "a").details, "a")
        XCTAssertEqual(OnePasswordError.integrationOff(details: "b").details, "b")
        XCTAssertEqual(OnePasswordError.timedOut(details: "c").details, "c")
        XCTAssertEqual(OnePasswordError.cancelled(details: "d").details, "d")
        XCTAssertNil(OnePasswordError.cancelled(details: nil).details)
        XCTAssertEqual(OnePasswordError.notFound("e").details, "e")
        XCTAssertEqual(OnePasswordError.failed("f").details, "f")
        XCTAssertNotEqual(OnePasswordError.appLocked(details: "a"), .appLocked(details: nil))
    }

    // MARK: Details

    /// What `op vault list` prints on a Mac where the CLI can't see any 1Password account (integration
    /// off, or macOS 27 not sharing 1Password's data), stdin being /dev/null.
    static let noAccountsStderr = """
        No accounts configured for use with 1Password CLI.

        Your options are:

        \t1. Turn on the 1Password desktop app integration. Learn more: https://developer.1password.com/docs/cli/get-started/#step-2-turn-on-the-1password-desktop-app-integration
        \t2. Add an account manually by running 'op account add'.

        Do you want to add an account manually now? [Y/n] [ERROR] 2026/11/14 10:00:00 EOF

        """

    func testNoAccountsConfiguredMapsToIntegrationOffWithDetails() async throws {
        let op = try fake("cat \"$d/err\" >&2; exit 1")
        try op.put("err", Self.noAccountsStderr)
        do {
            try await cli(op).check()
            XCTFail("expected an error")
        } catch {
            guard case .integrationOff(let details?) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(details.hasPrefix("No accounts configured for use with 1Password CLI. Your options are:"), details)
            XCTAssertTrue(details.contains("Do you want to add an account manually now? [Y/n]"), details)
            XCTAssertFalse(details.contains("\t"))
            XCTAssertFalse(details.contains("\n"))
            XCTAssertLessThanOrEqual(details.count, 500)
        }
    }

    func testDetailsAreSanitized() {
        let stderr = "[ERROR] 2026/11/14 10:00:00 \u{1B}[31mlocked\u{1B}[0m\tnow\u{07}\u{00}\r\nnext \u{202E}line\u{7F}"
        XCTAssertEqual(ProcessOnePasswordCLI.details(Data(stderr.utf8)), "locked now next line")
        let long = String(repeating: "x", count: 2000)
        let capped = ProcessOnePasswordCLI.details(Data(long.utf8))
        XCTAssertEqual(capped.count, 500)
        XCTAssertEqual(capped, String(repeating: "x", count: 499) + "\u{2026}")
        XCTAssertEqual(ProcessOnePasswordCLI.details(Data(String(repeating: "y", count: 500).utf8)).count, 500)
        for scalar in capped.unicodeScalars { XCTAssertFalse(scalar.properties.generalCategory == .control) }
    }

    func testEveryMappedCaseCarriesSanitizedDetails() {
        let error = ProcessOnePasswordCLI.error(stderr: Data("\u{1B}[1mauthorization timeout\u{1B}[0m\n".utf8), status: 1)
        XCTAssertEqual(error, .timedOut(details: "authorization timeout"))
        let notFound = ProcessOnePasswordCLI.error(stderr: Data("could not find\u{07} item x".utf8), status: 1)
        XCTAssertEqual(notFound, .notFound("could not find item x"))
    }

    func testTimeoutAndCancellationKeepStderrSoFar() async throws {
        let op = try fake("echo 'waiting for 1Password' >&2; exec sleep 30")
        let error = await readError(cli(op, timeout: .milliseconds(500)))
        XCTAssertEqual(error, .timedOut(details: "waiting for 1Password"))
    }

    func testDetailsNeverCarryReadOutput() async throws {
        let cases = [
            "printf 'TOPSECRET'; echo 'authorization timeout' >&2; exit 1",
            "printf 'TOPSECRET'; echo 'No accounts configured for use with 1Password CLI.' >&2; exit 1",
            "printf 'TOPSECRET'; echo '1Password app is locked' >&2; exit 1",
            "printf 'TOPSECRET'; exit 1",
            "printf 'TOPSECRET'; exec sleep 30",
        ]
        for body in cases {
            let op = try fake(body)
            let maybeError = await readError(cli(op, timeout: .milliseconds(500)))
            let error = try XCTUnwrap(maybeError, body)
            XCTAssertFalse(error.details?.contains("TOPSECRET") ?? false, body)
            XCTAssertFalse(error.message.contains("TOPSECRET"), body)
            XCTAssertFalse("\(error)".contains("TOPSECRET"), body)
        }
    }

    func testCheckUsesStdoutWhenStderrIsEmpty() async throws {
        // op may print the "No accounts configured" text to stdout; `check` (op vault list) has no secrets.
        let op = try fake("cat \"$d/err\"; exit 1")
        try op.put("err", Self.noAccountsStderr)
        do {
            try await cli(op).check()
            XCTFail("expected an error")
        } catch {
            guard case .integrationOff(let details?) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(details.hasPrefix("No accounts configured"), details)
        }
    }

    // MARK: check

    func testCheckListsVaults() async throws {
        let op = try fake("echo '[{\"id\":\"kzz3\",\"name\":\"Private\"}]'")
        try await cli(op).check()
        XCTAssertEqual(op.argv, ["vault", "list", "--format", "json"])
    }

    func testCheckMapsErrors() async throws {
        let op = try fake("echo '[ERROR] 2026/11/14 10:00:00 connecting to desktop app: read: connection reset' >&2; exit 1")
        do {
            try await cli(op).check()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error, .integrationOff(details: "connecting to desktop app: read: connection reset"))
        }
    }

    // MARK: listItems / fields

    // MARK: Diagnosis (v1.0.0)

    /// What `op` printed on Cory's second Mac (macOS 27) and in 1Password's community reports.
    func testClassifierTellsTheSetupProblemsApart() {
        let cases: [(String, OnePasswordError)] = [
            ("[ERROR] 2026/11/14 21:03:11 No accounts configured for use with 1Password CLI.",
             .integrationOff(details: "No accounts configured for use with 1Password CLI.")),
            ("[ERROR] 2026/11/14 21:03:11 error initializing client: connecting to desktop app: read: connection reset, make sure 1Password CLI is installed correctly, then open the 1Password app, select 1Password in the menu bar, and select Settings > Developer > Integrate with 1Password CLI.",
             .integrationOff(details: "error initializing client: connecting to desktop app: read: connection reset, make sure 1Password CLI is installed correctly, then open the 1Password app, select 1Password in the menu bar, and select Settings > Developer > Integrate with 1Password CLI.")),
            ("[ERROR] 2026/11/14 21:03:11 open /Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/settings/settings.json: operation not permitted",
             .containerBlocked(details: "open /Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/settings/settings.json: operation not permitted")),
            ("[ERROR] 2026/11/14 21:03:11 error initializing client: connecting to desktop app: dial unix /Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/t/s.sock: connect: operation not permitted",
             .containerBlocked(details: "error initializing client: connecting to desktop app: dial unix /Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/t/s.sock: connect: operation not permitted")),
            ("[ERROR] 2026/11/14 21:03:11 error initializing client: connecting to desktop app: dial unix /Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/t/s.sock: connect: connection refused",
             .appNotRunning(details: "error initializing client: connecting to desktop app: dial unix /Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/t/s.sock: connect: connection refused")),
            ("[ERROR] 2026/11/14 21:03:11 1Password app is locked", .appLocked(details: "1Password app is locked")),
            ("open /etc/x: operation not permitted", .failed("open /etc/x: operation not permitted")),
        ]
        for (stderr, expected) in cases {
            XCTAssertEqual(ProcessOnePasswordCLI.error(stderr: Data(stderr.utf8), status: 1), expected, stderr)
        }
    }

    /// Review samples: 1Password quit (its socket gone), `op` that couldn't start behind a wrapper,
    /// signed-out wordings and EACCES on the container.
    func testClassifierReviewSamples() {
        let path = "/Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/t/s.sock"
        let cases: [(String, OnePasswordError)] = [
            ("[ERROR] 2026/11/15 09:00:00 error initializing client: connecting to desktop app: dial unix \(path): connect: no such file or directory",
             .appNotRunning(details: "error initializing client: connecting to desktop app: dial unix \(path): connect: no such file or directory")),
            ("[ERROR] 2026/11/15 09:00:00 error initializing client: connecting to desktop app: cannot connect to 1Password app, make sure it is running",
             .appNotRunning(details: "error initializing client: connecting to desktop app: cannot connect to 1Password app, make sure it is running")),
            ("[ERROR] 2026/11/15 09:00:00 cannot connect to 1Password app, make sure it is running",
             .appNotRunning(details: "cannot connect to 1Password app, make sure it is running")),
            ("/opt/tools/op-wrapper: line 2: op: command not found",
             .failed("op couldn\u{2019}t start: /opt/tools/op-wrapper: line 2: op: command not found")),
            ("env: op: No such file or directory", .failed("op couldn\u{2019}t start: env: op: No such file or directory")),
            ("/opt/tools/op: exec format error", .failed("op couldn\u{2019}t start: /opt/tools/op: exec format error")),
            ("[ERROR] 2026/11/15 09:00:00 account is not signed in", .appLocked(details: "account is not signed in")),
            ("[ERROR] 2026/11/15 09:00:00 You are not currently signed in. Please run `op signin --help` for instructions",
             .appLocked(details: "You are not currently signed in. Please run `op signin --help` for instructions")),
            ("open /Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/settings/settings.json: permission denied",
             .containerBlocked(details: "open /Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/settings/settings.json: permission denied")),
            // A missing item is still a missing item; a stray "not found" is not.
            ("[ERROR] 2026/11/15 09:00:00 could not read secret op://Private/web/password: no item matched",
             .notFound("could not read secret op://Private/web/password: no item matched")),
            ("[ERROR] 2026/11/15 09:00:00 vault \"Old\" does not exist", .notFound("vault \"Old\" does not exist")),
            ("[ERROR] 2026/11/15 09:00:00 plugin not found in config", .failed("plugin not found in config")),
            ("[ERROR] 2026/11/15 09:00:00 connecting to desktop app: read: connection reset",
             .integrationOff(details: "connecting to desktop app: read: connection reset")),
        ]
        for (stderr, expected) in cases {
            XCTAssertEqual(ProcessOnePasswordCLI.error(stderr: Data(stderr.utf8), status: 1), expected, stderr)
        }
    }

    /// The telling words may come after the first 500 characters; only the stored details are cut.
    func testClassifierReadsPastTheDetailsLimit() {
        let stderr = String(repeating: "padding ", count: 80) + "No accounts configured for use with 1Password CLI."
        let error = ProcessOnePasswordCLI.error(stderr: Data(stderr.utf8), status: 1)
        guard case .integrationOff(let details?) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(details.count, ProcessOnePasswordCLI.detailsLimit)
    }

    /// The container probe can sit behind a macOS privacy prompt: it never runs on the caller's thread.
    @MainActor
    func testContainerProbeRunsOffTheMainThread() async {
        let ranOnMain = await OnePasswordPaths.inBackground { Thread.isMainThread }
        XCTAssertFalse(ranOnMain)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)").path
        let access = await OnePasswordPaths.groupContainerAccessInBackground(home: home)
        XCTAssertEqual(access, .missing)
    }

    func testNoAccountsConfiguredIsTheContainerWhenMacOSBlocksThisAppToo() async throws {
        let op = try fake("echo '[ERROR] 2026/11/14 21:03:11 No accounts configured for use with 1Password CLI.' >&2; exit 1")
        do {
            try await cli(op, containerAccess: { .denied }).check()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error, .containerBlocked(details: "No accounts configured for use with 1Password CLI."))
        }
        do {
            try await cli(op, containerAccess: { .exists }).check()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error, .integrationOff(details: "No accounts configured for use with 1Password CLI."))
        }
    }

    func testRefineLeavesOtherErrorsAlone() {
        let reset = OnePasswordError.integrationOff(details: "connecting to desktop app: read: connection reset")
        XCTAssertEqual(ProcessOnePasswordCLI.refine(reset, containerAccess: { .denied }), reset)
        XCTAssertEqual(ProcessOnePasswordCLI.refine(.appLocked(details: nil), containerAccess: { .denied }),
                       .appLocked(details: nil))
    }

    func testNeedsSetup() {
        for error in [OnePasswordError.cliNotFound, .integrationOff(details: nil), .appLocked(details: nil),
                      .containerBlocked(details: nil), .appNotRunning(details: nil)] {
            XCTAssertTrue(error.needsSetup, "\(error)")
        }
        for error in [OnePasswordError.cancelled(details: nil), .timedOut(details: nil), .notFound("x"), .failed("y")] {
            XCTAssertFalse(error.needsSetup, "\(error)")
        }
    }

    func testListVaultsDecodesNamesAndIDs() async throws {
        let op = try fake("""
        echo '[{"id":"kzz3xbmyq5ezlnuojlf4ddmtmu","name":"Private","content_version":41},{"id":"zr4rnryd5wfhpxjsdlvx2cdh5e","name":"SSH Key Vault","content_version":3},{"id":"nonamevault"}]'
        """)
        let vaults = try await cli(op).listVaults()
        XCTAssertEqual(op.argv, ["vault", "list", "--format", "json"])
        XCTAssertEqual(vaults, [OnePasswordVault(id: "kzz3xbmyq5ezlnuojlf4ddmtmu", name: "Private"),
                                OnePasswordVault(id: "zr4rnryd5wfhpxjsdlvx2cdh5e", name: "SSH Key Vault"),
                                OnePasswordVault(id: "nonamevault", name: "nonamevault")])
    }

    func testListVaultsWithUnreadableOutput() async throws {
        let op = try fake("echo 'not json'")
        do {
            _ = try await cli(op).listVaults()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error, .failed("Couldn't read the vault list from 1Password."))
        }
    }

    func testListItemsByCategoryAsksOpToFilter() async throws {
        let op = try fake("cat \"$d/list\"")
        try op.put("list", itemListJSON)
        let items = try await cli(op).listItems(categories: ["SSH Key"])
        XCTAssertEqual(op.argv, ["item", "list", "--categories", "SSH Key", "--format", "json"])
        XCTAssertEqual(items.count, 3, "op filters; the answer is taken as given")
    }

    func testCategoryIDs() {
        XCTAssertEqual(OnePasswordItemSummary.categoryID("SSH Key"), "SSH_KEY")
        XCTAssertEqual(OnePasswordItemSummary.categoryID("Login"), "LOGIN")
        XCTAssertEqual(OnePasswordItemSummary.categoryID("SSH_KEY"), "SSH_KEY")
    }

    func testGroupContainerProbe() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(OnePasswordPaths.groupContainerAccess(home: home.path), .missing)
        var seen: String?
        XCTAssertEqual(OnePasswordPaths.groupContainerAccess(home: "/Users/cory", probe: { seen = $0; return .denied }), .denied)
        XCTAssertEqual(seen, "/Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/settings/settings.json")
        let file = home.appendingPathComponent("f")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(OnePasswordPaths.probeOpen(file.path), .exists)
    }

    func testListItemsDecodesTheItemList() async throws {
        let op = try fake("cat \"$d/out\"")
        try op.put("out", itemListJSON)
        let items = try await cli(op).listItems()
        XCTAssertEqual(op.argv, ["item", "list", "--format", "json"])
        XCTAssertEqual(items, [
            OnePasswordItemSummary(id: "u3xkqzq2ozhl4ye6ojxbs5ycyy", title: "web.example root", vault: "Private",
                                   vaultID: "kzz3xbmyq5ezlnuojlf4ddmtmu", category: "LOGIN"),
            OnePasswordItemSummary(id: "7kb2tbkqrnbx5aq3yzz5yrgkfe", title: "Homelab key", vault: "Homelab",
                                   vaultID: "zr4rnryd5wfhpxjsdlvx2cdh5e", category: "SSH_KEY"),
            OnePasswordItemSummary(id: "c4iuvvprq4ct6d3ma2aaaaaaaa", title: "NAS", vault: "zr4rnryd5wfhpxjsdlvx2cdh5e",
                                   vaultID: "zr4rnryd5wfhpxjsdlvx2cdh5e", category: "SERVER"),
        ])
    }

    func testListItemsWithNoItems() async throws {
        let op = try fake("exit 0")
        let items = try await cli(op).listItems()
        XCTAssertEqual(items, [])
    }

    func testListItemsWithUnreadableOutput() async throws {
        let op = try fake("echo 'not json'")
        do {
            _ = try await cli(op).listItems()
            XCTFail("expected an error")
        } catch {
            guard case .failed = error else { return XCTFail("\(error)") }
        }
    }

    func testFieldsAreBuiltWithoutRunningOp() async throws {
        let op = try fake("exit 0")
        let fields = try await cli(op).fields(itemID: "u3xkqzq2ozhl4ye6ojxbs5ycyy", vault: "Private")
        XCTAssertNil(op.argv, "no op call: values are never fetched for the picker")
        XCTAssertEqual(fields, [
            OnePasswordField(id: "password", label: "password",
                             reference: "op://Private/u3xkqzq2ozhl4ye6ojxbs5ycyy/password", isSecret: true),
            OnePasswordField(id: "username", label: "username",
                             reference: "op://Private/u3xkqzq2ozhl4ye6ojxbs5ycyy/username", isSecret: false),
        ])
    }

    func testFieldsFollowTheCategorySeenInTheList() async throws {
        let op = try fake("cat \"$d/out\"")
        try op.put("out", itemListJSON)
        let client = cli(op)
        _ = try await client.listItems()
        let fields = try await client.fields(itemID: "7kb2tbkqrnbx5aq3yzz5yrgkfe", vault: "Homelab")
        XCTAssertEqual(fields.map(\.reference), ["op://Homelab/7kb2tbkqrnbx5aq3yzz5yrgkfe/private key",
                                                 "op://Homelab/7kb2tbkqrnbx5aq3yzz5yrgkfe/public key"])
        XCTAssertEqual(fields.map(\.isSecret), [true, false])
    }

    func testStandardFieldsUseTheVaultIDWhenTheNameCantBeInAReference() {
        let fields = OnePasswordField.standardFields(itemID: "abc", vault: "Work/Ops", vaultID: "vid123", category: "LOGIN")
        XCTAssertEqual(fields.first?.reference, "op://vid123/abc/password")
        let named = OnePasswordField.standardFields(itemID: "abc", vault: "My Vault_1.x-y", vaultID: "vid123", category: "LOGIN")
        XCTAssertEqual(named.first?.reference, "op://My Vault_1.x-y/abc/password")
        let sshKey = OnePasswordField.standardFields(itemID: "abc", vault: "V", vaultID: nil, category: "SSH_KEY")
        XCTAssertEqual(sshKey.map(\.label), ["private key", "public key"])
    }

    func testPasswordPurposeOffersOnlyPasswordFields() {
        func labels(_ category: String?) -> [String] {
            OnePasswordField.standardFields(itemID: "abc", vault: "V", vaultID: nil, category: category,
                                            purpose: .password).map(\.label)
        }
        for category in ["LOGIN", "PASSWORD", "SERVER", "DATABASE"] {
            XCTAssertEqual(labels(category), ["password"], category)
        }
        let login = OnePasswordField.standardFields(itemID: "abc", vault: "V", vaultID: nil, category: "LOGIN",
                                                    purpose: .password)
        XCTAssertEqual(login.map(\.reference), ["op://V/abc/password"])
        XCTAssertEqual(login.map(\.isSecret), [true])
        // An SSH key's private or public key is never a password: the UI steers to the agent instead.
        XCTAssertEqual(labels("SSH_KEY"), [])
        for other in ["SECURE_NOTE", "CREDIT_CARD", "API_CREDENTIAL", "", nil] as [String?] {
            XCTAssertEqual(labels(other), [], other ?? "nil")
        }
        // Without a purpose, every standard field (as before).
        XCTAssertEqual(OnePasswordField.standardFields(itemID: "abc", vault: "V", vaultID: nil, category: "SSH_KEY",
                                                       purpose: .any).map(\.label), ["private key", "public key"])
        XCTAssertEqual(OnePasswordField.standardFields(itemID: "abc", vault: "V", vaultID: nil, category: "LOGIN",
                                                       purpose: .any).map(\.label), ["password", "username"])
    }
}
