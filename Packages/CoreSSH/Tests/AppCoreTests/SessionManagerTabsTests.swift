import XCTest
import Synchronization
import CoreModels
import SSHCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

/// A session that connects and becomes ready at once, and records its close.
private final class ReadySession: TerminalSession, Sendable {
    let plan: ConnectionPlan
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let closedFlag = Mutex(false)

    init(plan: ConnectionPlan) {
        self.plan = plan
        (events, continuation) = AsyncStream.makeStream()
    }

    var closed: Bool { closedFlag.withLock { $0 } }

    func start(cols: Int, rows: Int) async {
        continuation.yield(.connected)
        continuation.yield(.ready)
    }

    func send(_ bytes: [UInt8]) async {}
    func resize(cols: Int, rows: Int) async {}
    func runCommand(_ command: String) async throws -> String { "Linux\nID=ubuntu\n" }

    /// The connection drops (auto-reconnect starts for a tab that was ready).
    func drop() {
        closedFlag.withLock { $0 = true }
        continuation.yield(.closed(.failed(.connectionFailed("dropped"))))
        continuation.finish()
    }

    func close() async {
        let first = closedFlag.withLock { closed -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        continuation.yield(.closed(.userClosed))
        continuation.finish()
    }
}

@MainActor
private final class ReadyFactory {
    var sessions: [ReadySession] = []

    func make(_ plan: ConnectionPlan) -> any TerminalSession {
        let session = ReadySession(plan: plan)
        sessions.append(session)
        return session
    }
}

/// Tab order, rename, duplicate, per-tab theme and windows.
@MainActor
final class SessionManagerTabsTests: XCTestCase {
    private var vault: LocalVault!
    private var factory: ReadyFactory!
    private var manager: SessionManager!

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        let factory = ReadyFactory()
        self.factory = factory
        manager = SessionManager(vault: vault, knownHosts: KnownHostsStore(vault: vault),
                                 makeSession: { plan, _ in factory.make(plan) },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero)
    }

    private func waitUntil(_ what: String = "condition", timeout: TimeInterval = 2,
                           _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func host(_ label: String, themeID: String? = nil) -> SavedHost {
        vault.saveNow(SavedHost(label: label, address: "\(label.lowercased()).example", username: "root",
                                password: "pw", themeID: themeID))
    }

    private func quick(_ name: String, port: Int? = nil) -> TerminalTab {
        manager.open(quickConnect: QuickConnectTarget(username: "u", host: "\(name).example", port: port))
    }

    /// Opens a saved-host tab (it connects without a password prompt).
    private func hostTab(_ label: String) -> TerminalTab {
        try! manager.open(hostID: host(label).id)
    }

    /// Opens three saved-host tabs a, b, c (in that order).
    private func threeTabs() -> (TerminalTab, TerminalTab, TerminalTab) {
        (hostTab("a"), hostTab("b"), hostTab("c"))
    }

    private func order(_ window: UUID? = nil) -> [UUID] {
        manager.tabs(inWindow: window).map(\.id)
    }

    // MARK: moveTab

    func testMoveTabForwardPutsItAtTheIndex() async {
        let (a, b, c) = threeTabs()
        manager.moveTab(id: a.id, toIndex: 2)
        XCTAssertEqual(manager.tabs.map(\.id), [b.id, c.id, a.id])
    }

    func testMoveTabBackward() async {
        let (a, b, c) = threeTabs()
        manager.moveTab(id: c.id, toIndex: 0)
        XCTAssertEqual(manager.tabs.map(\.id), [c.id, a.id, b.id])
    }

    func testMoveTabToTheMiddle() async {
        let (a, b, c) = threeTabs()
        manager.moveTab(id: a.id, toIndex: 1)
        XCTAssertEqual(manager.tabs.map(\.id), [b.id, a.id, c.id])
    }

    func testMoveTabClampsTheIndex() async {
        let (a, b, c) = threeTabs()
        manager.moveTab(id: a.id, toIndex: 99)
        XCTAssertEqual(manager.tabs.map(\.id), [b.id, c.id, a.id])
        manager.moveTab(id: a.id, toIndex: -5)
        XCTAssertEqual(manager.tabs.map(\.id), [a.id, b.id, c.id])
    }

    func testMoveTabToItsOwnIndexOrUnknownIDChangesNothing() async {
        let (a, b, c) = threeTabs()
        manager.moveTab(id: b.id, toIndex: 1)
        manager.moveTab(id: UUID(), toIndex: 0)
        XCTAssertEqual(manager.tabs.map(\.id), [a.id, b.id, c.id])
    }

    func testMoveTabKeepsTheSelectionAndSessions() async {
        let (a, _, c) = threeTabs()
        await waitUntil("connected") { manager.tabs.allSatisfy { $0.state == .connected } }
        XCTAssertEqual(manager.selectedTabID, c.id)
        manager.moveTab(id: c.id, toIndex: 0)
        XCTAssertEqual(manager.selectedTabID, c.id)
        XCTAssertEqual(factory.sessions.count, 3)
        XCTAssertTrue(factory.sessions.allSatisfy { !$0.closed })
        XCTAssertEqual(a.state, .connected)
    }

    // MARK: Next and previous tab

    func testNextAndPreviousFollowTheOrder() async {
        let (a, b, c) = threeTabs()
        manager.moveTab(id: c.id, toIndex: 0) // c a b
        manager.selectedTabID = c.id
        manager.selectNextTab(inWindow: nil)
        XCTAssertEqual(manager.selectedTabID, a.id)
        manager.selectNextTab(inWindow: nil)
        XCTAssertEqual(manager.selectedTabID, b.id)
        manager.selectNextTab(inWindow: nil) // wraps
        XCTAssertEqual(manager.selectedTabID, c.id)
        manager.selectPreviousTab(inWindow: nil) // wraps back
        XCTAssertEqual(manager.selectedTabID, b.id)
    }

    func testNextAndPreviousFromVaults() async {
        let (a, _, c) = threeTabs()
        manager.selectedTabID = nil
        manager.selectNextTab(inWindow: nil)
        XCTAssertEqual(manager.selectedTabID, a.id)
        manager.selectedTabID = nil
        manager.selectPreviousTab(inWindow: nil)
        XCTAssertEqual(manager.selectedTabID, c.id)
    }

    func testNextWithNoTabsDoesNothing() async {
        manager.selectNextTab(inWindow: nil)
        manager.selectPreviousTab(inWindow: nil)
        XCTAssertNil(manager.selectedTabID)
    }

    // MARK: Rename

    func testRenameChangesOnlyTheDisplayTitle() async throws {
        let saved = host("Web")
        let tab = try manager.open(hostID: saved.id)
        manager.rename(tabID: tab.id, to: "  Prod box  ")
        XCTAssertEqual(tab.displayTitle, "Prod box")
        XCTAssertEqual(tab.customTitle, "Prod box")
        XCTAssertEqual(tab.title, "Web")
        XCTAssertEqual(vault.get(SavedHost.self, id: saved.id)?.label, "Web")
    }

    func testRenameToBlankGoesBackToTheHostLabel() async throws {
        let tab = try manager.open(hostID: host("Web").id)
        manager.rename(tabID: tab.id, to: "Custom")
        manager.rename(tabID: tab.id, to: "   ")
        XCTAssertNil(tab.customTitle)
        XCTAssertEqual(tab.displayTitle, "Web")
    }

    func testRenameSurvivesReconnect() async throws {
        let tab = try manager.open(hostID: host("Web").id)
        await waitUntil("connected") { tab.state == .connected }
        manager.rename(tabID: tab.id, to: "Custom")
        manager.reconnect(tabID: tab.id)
        await waitUntil("reconnected") { tab.state == .connected && self.factory.sessions.count == 2 }
        XCTAssertEqual(tab.displayTitle, "Custom")
    }

    func testDisplayTitleDefaultsToTitle() async {
        let tab = quick("a")
        XCTAssertEqual(tab.displayTitle, tab.title)
        XCTAssertNil(tab.customTitle)
    }

    // MARK: Duplicate

    func testDuplicateHostTabOpensANewSessionRightAfterIt() async throws {
        let saved = host("Web")
        let source = try manager.open(hostID: saved.id)
        let other = quick("b")
        let copy = try XCTUnwrap(manager.duplicate(tabID: source.id))
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(manager.tabs.map(\.id), [source.id, copy.id, other.id])
        XCTAssertEqual(manager.selectedTabID, copy.id)
        XCTAssertEqual(copy.savedHostID, saved.id)
        XCTAssertEqual(copy.title, "Web")
        await waitUntil("copy connected") { copy.state == .connected }
        XCTAssertEqual(factory.sessions.count, 2) // the quick connect tab waits for a password
        XCTAssertEqual(factory.sessions.last?.plan.host, "web.example")
    }

    func testDuplicateQuickConnectUsesTheSameTarget() async {
        let source = quick("q", port: 2200)
        let copy = manager.duplicate(tabID: source.id)
        XCTAssertNil(copy?.savedHostID)
        XCTAssertEqual(copy?.state, .awaitingPassword(prompt: "Password for u@q.example"))
        guard let copy else { return XCTFail("no copy") }
        manager.providePassword(tabID: copy.id, "pw", save: false)
        await waitUntil("session") { self.factory.sessions.count == 1 }
        XCTAssertEqual(factory.sessions[0].plan.host, "q.example")
        XCTAssertEqual(factory.sessions[0].plan.port, 2200)
        XCTAssertEqual(factory.sessions[0].plan.username, "u")
    }

    func testDuplicateKeepsTheThemeOverrideButNotTheCustomTitle() async {
        let source = quick("q")
        manager.applyTheme("dracula", tabID: source.id)
        manager.rename(tabID: source.id, to: "Mine")
        let copy = manager.duplicate(tabID: source.id)
        XCTAssertEqual(copy?.themeOverrideID, "dracula")
        XCTAssertNil(copy?.customTitle)
    }

    func testDuplicateUnknownTabReturnsNil() async {
        XCTAssertNil(manager.duplicate(tabID: UUID()))
        XCTAssertTrue(manager.tabs.isEmpty)
    }

    func testDuplicateOfADeletedHostShowsDisconnected() async throws {
        let saved = host("Web")
        let source = try manager.open(hostID: saved.id)
        try await vault.delete(SavedHost.self, id: saved.id)
        let copy = try XCTUnwrap(manager.duplicate(tabID: source.id))
        guard case .disconnected(let message) = copy.state else { return XCTFail("\(copy.state)") }
        XCTAssertNotNil(message)
    }

    // MARK: Theme

    func testApplyThemeToAHostTabSavesTheHostAfterAShortDelay() async throws {
        manager.themeSaveDelay = .milliseconds(20)
        let saved = host("Web")
        let tab = try manager.open(hostID: saved.id)
        manager.applyTheme("dracula", tabID: tab.id)
        // The tab (and the panel) show it at once; the host is saved a moment later.
        XCTAssertEqual(manager.themeChoice(tabID: tab.id), "dracula")
        XCTAssertEqual(manager.pendingTheme(forHost: saved.id), PendingThemeChoice(themeID: "dracula"))
        XCTAssertNil(vault.get(SavedHost.self, id: saved.id)?.themeID)
        await waitUntil("saved") { self.vault.get(SavedHost.self, id: saved.id)?.themeID == "dracula" }
        XCTAssertNil(manager.pendingTheme(forHost: saved.id))
        XCTAssertNil(tab.themeOverrideID)
        XCTAssertEqual(manager.themeChoice(tabID: tab.id), "dracula")
    }

    func testRapidThemeClicksSaveOnlyTheLast() async throws {
        manager.themeSaveDelay = .milliseconds(60)
        let saved = host("Web")
        let tab = try manager.open(hostID: saved.id)
        manager.applyTheme("dracula", tabID: tab.id)
        manager.applyTheme("nord", tabID: tab.id)
        manager.applyTheme("solarized-dark", tabID: tab.id)
        XCTAssertEqual(manager.themeChoice(tabID: tab.id), "solarized-dark")
        XCTAssertNil(vault.get(SavedHost.self, id: saved.id)?.themeID)
        await waitUntil("saved") { self.manager.pendingTheme(forHost: saved.id) == nil }
        XCTAssertEqual(vault.get(SavedHost.self, id: saved.id)?.themeID, "solarized-dark")
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(vault.get(SavedHost.self, id: saved.id)?.themeID, "solarized-dark")
    }

    func testChoosingDefaultForAHostIsPendingThenSaved() async throws {
        manager.themeSaveDelay = .milliseconds(20)
        let saved = host("Web", themeID: "dracula")
        let tab = try manager.open(hostID: saved.id)
        manager.applyTheme(nil, tabID: tab.id)
        XCTAssertEqual(manager.pendingTheme(forHost: saved.id), PendingThemeChoice(themeID: nil))
        XCTAssertNil(manager.themeChoice(tabID: tab.id))
        await waitUntil("saved") { self.vault.get(SavedHost.self, id: saved.id)?.themeID == nil }
    }

    func testFlushPendingThemeSavesSavesAtOnce() async throws {
        manager.themeSaveDelay = .seconds(60)
        let saved = host("Web")
        let tab = try manager.open(hostID: saved.id)
        manager.applyTheme("dracula", tabID: tab.id)
        manager.flushPendingThemeSaves()
        XCTAssertEqual(vault.get(SavedHost.self, id: saved.id)?.themeID, "dracula")
        XCTAssertNil(manager.pendingTheme(forHost: saved.id))
    }

    func testCloseAllSavesAPendingTheme() async throws {
        manager.themeSaveDelay = .seconds(60)
        let saved = host("Web")
        let tab = try manager.open(hostID: saved.id)
        manager.applyTheme("dracula", tabID: tab.id)
        await manager.closeAll()
        XCTAssertEqual(vault.get(SavedHost.self, id: saved.id)?.themeID, "dracula")
    }

    func testApplyThemeToAQuickConnectTabSetsOnlyItsOverride() async {
        let tab = quick("q")
        let other = quick("r")
        manager.applyTheme("dracula", tabID: tab.id)
        XCTAssertEqual(tab.themeOverrideID, "dracula")
        XCTAssertNil(other.themeOverrideID)
        XCTAssertEqual(manager.themeChoice(tabID: tab.id), "dracula")
        manager.applyTheme(nil, tabID: tab.id)
        XCTAssertNil(tab.themeOverrideID)
    }

    func testApplyingTheSameThemeDoesNotResaveTheHost() async throws {
        manager.themeSaveDelay = .milliseconds(10)
        let saved = host("Web", themeID: "dracula")
        let tab = try manager.open(hostID: saved.id)
        // Let the OS probe after connecting save its badge first.
        await waitUntil("connected") { tab.state == .connected }
        try? await Task.sleep(for: .milliseconds(100))
        let before = vault.get(SavedHost.self, id: saved.id)?.updatedAt
        manager.applyTheme("dracula", tabID: tab.id)
        await waitUntil("committed") { self.manager.pendingTheme(forHost: saved.id) == nil }
        XCTAssertEqual(vault.get(SavedHost.self, id: saved.id)?.updatedAt, before)
    }

    func testApplyThemeToADeletedHostTabFallsBackToAnOverride() async throws {
        let saved = host("Web")
        let tab = try manager.open(hostID: saved.id)
        try await vault.delete(SavedHost.self, id: saved.id)
        manager.applyTheme("dracula", tabID: tab.id)
        XCTAssertEqual(tab.themeOverrideID, "dracula")
        XCTAssertEqual(manager.themeChoice(tabID: tab.id), "dracula")
    }

    /// The panel's ring and the drawing agree: an override wins, as it does when drawing.
    func testOverrideWinsWhenTheHostComesBack() async throws {
        var saved = host("Web", themeID: "nord")
        let tab = try manager.open(hostID: saved.id)
        try await vault.delete(SavedHost.self, id: saved.id)
        manager.applyTheme("dracula", tabID: tab.id)
        saved.deleted = false
        vault.saveNow(saved) // restored, e.g. by sync
        XCTAssertNotNil(vault.get(SavedHost.self, id: saved.id))
        XCTAssertEqual(manager.themeChoice(tabID: tab.id), "dracula")
        // Choosing again from the panel goes to the host and drops the override.
        manager.themeSaveDelay = .milliseconds(10)
        manager.applyTheme("nord", tabID: tab.id)
        XCTAssertNil(tab.themeOverrideID)
        XCTAssertEqual(manager.themeChoice(tabID: tab.id), "nord")
    }

    // MARK: Windows

    func testTabsOpenInTheMainWindow() async {
        let a = quick("a")
        XCTAssertNil(a.windowID)
        XCTAssertEqual(order(nil), [a.id])
    }

    func testDuplicateInNewWindowOpensThereAndSelectsIt() async {
        let a = hostTab("a")
        let window = UUID()
        let copy = manager.duplicate(tabID: a.id, inWindow: window)
        XCTAssertEqual(copy?.windowID, window)
        XCTAssertEqual(order(window), copy.map { [$0.id] })
        XCTAssertEqual(order(nil), [a.id])
        XCTAssertEqual(manager.selectedTabID(inWindow: window), copy?.id)
        XCTAssertEqual(manager.selectedTabID(inWindow: nil), a.id)
        XCTAssertEqual(manager.selectedTabID, a.id) // the main window's
        await waitUntil("two sessions") { self.factory.sessions.count == 2 }
    }

    func testDuplicateInAWindowStaysInThatWindow() async throws {
        let a = quick("a")
        let window = UUID()
        let b = try XCTUnwrap(manager.duplicate(tabID: a.id, inWindow: window))
        let c = try XCTUnwrap(manager.duplicate(tabID: b.id))
        XCTAssertEqual(c.windowID, window)
        XCTAssertEqual(order(window), [b.id, c.id])
        XCTAssertEqual(manager.selectedTabID(inWindow: window), c.id)
        XCTAssertEqual(manager.selectedTabID(inWindow: nil), a.id)
    }

    func testSelectingATabOfAnotherWindowIsIgnored() async throws {
        let a = quick("a")
        let window = UUID()
        let b = try XCTUnwrap(manager.duplicate(tabID: a.id, inWindow: window))
        manager.select(tabID: a.id, inWindow: window)
        XCTAssertEqual(manager.selectedTabID(inWindow: window), b.id)
        manager.selectedTabID = b.id
        XCTAssertEqual(manager.selectedTabID, a.id)
        manager.select(tabID: nil, inWindow: nil)
        XCTAssertNil(manager.selectedTabID)
    }

    func testClosingATabSelectsANeighbourInItsOwnWindow() async throws {
        let a = quick("a")
        let window = UUID()
        let b = try XCTUnwrap(manager.duplicate(tabID: a.id, inWindow: window))
        let c = try XCTUnwrap(manager.duplicate(tabID: b.id))
        let d = quick("d")
        // global order a b c d; main window: a d; other: b c
        manager.select(tabID: b.id, inWindow: window)
        manager.close(tabID: b.id)
        XCTAssertEqual(manager.selectedTabID(inWindow: window), c.id)
        XCTAssertEqual(manager.selectedTabID(inWindow: nil), d.id)
        manager.close(tabID: d.id)
        XCTAssertEqual(manager.selectedTabID(inWindow: nil), a.id)
        XCTAssertEqual(manager.selectedTabID(inWindow: window), c.id)
        manager.close(tabID: c.id)
        XCTAssertNil(manager.selectedTabID(inWindow: window))
    }

    func testCloseWindowClosesItsTabsOnly() async throws {
        let a = hostTab("a")
        let window = UUID()
        let b = try XCTUnwrap(manager.duplicate(tabID: a.id, inWindow: window))
        _ = manager.duplicate(tabID: b.id)
        await waitUntil("sessions") { self.factory.sessions.count == 3 }
        manager.closeWindow(window)
        XCTAssertEqual(manager.tabs.map(\.id), [a.id])
        XCTAssertEqual(manager.selectedTabID, a.id)
        await waitUntil("closed") { self.factory.sessions[1].closed && self.factory.sessions[2].closed }
        XCTAssertFalse(factory.sessions[0].closed)
    }

    func testClosingTheMainWindowClosesItsTabsOnly() async throws {
        let a = hostTab("a")
        let window = UUID()
        let b = try XCTUnwrap(manager.duplicate(tabID: a.id, inWindow: window))
        await waitUntil("sessions") { self.factory.sessions.count == 2 }
        manager.closeWindow(nil)
        XCTAssertEqual(manager.tabs.map(\.id), [b.id])
        XCTAssertNil(manager.selectedTabID)
        XCTAssertEqual(manager.selectedTabID(inWindow: window), b.id)
        await waitUntil("closed") { self.factory.sessions[0].closed }
        XCTAssertFalse(factory.sessions[1].closed)
    }

    func testMoveTabIsWithinTheTabsWindow() async throws {
        let a = quick("a")
        let window = UUID()
        let b = try XCTUnwrap(manager.duplicate(tabID: a.id, inWindow: window))
        let c = quick("c")
        let d = quick("d")
        // main window: a c d
        manager.moveTab(id: d.id, toIndex: 0)
        XCTAssertEqual(order(nil), [d.id, a.id, c.id])
        XCTAssertEqual(order(window), [b.id])
        XCTAssertEqual(manager.tabs.count, 4)
    }

    func testNextTabStaysInItsWindow() async throws {
        let a = quick("a")
        let window = UUID()
        let b = try XCTUnwrap(manager.duplicate(tabID: a.id, inWindow: window))
        let c = quick("c")
        manager.selectedTabID = a.id
        manager.selectNextTab(inWindow: nil)
        XCTAssertEqual(manager.selectedTabID, c.id)
        manager.selectNextTab(inWindow: nil)
        XCTAssertEqual(manager.selectedTabID, a.id)
        manager.selectPreviousTab(inWindow: window)
        XCTAssertEqual(manager.selectedTabID(inWindow: window), b.id)
        XCTAssertEqual(manager.selectedTabID, a.id)
    }

    func testCloseAllClearsEverySelection() async throws {
        let a = quick("a")
        let window = UUID()
        _ = manager.duplicate(tabID: a.id, inWindow: window)
        await manager.closeAll()
        XCTAssertNil(manager.selectedTabID(inWindow: nil))
        XCTAssertNil(manager.selectedTabID(inWindow: window))
    }

    func testReconnectWaitingIsCountedAndRetriedPerWindow() async throws {
        let a = hostTab("a")
        let window = UUID()
        let b = try XCTUnwrap(manager.duplicate(tabID: a.id, inWindow: window))
        await waitUntil("connected") { a.state == .connected && b.state == .connected }
        factory.sessions[0].drop()
        factory.sessions[1].drop()
        await waitUntil("waiting") { self.manager.waitingForReconnectCount == 2 }
        XCTAssertEqual(manager.waitingForReconnectCount(inWindow: nil), 1)
        XCTAssertEqual(manager.waitingForReconnectCount(inWindow: window), 1)
        manager.reconnectWaitingNow(inWindow: window)
        await waitUntil("b reconnected") { b.state == .connected && b.autoReconnect == nil }
        guard case .waiting = a.autoReconnect else { return XCTFail("a: \(String(describing: a.autoReconnect))") }
        manager.stopAutoReconnect(tabID: a.id)
    }
}
