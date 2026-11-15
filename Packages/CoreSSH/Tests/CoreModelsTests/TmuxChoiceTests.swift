import XCTest
@testable import CoreModels

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

final class TmuxChoiceTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000.123)

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: CoreJSON.encoder.encode(value)) as? [String: Any])
    }

    // MARK: Coding

    func testChoiceRoundTrips() throws {
        for choice in [TmuxChoice.inherit, .off, .session("main"), .session("work.2_a-b")] {
            let data = try CoreJSON.encoder.encode(choice)
            XCTAssertEqual(try CoreJSON.decoder.decode(TmuxChoice.self, from: data), choice)
        }
    }

    func testChoiceEncodingIsStable() throws {
        XCTAssertEqual(String(decoding: try CoreJSON.encoder.encode(TmuxChoice.off), as: UTF8.self), #"{"kind":"off"}"#)
        XCTAssertEqual(String(decoding: try CoreJSON.encoder.encode(TmuxChoice.inherit), as: UTF8.self), #"{"kind":"inherit"}"#)
        XCTAssertEqual(String(decoding: try CoreJSON.encoder.encode(TmuxChoice.session("main")), as: UTF8.self),
                       #"{"kind":"session","name":"main"}"#)
    }

    func testUnknownOrBrokenChoiceDecodesAsInheritInsteadOfFailingTheRecord() throws {
        for text in [#"{"kind":"window","pane":3}"#, #"{"kind":"session"}"#, #"{}"#] {
            XCTAssertEqual(try CoreJSON.decoder.decode(TmuxChoice.self, from: Data(text.utf8)), .inherit, text)
        }
        // A newer build's choice inside a host record does not lose the host.
        var object = try json(Host(label: "H", address: "a", updatedAt: date))
        object["tmuxSession"] = ["kind": "somethingNew"]
        let host = try CoreJSON.decoder.decode(Host.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(host.label, "H")
        XCTAssertEqual(host.tmuxSession, .inherit)
    }

    // MARK: Records

    func testHostAndGroupDefaultToNilAndRoundTrip() throws {
        XCTAssertNil(Host(label: "x", address: "y").tmuxSession)
        XCTAssertNil(HostGroup(name: "g").defaultTmuxSession)
        let host = Host(label: "H", address: "a", tmuxSession: .session("main"), updatedAt: date)
        XCTAssertEqual(try CoreJSON.decoder.decode(Host.self, from: CoreJSON.encoder.encode(host)), host)
        let off = Host(label: "H", address: "a", tmuxSession: .off, updatedAt: date)
        XCTAssertEqual(try CoreJSON.decoder.decode(Host.self, from: CoreJSON.encoder.encode(off)), off)
        let group = HostGroup(name: "G", defaultTmuxSession: .session("ops"), updatedAt: date)
        XCTAssertEqual(try CoreJSON.decoder.decode(HostGroup.self, from: CoreJSON.encoder.encode(group)), group)
    }

    func testOlderRecordsWithoutTmuxDecodeAsNil() throws {
        var hostObject = try json(Host(label: "Old", address: "10.0.0.2", tmuxSession: .session("main"), updatedAt: date))
        XCTAssertNotNil(hostObject["tmuxSession"])
        hostObject.removeValue(forKey: "tmuxSession")
        let host = try CoreJSON.decoder.decode(Host.self, from: JSONSerialization.data(withJSONObject: hostObject))
        XCTAssertNil(host.tmuxSession)
        XCTAssertEqual(host.label, "Old")

        var groupObject = try json(HostGroup(name: "Old", defaultTmuxSession: .off, updatedAt: date))
        XCTAssertNotNil(groupObject["defaultTmuxSession"])
        groupObject.removeValue(forKey: "defaultTmuxSession")
        let group = try CoreJSON.decoder.decode(HostGroup.self, from: JSONSerialization.data(withJSONObject: groupObject))
        XCTAssertNil(group.defaultTmuxSession)
        XCTAssertEqual(group.name, "Old")
    }

    func testNilIsNotWrittenSoOlderBuildsSeeTheSameRecord() throws {
        XCTAssertNil(try json(Host(label: "H", address: "a", updatedAt: date))["tmuxSession"])
        XCTAssertNil(try json(HostGroup(name: "G", updatedAt: date))["defaultTmuxSession"])
    }

    /// A v0.6 build decodes records with the synthesized decoder of its own (older) struct, which
    /// ignores keys it doesn't know; this mirrors that struct.
    func testOlderBuildsIgnoreTheNewFields() throws {
        struct V06Host: Decodable { var id: UUID; var label: String; var address: String; var updatedAt: Date; var deleted: Bool }
        struct V06Group: Decodable { var id: UUID; var name: String; var updatedAt: Date; var deleted: Bool }
        let host = Host(label: "New", address: "a", tmuxSession: .session("main"), updatedAt: date)
        XCTAssertEqual(try CoreJSON.decoder.decode(V06Host.self, from: CoreJSON.encoder.encode(host)).label, "New")
        let group = HostGroup(name: "G", defaultTmuxSession: .off, updatedAt: date)
        XCTAssertEqual(try CoreJSON.decoder.decode(V06Group.self, from: CoreJSON.encoder.encode(group)).name, "G")
    }

    // MARK: Names

    func testSessionNameValidation() {
        for good in ["main", "a", "Work-1", "my.session_2", String(repeating: "x", count: 64)] {
            XCTAssertTrue(TmuxChoice.isValidSessionName(good), good)
        }
        for bad in ["", " main", "main ", "a b", "it's", "a;rm -rf", "$(x)", "a:b", "ü", "日本",
                    String(repeating: "x", count: 65), "a\nb", "a'b"] {
            XCTAssertFalse(TmuxChoice.isValidSessionName(bad), bad)
        }
        XCTAssertEqual(TmuxChoice.defaultSessionName, "main")
    }

    func testSessionNameAccessor() {
        XCTAssertEqual(TmuxChoice.session("x").sessionName, "x")
        XCTAssertNil(TmuxChoice.off.sessionName)
        XCTAssertNil(TmuxChoice.inherit.sessionName)
    }

    // MARK: Inheritance

    func testHostChoiceWinsThenNearestGroupThenOff() {
        let grand = HostGroup(name: "grand", defaultTmuxSession: .session("ops"))
        let parent = HostGroup(name: "parent", parentID: grand.id)
        let child = HostGroup(name: "child", parentID: parent.id, defaultTmuxSession: .inherit)
        let inherits = Host(label: "a", address: "a", groupID: child.id)
        let explicitInherit = Host(label: "b", address: "b", groupID: child.id, tmuxSession: .inherit)
        let own = Host(label: "c", address: "c", groupID: child.id, tmuxSession: .session("mine"))
        let off = Host(label: "d", address: "d", groupID: child.id, tmuxSession: .off)
        let dir = HostDirectory(hosts: [inherits, explicitInherit, own, off], groups: [grand, parent, child])
        XCTAssertEqual(dir.effectiveTmuxSession(for: inherits), "ops")
        XCTAssertEqual(dir.effectiveTmuxSession(for: explicitInherit), "ops")
        XCTAssertEqual(dir.effectiveTmuxSession(for: own), "mine")
        XCTAssertNil(dir.effectiveTmuxSession(for: off), "the host can turn it off explicitly")

        let loose = Host(label: "e", address: "e")
        XCTAssertNil(HostDirectory(hosts: [loose], groups: [grand]).effectiveTmuxSession(for: loose), "nil = off")
    }

    func testGroupOffStopsTheWalk() {
        let grand = HostGroup(name: "grand", defaultTmuxSession: .session("ops"))
        let parent = HostGroup(name: "parent", parentID: grand.id, defaultTmuxSession: .off)
        let host = Host(label: "a", address: "a", groupID: parent.id)
        let dir = HostDirectory(hosts: [host], groups: [grand, parent])
        XCTAssertNil(dir.effectiveTmuxSession(for: host))
        XCTAssertEqual(dir.inheritedTmux(for: host), InheritedTmux(choice: .off, groupName: "parent"))
    }

    func testInheritedTmuxNamesTheDecidingGroup() {
        let grand = HostGroup(name: "grand", defaultTmuxSession: .session("ops"))
        let parent = HostGroup(name: "parent", parentID: grand.id)
        let host = Host(label: "a", address: "a", groupID: parent.id, tmuxSession: .off)
        let dir = HostDirectory(hosts: [host], groups: [grand, parent])
        XCTAssertEqual(dir.inheritedTmux(for: host), InheritedTmux(choice: .session("ops"), groupName: "grand"),
                       "ignores the host's own choice")
        XCTAssertEqual(dir.inheritedTmux(fromGroup: parent.id), InheritedTmux(choice: .session("ops"), groupName: "grand"))
        XCTAssertEqual(dir.inheritedTmux(fromGroup: grand.parentID), InheritedTmux(choice: .inherit, groupName: nil))
        XCTAssertEqual(dir.inheritedTmux(fromGroup: nil), InheritedTmux(choice: .inherit, groupName: nil))
    }

    func testTmuxWalkSkipsDeletedGroupsAndStopsOnCycle() {
        let grand = HostGroup(name: "grand", defaultTmuxSession: .session("ops"))
        let dead = HostGroup(name: "dead", parentID: grand.id, defaultTmuxSession: .session("x"), deleted: true)
        let orphan = Host(label: "a", address: "a", groupID: dead.id)
        XCTAssertNil(HostDirectory(hosts: [orphan], groups: [grand, dead]).effectiveTmuxSession(for: orphan))

        var a = HostGroup(name: "A")
        var b = HostGroup(name: "B")
        a.parentID = b.id
        b.parentID = a.id
        let host = Host(label: "h", address: "h", groupID: a.id)
        XCTAssertNil(HostDirectory(hosts: [host], groups: [a, b]).effectiveTmuxSession(for: host))
        b.defaultTmuxSession = .session("loop")
        XCTAssertEqual(HostDirectory(hosts: [host], groups: [a, b]).effectiveTmuxSession(for: host), "loop")
    }
}
