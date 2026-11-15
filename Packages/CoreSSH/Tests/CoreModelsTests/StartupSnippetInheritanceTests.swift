import XCTest
@testable import CoreModels

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

/// Group startup snippets: the field on `HostGroup`, the host's "None" choice, and how
/// `HostDirectory` resolves the snippet a host runs (host, then nearest group, like tmux).
final class StartupSnippetInheritanceTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000.123)
    private let everyID: (UUID) -> Bool = { _ in true }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: CoreJSON.encoder.encode(value)) as? [String: Any])
    }

    // MARK: Records

    func testFieldsDefaultToNilAndRoundTrip() throws {
        XCTAssertNil(HostGroup(name: "g").startupSnippetID)
        XCTAssertNil(Host(label: "h", address: "a").startupSnippetOff)
        let group = HostGroup(name: "G", startupSnippetID: UUID(), updatedAt: date)
        XCTAssertEqual(try CoreJSON.decoder.decode(HostGroup.self, from: CoreJSON.encoder.encode(group)), group)
        let host = Host(label: "H", address: "a", startupSnippetOff: true, updatedAt: date)
        XCTAssertEqual(try CoreJSON.decoder.decode(Host.self, from: CoreJSON.encoder.encode(host)), host)
    }

    func testOlderRecordsWithoutTheFieldsDecodeAsNil() throws {
        var groupObject = try json(HostGroup(name: "Old", startupSnippetID: UUID(), updatedAt: date))
        XCTAssertNotNil(groupObject["startupSnippetID"], "a top-level field")
        groupObject.removeValue(forKey: "startupSnippetID")
        let group = try CoreJSON.decoder.decode(HostGroup.self, from: JSONSerialization.data(withJSONObject: groupObject))
        XCTAssertNil(group.startupSnippetID)
        XCTAssertEqual(group.name, "Old")

        var hostObject = try json(Host(label: "Old", address: "a", startupSnippetOff: true, updatedAt: date))
        XCTAssertNotNil(hostObject["startupSnippetOff"])
        hostObject.removeValue(forKey: "startupSnippetOff")
        let host = try CoreJSON.decoder.decode(Host.self, from: JSONSerialization.data(withJSONObject: hostObject))
        XCTAssertNil(host.startupSnippetOff)
    }

    // MARK: Resolution

    func testHostWithoutItsOwnUsesTheNearestGroups() {
        let top = UUID(), mid = UUID()
        let grand = HostGroup(name: "Grand", startupSnippetID: top)
        let parent = HostGroup(name: "Parent", parentID: grand.id)
        let child = HostGroup(name: "Child", parentID: parent.id)
        let host = Host(label: "h", address: "h", groupID: child.id)
        var dir = HostDirectory(hosts: [host], groups: [grand, parent, child])
        XCTAssertEqual(dir.effectiveStartupSnippetID(for: host, isAvailable: everyID), top)
        XCTAssertEqual(dir.inheritedStartupSnippet(for: host, isAvailable: everyID),
                       InheritedStartupSnippet(snippetID: top, groupName: "Grand"))

        var nearer = parent
        nearer.startupSnippetID = mid
        dir = HostDirectory(hosts: [host], groups: [grand, nearer, child])
        XCTAssertEqual(dir.effectiveStartupSnippetID(for: host, isAvailable: everyID), mid, "nearest group wins")
        XCTAssertEqual(dir.inheritedStartupSnippet(for: host, isAvailable: everyID)?.groupName, "Parent")
    }

    func testHostsOwnSnippetWins() {
        let own = UUID()
        let group = HostGroup(name: "G", startupSnippetID: UUID())
        let host = Host(label: "h", address: "h", groupID: group.id, startupSnippetID: own)
        let dir = HostDirectory(hosts: [host], groups: [group])
        XCTAssertEqual(dir.effectiveStartupSnippetID(for: host, isAvailable: everyID), own)
    }

    func testNoneOnTheHostSkipsTheGroups() {
        let group = HostGroup(name: "G", startupSnippetID: UUID())
        let host = Host(label: "h", address: "h", groupID: group.id, startupSnippetOff: true)
        let dir = HostDirectory(hosts: [host], groups: [group])
        XCTAssertNil(dir.effectiveStartupSnippetID(for: host, isAvailable: everyID))
        XCTAssertNotNil(dir.inheritedStartupSnippet(for: host, isAvailable: everyID),
                        "what Default would be is still known")
        let own = UUID()
        let both = Host(label: "b", address: "b", groupID: group.id, startupSnippetID: own, startupSnippetOff: true)
        XCTAssertEqual(dir.effectiveStartupSnippetID(for: both, isAvailable: everyID), own,
                       "a chosen snippet wins over the None flag")
    }

    func testMissingSnippetsCountAsUnsetAtEveryLevel() {
        let gone = UUID(), kept = UUID()
        let parent = HostGroup(name: "Parent", startupSnippetID: kept)
        let child = HostGroup(name: "Child", parentID: parent.id, startupSnippetID: gone)
        let host = Host(label: "h", address: "h", groupID: child.id, startupSnippetID: gone)
        let dir = HostDirectory(hosts: [host], groups: [parent, child])
        let available: (UUID) -> Bool = { $0 == kept }
        XCTAssertEqual(dir.effectiveStartupSnippetID(for: host, isAvailable: available), kept)
        XCTAssertEqual(dir.inheritedStartupSnippet(for: host, isAvailable: available)?.groupName, "Parent")
    }

    func testNoGroupDeletedGroupAndCycle() {
        let loose = Host(label: "l", address: "l")
        XCTAssertNil(HostDirectory(hosts: [loose], groups: []).effectiveStartupSnippetID(for: loose, isAvailable: everyID))

        let deleted = HostGroup(name: "D", startupSnippetID: UUID(), deleted: true)
        let inDeleted = Host(label: "d", address: "d", groupID: deleted.id)
        XCTAssertNil(HostDirectory(hosts: [inDeleted], groups: [deleted])
            .effectiveStartupSnippetID(for: inDeleted, isAvailable: everyID))

        var a = HostGroup(name: "A"), b = HostGroup(name: "B")
        a.parentID = b.id
        b.parentID = a.id
        let cycled = Host(label: "c", address: "c", groupID: a.id)
        XCTAssertNil(HostDirectory(hosts: [cycled], groups: [a, b])
            .effectiveStartupSnippetID(for: cycled, isAvailable: everyID))
    }

    func testFromGroupStartsAtThatGroup() {
        let snippet = UUID()
        let parent = HostGroup(name: "Parent", startupSnippetID: snippet)
        let child = HostGroup(name: "Child", parentID: parent.id)
        let dir = HostDirectory(hosts: [], groups: [parent, child])
        XCTAssertEqual(dir.inheritedStartupSnippet(fromGroup: child.id, isAvailable: everyID)?.snippetID, snippet)
        XCTAssertNil(dir.inheritedStartupSnippet(fromGroup: nil, isAvailable: everyID))
    }
}
