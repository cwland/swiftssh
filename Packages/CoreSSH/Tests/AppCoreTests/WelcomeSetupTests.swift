import XCTest
import CoreModels
@testable import AppCore

final class WelcomeSetupTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "welcome-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    func testShowsOnANewMacOnly() async {
        let settings = WelcomeSettings(defaults: defaults)
        XCTAssertFalse(settings.dontShowAgain)
        // A clean second Mac: nothing in the vault, no sync server.
        XCTAssertTrue(WelcomeSetup.shouldShowAtLaunch(liveCounts: [:], syncServerConfigured: false, settings: settings))
        // Cory's MacBook: hosts and keys, and sync set up.
        XCTAssertFalse(WelcomeSetup.shouldShowAtLaunch(liveCounts: [.host: 12, .sshKey: 2], syncServerConfigured: true,
                                                       settings: settings))
        // Data but no sync, or sync but no data yet: an existing user either way.
        XCTAssertFalse(WelcomeSetup.shouldShowAtLaunch(liveCounts: [.host: 1], syncServerConfigured: false, settings: settings))
        XCTAssertFalse(WelcomeSetup.shouldShowAtLaunch(liveCounts: [:], syncServerConfigured: true, settings: settings))
        // Any record counts, even only known hosts or a connection log.
        XCTAssertFalse(WelcomeSetup.shouldShowAtLaunch(liveCounts: [.knownHost: 1], syncServerConfigured: false, settings: settings))
        XCTAssertTrue(WelcomeSetup.shouldShowAtLaunch(liveCounts: [.host: 0], syncServerConfigured: false, settings: settings))
    }

    @MainActor
    func testDontShowAgainIsRemembered() async {
        let settings = WelcomeSettings(defaults: defaults)
        settings.dontShowAgain = true
        XCTAssertFalse(WelcomeSetup.shouldShowAtLaunch(liveCounts: [:], syncServerConfigured: false, settings: settings))
        XCTAssertTrue(WelcomeSettings(defaults: defaults).dontShowAgain)
        XCTAssertEqual(defaults.object(forKey: "welcome.dontShowAgain") as? Bool, true)
    }

    @MainActor
    func testEmptyVaultCountsFromARealVault() async throws {
        let vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        XCTAssertTrue(WelcomeSetup.vaultIsEmpty(vault.liveCounts()))
        let host = vault.saveNow(CoreModels.Host(label: "Web", address: "web.example", username: "root"))
        XCTAssertFalse(WelcomeSetup.vaultIsEmpty(vault.liveCounts()))
        try await vault.delete(CoreModels.Host.self, id: host.id)
        XCTAssertTrue(WelcomeSetup.vaultIsEmpty(vault.liveCounts()))
    }

    func testSteps() {
        XCTAssertEqual(WelcomeSetup.Step.allCases, [.sync, .onePassword, .done])
        XCTAssertEqual(WelcomeSetup.Step.sync.next, .onePassword)
        XCTAssertEqual(WelcomeSetup.Step.onePassword.next, .done)
        XCTAssertNil(WelcomeSetup.Step.done.next)
        XCTAssertNil(WelcomeSetup.Step.sync.previous)
        XCTAssertEqual(WelcomeSetup.Step.done.previous, .onePassword)
        XCTAssertEqual(WelcomeSetup.Step.onePassword.progress, "Step 2 of 3")
        XCTAssertEqual(WelcomeSetup.Step.sync.title, "Join your sync server")
    }
}
