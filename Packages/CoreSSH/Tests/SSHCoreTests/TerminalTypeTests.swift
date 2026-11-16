import XCTest
@testable import SSHCore

final class TerminalTypeTests: XCTestCase {
    func testChoicesInPickerOrderWithTheirTERMValues() {
        XCTAssertEqual(TerminalType.allCases.map(\.rawValue),
                       ["xterm-256color", "xterm", "xterm-color", "vt100", "linux"])
        XCTAssertEqual(TerminalType.default, .xterm256color)
    }

    func testConnectionPlanDefaultsToXterm256ColorAndKeepsAGivenType() {
        var plan = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                                  credential: .none, engine: .citadel, startupScript: nil)
        XCTAssertEqual(plan.terminalType, .xterm256color)
        plan.terminalType = .vt100
        XCTAssertEqual(plan.terminalType, .vt100)
        let linux = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                                   credential: .none, engine: .systemSSH, startupScript: nil, terminalType: .linux)
        XCTAssertEqual(linux.terminalType, .linux)
    }
}
