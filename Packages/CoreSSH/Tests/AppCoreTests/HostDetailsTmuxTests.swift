import XCTest
import CoreModels
@testable import AppCore

@MainActor
final class HostDetailsTmuxTests: XCTestCase {
    private var vault: LocalVault!

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev-1" })
    }

    private func stored(_ id: UUID) -> SavedHost? { vault.get(SavedHost.self, id: id) }

    private func host(groupID: UUID? = nil, tmux: TmuxChoice? = nil) -> SavedHost {
        vault.saveNow(SavedHost(label: "h", address: "h.example", groupID: groupID, username: "root",
                                password: "pw", tmuxSession: tmux))
    }

    func testDefaultsToInheritWithSummary() async {
        let vm = HostDetailsViewModel(vault: vault, hostID: host().id)
        XCTAssertEqual(vm.tmuxMode, .inherit)
        XCTAssertEqual(vm.tmuxNameText, "")
        XCTAssertNil(vm.tmuxNameError)
        XCTAssertNil(vm.effectiveTmuxSession)
        XCTAssertEqual(vm.inheritedTmuxSummary, "Default (off)")
        XCTAssertEqual(vm.tmuxSummary, "Default (off)")
    }

    func testInheritedSummaryNamesTheGroupsChoice() async {
        let on = vault.saveNow(HostGroup(name: "Prod", defaultTmuxSession: .session("ops")))
        let vm = HostDetailsViewModel(vault: vault, hostID: host(groupID: on.id).id)
        XCTAssertEqual(vm.inheritedTmuxSummary, "Default (group: on, ops)")
        XCTAssertEqual(vm.effectiveTmuxSession, "ops")

        let off = vault.saveNow(HostGroup(name: "Lab", defaultTmuxSession: .off))
        let vm2 = HostDetailsViewModel(vault: vault, hostID: host(groupID: off.id).id)
        XCTAssertEqual(vm2.inheritedTmuxSummary, "Default (group: off)")
        XCTAssertNil(vm2.effectiveTmuxSession)
    }

    func testSwitchingOnStoresMainAndKeepsUsernameAndCredentials() async {
        let h = host()
        let vm = HostDetailsViewModel(vault: vault, hostID: h.id)
        vm.tmuxMode = .on
        XCTAssertEqual(stored(h.id)?.tmuxSession, .session("main"))
        XCTAssertEqual(vm.tmuxMode, .on)
        XCTAssertEqual(vm.tmuxNameText, "main")
        XCTAssertEqual(vm.tmuxSummary, "On (main)")
        XCTAssertEqual(vm.effectiveTmuxSession, "main")
        XCTAssertEqual(stored(h.id)?.username, "root", "never clears the username")
        XCTAssertEqual(stored(h.id)?.password, "pw")
    }

    func testSwitchingOnUsesTheInheritedNameWhenThereIsOne() async {
        let group = vault.saveNow(HostGroup(name: "Prod", defaultTmuxSession: .session("ops")))
        let h = host(groupID: group.id)
        let vm = HostDetailsViewModel(vault: vault, hostID: h.id)
        vm.tmuxMode = .on
        XCTAssertEqual(stored(h.id)?.tmuxSession, .session("ops"))
    }

    func testOffAndInheritAreStored() async {
        let group = vault.saveNow(HostGroup(name: "Prod", defaultTmuxSession: .session("ops")))
        let h = host(groupID: group.id)
        let vm = HostDetailsViewModel(vault: vault, hostID: h.id)
        vm.tmuxMode = .off
        XCTAssertEqual(stored(h.id)?.tmuxSession, .off)
        XCTAssertEqual(vm.tmuxMode, .off)
        XCTAssertEqual(vm.tmuxSummary, "Off")
        XCTAssertNil(vm.effectiveTmuxSession, "the host turns off what the group turns on")
        vm.tmuxMode = .inherit
        XCTAssertNil(stored(h.id)?.tmuxSession)
        XCTAssertEqual(vm.effectiveTmuxSession, "ops")
        XCTAssertEqual(vm.tmuxSummary, "Default (group: on, ops)")
    }

    func testStoredInheritCaseReadsAsInherit() async {
        let vm = HostDetailsViewModel(vault: vault, hostID: host(tmux: .inherit).id)
        XCTAssertEqual(vm.tmuxMode, .inherit)
    }

    func testSettersAreIdempotent() async {
        let h = host(tmux: .session("main"))
        let vm = HostDetailsViewModel(vault: vault, hostID: h.id)
        let before = stored(h.id)!.updatedAt
        vm.tmuxMode = .on
        vm.tmuxNameText = "main"
        XCTAssertEqual(stored(h.id)?.updatedAt, before, "writing what is stored saves nothing")
        XCTAssertEqual(stored(h.id)?.tmuxSession, .session("main"), "switching on again keeps the name")

        let off = host(tmux: .off)
        let vm2 = HostDetailsViewModel(vault: vault, hostID: off.id)
        let offBefore = stored(off.id)!.updatedAt
        vm2.tmuxMode = .off
        XCTAssertEqual(stored(off.id)?.updatedAt, offBefore)
    }

    func testValidNameIsSavedTrimmed() async {
        let h = host(tmux: .session("main"))
        let vm = HostDetailsViewModel(vault: vault, hostID: h.id)
        vm.tmuxNameText = "work-2"
        XCTAssertEqual(stored(h.id)?.tmuxSession, .session("work-2"))
        vm.tmuxNameText = "  dev_box-1 "
        XCTAssertEqual(stored(h.id)?.tmuxSession, .session("dev_box-1"))
        XCTAssertNil(vm.tmuxNameError)
    }

    func testInvalidNameIsShownWithErrorAndNotSaved() async {
        let h = host(tmux: .session("main"))
        let vm = HostDetailsViewModel(vault: vault, hostID: h.id)
        for bad in ["", "a b", "it's", "x;rm", "$(id)", String(repeating: "a", count: 65)] {
            vm.tmuxNameText = bad
            XCTAssertEqual(stored(h.id)?.tmuxSession, .session("main"), bad)
            XCTAssertEqual(vm.tmuxNameText, bad, "the field shows what was typed")
            XCTAssertNotNil(vm.tmuxNameError, bad)
        }
        vm.tmuxNameText = "ok"
        XCTAssertNil(vm.tmuxNameError)
        XCTAssertEqual(stored(h.id)?.tmuxSession, .session("ok"))
    }

    func testNameTypedWhileNotOnIsNotSaved() async {
        let h = host(tmux: .off)
        let vm = HostDetailsViewModel(vault: vault, hostID: h.id)
        vm.tmuxNameText = "later"
        XCTAssertEqual(stored(h.id)?.tmuxSession, .off)
    }

    func testTurningOffThenOnAgainKeepsTheLastName() async {
        let h = host(tmux: .session("main"))
        let vm = HostDetailsViewModel(vault: vault, hostID: h.id)
        vm.tmuxNameText = "build"
        vm.tmuxMode = .off
        vm.tmuxMode = .on
        XCTAssertEqual(stored(h.id)?.tmuxSession, .session("build"))
    }

    func testLeavingOnDropsAnInvalidTypedName() async {
        let h = host(tmux: .session("main"))
        let vm = HostDetailsViewModel(vault: vault, hostID: h.id)
        vm.tmuxNameText = "bad name"
        vm.tmuxMode = .off
        XCTAssertNil(vm.tmuxNameError)
        vm.tmuxMode = .on
        XCTAssertEqual(stored(h.id)?.tmuxSession, .session("main"))
        XCTAssertEqual(vm.tmuxNameText, "main")
    }

    func testDeletedHostIgnoresSets() async throws {
        let h = host()
        let vm = HostDetailsViewModel(vault: vault, hostID: h.id)
        try await vault.delete(SavedHost.self, id: h.id)
        vm.tmuxMode = .on
        vm.tmuxNameText = "x"
        XCTAssertNil(stored(h.id))
        XCTAssertEqual(vm.tmuxMode, .inherit)
    }
}
