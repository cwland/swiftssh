import XCTest
@testable import AppCore

final class QuickConnectTests: XCTestCase {
    private func target(_ user: String?, _ host: String, _ port: Int?) -> QuickConnectTarget {
        QuickConnectTarget(username: user, host: host, port: port)
    }

    func testParsesUserHostPort() {
        XCTAssertEqual(QuickConnect.parse("cory@10.1.10.25:2222"), target("cory", "10.1.10.25", 2222))
    }

    func testParsesSSHStyleWithDashP() {
        XCTAssertEqual(QuickConnect.parse("ssh root@10.0.0.5 -p 2222"), target("root", "10.0.0.5", 2222))
    }

    func testParsesDashL() {
        XCTAssertEqual(QuickConnect.parse("ssh -l pi raspi.local"), target("pi", "raspi.local", nil))
    }

    func testParsesBracketedIPv6() {
        XCTAssertEqual(QuickConnect.parse("[fe80::1]:22"), target(nil, "fe80::1", 22))
        XCTAssertEqual(QuickConnect.parse("admin@[fe80::1]"), target("admin", "fe80::1", nil))
    }

    func testBareIPv6HasNoPort() {
        XCTAssertEqual(QuickConnect.parse("fe80::1"), target(nil, "fe80::1", nil))
    }

    func testBareHostAndTrimming() {
        XCTAssertEqual(QuickConnect.parse("  pihole  "), target(nil, "pihole", nil))
    }

    func testRejectsEmptyAndBadPort() {
        for input in ["", "   ", "host:0", "host:70000", "host:abc", "host -p 0", "host -p", "-l", "host -x"] {
            XCTAssertNil(QuickConnect.parse(input), input)
        }
    }
}
