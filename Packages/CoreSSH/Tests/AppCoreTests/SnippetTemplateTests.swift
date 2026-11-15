import XCTest
@testable import AppCore

final class SnippetTemplateTests: XCTestCase {
    private typealias P = SnippetTemplate.Placeholder

    func testNoPlaceholders() {
        let t = SnippetTemplate("ls -la /srv")
        XCTAssertEqual(t.placeholders, [])
        XCTAssertFalse(t.hasPlaceholders)
        XCTAssertEqual(t.filled(with: [:]), "ls -la /srv")
        XCTAssertEqual(t.filled(with: ["x": "y"]), "ls -la /srv")
    }

    func testNameAndDefault() {
        let t = SnippetTemplate("ssh {{user}}@{{host:web.local}}")
        XCTAssertEqual(t.placeholders, [P(name: "user", defaultValue: nil), P(name: "host", defaultValue: "web.local")])
        XCTAssertTrue(t.hasPlaceholders)
        XCTAssertEqual(t.filled(with: ["user": "root", "host": "db"]), "ssh root@db")
    }

    func testFillMissingUsesDefaultThenEmpty() {
        let t = SnippetTemplate("ping -c {{count:3}} {{host}}")
        XCTAssertEqual(t.filled(with: [:]), "ping -c 3 ")
        XCTAssertEqual(t.filled(with: ["host": "x"]), "ping -c 3 x")
        XCTAssertEqual(t.filled(with: ["count": "", "host": "x"]), "ping -c  x", "a given empty value is used as typed")
    }

    func testValuesInsertedAsTyped() {
        let t = SnippetTemplate("echo {{msg}}")
        XCTAssertEqual(t.filled(with: ["msg": "a b; rm 'x' {{y}}"]), "echo a b; rm 'x' {{y}}")
    }

    func testSpacesAroundNameAndDefaultAreTrimmed() {
        let t = SnippetTemplate("cd {{ dir : /var/log }} && {{  cmd  }}")
        XCTAssertEqual(t.placeholders, [P(name: "dir", defaultValue: "/var/log"), P(name: "cmd", defaultValue: nil)])
        XCTAssertEqual(t.filled(with: ["cmd": "ls"]), "cd /var/log && ls")
    }

    func testNameCharacters() {
        let t = SnippetTemplate("{{a_b-1}} {{ABC}} {{9}}")
        XCTAssertEqual(t.placeholders.map(\.name), ["a_b-1", "ABC", "9"])
    }

    func testInvalidNamesStayLiteral() {
        for script in ["{{}}", "{{ }}", "{{a b}}", "{{a.b}}", "{{$x}}", "{{:def}}", "{{a/b:c}}"] {
            let t = SnippetTemplate(script)
            XCTAssertEqual(t.placeholders, [], script)
            XCTAssertEqual(t.filled(with: [:]), script, script)
        }
    }

    func testUnclosedStaysLiteral() {
        for script in ["echo {{name", "echo {{name}", "echo {name}}", "{{a\n}}", "awk '{print $1}'", "x }} {{"] {
            let t = SnippetTemplate(script)
            XCTAssertEqual(t.placeholders, [], script)
            XCTAssertEqual(t.filled(with: ["name": "v", "a": "v"]), script, script)
        }
    }

    func testLiteralPartsAroundValidOnes() {
        let t = SnippetTemplate("{{bad name}} {{good}} {{open")
        XCTAssertEqual(t.placeholders.map(\.name), ["good"])
        XCTAssertEqual(t.filled(with: ["good": "G"]), "{{bad name}} G {{open")
    }

    func testExtraBracesAroundAPlaceholder() {
        let t = SnippetTemplate("{{{x}}}")
        XCTAssertEqual(t.placeholders.map(\.name), ["x"])
        XCTAssertEqual(t.filled(with: ["x": "1"]), "{1}")
    }

    func testDuplicatesListedOnceInFirstAppearanceOrder() {
        let t = SnippetTemplate("{{b}} {{a}} {{b:2}} {{c}} {{a}}")
        XCTAssertEqual(t.placeholders.map(\.name), ["b", "a", "c"])
        XCTAssertEqual(t.placeholders[0].defaultValue, "2", "the first default given")
        XCTAssertEqual(t.filled(with: ["b": "B", "a": "A"]), "B A B  A")
        XCTAssertEqual(t.filled(with: [:]), "2  2  ", "every occurrence uses the placeholder's default")
    }

    func testNamesAreCaseSensitive() {
        XCTAssertEqual(SnippetTemplate("{{a}}{{A}}").placeholders.map(\.name), ["a", "A"])
    }

    func testDefaultMayContainColonsAndSpaces() {
        let t = SnippetTemplate("{{url:http://x:8080/a b}}")
        XCTAssertEqual(t.placeholders, [P(name: "url", defaultValue: "http://x:8080/a b")])
        XCTAssertEqual(t.filled(with: [:]), "http://x:8080/a b")
    }

    func testEmptyDefault() {
        let t = SnippetTemplate("{{x:}}")
        XCTAssertEqual(t.placeholders, [P(name: "x", defaultValue: "")])
        XCTAssertEqual(t.filled(with: [:]), "")
    }

    func testMultilineScript() {
        let t = SnippetTemplate("cd {{dir}}\nls\necho {{dir}}")
        XCTAssertEqual(t.filled(with: ["dir": "/tmp"]), "cd /tmp\nls\necho /tmp")
    }

    func testUnicodeLiteralsArePreserved() {
        let t = SnippetTemplate("echo \u{1F600} {{x:é}} — done")
        XCTAssertEqual(t.filled(with: [:]), "echo \u{1F600} é — done")
    }
}
