import Foundation
import NIOCore
import Synchronization
import XCTest
@testable import SSHCore

final class ConnectionRaceTests: XCTestCase {
    private struct Refused: Error {}

    func testASilentFirstAddressLosesToTheNextAfterTheStagger() async throws {
        let discarded = Mutex<[String]>([])
        let started = Mutex<[String]>([])
        let clock = ContinuousClock()
        let begin = clock.now
        let winner = try await ConnectionRace.run(
            candidates: ["blackholed-v6", "v4"],
            started: { candidate in started.withLock { $0.append(candidate) } },
            attempt: { candidate -> String in
                if candidate == "blackholed-v6" { try await Task.sleep(for: .seconds(2)) } // answers late
                return candidate
            },
            discard: { value in discarded.withLock { $0.append(value) } })
        let elapsed = clock.now - begin
        XCTAssertEqual(winner, "v4")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(240), "the second waits for the stagger")
        XCTAssertLessThan(elapsed, .milliseconds(500))
        XCTAssertEqual(started.withLock { $0 }, ["blackholed-v6", "v4"])
        // The late first attempt still succeeds later: it is handed back to be closed.
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertEqual(discarded.withLock { $0 }, ["blackholed-v6"])
    }

    func testAFastFailureStartsTheNextAtOnce() async throws {
        let clock = ContinuousClock()
        let begin = clock.now
        let winner = try await ConnectionRace.run(
            candidates: ["refused", "ok"], started: { _ in },
            attempt: { candidate -> String in
                if candidate == "refused" { throw Refused() }
                return candidate
            },
            discard: { _ in })
        XCTAssertEqual(winner, "ok")
        XCTAssertLessThan(clock.now - begin, .milliseconds(200))
    }

    func testAllFailingGivesEveryError() async throws {
        do {
            _ = try await ConnectionRace.run(candidates: ["a", "b", "c"], started: { _ in },
                                             attempt: { _ -> String in throw Refused() }, discard: { _ in })
            XCTFail("expected a failure")
        } catch let failure as ConnectionRace.Failure {
            XCTAssertEqual(failure.errors.count, 3)
        }
    }

    func testNoNewAttemptsOnceAbandoned() async throws {
        let started = Mutex(0)
        do {
            _ = try await ConnectionRace.run(candidates: ["a", "b", "c"], isAbandoned: { true },
                                             started: { _ in started.withLock { $0 += 1 } },
                                             attempt: { _ -> String in throw Refused() }, discard: { _ in })
            XCTFail("expected a failure")
        } catch is ConnectionRace.Failure {}
        XCTAssertEqual(started.withLock { $0 }, 1)
    }

    func testFamiliesAreInterleaved() throws {
        let v6a = try SocketAddress(ipAddress: "2001:db8::1", port: 22)
        let v6b = try SocketAddress(ipAddress: "2001:db8::2", port: 22)
        let v4a = try SocketAddress(ipAddress: "192.0.2.1", port: 22)
        let v4b = try SocketAddress(ipAddress: "192.0.2.2", port: 22)
        XCTAssertEqual(ConnectionRace.interleavedByFamily([v6a, v6b, v4a, v4b]), [v6a, v4a, v6b, v4b])
        XCTAssertEqual(ConnectionRace.interleavedByFamily([v4a, v6a, v6b]), [v4a, v6a, v6b])
        XCTAssertEqual(ConnectionRace.interleavedByFamily([v4a]), [v4a])
    }

    func testIPv6AddressesAreBracketedInTheStepText() {
        XCTAssertEqual(ConnectionStep.connecting(address: "fd7a::1", port: 22).text, "Connecting to [fd7a::1]:22\u{2026}")
        XCTAssertEqual(ConnectionStep.connecting(address: "10.0.0.5", port: 22).text, "Connecting to 10.0.0.5:22\u{2026}")
    }

    func testAbandonedLookupReturnsAtOnce() async throws {
        let clock = ContinuousClock()
        let begin = clock.now
        do {
            _ = try await NameResolver.resolve(host: "localhost", port: 22, isAbandoned: { true })
        } catch is CancellationError {}
        XCTAssertLessThan(clock.now - begin, .milliseconds(500))
    }
}
