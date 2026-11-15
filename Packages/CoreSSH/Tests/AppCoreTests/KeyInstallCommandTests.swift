import XCTest
@testable import AppCore

final class KeyInstallCommandTests: XCTestCase {
    private let prefix = "SSH_AUTH_SOCK=\"$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\" ssh-add -L | ssh -p "
    private let suffix = " 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
    private var placeholder: String { prefix + "PORT USER@HOST" + suffix }

    func testNilAndEmptyGiveTheTemplate() {
        XCTAssertEqual(KeyInstallCommand.make(port: nil, user: nil, host: nil), placeholder)
        XCTAssertEqual(KeyInstallCommand.make(port: nil, user: "", host: ""), placeholder)
    }

    func testValuesAreQuotedWithDoubleDash() {
        XCTAssertEqual(KeyInstallCommand.make(port: 2222, user: "root", host: "h.example"),
                       prefix + "2222 -- 'root@h.example'" + suffix)
    }

    func testBadPortUsesPlaceholderPortButKeepsTarget() {
        for port in [0, -1, 65536] {
            XCTAssertEqual(KeyInstallCommand.make(port: port, user: "root", host: "h"),
                           prefix + "PORT -- 'root@h'" + suffix)
        }
        XCTAssertEqual(KeyInstallCommand.make(port: 65535, user: "root", host: "h"), prefix + "65535 -- 'root@h'" + suffix)
        XCTAssertEqual(KeyInstallCommand.make(port: 1, user: "root", host: "h"), prefix + "1 -- 'root@h'" + suffix)
    }

    func testDashLeadingOrEmptyOrControlValuesGiveTheTemplate() {
        let bad: [(String?, String?)] = [
            ("root", "-oProxyCommand=touch /tmp/x"), ("-oProxyCommand=x", "h"), ("root", "-h"),
            ("root", ""), ("", "h"), (nil, "h"), ("root", nil),
            ("ro\not", "h"), ("root", "h\u{0}x"), ("root", "h\r"), ("ro\u{7F}ot", "h"), ("root", "h\tx"),
        ]
        for (user, host) in bad {
            XCTAssertEqual(KeyInstallCommand.make(port: 22, user: user, host: host), placeholder,
                           "\(String(describing: user)) @ \(String(describing: host))")
        }
        XCTAssertEqual(KeyInstallCommand.make(port: nil, user: "root", host: "-x"), placeholder)
    }

    func testSingleQuotesAreEscaped() {
        XCTAssertEqual(KeyInstallCommand.make(port: 22, user: "o'brien", host: "h'; rm -rf ~; '"),
                       prefix + "22 -- 'o'\\''brien@h'\\''; rm -rf ~; '\\'''" + suffix)
    }

    func testIPv6HostIsKeptVerbatimInsideQuotes() {
        XCTAssertEqual(KeyInstallCommand.make(port: 22, user: "root", host: "fe80::1%en0"),
                       prefix + "22 -- 'root@fe80::1%en0'" + suffix)
    }
}
