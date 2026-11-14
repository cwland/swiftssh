import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import SSHCore

final class HostKeyValidationDelegateTests: XCTestCase {
    // Two fixed ed25519 public keys.
    private let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOiuxloU1VddeltegKdfeKT9A96Xd+Jowut6BPrjp4tL"
    private let keyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDlnbdTsjLH0SrUMVEQeZUKWYUgFEZqRsPPhqCGhKGJT"

    private func candidate(_ line: String) throws -> HostKeyCandidate {
        let key = try NIOSSHPublicKey(openSSHPublicKey: line)
        return try XCTUnwrap(HostKeyValidationDelegate.candidate(for: key, host: "example.com", port: 2222))
    }

    private func validate(_ line: String, delegate: HostKeyValidationDelegate) async throws -> Bool {
        let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: try NIOSSHPublicKey(openSSHPublicKey: line), validationCompletePromise: promise)
        do {
            try await promise.futureResult.get()
            return true
        } catch {
            return false
        }
    }

    func testCandidateCarriesTypeBlobAndHostPort() throws {
        let c = try candidate(keyA)
        XCTAssertEqual(c.keyType, "ssh-ed25519")
        XCTAssertEqual(c.hostPort, "[example.com]:2222")
        XCTAssertEqual(c.fingerprint, "SHA256:RRbmR91glWz3fSs2lRGcStgvHJN15ymZGGyvojei2Uw")
    }

    func testPreapprovedKeySkipsEvaluator() async throws {
        let evaluator = TestEvaluator(decision: .rejected)
        let tracker = HostKeyTracker(preapproved: try candidate(keyA))
        let delegate = HostKeyValidationDelegate(host: "example.com", port: 2222, evaluator: evaluator, tracker: tracker)
        let accepted = try await validate(keyA, delegate: delegate)
        XCTAssertTrue(accepted)
        XCTAssertTrue(evaluator.candidates.isEmpty)
    }

    func testDifferentKeyThanPreapprovedIsEvaluated() async throws {
        let evaluator = TestEvaluator(decision: .rejected)
        let tracker = HostKeyTracker(preapproved: try candidate(keyA))
        let delegate = HostKeyValidationDelegate(host: "example.com", port: 2222, evaluator: evaluator, tracker: tracker)
        let accepted = try await validate(keyB, delegate: delegate)
        XCTAssertFalse(accepted)
        XCTAssertEqual(evaluator.candidates, [try candidate(keyB)])
        XCTAssertTrue(tracker.wasRejected)
    }

    func testAbandonFailsPendingValidationAndIgnoresLateAnswer() async throws {
        let evaluator = TestEvaluator(decision: .trusted, delay: .seconds(1))
        let tracker = HostKeyTracker(preapproved: nil)
        let delegate = HostKeyValidationDelegate(host: "example.com", port: 2222, evaluator: evaluator, tracker: tracker)
        let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: try NIOSSHPublicKey(openSSHPublicKey: keyA), validationCompletePromise: promise)
        try await waitUntil { !evaluator.candidates.isEmpty }
        let clock = ContinuousClock()
        let abandonedAt = clock.now
        tracker.abandon()
        do {
            try await promise.futureResult.get()
            XCTFail("an abandoned validation must fail")
        } catch {}
        XCTAssertLessThan(clock.now - abandonedAt, .milliseconds(200), "fails at once, without waiting for the evaluator")
        // The late "trusted" answer is recorded but changes nothing.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(tracker.wasRejected)
    }
}
