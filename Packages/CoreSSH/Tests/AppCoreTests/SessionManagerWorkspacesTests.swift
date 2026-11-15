import XCTest
import Synchronization
import CoreModels
import SSHCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

/// A session that connects and becomes ready at once, records what is sent to it and its close.
private final class PaneSession: TerminalSession, Sendable {
    let plan: ConnectionPlan
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let state = Mutex<(sends: [[UInt8]], closed: Bool)>(([], false))

    init(plan: ConnectionPlan) {
        self.plan = plan
        (events, continuation) = AsyncStream.makeStream()
    }

    var sends: [[UInt8]] { state.withLock { $0.sends } }
    var sentText: String { sends.map { String(decoding: $0, as: UTF8.self) }.joined() }
    var closed: Bool { state.withLock { $0.closed } }

    func start(cols: Int, rows: Int) async {
        continuation.yield(.connected)
        continuation.yield(.ready)
    }

    func send(_ bytes: [UInt8]) async { state.withLock { $0.sends.append(bytes) } }
    func resize(cols: Int, rows: Int) async {}
    func runCommand(_ command: String) async throws -> String { "Linux\nID=ubuntu\n" }

    func output(_ text: String) { continuation.yield(.output(Array(text.utf8))) }
    /// The remote shell ended (`exit`).
    func exitShell() { continuation.yield(.closed(.remoteClosed)) }

    func drop() {
        state.withLock { $0.closed = true }
        continuation.yield(.closed(.failed(.connectionFailed("dropped"))))
        continuation.finish()
    }

    func close() async {
        let first = state.withLock { s -> Bool in
            defer { s.closed = true }
            return !s.closed
        }
        guard first else { return }
        continuation.yield(.closed(.userClosed))
        continuation.finish()
    }
}

@MainActor
private final class PaneFactory {
    var sessions: [PaneSession] = []

    func make(_ plan: ConnectionPlan) -> any TerminalSession {
        let session = PaneSession(plan: plan)
        sessions.append(session)
        return session
    }

    /// The latest session made for `label`'s host (`<label>.example`).
    func session(_ label: String) -> PaneSession? {
        sessions.last { $0.plan.host == "\(label.lowercased()).example" }
    }
}

/// Workspaces: the strip, making and dissolving, panes, focus, broadcast, status and unsaved changes.
@MainActor
final class SessionManagerWorkspacesTests: XCTestCase {
    private var vault: LocalVault!
    private var factory: PaneFactory!
    private var manager: SessionManager!

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        let factory = PaneFactory()
        self.factory = factory
        manager = SessionManager(vault: vault, knownHosts: KnownHostsStore(vault: vault),
                                 makeSession: { plan, _ in factory.make(plan) },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero,
                                 autoReconnectEnabled: { false })
    }

    private func waitUntil(_ what: String = "condition", timeout: TimeInterval = 2,
                           _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func host(_ label: String) -> SavedHost {
        vault.saveNow(SavedHost(label: label, address: "\(label.lowercased()).example", username: "root", password: "pw"))
    }

    private func hostTab(_ label: String) -> TerminalTab {
        try! manager.open(hostID: host(label).id)
    }

    private func quick(_ name: String, port: Int? = nil) -> TerminalTab {
        manager.open(quickConnect: QuickConnectTarget(username: "u", host: "\(name).example", port: port))
    }

    private func strip(_ window: UUID? = nil) -> [StripItem] { manager.strip(inWindow: window) }

    private func connected(_ tabs: TerminalTab...) async {
        await waitUntil("connected") { tabs.allSatisfy { $0.state == .connected } }
    }

    /// A workspace of fresh host tabs (labels in order), all connected.
    private func workspace(_ labels: String...) async throws -> (Workspace, [TerminalTab]) {
        let tabs = labels.map { hostTab($0) }
        let ws = try XCTUnwrap(manager.makeWorkspace(from: tabs.map(\.id), name: nil))
        await waitUntil("connected") { tabs.allSatisfy { $0.state == .connected } }
        return (ws, tabs)
    }

    func testExitingThePanesShellClosesThePane() async throws {
        let (ws, tabs) = try await workspace("a", "b", "c")
        let session = try XCTUnwrap(factory.session("b"))
        await waitUntil("logs") { self.vault.all(ConnectionLog.self).count >= 3 }
        session.exitShell()
        await waitUntil("pane closed") { ws.paneIDs == [tabs[0].id, tabs[2].id] }
    }

    // MARK: A theme for each pane (v0.10)

    func testAThemeChosenInAPaneIsThatPanesOnlyAndNeverSavedToTheHost() async throws {
        let (_, tabs) = try await workspace("a", "b")
        let hostID = try XCTUnwrap(tabs[0].savedHostID)
        manager.applyTheme("dracula", tabID: tabs[0].id)
        XCTAssertEqual(manager.themeChoice(tabID: tabs[0].id), "dracula")
        XCTAssertNil(manager.themeChoice(tabID: tabs[1].id))
        XCTAssertNil(manager.pendingTheme(forHost: hostID))
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertNil(vault.get(SavedHost.self, id: hostID)?.themeID, "the host's own theme is untouched")
        manager.applyTheme(nil, tabID: tabs[0].id)
        XCTAssertNil(manager.themeChoice(tabID: tabs[0].id), "Default: the pane follows its host again")
    }

    // MARK: Hosts screen actions (v0.10)

    func testOpenHostInAnotherWindowSelectsItThere() async throws {
        let window = UUID()
        let h = host("a")
        let tab = try manager.open(hostID: h.id, inWindow: window)
        XCTAssertEqual(tab.windowID, window)
        XCTAssertEqual(manager.selectedTabID(inWindow: window), tab.id)
        XCTAssertEqual(strip(window), [.tab(tab.id)])
        XCTAssertEqual(strip(), [], "the main window is untouched")
    }

    func testWorkspacesOfAWindowInStripOrder() async throws {
        let (first, _) = try await workspace("a", "b")
        _ = hostTab("p")
        let (second, _) = try await workspace("c", "d")
        XCTAssertEqual(manager.workspaces(inWindow: nil).map(\.id), [first.id, second.id])
        XCTAssertEqual(manager.workspaces(inWindow: UUID()).count, 0)
    }

    func testAddHostToAWorkspaceGoesBesideTheFocusedPaneAndShowsTheWorkspace() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        let plain = hostTab("p")
        XCTAssertEqual(manager.selectedTabID, plain.id)
        manager.focusPane(tabs[0].id)
        manager.select(tabID: plain.id, inWindow: nil)
        let added = try manager.addHost(host("c").id, toWorkspace: ws.id)
        XCTAssertEqual(ws.paneIDs, [tabs[0].id, added.id, tabs[1].id])
        XCTAssertEqual(ws.focusedPaneID, added.id)
        XCTAssertEqual(manager.selectedTabID, added.id, "the workspace is shown, the new pane focused")
        XCTAssertThrowsError(try manager.addHost(host("d").id, toWorkspace: UUID()))
    }

    // MARK: Strip

    func testWithoutWorkspacesTheStripIsTheTabs() async {
        let a = hostTab("a"), b = quick("b")
        XCTAssertEqual(strip(), [.tab(a.id), .tab(b.id)])
        XCTAssertEqual(StripItem.tab(a.id).id, a.id)
    }

    func testMakeWorkspaceTakesTheFirstTabsPlace() async throws {
        let a = hostTab("a"), b = hostTab("b"), c = hostTab("c"), d = hostTab("d")
        let ws = try XCTUnwrap(manager.makeWorkspace(from: [c.id, a.id], name: nil))
        XCTAssertEqual(strip(), [.tab(b.id), .workspace(ws.id), .tab(d.id)])
        XCTAssertEqual(ws.name, "Workspace")
        XCTAssertEqual(ws.root, .split(.horizontal, ratio: 0.5, .pane(c.id), .pane(a.id)))
        XCTAssertEqual(ws.paneIDs, [c.id, a.id])
        XCTAssertEqual(ws.focusedPaneID, c.id)
        XCTAssertEqual(ws.viewMode, .split)
        XCTAssertFalse(ws.isBroadcasting)
        XCTAssertNil(ws.templateID)
        // Every session of the window stays listed, panes at their workspace's place.
        XCTAssertEqual(manager.tabs(inWindow: nil).map(\.id), [b.id, c.id, a.id, d.id])
        XCTAssertEqual(manager.tabs.count, 4)
        XCTAssertTrue(manager.workspace(ws.id) === ws)
        XCTAssertTrue(manager.workspace(containing: a.id) === ws)
        XCTAssertNil(manager.workspace(containing: b.id))
        XCTAssertNil(manager.workspace(UUID()))
    }

    func testMakeWorkspaceSelectsItAndTheSelectedTabIsTheFocusedPane() async throws {
        let a = hostTab("a"), b = hostTab("b"), _ = hostTab("c")
        let ws = try XCTUnwrap(manager.makeWorkspace(from: [a.id, b.id], name: "  Prod  "))
        XCTAssertEqual(ws.name, "Prod")
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id))
        XCTAssertEqual(manager.selectedTabID, a.id)
        manager.focusPane(b.id)
        XCTAssertEqual(manager.selectedTabID, b.id)
    }

    func testMakeWorkspaceRejectsBadInput() async throws {
        let a = hostTab("a"), b = hostTab("b"), c = hostTab("c")
        XCTAssertNil(manager.makeWorkspace(from: [a.id], name: nil))
        XCTAssertNil(manager.makeWorkspace(from: [a.id, a.id], name: nil))
        XCTAssertNil(manager.makeWorkspace(from: [a.id, UUID()], name: nil))
        let other = try XCTUnwrap(manager.duplicate(tabID: a.id, inWindow: UUID()))
        XCTAssertNil(manager.makeWorkspace(from: [a.id, other.id], name: nil))
        _ = try XCTUnwrap(manager.makeWorkspace(from: [a.id, b.id], name: nil))
        XCTAssertNil(manager.makeWorkspace(from: [a.id, c.id], name: nil)) // a is a pane already
        let many = (0..<17).map { _ in quick("q") }
        XCTAssertNil(manager.makeWorkspace(from: many.map(\.id), name: nil))
        XCTAssertNotNil(manager.makeWorkspace(from: many.dropLast().map(\.id), name: nil)) // 16 is fine
    }

    func testOpenWorkspaceConnectsEachHostInABalancedLayout() async throws {
        let existing = quick("x")
        let hosts = ["a", "b", "c", "d"].map { host($0).id }
        let ws = try manager.openWorkspace(hostIDs: hosts, name: nil)
        XCTAssertEqual(ws.paneIDs.count, 4)
        guard case .split(.vertical, _, .split(.horizontal, _, _, _), .split(.horizontal, _, _, _)) = ws.root else {
            return XCTFail("\(ws.root)")
        }
        XCTAssertEqual(strip(), [.tab(existing.id), .workspace(ws.id)])
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id))
        XCTAssertEqual(ws.paneIDs.compactMap { id in manager.tabs.first { $0.id == id }?.savedHostID }, hosts)
        await waitUntil("four sessions") { self.factory.sessions.count == 4 }
        XCTAssertEqual(factory.sessions.map(\.plan.host), ["a.example", "b.example", "c.example", "d.example"])
    }

    func testOpenWorkspaceThrowsAndOpensNothingWhenAHostCantBePlanned() async {
        let a = host("a").id
        XCTAssertThrowsError(try manager.openWorkspace(hostIDs: [a, UUID()], name: nil))
        XCTAssertThrowsError(try manager.openWorkspace(hostIDs: [a], name: nil)) { error in
            XCTAssertEqual(error as? WorkspaceError, .notEnoughPanes)
        }
        XCTAssertThrowsError(try manager.openWorkspace(hostIDs: Array(repeating: a, count: 17), name: nil)) { error in
            XCTAssertEqual(error as? WorkspaceError, .tooManyPanes)
        }
        XCTAssertTrue(manager.tabs.isEmpty)
        XCTAssertTrue(strip().isEmpty)
    }

    func testOpenWorkspaceInAnotherWindow() async throws {
        let window = UUID()
        let ws = try manager.openWorkspace(hostIDs: [host("a").id, host("b").id], name: "W", inWindow: window)
        XCTAssertEqual(strip(window), [.workspace(ws.id)])
        XCTAssertTrue(strip(nil).isEmpty)
        XCTAssertEqual(ws.windowID, window)
        XCTAssertEqual(manager.selectedItem(inWindow: window), .workspace(ws.id))
        XCTAssertNil(manager.selectedTabID)
    }

    // MARK: Order and selection

    func testMoveTabMovesStripItems() async throws {
        let a = hostTab("a"), b = hostTab("b"), c = hostTab("c"), d = hostTab("d")
        let ws = try XCTUnwrap(manager.makeWorkspace(from: [b.id, c.id], name: nil)) // a ws d
        manager.moveTab(id: ws.id, toIndex: 2)
        XCTAssertEqual(strip(), [.tab(a.id), .tab(d.id), .workspace(ws.id)])
        manager.moveTab(id: a.id, toIndex: 99)
        XCTAssertEqual(strip(), [.tab(d.id), .workspace(ws.id), .tab(a.id)])
        manager.moveTab(id: ws.id, toIndex: 0)
        XCTAssertEqual(strip(), [.workspace(ws.id), .tab(d.id), .tab(a.id)])
        XCTAssertEqual(manager.tabs.map(\.id), [b.id, c.id, d.id, a.id])
        manager.moveTab(id: b.id, toIndex: 2) // a pane is not a strip item
        XCTAssertEqual(strip(), [.workspace(ws.id), .tab(d.id), .tab(a.id)])
    }

    func testNextAndPreviousWalkStripItems() async throws {
        let a = hostTab("a"), b = hostTab("b"), c = hostTab("c"), d = hostTab("d")
        let ws = try XCTUnwrap(manager.makeWorkspace(from: [b.id, c.id], name: nil)) // a ws d
        manager.selectedTabID = a.id
        manager.selectNextTab(inWindow: nil)
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id))
        XCTAssertEqual(manager.selectedTabID, b.id)
        manager.selectNextTab(inWindow: nil)
        XCTAssertEqual(manager.selectedTabID, d.id)
        manager.selectNextTab(inWindow: nil)
        XCTAssertEqual(manager.selectedTabID, a.id)
        manager.selectPreviousTab(inWindow: nil)
        XCTAssertEqual(manager.selectedTabID, d.id)
        manager.selectPreviousTab(inWindow: nil)
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id))
    }

    func testSelectingAPaneSelectsItsWorkspaceAndFocusesIt() async throws {
        let a = hostTab("a"), b = hostTab("b"), c = hostTab("c")
        let ws = try XCTUnwrap(manager.makeWorkspace(from: [a.id, b.id], name: nil))
        manager.selectedTabID = c.id
        manager.select(tabID: b.id, inWindow: nil)
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id))
        XCTAssertEqual(ws.focusedPaneID, b.id)
        manager.selectedTabID = c.id
        manager.select(tabID: ws.id, inWindow: nil)
        XCTAssertEqual(manager.selectedTabID, b.id)
        manager.select(tabID: ws.id, inWindow: UUID()) // another window: ignored
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id))
    }

    // MARK: Closing, popping out, dissolving

    func testClosingAPaneEndsItsSessionAndMovesTheFocus() async throws {
        let (ws, tabs) = try await workspace("a", "b", "c")
        manager.focusPane(tabs[1].id)
        manager.closePane(tabs[1].id)
        XCTAssertEqual(ws.paneIDs, [tabs[0].id, tabs[2].id])
        XCTAssertEqual(ws.focusedPaneID, tabs[2].id)
        XCTAssertFalse(manager.tabs.contains { $0.id == tabs[1].id })
        XCTAssertNotNil(manager.workspace(ws.id))
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id))
        await waitUntil("closed") { self.factory.session("b")!.closed }
        XCTAssertFalse(factory.session("a")!.closed)
    }

    func testClosingThePaneBeforeTheLastDissolvesTheWorkspaceIntoATab() async throws {
        let x = hostTab("x")
        let (ws, tabs) = try await workspace("a", "b")
        let y = hostTab("y")
        manager.select(tabID: ws.id, inWindow: nil)
        manager.close(tabID: tabs[0].id) // Cmd+W on the focused pane
        XCTAssertNil(manager.workspace(ws.id))
        XCTAssertNil(manager.workspace(containing: tabs[1].id))
        XCTAssertEqual(strip(), [.tab(x.id), .tab(tabs[1].id), .tab(y.id)])
        XCTAssertEqual(manager.selectedTabID, tabs[1].id)
        await waitUntil("closed") { self.factory.session("a")!.closed }
        XCTAssertFalse(factory.session("b")!.closed)
    }

    func testPopOutMovesThePaneToItsOwnTabAfterTheWorkspace() async throws {
        let (ws, tabs) = try await workspace("a", "b", "c")
        let z = hostTab("z")
        manager.popOutPane(tabs[0].id)
        XCTAssertEqual(strip(), [.workspace(ws.id), .tab(tabs[0].id), .tab(z.id)])
        XCTAssertEqual(ws.paneIDs, [tabs[1].id, tabs[2].id])
        XCTAssertEqual(manager.selectedTabID, tabs[0].id)
        XCTAssertEqual(tabs[0].state, .connected)
        XCTAssertFalse(factory.session("a")!.closed)
    }

    func testPopOutOfTwoPanesLeavesTwoTabs() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        manager.popOutPane(tabs[0].id)
        XCTAssertNil(manager.workspace(ws.id))
        XCTAssertEqual(strip(), [.tab(tabs[1].id), .tab(tabs[0].id)])
        XCTAssertEqual(manager.selectedTabID, tabs[0].id)
        XCTAssertTrue(factory.sessions.allSatisfy { !$0.closed })
    }

    func testCloseWorkspaceEndsAllItsSessionsAndSelectsANeighbour() async throws {
        let x = hostTab("x")
        let (ws, _) = try await workspace("a", "b", "c")
        let y = hostTab("y")
        manager.select(tabID: ws.id, inWindow: nil)
        manager.closeWorkspace(ws.id)
        XCTAssertNil(manager.workspace(ws.id))
        XCTAssertEqual(strip(), [.tab(x.id), .tab(y.id)])
        XCTAssertEqual(manager.tabs.map(\.id), [x.id, y.id])
        XCTAssertEqual(manager.selectedTabID, y.id)
        await waitUntil("closed") { ["a", "b", "c"].allSatisfy { self.factory.session($0)!.closed } }
    }

    func testCloseWindowClosesItsWorkspacesOnly() async throws {
        let window = UUID()
        let main = try manager.openWorkspace(hostIDs: [host("a").id, host("b").id], name: nil)
        let other = try manager.openWorkspace(hostIDs: [host("c").id, host("d").id], name: nil, inWindow: window)
        manager.closeWindow(window)
        XCTAssertNil(manager.workspace(other.id))
        XCTAssertNotNil(manager.workspace(main.id))
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertNil(manager.selectedItem(inWindow: window))
    }

    func testCloseAllForgetsWorkspaces() async throws {
        let ws = try manager.openWorkspace(hostIDs: [host("a").id, host("b").id], name: nil)
        await manager.closeAll()
        XCTAssertNil(manager.workspace(ws.id))
        XCTAssertTrue(strip().isEmpty)
    }

    func testARemoteUserCloseOfAPaneFollowsTheDissolveRule() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        await factory.session("b")!.close() // ends as .userClosed: the tab closes
        await waitUntil("pane gone") { !self.manager.tabs.contains { $0.id == tabs[1].id } }
        XCTAssertNil(manager.workspace(ws.id))
        XCTAssertEqual(strip(), [.tab(tabs[0].id)])
    }

    // MARK: Adding, splitting, moving panes

    func testAddPaneMovesAPlainTabIntoTheWorkspace() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        let c = hostTab("c")
        manager.addPane(tabID: c.id, to: ws.id, beside: tabs[1].id, at: .bottom)
        XCTAssertEqual(ws.root, .split(.horizontal, ratio: 0.5, .pane(tabs[0].id),
                                       .split(.vertical, ratio: 0.5, .pane(tabs[1].id), .pane(c.id))))
        XCTAssertEqual(strip(), [.workspace(ws.id)])
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id)) // c was selected
        XCTAssertEqual(ws.focusedPaneID, c.id)
        XCTAssertFalse(factory.session("c")!.closed)
    }

    func testAddPaneTakesAPaneFromAnotherWorkspace() async throws {
        let (first, a) = try await workspace("a", "b")
        let (second, c) = try await workspace("c", "d")
        manager.addPane(tabID: a[0].id, to: second.id, beside: c[0].id, at: .left)
        XCTAssertEqual(second.paneIDs, [a[0].id, c[0].id, c[1].id])
        XCTAssertNil(manager.workspace(first.id)) // one pane left: dissolved
        XCTAssertEqual(strip(), [.tab(a[1].id), .workspace(second.id)])
    }

    func testAddPaneIgnoresOtherWindowsAndAFullWorkspace() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        let far = try XCTUnwrap(manager.duplicate(tabID: tabs[0].id, inWindow: UUID()))
        manager.addPane(tabID: far.id, to: ws.id, beside: tabs[0].id, at: .left)
        XCTAssertEqual(ws.paneIDs.count, 2)
        let more = (0..<14).map { _ in quick("q") }
        for tab in more { manager.addPane(tabID: tab.id, to: ws.id, beside: tabs[0].id, at: .right) }
        XCTAssertEqual(ws.paneIDs.count, 16)
        let extra = quick("r")
        manager.addPane(tabID: extra.id, to: ws.id, beside: tabs[0].id, at: .right)
        XCTAssertEqual(ws.paneIDs.count, 16)
        XCTAssertNil(manager.workspace(containing: extra.id))
    }

    func testAddPaneOfAPaneOfTheSameWorkspaceMovesIt() async throws {
        let (ws, tabs) = try await workspace("a", "b", "c")
        manager.addPane(tabID: tabs[0].id, to: ws.id, beside: tabs[2].id, at: .right)
        XCTAssertEqual(ws.paneIDs, [tabs[1].id, tabs[2].id, tabs[0].id])
    }

    func testAddPaneWithAHostOpensANewConnection() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        try manager.addPane(hostID: host("c").id, to: ws.id, beside: tabs[0].id, at: .top)
        XCTAssertEqual(ws.paneIDs.count, 3)
        XCTAssertEqual(ws.paneIDs[1], tabs[0].id)
        await waitUntil("c connects") { self.factory.session("c") != nil }
        XCTAssertEqual(manager.tabs.count, 3)
        XCTAssertEqual(strip(), [.workspace(ws.id)])
        XCTAssertThrowsError(try manager.addPane(hostID: UUID(), to: ws.id, beside: tabs[0].id, at: .top))
        XCTAssertEqual(manager.tabs.count, 3)
    }

    func testSplitTabMakesAWorkspaceWithADuplicateBesideIt() async throws {
        let x = hostTab("x")
        let a = hostTab("a")
        let y = hostTab("y")
        manager.selectedTabID = x.id
        let ws = try manager.splitTab(a.id, at: .right)
        XCTAssertEqual(ws.paneIDs.count, 2)
        XCTAssertEqual(ws.paneIDs[0], a.id)
        guard case .split(.horizontal, 0.5, .pane(a.id), .pane(let copyID)) = ws.root else { return XCTFail("\(ws.root)") }
        XCTAssertEqual(manager.tabs.first { $0.id == copyID }?.savedHostID, a.savedHostID)
        XCTAssertEqual(strip(), [.tab(x.id), .workspace(ws.id), .tab(y.id)])
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id))
        let down = try manager.splitTab(copyID, at: .bottom) // a pane: splits inside its workspace
        XCTAssertTrue(down === ws)
        XCTAssertEqual(ws.paneIDs.count, 3)
        XCTAssertThrowsError(try manager.splitTab(UUID(), at: .left))
    }

    func testMovePaneAndRatioAndReorder() async throws {
        let (ws, tabs) = try await workspace("a", "b", "c")
        manager.movePane(tabs[2].id, beside: tabs[0].id, at: .left, in: ws.id)
        XCTAssertEqual(ws.paneIDs.first, tabs[2].id)
        XCTAssertEqual(manager.tabs(inWindow: nil).map(\.id), ws.paneIDs)
        manager.setRatio(0.25, atPath: [], in: ws.id)
        guard case .split(_, let ratio, _, _) = ws.root else { return XCTFail() }
        XCTAssertEqual(ratio, 0.25)
        manager.movePane(tabs[1].id, toIndex: 0, in: ws.id)
        XCTAssertEqual(ws.paneIDs.first, tabs[1].id)
        guard case .split(_, let kept, _, _) = ws.root else { return XCTFail() }
        XCTAssertEqual(kept, 0.25) // reordering keeps the shape
        XCTAssertEqual(manager.tabs(inWindow: nil).map(\.id), ws.paneIDs)
        manager.movePane(tabs[1].id, beside: UUID(), at: .left, in: ws.id) // unknown target: nothing
        XCTAssertEqual(ws.paneIDs.first, tabs[1].id)
    }

    func testRenameWorkspace() async throws {
        let (ws, _) = try await workspace("a", "b")
        manager.renameWorkspace(ws.id, to: "  Prod ")
        XCTAssertEqual(ws.name, "Prod")
        manager.renameWorkspace(ws.id, to: " ")
        XCTAssertEqual(ws.name, "Workspace")
    }

    // MARK: Broadcast

    func testSendInputWithoutBroadcastIsSend() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        manager.sendInput(fromTab: tabs[0].id, [0x6C, 0x73, 0x0D])
        manager.send(tabID: tabs[1].id, [0x71])
        await waitUntil("sent") { self.factory.session("a")!.sends.count == 1 && self.factory.session("b")!.sends.count == 1 }
        XCTAssertEqual(factory.session("a")!.sends, [[0x6C, 0x73, 0x0D]])
        XCTAssertEqual(factory.session("b")!.sends, [[0x71]])
        XCTAssertFalse(ws.isBroadcasting)
        let plain = hostTab("p")
        await connected(plain)
        manager.sendInput(fromTab: plain.id, [0x41])
        await waitUntil("plain") { self.factory.session("p")!.sends == [[0x41]] }
    }

    func testBroadcastReachesIncludedConnectedPanesOfTheWorkspaceOnly() async throws {
        let (ws, tabs) = try await workspace("a", "b", "c")
        let waiting = quick("w") // asks for a password: not connected
        manager.addPane(tabID: waiting.id, to: ws.id, beside: tabs[0].id, at: .right)
        let plain = hostTab("p")
        let far = try XCTUnwrap(manager.duplicate(tabID: tabs[0].id, inWindow: UUID()))
        await connected(plain, far)
        manager.focusPane(tabs[0].id)
        manager.toggleBroadcast(in: ws.id)
        XCTAssertTrue(ws.isBroadcasting)
        manager.setPane(tabs[2].id, includedInBroadcast: false)
        XCTAssertEqual(ws.excludedFromBroadcast, [tabs[2].id])
        manager.sendInput(fromTab: tabs[0].id, Array("x".utf8))
        let mainA = try XCTUnwrap(factory.sessions.first { $0.plan.host == "a.example" })
        await waitUntil("a and b") { mainA.sentText == "x" && self.factory.session("b")!.sentText == "x" }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.session("c")!.sends, [])
        XCTAssertEqual(factory.session("p")!.sends, [])
        XCTAssertEqual(factory.sessions.filter { $0.plan.host == "a.example" }.first!.sentText, "x")
        XCTAssertEqual(factory.sessions.filter { $0.plan.host == "a.example" }.last!.sends, []) // the other window's copy
        XCTAssertNil(factory.session("w"))
    }

    func testOnlyTheFocusedPaneBroadcasts() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        manager.toggleBroadcast(in: ws.id)
        manager.focusPane(tabs[0].id)
        manager.sendInput(fromTab: tabs[1].id, Array("y".utf8))
        await waitUntil("b") { self.factory.session("b")!.sentText == "y" }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.session("a")!.sends, [])
    }

    func testAnExcludedFocusedPaneDoesNotBroadcast() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        manager.toggleBroadcast(in: ws.id)
        manager.setPane(tabs[0].id, includedInBroadcast: false)
        manager.sendInput(fromTab: tabs[0].id, Array("z".utf8))
        await waitUntil("a") { self.factory.session("a")!.sentText == "z" }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.session("b")!.sends, [])
        manager.setPane(tabs[0].id, includedInBroadcast: true)
        XCTAssertTrue(ws.excludedFromBroadcast.isEmpty)
    }

    func testBroadcastOffAgain() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        manager.toggleBroadcast(in: ws.id)
        manager.toggleBroadcast(in: ws.id)
        XCTAssertFalse(ws.isBroadcasting)
        manager.sendInput(fromTab: tabs[0].id, Array("q".utf8))
        await waitUntil("a") { self.factory.session("a")!.sentText == "q" }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.session("b")!.sends, [])
    }

    func testSnippetRunWhileBroadcastingReachesTheIncludedPanes() async throws {
        let (ws, tabs) = try await workspace("a", "b", "c")
        manager.setPane(tabs[2].id, includedInBroadcast: false)
        XCTAssertTrue(manager.deliver("uptime", as: .run, toTab: tabs[0].id))
        await waitUntil("a") { self.factory.session("a")!.sentText == "uptime\r" }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.session("b")!.sends, []) // not broadcasting yet
        manager.toggleBroadcast(in: ws.id)
        XCTAssertTrue(manager.deliver("ls", as: .run, toTab: tabs[0].id))
        await waitUntil("a and b") {
            self.factory.session("a")!.sentText == "uptime\rls\r" && self.factory.session("b")!.sentText == "ls\r"
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.session("c")!.sends, [])
    }

    func testRunInAllTabsTypesOncePerTabEvenWhileAWorkspaceBroadcasts() async throws {
        let (ws, _) = try await workspace("a", "b")
        manager.toggleBroadcast(in: ws.id)
        let plain = hostTab("p")
        await connected(plain)
        XCTAssertEqual(manager.deliverToAllTabs("w", as: .run, inWindow: nil), 3)
        await waitUntil("all") { ["a", "b", "p"].allSatisfy { self.factory.session($0)!.sentText == "w\r" } }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.session("a")!.sentText, "w\r", "not again through the broadcast")
        XCTAssertEqual(factory.session("b")!.sentText, "w\r")
    }

    func testRunInAllPanes() async throws {
        let (ws, tabs) = try await workspace("a", "b", "c")
        let plain = hostTab("p")
        await connected(plain)
        manager.setPane(tabs[1].id, includedInBroadcast: false)
        XCTAssertEqual(manager.connectablePaneCount(inWorkspace: ws.id), 2)
        XCTAssertEqual(manager.deliverToAllPanes("df", as: .run, inWorkspace: ws.id), 2)
        await waitUntil("a and c") { self.factory.session("a")!.sentText == "df\r" && self.factory.session("c")!.sentText == "df\r" }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.session("b")!.sends, [])
        XCTAssertEqual(factory.session("p")!.sends, [])
        XCTAssertEqual(manager.deliverToAllPanes("df", as: .run, inWorkspace: UUID()), 0)
    }

    func testBroadcastStateIsNotSharedBetweenWorkspaces() async throws {
        let (first, a) = try await workspace("a", "b")
        let (_, c) = try await workspace("c", "d")
        manager.toggleBroadcast(in: first.id)
        manager.sendInput(fromTab: c[0].id, Array("k".utf8))
        await waitUntil("c") { self.factory.session("c")!.sentText == "k" }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(factory.session("d")!.sends, [])
        XCTAssertEqual(factory.session("a")!.sends, [])
        _ = a
    }

    // MARK: Status dots

    func testNewOutputOnAnUnfocusedPaneUntilItIsFocused() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        XCTAssertEqual(ws.status(of: tabs[1].id), .none)
        manager.noteOutput(tabID: tabs[1].id)
        manager.noteOutput(tabID: tabs[0].id) // focused: nothing
        XCTAssertEqual(ws.status(of: tabs[1].id), .newOutput)
        XCTAssertEqual(ws.status(of: tabs[0].id), .none)
        manager.focusPane(tabs[1].id)
        XCTAssertEqual(ws.status(of: tabs[1].id), .none)
        manager.focusPane(tabs[0].id)
        XCTAssertEqual(ws.status(of: tabs[1].id), .none) // cleared, not just hidden
    }

    func testSessionOutputMarksNewOutput() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        factory.session("b")!.output("hello")
        await waitUntil("green") { ws.status(of: tabs[1].id) == .newOutput }
    }

    func testWaitingAndFailedStatus() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        let waiting = quick("w")
        manager.addPane(tabID: waiting.id, to: ws.id, beside: tabs[0].id, at: .right)
        XCTAssertEqual(ws.status(of: waiting.id), .waitingForInput)
        factory.session("b")!.drop()
        await waitUntil("red") { ws.status(of: tabs[1].id) == .failed }
        manager.focusPane(tabs[1].id)
        XCTAssertEqual(ws.status(of: tabs[1].id), .failed)
        XCTAssertEqual(ws.status(of: UUID()), .none)
    }

    func testOnePromptAtATimeFocusedPaneFirst() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        XCTAssertNil(ws.promptingPaneID)
        let first = quick("w1")
        let second = quick("w2")
        manager.addPane(tabID: first.id, to: ws.id, beside: tabs[0].id, at: .right)
        manager.addPane(tabID: second.id, to: ws.id, beside: first.id, at: .right)
        manager.focusPane(tabs[0].id)
        XCTAssertEqual(ws.promptingPaneID, first.id, "the first waiting pane in order")
        manager.focusPane(second.id)
        XCTAssertEqual(ws.promptingPaneID, second.id, "the focused pane's question comes first")
        manager.close(tabID: second.id)
        XCTAssertEqual(ws.promptingPaneID, first.id)
    }

    // MARK: Unsaved changes

    func testUnsavedChangesTracking() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        XCTAssertTrue(ws.hasUnsavedChanges) // never saved
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceTemplateStore(fileURL: url)
        let template = try store.save(ws, sessions: manager)
        XCTAssertEqual(ws.templateID, template.id)
        XCTAssertFalse(ws.hasUnsavedChanges)

        ws.name = "Other"
        XCTAssertTrue(ws.hasUnsavedChanges)
        ws.name = "Workspace"
        XCTAssertFalse(ws.hasUnsavedChanges)

        manager.setViewMode(.focus, for: ws.id)
        XCTAssertEqual(ws.viewMode, .focus)
        XCTAssertTrue(ws.hasUnsavedChanges)
        manager.setViewMode(.split, for: ws.id)
        XCTAssertFalse(ws.hasUnsavedChanges)

        manager.setRatio(0.3, atPath: [], in: ws.id)
        XCTAssertTrue(ws.hasUnsavedChanges)
        _ = try store.save(ws, sessions: manager)
        XCTAssertFalse(ws.hasUnsavedChanges)
        XCTAssertEqual(store.templates.count, 1) // saved over the same template

        manager.rename(tabID: tabs[0].id, to: "web")
        XCTAssertTrue(ws.hasUnsavedChanges)
        _ = try store.save(ws, sessions: manager)

        manager.focusPane(tabs[1].id) // focus and broadcast are not saved
        manager.toggleBroadcast(in: ws.id)
        XCTAssertFalse(ws.hasUnsavedChanges)

        try manager.addPane(hostID: host("c").id, to: ws.id, beside: tabs[1].id, at: .right)
        XCTAssertTrue(ws.hasUnsavedChanges)
    }

    func testPasteWhileBroadcastingReachesTheIncludedPanesToo() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        manager.toggleBroadcast(in: ws.id)
        XCTAssertTrue(manager.deliver("echo hi", as: .paste, toTab: tabs[0].id, bracketedPaste: true))
        let typed = "\u{1B}[200~echo hi\u{1B}[201~"
        await waitUntil("both") { self.factory.session("a")!.sentText == typed && self.factory.session("b")!.sentText == typed }
    }

    /// The tab bar's selection always resolves to one of a shown workspace's panes.
    func testSelectedTabIDIsAPaneOfTheSelectedWorkspace() async throws {
        func check(_ ws: Workspace, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id), file: file, line: line)
            XCTAssertEqual(manager.selectedTabID, ws.focusedPaneID, file: file, line: line)
            XCTAssertTrue(ws.paneIDs.contains(manager.selectedTabID ?? UUID()), file: file, line: line)
        }
        let (ws, tabs) = try await workspace("a", "b", "c")
        check(ws)
        let d = hostTab("d")
        XCTAssertEqual(manager.selectedTabID, d.id)
        manager.addPane(tabID: d.id, to: ws.id, beside: tabs[0].id, at: .left)
        check(ws)
        manager.closePane(ws.focusedPaneID)
        check(ws)
        manager.popOutPane(tabs[2].id)
        manager.select(tabID: ws.id, inWindow: nil)
        check(ws)
        let opened = try manager.openWorkspace(hostIDs: [host("e").id, host("f").id], name: nil)
        check(opened)
        _ = try manager.splitTab(opened.paneIDs[0], at: .right)
        check(opened)
    }

    // MARK: v0.11 tab bar and pane polish

    func testSwapPanesTradesPlacesKeepingTheLayout() async throws {
        let (ws, tabs) = try await workspace("a", "b", "c")
        manager.setRatio(0.25, atPath: [], in: ws.id)
        let shapeBefore = ws.root
        manager.swapPanes(tabs[0].id, tabs[2].id, in: ws.id)
        XCTAssertEqual(ws.paneIDs, [tabs[2].id, tabs[1].id, tabs[0].id])
        XCTAssertEqual(ws.root, shapeBefore.reordered([tabs[2].id, tabs[1].id, tabs[0].id]), "same shape and ratios")
        XCTAssertEqual(manager.tabs(inWindow: nil).map(\.id), ws.paneIDs, "tab order follows reading order")
        manager.swapPanes(tabs[0].id, UUID(), in: ws.id)
        manager.swapPanes(tabs[0].id, tabs[0].id, in: ws.id)
        manager.swapPanes(tabs[0].id, tabs[1].id, in: UUID())
        XCTAssertEqual(ws.paneIDs, [tabs[2].id, tabs[1].id, tabs[0].id], "ignored")
    }

    func testSwapPanesIgnoresAPaneOfAnotherWorkspace() async throws {
        let (first, one) = try await workspace("a", "b")
        let (_, two) = try await workspace("c", "d")
        manager.swapPanes(one[0].id, two[0].id, in: first.id)
        XCTAssertEqual(first.paneIDs, [one[0].id, one[1].id])
    }

    func testClosingThePaneBeforeTheLastAsksToSaveOnlyWithUnsavedChangesAndTheSetting() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        // Never saved: unsaved changes.
        XCTAssertTrue(manager.workspaceToSaveBeforeClosing(pane: tabs[0].id, asksToSave: true) === ws)
        XCTAssertNil(manager.workspaceToSaveBeforeClosing(pane: tabs[0].id, asksToSave: false), "setting off")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceTemplateStore(fileURL: url)
        _ = try store.save(ws, sessions: manager)
        XCTAssertNil(manager.workspaceToSaveBeforeClosing(pane: tabs[1].id, asksToSave: true), "saved, unchanged")
        manager.setRatio(0.3, atPath: [], in: ws.id)
        XCTAssertTrue(manager.workspaceToSaveBeforeClosing(pane: tabs[1].id, asksToSave: true) === ws, "saved, changed")
        let plain = hostTab("p")
        XCTAssertNil(manager.workspaceToSaveBeforeClosing(pane: plain.id, asksToSave: true), "a plain tab")
        XCTAssertNil(manager.workspaceToSaveBeforeClosing(pane: UUID(), asksToSave: true))
    }

    func testClosingAPaneThatLeavesAWorkspaceNeverAsks() async throws {
        let (_, tabs) = try await workspace("a", "b", "c")
        XCTAssertNil(manager.workspaceToSaveBeforeClosing(pane: tabs[0].id, asksToSave: true),
                     "two panes are left: still a workspace")
    }

    func testIsDraggingWorkspace() async throws {
        let (ws, tabs) = try await workspace("a", "b")
        XCTAssertFalse(manager.isDraggingWorkspace)
        manager.draggedTabID = tabs[0].id
        XCTAssertFalse(manager.isDraggingWorkspace)
        manager.draggedTabID = ws.id
        XCTAssertTrue(manager.isDraggingWorkspace)
        manager.draggedTabID = nil
        XCTAssertFalse(manager.isDraggingWorkspace)
    }

    func testDraggingAWorkspaceToAStripPositionMovesItWithItsPanes() async throws {
        let a = hostTab("a"), b = hostTab("b"), c = hostTab("c"), d = hostTab("d"), e = hostTab("e")
        let ws = try XCTUnwrap(manager.makeWorkspace(from: [b.id, c.id], name: nil)) // a ws d e
        // Dropped on "e" (strip index 3): it takes e's place.
        manager.moveTab(id: ws.id, toIndex: 3)
        XCTAssertEqual(strip(), [.tab(a.id), .tab(d.id), .tab(e.id), .workspace(ws.id)])
        XCTAssertEqual(manager.tabs.map(\.id), [a.id, d.id, e.id, b.id, c.id])
        // Dropped on "d" (index 1).
        manager.moveTab(id: ws.id, toIndex: 1)
        XCTAssertEqual(strip(), [.tab(a.id), .workspace(ws.id), .tab(d.id), .tab(e.id)])
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(ws.id), "the selection is untouched")
    }
}

