import XCTest
@testable import AppCore

final class OnePasswordPathsTests: XCTestCase {
    private let home = "/Users/cory"
    private let groupSocket = "/Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    private let linkSocket = "/Users/cory/.1password/agent.sock"

    func testCandidates() {
        XCTAssertEqual(OnePasswordPaths.agentSocketCandidates, [
            "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock",
            "~/.1password/agent.sock",
        ])
        XCTAssertEqual(OnePasswordPaths.cliCandidates, ["/opt/homebrew/bin/op", "/usr/local/bin/op"])
    }

    func testAgentSocketPrefersTheGroupContainer() {
        XCTAssertEqual(OnePasswordPaths.agentSocket(home: home, override: nil, fileExists: { _ in true }), groupSocket)
        XCTAssertEqual(OnePasswordPaths.agentSocket(home: home, override: nil, fileExists: { $0 == self.linkSocket }), linkSocket)
        XCTAssertNil(OnePasswordPaths.agentSocket(home: home, override: nil, fileExists: { _ in false }))
        // A home with a trailing slash expands the same way.
        XCTAssertEqual(OnePasswordPaths.agentSocket(home: home + "/", override: nil, fileExists: { _ in true }), groupSocket)
    }

    func testAgentSocketOverride() {
        var asked: [String] = []
        XCTAssertEqual(OnePasswordPaths.agentSocket(home: home, override: "~/custom/agent.sock",
                                                    fileExists: { asked.append($0); return true }),
                       "/Users/cory/custom/agent.sock")
        XCTAssertEqual(asked, ["/Users/cory/custom/agent.sock"], "only the override is looked at")
        XCTAssertEqual(OnePasswordPaths.agentSocket(home: home, override: " /tmp/a.sock ", fileExists: { _ in true }), "/tmp/a.sock")
        // A missing override is not replaced by a default location.
        XCTAssertNil(OnePasswordPaths.agentSocket(home: home, override: "/tmp/missing.sock", fileExists: { $0 != "/tmp/missing.sock" }))
        // A blank override counts as none.
        XCTAssertEqual(OnePasswordPaths.agentSocket(home: home, override: "  ", fileExists: { _ in true }), groupSocket)
    }

    func testAgentSocketStatus() {
        func status(_ probes: [String: OnePasswordPaths.Probe], override: String? = nil) -> AgentSocketStatus {
            OnePasswordPaths.agentSocketStatus(home: home, override: override, probe: { probes[$0] ?? .missing })
        }
        XCTAssertEqual(status([:]), .notFound)
        XCTAssertEqual(status([groupSocket: .exists, linkSocket: .exists]), .available(groupSocket))
        XCTAssertEqual(status([groupSocket: .denied]), .blocked(groupSocket))
        // A usable candidate wins over a blocked one.
        XCTAssertEqual(status([groupSocket: .denied, linkSocket: .exists]), .available(linkSocket))
        XCTAssertEqual(status([linkSocket: .denied]), .blocked(linkSocket))
        // Override: only that path.
        XCTAssertEqual(status([groupSocket: .exists], override: "/tmp/a.sock"), .notFound)
        XCTAssertEqual(status(["/tmp/a.sock": .exists], override: "/tmp/a.sock"), .available("/tmp/a.sock"))
        XCTAssertEqual(status(["/Users/cory/x.sock": .denied], override: "~/x.sock"), .blocked("/Users/cory/x.sock"))

        // agentSocket with a probe returns the path when available or blocked.
        XCTAssertEqual(OnePasswordPaths.agentSocket(home: home, override: nil, probe: { $0 == self.groupSocket ? .denied : .missing }),
                       groupSocket)
        XCTAssertEqual(OnePasswordPaths.agentSocket(home: home, override: nil, probe: { $0 == self.linkSocket ? .exists : .missing }),
                       linkSocket)
        XCTAssertNil(OnePasswordPaths.agentSocket(home: home, override: nil, probe: { _ in .missing }))
    }

    func testFileProbe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-probe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent.sock")
        XCTAssertEqual(OnePasswordPaths.probe(file.path), .missing)
        try Data().write(to: file)
        XCTAssertEqual(OnePasswordPaths.probe(file.path), .exists)
        XCTAssertEqual(OnePasswordPaths.Probe(statErrno: EPERM), .denied)
        XCTAssertEqual(OnePasswordPaths.Probe(statErrno: EACCES), .denied)
        XCTAssertEqual(OnePasswordPaths.Probe(statErrno: ENOENT), .missing)
        XCTAssertEqual(OnePasswordPaths.Probe(statErrno: ENOTDIR), .missing)
    }

    func testCLI() {
        XCTAssertEqual(OnePasswordPaths.cli(override: nil, isExecutable: { _ in true }), "/opt/homebrew/bin/op")
        XCTAssertEqual(OnePasswordPaths.cli(override: nil, isExecutable: { $0 == "/usr/local/bin/op" }), "/usr/local/bin/op")
        XCTAssertNil(OnePasswordPaths.cli(override: nil, isExecutable: { _ in false }))
        XCTAssertEqual(OnePasswordPaths.cli(override: "/Users/cory/bin/op", isExecutable: { _ in true }), "/Users/cory/bin/op")
        XCTAssertNil(OnePasswordPaths.cli(override: "/Users/cory/bin/op", isExecutable: { $0 != "/Users/cory/bin/op" }))
        XCTAssertEqual(OnePasswordPaths.cli(override: "", isExecutable: { _ in true }), "/opt/homebrew/bin/op")
    }
}

@MainActor
final class OnePasswordSettingsTests: XCTestCase {
    private let suite = "OnePasswordSettingsTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsToNoOverrides() async {
        let settings = OnePasswordSettings(defaults: defaults)
        XCTAssertNil(settings.agentSocketOverride)
        XCTAssertNil(settings.cliPathOverride)
    }

    func testOverridesPersist() async {
        let settings = OnePasswordSettings(defaults: defaults)
        settings.agentSocketOverride = "~/.1password/agent.sock"
        settings.cliPathOverride = "/opt/op"
        XCTAssertEqual(defaults.string(forKey: "onepassword.agentSocketOverride"), "~/.1password/agent.sock")
        XCTAssertEqual(defaults.string(forKey: "onepassword.cliPathOverride"), "/opt/op")
        let reloaded = OnePasswordSettings(defaults: defaults)
        XCTAssertEqual(reloaded.agentSocketOverride, "~/.1password/agent.sock")
        XCTAssertEqual(reloaded.cliPathOverride, "/opt/op")
    }

    func testClearingRemovesTheStoredValue() async {
        let settings = OnePasswordSettings(defaults: defaults)
        settings.agentSocketOverride = "/x"
        settings.cliPathOverride = "/y"
        settings.agentSocketOverride = nil
        settings.cliPathOverride = "   "
        XCTAssertNil(defaults.object(forKey: "onepassword.agentSocketOverride"))
        XCTAssertNil(defaults.object(forKey: "onepassword.cliPathOverride"))
        let reloaded = OnePasswordSettings(defaults: defaults)
        XCTAssertNil(reloaded.agentSocketOverride)
        XCTAssertNil(reloaded.cliPathOverride)
    }

    func testBlankStoredValueReadsAsNone() async {
        defaults.set("  ", forKey: "onepassword.agentSocketOverride")
        XCTAssertNil(OnePasswordSettings(defaults: defaults).agentSocketOverride)
    }
}
