import XCTest
@testable import AppCore

final class TerminalLinkFilterTests: XCTestCase {
    func testOpensWebSSHAndMailLinks() {
        XCTAssertEqual(TerminalLinkFilter.openableURL("https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(TerminalLinkFilter.openableURL("http://192.168.50.1:8080")?.absoluteString, "http://192.168.50.1:8080")
        XCTAssertEqual(TerminalLinkFilter.openableURL("ssh://root@host:2222")?.absoluteString, "ssh://root@host:2222")
        XCTAssertEqual(TerminalLinkFilter.openableURL("mailto:me@example.com")?.absoluteString, "mailto:me@example.com")
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertNotNil(TerminalLinkFilter.openableURL("HTTPS://Example.com"))
        XCTAssertNotNil(TerminalLinkFilter.openableURL("MailTo:x@y.z"))
    }

    func testIgnoresEverythingElse() {
        for link in ["file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple",
                     "ftp://host/file", "tel:5551234", "main.swift:12", "/usr/bin/env", "~/Desktop",
                     "example.com", "", "   ", "https://", "http:example", "mailto:"] {
            XCTAssertNil(TerminalLinkFilter.openableURL(link), link)
        }
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(TerminalLinkFilter.openableURL("  https://example.com\n")?.absoluteString, "https://example.com")
    }
}
