import XCTest
@testable import AppCore

final class TerminalLinkFilterTests: XCTestCase {
    func testOpensWebAndMailLinks() {
        XCTAssertEqual(TerminalLinkFilter.openableURL("https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(TerminalLinkFilter.openableURL("http://192.168.99.1:8080")?.absoluteString, "http://192.168.99.1:8080")
        XCTAssertEqual(TerminalLinkFilter.openableURL("https://user@example.com/x")?.absoluteString, "https://user@example.com/x")
        XCTAssertEqual(TerminalLinkFilter.openableURL("mailto:me@example.com")?.absoluteString, "mailto:me@example.com")
        XCTAssertEqual(TerminalLinkFilter.openableURL("mailto:me@example.com?subject=hi")?.absoluteString,
                       "mailto:me@example.com?subject=hi")
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertNotNil(TerminalLinkFilter.openableURL("HTTPS://Example.com"))
        XCTAssertNotNil(TerminalLinkFilter.openableURL("MailTo:x@y.z"))
    }

    func testSSHLinksNoLongerOpen() {
        XCTAssertNil(TerminalLinkFilter.openableURL("ssh://root@host:2222"))
        XCTAssertNil(TerminalLinkFilter.openableURL("ssh://host"))
    }

    /// The reviewer's examples: option injection through the host or user of a handler URL.
    func testRejectsHostOrUserStartingWithADash() {
        for link in ["ssh://-oProxyCommand=open%20-a%20Calculator", "ssh://user@-host",
                     "https://-oProxyCommand=x/", "https://-evil.example.com/", "http://-x@example.com/",
                     "https://%2Dhost.example.com/", "http://%2Duser@example.com/", "mailto:-x@example.com"] {
            XCTAssertNil(TerminalLinkFilter.openableURL(link), link)
        }
    }

    func testRejectsControlFormatAndWhitespaceCharacters() {
        for link in ["https://example.com/\u{0007}", "https://exa\u{0000}mple.com", "https://example.com/\u{7F}",
                     "https://example.com/\u{202E}gpj.exe", "https://exam\u{200B}ple.com", "https://example.com/\u{2066}x",
                     "https://example.com/a b", "https://example.com/\t", " https://example.com", "https://example.com\n",
                     "https://example.com/\u{00A0}", "mailto:me@example.com\u{202E}"] {
            XCTAssertNil(TerminalLinkFilter.openableURL(link), link.debugDescription)
        }
    }

    func testMailtoNeedsAnAddress() {
        for link in ["mailto:", "mailto:?subject=x", "mailto:?to=me@example.com", "mailto:nobody"] {
            XCTAssertNil(TerminalLinkFilter.openableURL(link), link)
        }
    }

    func testIgnoresEverythingElse() {
        for link in ["file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple",
                     "ftp://host/file", "tel:5551234", "main.swift:12", "/usr/bin/env", "~/Desktop",
                     "example.com", "", "https://", "http:example", "https:///path"] {
            XCTAssertNil(TerminalLinkFilter.openableURL(link), link)
        }
    }

    // MARK: Decision (detected vs OSC 8)

    func testDetectedLinkOpensWithoutAsking() {
        XCTAssertEqual(TerminalLinkFilter.decision(link: "https://example.com", isExplicit: false, visibleText: nil),
                       .open(URL(string: "https://example.com")!))
    }

    func testExplicitLinkWhoseTargetDiffersFromTheTextAsksFirst() {
        XCTAssertEqual(TerminalLinkFilter.decision(link: "https://evil.example/", isExplicit: true,
                                                   visibleText: "https://bank.example/"),
                       .confirm(URL(string: "https://evil.example/")!))
        XCTAssertEqual(TerminalLinkFilter.decision(link: "https://example.com/docs", isExplicit: true,
                                                   visibleText: "the docs"),
                       .confirm(URL(string: "https://example.com/docs")!))
    }

    func testExplicitLinkWithUnknownTextAsksFirst() {
        XCTAssertEqual(TerminalLinkFilter.decision(link: "https://example.com", isExplicit: true, visibleText: nil),
                       .confirm(URL(string: "https://example.com")!))
    }

    func testExplicitLinkShowingItsOwnTargetOpens() {
        XCTAssertEqual(TerminalLinkFilter.decision(link: "https://example.com/a", isExplicit: true,
                                                   visibleText: " https://example.com/a\n"),
                       .open(URL(string: "https://example.com/a")!))
    }

    func testUnsafeLinksAreIgnoredWhateverTheirKind() {
        XCTAssertEqual(TerminalLinkFilter.decision(link: "ssh://user@-host", isExplicit: true, visibleText: "x"), .ignore)
        XCTAssertEqual(TerminalLinkFilter.decision(link: "file:///etc/passwd", isExplicit: false, visibleText: nil), .ignore)
    }
}
