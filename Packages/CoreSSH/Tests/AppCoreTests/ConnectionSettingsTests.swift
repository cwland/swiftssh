import XCTest
import SSHCore
@testable import AppCore

@MainActor
final class ConnectionSettingsTests: XCTestCase {
    private let suite = "ConnectionSettingsTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// One fixed policy (v0.10): a probe every 5 seconds, dead after 2 missed (about 10–15 seconds),
    /// with on-demand checks for typing, network changes and wake on top.
    func testKeepAliveIsFixedAtFiveSecondsTwice() async {
        XCTAssertEqual(KeepAlivePolicy.standard, KeepAlivePolicy(interval: .seconds(5), maxUnanswered: 2))
        XCTAssertEqual(ConnectionSettings(defaults: defaults).keepAlivePolicy, .standard)
    }

    func testAnOldDetectionChoiceIsIgnored() async {
        defaults.set("relaxed", forKey: "connection.droppedConnectionDetection")
        XCTAssertEqual(ConnectionSettings(defaults: defaults).keepAlivePolicy, .standard)
    }

    func testAutoReconnectDefaultsToOnWhenNothingStored() async {
        XCTAssertNil(defaults.object(forKey: "connection.autoReconnect"))
        XCTAssertTrue(ConnectionSettings(defaults: defaults).autoReconnect)
    }

    func testAutoReconnectChangesPersist() async {
        let settings = ConnectionSettings(defaults: defaults)
        settings.autoReconnect = false
        XCTAssertEqual(defaults.object(forKey: "connection.autoReconnect") as? Bool, false)
        XCTAssertFalse(ConnectionSettings(defaults: defaults).autoReconnect)
        settings.autoReconnect = true
        XCTAssertEqual(defaults.object(forKey: "connection.autoReconnect") as? Bool, true)
        XCTAssertTrue(ConnectionSettings(defaults: defaults).autoReconnect)
    }

    func testAskToSaveWorkspacesDefaultsOnAndPersists() async {
        let settings = ConnectionSettings(defaults: defaults)
        XCTAssertTrue(settings.askToSaveWorkspaces)
        settings.askToSaveWorkspaces = false
        XCTAssertFalse(ConnectionSettings(defaults: defaults).askToSaveWorkspaces)
    }
}
