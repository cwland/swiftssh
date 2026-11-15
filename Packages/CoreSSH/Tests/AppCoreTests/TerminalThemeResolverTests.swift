import XCTest
import CoreModels
@testable import AppCore

final class TerminalThemeResolverTests: XCTestCase {
    private func resolve(_ hostID: UUID?, hosts: [SavedHost], groups: [HostGroup] = [],
                         defaultThemeID: String? = nil, prefersDark: Bool = false) -> String {
        TerminalThemeResolver.theme(forHostID: hostID, hosts: hosts, groups: groups,
                                    defaultThemeID: defaultThemeID, prefersDark: prefersDark).id
    }

    func testHostOwnThemeWins() {
        let group = HostGroup(name: "g", defaultThemeID: "nord")
        let host = SavedHost(label: "h", address: "h", groupID: group.id, themeID: "dracula")
        XCTAssertEqual(resolve(host.id, hosts: [host], groups: [group], defaultThemeID: "aura"), "dracula")
    }

    func testInheritsNearestGroupTheme() {
        let parent = HostGroup(name: "p", defaultThemeID: "aura")
        let child = HostGroup(name: "c", parentID: parent.id, defaultThemeID: "nord")
        let host = SavedHost(label: "h", address: "h", groupID: child.id)
        XCTAssertEqual(resolve(host.id, hosts: [host], groups: [parent, child], defaultThemeID: "dracula"), "nord")
    }

    func testInheritsGrandparentWhenParentHasNone() {
        let grand = HostGroup(name: "g", defaultThemeID: "aura")
        let parent = HostGroup(name: "p", parentID: grand.id)
        let host = SavedHost(label: "h", address: "h", groupID: parent.id)
        XCTAssertEqual(resolve(host.id, hosts: [host], groups: [grand, parent], defaultThemeID: "dracula"), "aura")
    }

    func testUnknownHostThemeFallsToGroup() {
        let group = HostGroup(name: "g", defaultThemeID: "nord")
        let host = SavedHost(label: "h", address: "h", groupID: group.id, themeID: "from-a-newer-build")
        XCTAssertEqual(resolve(host.id, hosts: [host], groups: [group], defaultThemeID: "dracula"), "nord")
    }

    func testUnknownEverywhereFallsToAppDefault() {
        let group = HostGroup(name: "g", defaultThemeID: "gone")
        let host = SavedHost(label: "h", address: "h", groupID: group.id, themeID: "also-gone")
        XCTAssertEqual(resolve(host.id, hosts: [host], groups: [group], defaultThemeID: "dracula"), "dracula")
    }

    func testUnknownAppDefaultFallsToAutomatic() {
        let host = SavedHost(label: "h", address: "h", themeID: "gone")
        XCTAssertEqual(resolve(host.id, hosts: [host], defaultThemeID: "missing", prefersDark: true), "reimagined-dark")
        XCTAssertEqual(resolve(host.id, hosts: [host], defaultThemeID: nil, prefersDark: false), "reimagined-light")
    }

    func testAutomaticFollowsPrefersDark() {
        let host = SavedHost(label: "h", address: "h")
        XCTAssertEqual(resolve(host.id, hosts: [host], prefersDark: false), TerminalThemeCatalog.lightDefaultID)
        XCTAssertEqual(resolve(host.id, hosts: [host], prefersDark: true), TerminalThemeCatalog.darkDefaultID)
        // A chosen default doesn't follow the system appearance.
        XCTAssertEqual(resolve(host.id, hosts: [host], defaultThemeID: "solarized-light", prefersDark: true),
                       "solarized-light")
    }

    func testNilHostIDUsesAppDefault() {
        let host = SavedHost(label: "h", address: "h", themeID: "nord")
        XCTAssertEqual(resolve(nil, hosts: [host], defaultThemeID: "dracula"), "dracula")
        XCTAssertEqual(resolve(nil, hosts: [host], prefersDark: true), "reimagined-dark")
    }

    func testDeletedHostUsesAppDefault() {
        let host = SavedHost(label: "h", address: "h", themeID: "nord", deleted: true)
        XCTAssertEqual(resolve(host.id, hosts: [host], defaultThemeID: "dracula"), "dracula")
        XCTAssertEqual(resolve(UUID(), hosts: [host], defaultThemeID: "dracula"), "dracula")
    }

    func testInheritedThemeIDIgnoresHostsOwn() {
        let parent = HostGroup(name: "p", defaultThemeID: "aura")
        let child = HostGroup(name: "c", parentID: parent.id, defaultThemeID: "unknown-id")
        let host = SavedHost(label: "h", address: "h", groupID: child.id, themeID: "dracula")
        XCTAssertEqual(TerminalThemeResolver.inheritedThemeID(forHostID: host.id, hosts: [host],
                                                              groups: [parent, child]), "aura")
    }

    func testInheritedThemeIDForGroupIgnoresGroupsOwn() {
        let grand = HostGroup(name: "g", defaultThemeID: "nord")
        let parent = HostGroup(name: "p", parentID: grand.id)
        let child = HostGroup(name: "c", parentID: parent.id, defaultThemeID: "dracula")
        XCTAssertEqual(TerminalThemeResolver.inheritedThemeID(forGroupID: child.id, groups: [grand, parent, child]),
                       "nord")
        // A cycle back to the group itself doesn't count its own theme.
        var a = HostGroup(name: "A", defaultThemeID: "dracula")
        var b = HostGroup(name: "B")
        a.parentID = b.id
        b.parentID = a.id
        XCTAssertNil(TerminalThemeResolver.inheritedThemeID(forGroupID: a.id, groups: [a, b]))
    }

    func testInheritedThemeIDNilWhenNothingKnown() {
        let group = HostGroup(name: "g", defaultThemeID: "unknown-id")
        let host = SavedHost(label: "h", address: "h", groupID: group.id, themeID: "dracula")
        let loose = SavedHost(label: "l", address: "l", themeID: "nord")
        let deadGroup = HostGroup(name: "dead", defaultThemeID: "nord", deleted: true)
        let inDead = HostGroup(name: "in-dead", parentID: deadGroup.id)
        let groups = [group, deadGroup, inDead]
        XCTAssertNil(TerminalThemeResolver.inheritedThemeID(forHostID: host.id, hosts: [host, loose], groups: groups))
        XCTAssertNil(TerminalThemeResolver.inheritedThemeID(forHostID: loose.id, hosts: [host, loose], groups: groups))
        XCTAssertNil(TerminalThemeResolver.inheritedThemeID(forHostID: UUID(), hosts: [host, loose], groups: groups))
        XCTAssertNil(TerminalThemeResolver.inheritedThemeID(forGroupID: group.id, groups: groups))
        XCTAssertNil(TerminalThemeResolver.inheritedThemeID(forGroupID: inDead.id, groups: groups))
        XCTAssertNil(TerminalThemeResolver.inheritedThemeID(forGroupID: UUID(), groups: groups))
    }

    func testTerminalAppearanceHoldsThemeAndSize() {
        let theme = TerminalThemeCatalog.shared.automatic(prefersDark: true)
        let appearance = TerminalAppearance(theme: theme, fontSize: 14)
        XCTAssertEqual(appearance, TerminalAppearance(theme: theme, fontSize: 14))
        XCTAssertNotEqual(appearance, TerminalAppearance(theme: theme, fontSize: 15))
    }
}
