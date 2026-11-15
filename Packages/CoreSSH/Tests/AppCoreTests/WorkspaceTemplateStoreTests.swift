import XCTest
import CoreModels
import SSHCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

/// A session that never connects (templates only need tabs).
private final class IdleSession: TerminalSession, Sendable {
    let plan: ConnectionPlan
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation

    init(plan: ConnectionPlan) {
        self.plan = plan
        (events, continuation) = AsyncStream.makeStream()
    }

    func start(cols: Int, rows: Int) async {}
    func send(_ bytes: [UInt8]) async {}
    func resize(cols: Int, rows: Int) async {}
    func runCommand(_ command: String) async throws -> String { "" }
    func close() async {
        continuation.yield(.closed(.userClosed))
        continuation.finish()
    }
}

@MainActor
private final class Plans {
    var all: [ConnectionPlan] = []
}

/// Saved workspaces: the file, save/rename/delete, and opening a template.
@MainActor
final class WorkspaceTemplateStoreTests: XCTestCase {
    private var vault: LocalVault!
    private var manager: SessionManager!
    private var plans: Plans!
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("workspaces.json") }

    override func setUp() async throws {
        vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        let plans = Plans()
        self.plans = plans
        manager = SessionManager(vault: vault, knownHosts: KnownHostsStore(vault: vault),
                                 makeSession: { plan, _ in plans.all.append(plan); return IdleSession(plan: plan) },
                                 deviceName: "Test Mac", defaultUsername: "me", initialSizeTimeout: .zero)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wst-\(UUID())", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func host(_ label: String) -> SavedHost {
        vault.saveNow(SavedHost(label: label, address: "\(label.lowercased()).example", username: "root", password: "pw"))
    }

    /// A host pane (titled "web"), a quick connect pane below it, and a host pane on the right at 0.3.
    private func sampleWorkspace() throws -> (Workspace, SavedHost, SavedHost) {
        let a = host("A"), b = host("B")
        let ws = try manager.openWorkspace(hostIDs: [a.id, b.id], name: "Prod")
        let quick = manager.open(quickConnect: QuickConnectTarget(username: "u", host: "q.example", port: 2200))
        manager.addPane(tabID: quick.id, to: ws.id, beside: ws.paneIDs[0], at: .bottom)
        manager.setRatio(0.3, atPath: [], in: ws.id)
        manager.rename(tabID: ws.paneIDs[0], to: "web")
        manager.setViewMode(.focus, for: ws.id)
        return (ws, a, b)
    }

    // MARK: Store

    func testAMissingFileIsAnEmptyStore() async {
        XCTAssertEqual(WorkspaceTemplateStore(fileURL: fileURL).templates, [])
    }

    func testSaveWritesTheLayoutAndReadsBack() async throws {
        let (ws, a, b) = try sampleWorkspace()
        let store = WorkspaceTemplateStore(fileURL: fileURL)
        let template = try store.save(ws, sessions: manager)
        XCTAssertEqual(template.name, "Prod")
        XCTAssertEqual(template.viewMode, .focus)
        XCTAssertEqual(template.layout,
                       .split(.horizontal, ratio: 0.3,
                              .split(.vertical, ratio: 0.5,
                                     .pane(TemplatePane(hostID: a.id, quickConnect: nil, title: "web")),
                                     .pane(TemplatePane(hostID: nil, quickConnect: "u@q.example:2200", title: nil))),
                              .pane(TemplatePane(hostID: b.id))))
        XCTAssertEqual(store.templates, [template])
        XCTAssertEqual(WorkspaceTemplateStore(fileURL: fileURL).templates, [template])
        XCTAssertEqual(ws.templateID, template.id)
        XCTAssertFalse(ws.hasUnsavedChanges)
    }

    func testSavingAgainReplacesTheSameTemplate() async throws {
        let (ws, _, _) = try sampleWorkspace()
        let store = WorkspaceTemplateStore(fileURL: fileURL)
        let first = try store.save(ws, sessions: manager)
        ws.name = "Renamed"
        let second = try store.save(ws, sessions: manager)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.templates.map(\.name), ["Renamed"])
        // A second workspace is a second template.
        let other = try manager.openWorkspace(hostIDs: [host("C").id, host("D").id], name: nil)
        _ = try store.save(other, sessions: manager)
        XCTAssertEqual(WorkspaceTemplateStore(fileURL: fileURL).templates.map(\.name), ["Renamed", "Workspace"])
    }

    func testSavingAWorkspaceWhoseTemplateWasDeletedSavesItAgain() async throws {
        let (ws, _, _) = try sampleWorkspace()
        let store = WorkspaceTemplateStore(fileURL: fileURL)
        let template = try store.save(ws, sessions: manager)
        try store.delete(template.id)
        XCTAssertEqual(store.templates, [])
        let again = try store.save(ws, sessions: manager)
        XCTAssertEqual(again.id, template.id)
        XCTAssertEqual(store.templates.count, 1)
    }

    func testRenameAndDeletePersist() async throws {
        let (ws, _, _) = try sampleWorkspace()
        let store = WorkspaceTemplateStore(fileURL: fileURL)
        let template = try store.save(ws, sessions: manager)
        try store.rename(template.id, to: "  Staging ")
        XCTAssertEqual(store.templates.first?.name, "Staging")
        try store.rename(template.id, to: "   ") // ignored
        try store.rename(UUID(), to: "x") // ignored
        XCTAssertEqual(WorkspaceTemplateStore(fileURL: fileURL).templates.first?.name, "Staging")
        XCTAssertEqual(store.template(template.id)?.name, "Staging")
        try store.delete(UUID())
        try store.delete(template.id)
        XCTAssertEqual(WorkspaceTemplateStore(fileURL: fileURL).templates, [])
    }

    func testACorruptFileStartsEmptyAndIsKeptAside() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fileURL)
        let store = WorkspaceTemplateStore(fileURL: fileURL)
        XCTAssertEqual(store.templates, [])
        let (ws, _, _) = try sampleWorkspace()
        _ = try store.save(ws, sessions: manager)
        XCTAssertEqual(WorkspaceTemplateStore(fileURL: fileURL).templates.count, 1)
        let backup = fileURL.appendingPathExtension("corrupt")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not json")
    }

    func testAnUnreadableEntryIsSkippedAndRatiosAreClamped() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = UUID()
        let json = """
        {"version": 1, "templates": [
          {"id": "\(good.uuidString)", "name": "Good", "viewMode": "split", "savedAt": 0,
           "layout": {"split": {"axis": "vertical", "ratio": 5,
                                "first": {"pane": {"quickConnect": "a.example"}},
                                "second": {"pane": {"quickConnect": "b.example"}}}}},
          {"id": "nope", "name": "Bad"}
        ]}
        """
        try Data(json.utf8).write(to: fileURL)
        let store = WorkspaceTemplateStore(fileURL: fileURL)
        XCTAssertEqual(store.templates.map(\.name), ["Good"])
        XCTAssertEqual(store.templates.first?.layout,
                       .split(.vertical, ratio: 0.9, .pane(TemplatePane(quickConnect: "a.example")),
                              .pane(TemplatePane(quickConnect: "b.example"))))
    }

    func testQuickConnectText() async {
        XCTAssertEqual(WorkspaceTemplateStore.quickConnectText(QuickConnectTarget(username: "u", host: "h", port: 22)), "u@h:22")
        XCTAssertEqual(WorkspaceTemplateStore.quickConnectText(QuickConnectTarget(username: nil, host: "h", port: nil)), "h")
        let v6 = QuickConnectTarget(username: "u", host: "fe80::1", port: 2222)
        XCTAssertEqual(WorkspaceTemplateStore.quickConnectText(v6), "u@[fe80::1]:2222")
        XCTAssertEqual(QuickConnect.parse("u@[fe80::1]:2222"), v6)
    }

    // MARK: Opening

    func testOpenTemplateRestoresTheWorkspace() async throws {
        let (ws, a, b) = try sampleWorkspace()
        let store = WorkspaceTemplateStore(fileURL: fileURL)
        let template = try store.save(ws, sessions: manager)
        let before = plans.all.count

        let opened = try manager.openTemplate(template)
        XCTAssertFalse(opened === ws)
        XCTAssertEqual(opened.name, "Prod")
        XCTAssertEqual(opened.viewMode, .focus)
        XCTAssertEqual(opened.templateID, template.id)
        XCTAssertFalse(opened.hasUnsavedChanges)
        XCTAssertEqual(manager.selectedItem(inWindow: nil), .workspace(opened.id))
        guard case .split(.horizontal, 0.3, .split(.vertical, 0.5, .pane(let p1), .pane(let p2)), .pane(let p3)) = opened.root else {
            return XCTFail("\(opened.root)")
        }
        let tabs = [p1, p2, p3].map { id in manager.tabs.first { $0.id == id }! }
        XCTAssertEqual(tabs[0].savedHostID, a.id)
        XCTAssertEqual(tabs[0].displayTitle, "web")
        XCTAssertEqual(tabs[1].quickConnectTarget, QuickConnectTarget(username: "u", host: "q.example", port: 2200))
        XCTAssertEqual(tabs[2].savedHostID, b.id)
        XCTAssertEqual(manager.strip(inWindow: nil), [.workspace(ws.id), .workspace(opened.id)])
        // The two host panes start connecting (the quick connect one asks for a password first).
        XCTAssertEqual(plans.all.count - before, 2)
        XCTAssertEqual(tabs[1].state, .awaitingPassword(prompt: "Password for u@q.example"))
        // Saved again from the reopened workspace: the same template, unchanged layout.
        XCTAssertEqual(try store.save(opened, sessions: manager).layout, template.layout)
    }

    func testRenamingAnOpenWorkspaceRenamesItsSavedCopyWithoutMarkingItUnsaved() async throws {
        let (ws, _, _) = try sampleWorkspace()
        let store = WorkspaceTemplateStore(fileURL: fileURL)
        let template = try store.save(ws, sessions: manager)
        XCTAssertFalse(ws.hasUnsavedChanges)

        try store.rename(ws, to: "  Staging ", sessions: manager)
        XCTAssertEqual(ws.name, "Staging")
        XCTAssertEqual(store.templates.first { $0.id == template.id }?.name, "Staging")
        XCTAssertFalse(ws.hasUnsavedChanges, "the saved copy has the new name too")
        XCTAssertEqual(WorkspaceTemplateStore(fileURL: fileURL).templates.first?.name, "Staging", "written to the file")

        // Other unsaved changes stay unsaved.
        manager.setViewMode(.split, for: ws.id)
        XCTAssertTrue(ws.hasUnsavedChanges)
        try store.rename(ws, to: "Prod 2", sessions: manager)
        XCTAssertTrue(ws.hasUnsavedChanges)
        XCTAssertEqual(store.templates.first?.name, "Prod 2")
    }

    func testHasSavedCopyOnlyWhileItsTemplateExists() async throws {
        let (ws, _, _) = try sampleWorkspace()
        let store = WorkspaceTemplateStore(fileURL: fileURL)
        XCTAssertFalse(store.hasSavedCopy(of: ws), "never saved: the first save asks for a name")
        let template = try store.save(ws, sessions: manager)
        XCTAssertTrue(store.hasSavedCopy(of: ws))
        try store.delete(template.id)
        XCTAssertFalse(store.hasSavedCopy(of: ws), "its template was deleted: saving makes a new one")
    }

    func testRenamingANeverSavedWorkspaceOnlyRenamesIt() async throws {
        let (ws, _, _) = try sampleWorkspace()
        let store = WorkspaceTemplateStore(fileURL: fileURL)
        try store.rename(ws, to: "Lab", sessions: manager)
        XCTAssertEqual(ws.name, "Lab")
        XCTAssertTrue(store.templates.isEmpty)
        XCTAssertTrue(ws.hasUnsavedChanges)
    }

    func testOpenTemplateWithAMissingHostOpensItDisconnected() async throws {
        let a = host("A")
        let template = WorkspaceTemplate(id: UUID(), name: "W",
                                         layout: .split(.horizontal, ratio: 0.5, .pane(TemplatePane(hostID: a.id)),
                                                        .pane(TemplatePane(hostID: UUID(), title: "gone"))),
                                         viewMode: .split, savedAt: Date())
        let opened = try manager.openTemplate(template)
        let missing = manager.tabs.first { $0.id == opened.paneIDs[1] }!
        guard case .disconnected(let message?) = missing.state else { return XCTFail("\(missing.state)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(missing.displayTitle, "gone")
        XCTAssertEqual(opened.status(of: missing.id), .failed)
        XCTAssertFalse(opened.hasUnsavedChanges)
    }

    func testOpenTemplateSkipsUnusablePanesAndNeedsTwo() async throws {
        let a = host("A"), b = host("B")
        let three = WorkspaceTemplate(id: UUID(), name: "W",
                                      layout: .split(.vertical, ratio: 0.5, .pane(TemplatePane(hostID: a.id)),
                                                     .split(.horizontal, ratio: 0.5, .pane(TemplatePane(quickConnect: "-x")),
                                                            .pane(TemplatePane(hostID: b.id)))),
                                      viewMode: .split, savedAt: Date())
        let opened = try manager.openTemplate(three)
        XCTAssertEqual(opened.paneIDs.count, 2)
        XCTAssertTrue(opened.hasUnsavedChanges) // it no longer matches the template
        let one = WorkspaceTemplate(id: UUID(), name: "W",
                                    layout: .split(.vertical, ratio: 0.5, .pane(TemplatePane(hostID: a.id)), .pane(TemplatePane())),
                                    viewMode: .split, savedAt: Date())
        let count = manager.tabs.count
        XCTAssertThrowsError(try manager.openTemplate(one)) { XCTAssertEqual($0 as? WorkspaceError, .notEnoughPanes) }
        XCTAssertEqual(manager.tabs.count, count)
    }
}
