import XCTest
@testable import CoreModels

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

final class HostQueriesTests: XCTestCase {
    func testPortFallsBackThroughGroupChainThenTo22() {
        let grand = HostGroup(name: "grand", defaultPort: 2222)
        let parent = HostGroup(name: "parent", parentID: grand.id)
        let child = HostGroup(name: "child", parentID: parent.id)
        let inherited = Host(label: "a", address: "a", groupID: child.id)
        let explicit = Host(label: "b", address: "b", port: 2200, groupID: child.id)
        let dir = HostDirectory(hosts: [inherited, explicit], groups: [grand, parent, child])
        XCTAssertEqual(dir.effectivePort(for: inherited), 2222)
        XCTAssertEqual(dir.effectivePort(for: explicit), 2200)

        let plainGroup = HostGroup(name: "plain")
        let plain = Host(label: "c", address: "c", groupID: plainGroup.id)
        XCTAssertEqual(HostDirectory(hosts: [plain], groups: [plainGroup]).effectivePort(for: plain), 22)
    }

    func testIdentityAndThemeInheritOneSettingAtATime() {
        let identity = UUID()
        let group = HostGroup(name: "g", defaultIdentityID: identity)
        let host = Host(label: "h", address: "h", groupID: group.id, themeID: "solarized")
        let dir = HostDirectory(hosts: [host], groups: [group])
        XCTAssertEqual(dir.effectiveIdentityID(for: host), identity)
        XCTAssertEqual(dir.effectiveThemeID(for: host), "solarized")

        let themed = HostGroup(name: "t", defaultThemeID: "nord")
        let bare = Host(label: "b", address: "b", groupID: themed.id)
        let dir2 = HostDirectory(hosts: [bare], groups: [themed])
        XCTAssertNil(dir2.effectiveIdentityID(for: bare))
        XCTAssertEqual(dir2.effectiveThemeID(for: bare), "nord")
    }

    func testGroupCycleDoesNotHang() {
        var a = HostGroup(name: "A")
        var b = HostGroup(name: "B")
        a.parentID = b.id
        b.parentID = a.id
        let host = Host(label: "h", address: "h", groupID: a.id)
        let dir = HostDirectory(hosts: [host], groups: [a, b])
        XCTAssertEqual(dir.effectivePort(for: host), 22)
        XCTAssertEqual(dir.hosts(inGroup: a.id).count, 1)
    }

    func testHostsInGroupIncludesSubgroups() {
        let parent = HostGroup(name: "parent")
        let child = HostGroup(name: "child", parentID: parent.id)
        let other = HostGroup(name: "other")
        let inChild = Host(label: "c", address: "c", groupID: child.id)
        let inOther = Host(label: "o", address: "o", groupID: other.id)
        let ungrouped = Host(label: "u", address: "u")
        let dir = HostDirectory(hosts: [inChild, inOther, ungrouped], groups: [parent, child, other])
        XCTAssertEqual(dir.hosts(inGroup: parent.id).map(\.id), [inChild.id])
        XCTAssertEqual(dir.hosts(inGroup: nil).count, 3)
    }

    func testTagFilterRequiresAllTags() {
        let both = Host(label: "both", address: "1", tags: ["prod", "docker"])
        let one = Host(label: "one", address: "2", tags: ["prod"])
        let dir = HostDirectory(hosts: [both, one], groups: [])
        XCTAssertEqual(dir.filter(tags: ["prod", "docker"], search: "").map(\.id), [both.id])
        XCTAssertEqual(dir.filter(tags: [], search: "").count, 2)
    }

    func testSearchMatchesLabelAddressUsernameAndTag() {
        let pihole = Host(label: "PiHole", address: "10.0.0.2")
        let lan = Host(label: "nas", address: "192.168.99.7")
        let admin = Host(label: "box", address: "10.0.0.3", username: "root")
        let tagged = Host(label: "svc", address: "10.0.0.4", tags: ["Docker"])
        let dir = HostDirectory(hosts: [pihole, lan, admin, tagged], groups: [])
        XCTAssertEqual(dir.filter(tags: [], search: "pihole").map(\.id), [pihole.id])
        XCTAssertEqual(dir.filter(tags: [], search: "192.168.99").map(\.id), [lan.id])
        XCTAssertEqual(dir.filter(tags: [], search: "ROOT").map(\.id), [admin.id])
        XCTAssertEqual(dir.filter(tags: [], search: "docker").map(\.id), [tagged.id])
    }

    func testSearchMatchesTheBackupAddress() {
        let nas = Host(label: "NAS", address: "192.168.50.10", fallbackAddress: "nas.tail1234.ts.net")
        let other = Host(label: "Pi", address: "10.0.0.2")
        let dir = HostDirectory(hosts: [nas, other], groups: [])
        XCTAssertEqual(dir.filter(tags: [], search: "TAIL1234").map(\.id), [nas.id])
    }

    func testDeletedRecordsAreIgnored() {
        let deadGroup = HostGroup(name: "dead", defaultPort: 2222, deleted: true)
        let live = Host(label: "live", address: "l", groupID: deadGroup.id)
        let dead = Host(label: "dead", address: "d", deleted: true)
        let dir = HostDirectory(hosts: [live, dead], groups: [deadGroup])
        XCTAssertEqual(dir.effectivePort(for: live), 22)
        XCTAssertEqual(dir.filter(tags: [], search: "").map(\.id), [live.id])
    }

    // MARK: Theme chain

    func testThemeIDChainListsHostThenGroupsNearestFirst() {
        let grand = HostGroup(name: "grand", defaultThemeID: "dracula")
        let parent = HostGroup(name: "parent", parentID: grand.id, defaultThemeID: "nord")
        let host = Host(label: "h", address: "h", groupID: parent.id, themeID: "aura")
        let dir = HostDirectory(hosts: [host], groups: [grand, parent])
        XCTAssertEqual(dir.themeIDChain(for: host), ["aura", "nord", "dracula"])
    }

    func testThemeIDChainSkipsNilLevels() {
        let grand = HostGroup(name: "grand", defaultThemeID: "dracula")
        let parent = HostGroup(name: "parent", parentID: grand.id)
        let child = HostGroup(name: "child", parentID: parent.id, defaultThemeID: "nord")
        let host = Host(label: "h", address: "h", groupID: child.id)
        let dir = HostDirectory(hosts: [host], groups: [grand, parent, child])
        XCTAssertEqual(dir.themeIDChain(for: host), ["nord", "dracula"])
    }

    func testThemeIDChainSkipsDeletedGroups() {
        let grand = HostGroup(name: "grand", defaultThemeID: "dracula")
        let dead = HostGroup(name: "dead", parentID: grand.id, defaultThemeID: "nord", deleted: true)
        let host = Host(label: "h", address: "h", groupID: dead.id, themeID: "aura")
        let dir = HostDirectory(hosts: [host], groups: [grand, dead])
        // A deleted group ends the walk (its parent link is gone with it), like the other settings.
        XCTAssertEqual(dir.themeIDChain(for: host), ["aura"])
    }

    func testThemeIDChainStopsOnCycle() {
        var a = HostGroup(name: "A", defaultThemeID: "nord")
        var b = HostGroup(name: "B", defaultThemeID: "dracula")
        a.parentID = b.id
        b.parentID = a.id
        let host = Host(label: "h", address: "h", groupID: a.id)
        let dir = HostDirectory(hosts: [host], groups: [a, b])
        XCTAssertEqual(dir.themeIDChain(for: host), ["nord", "dracula"])
    }

    func testThemeIDChainForHostWithoutGroupIsOwnIDOnly() {
        let themed = Host(label: "t", address: "t", themeID: "nord")
        let bare = Host(label: "b", address: "b")
        let dir = HostDirectory(hosts: [themed, bare], groups: [HostGroup(name: "x", defaultThemeID: "aura")])
        XCTAssertEqual(dir.themeIDChain(for: themed), ["nord"])
        XCTAssertEqual(dir.themeIDChain(for: bare), [])
    }

    func testEffectiveThemeIDIsFirstOfChain() {
        let grand = HostGroup(name: "grand", defaultThemeID: "dracula")
        let parent = HostGroup(name: "parent", parentID: grand.id)
        let own = Host(label: "o", address: "o", groupID: parent.id, themeID: "aura")
        let inherited = Host(label: "i", address: "i", groupID: parent.id)
        let none = Host(label: "n", address: "n")
        let dir = HostDirectory(hosts: [own, inherited, none], groups: [grand, parent])
        for host in [own, inherited, none] {
            XCTAssertEqual(dir.effectiveThemeID(for: host), dir.themeIDChain(for: host).first)
        }
        XCTAssertEqual(dir.effectiveThemeID(for: inherited), "dracula")
        XCTAssertNil(dir.effectiveThemeID(for: none))
    }
}
