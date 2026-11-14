import XCTest
@testable import SSHCore

final class KeepAlivePolicyTests: XCTestCase {
    func testPresets() {
        XCTAssertEqual(KeepAlivePolicy.fast, KeepAlivePolicy(interval: .seconds(15), maxUnanswered: 2))
        XCTAssertEqual(KeepAlivePolicy.normal, KeepAlivePolicy(interval: .seconds(30), maxUnanswered: 3))
        XCTAssertEqual(KeepAlivePolicy.relaxed, KeepAlivePolicy(interval: .seconds(60), maxUnanswered: 5))
        XCTAssertEqual(KeepAlivePolicy.off, KeepAlivePolicy(interval: nil, maxUnanswered: 0))
        XCTAssertNil(KeepAlivePolicy.off.interval)
    }

    func testConnectionPlanDefaultsToNormalAndKeepsAGivenPolicy() {
        let plain = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                                   credential: .none, engine: .citadel, startupScript: nil)
        XCTAssertEqual(plain.keepAlive, .normal)
        let relaxed = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                                     credential: .none, engine: .systemSSH, startupScript: nil, keepAlive: .relaxed)
        XCTAssertEqual(relaxed.keepAlive, .relaxed)
    }
}
