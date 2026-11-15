import XCTest
@testable import SSHCore

final class KeepAlivePolicyTests: XCTestCase {
    func testPresets() {
        XCTAssertEqual(KeepAlivePolicy.standard, KeepAlivePolicy(interval: .seconds(5), maxUnanswered: 2))
        XCTAssertEqual(KeepAlivePolicy.off, KeepAlivePolicy(interval: nil, maxUnanswered: 0))
        XCTAssertNil(KeepAlivePolicy.off.interval)
    }

    func testConnectionPlanDefaultsToStandardAndKeepsAGivenPolicy() {
        let plain = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                                   credential: .none, engine: .citadel, startupScript: nil)
        XCTAssertEqual(plain.keepAlive, .standard)
        let slow = KeepAlivePolicy(interval: .seconds(60), maxUnanswered: 5)
        let custom = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                                    credential: .none, engine: .systemSSH, startupScript: nil, keepAlive: slow)
        XCTAssertEqual(custom.keepAlive, slow)
    }
}
