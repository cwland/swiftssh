import XCTest
import SSHCore
@testable import AppCore

/// When a connection to the main address moves on to the backup address.
final class ConnectionFallbackTests: XCTestCase {
    func testBackupAddressIsTrimmedAndNilWhenBlankOrTheSameAsMain() {
        XCTAssertEqual(ConnectionFallback.backupAddress(main: "192.168.50.10", backup: " 100.64.0.10\n"), "100.64.0.10")
        XCTAssertNil(ConnectionFallback.backupAddress(main: "a", backup: nil))
        XCTAssertNil(ConnectionFallback.backupAddress(main: "a", backup: ""))
        XCTAssertNil(ConnectionFallback.backupAddress(main: "a", backup: "  \t"))
        XCTAssertNil(ConnectionFallback.backupAddress(main: "nas.lan", backup: "NAS.lan"), "the same host, any case")
        XCTAssertNil(ConnectionFallback.backupAddress(main: "nas.lan", backup: "nas.lan."), "a trailing dot is the same host")
    }

    func testReachLimitIsFiveSeconds() {
        XCTAssertEqual(ConnectionFallback.reachTimeout, .seconds(5))
    }

    func testStepsThatShowTheServerWasReached() {
        XCTAssertFalse(ConnectionFallback.reachesServer(.resolving(host: "h")))
        XCTAssertFalse(ConnectionFallback.reachesServer(.connecting(address: "1.2.3.4", port: 22)))
        XCTAssertTrue(ConnectionFallback.reachesServer(.connected(address: "1.2.3.4")))
        XCTAssertTrue(ConnectionFallback.reachesServer(.handshake))
        XCTAssertTrue(ConnectionFallback.reachesServer(.authenticating(method: "password")))
        XCTAssertTrue(ConnectionFallback.reachesServer(.authenticated))
        XCTAssertTrue(ConnectionFallback.reachesServer(.openingShell))
        XCTAssertTrue(ConnectionFallback.reachesServer(.attachingTmux(session: "main")))
    }

    func testFallsBackOnlyWhenTheServerCouldNotBeReached() {
        let unreachable: [SessionError] = [.timedOut, .unreachable("Could not connect to h:22 (connection refused)"),
                                           .unreachable("Could not resolve h (host name not found)")]
        for error in unreachable {
            XCTAssertTrue(ConnectionFallback.shouldTryBackup(after: .failed(error), reachedServer: false), "\(error)")
            XCTAssertFalse(ConnectionFallback.shouldTryBackup(after: .failed(error), reachedServer: true),
                           "reached, then failed later: \(error)")
        }
        let others: [SessionError] = [.authenticationFailed, .hostKeyRejected,
                                      .hostKeyChanged(previous: "a", presented: "b"), .keyUnreadable,
                                      .connectionFailed("The server closed the connection before signing in."),
                                      .unsupportedKey("rsa"), .agentUnavailable("x")]
        for error in others {
            XCTAssertFalse(ConnectionFallback.shouldTryBackup(after: .failed(error), reachedServer: false), "\(error)")
        }
        XCTAssertFalse(ConnectionFallback.shouldTryBackup(after: .userClosed, reachedServer: false), "cancelled")
        XCTAssertFalse(ConnectionFallback.shouldTryBackup(after: .remoteClosed, reachedServer: false))
    }

    func testReasonIsShortAndPlain() {
        XCTAssertEqual(ConnectionFallback.reason(of: .timedOut), "timed out")
        XCTAssertEqual(ConnectionFallback.reason(of: .unreachable("Could not connect to 192.168.50.10:22 (connection refused)")),
                       "connection refused")
        XCTAssertEqual(ConnectionFallback.reason(of: .unreachable("Could not resolve nas.lan (host name not found)")),
                       "host name not found")
        XCTAssertEqual(ConnectionFallback.reason(of: .unreachable("ssh: connect to host h port 22: No route to host")),
                       "No route to host")
        XCTAssertEqual(ConnectionFallback.reason(of: .unreachable("Could not reach h:22")), "Could not reach h:22")
    }

    func testNoteNamesBothAddresses() {
        XCTAssertEqual(ConnectionFallback.note(main: "192.168.50.10", reason: "timed out", backup: "100.64.0.10"),
                       "Main address 192.168.50.10 unreachable (timed out); trying backup address 100.64.0.10\u{2026}")
    }

    func testUnreachableReadsLikeAConnectionFailure() {
        XCTAssertEqual(SessionError.unreachable("Could not connect to h:22 (connection refused)").localizedDescription,
                       "The connection failed: Could not connect to h:22 (connection refused)")
    }
}
