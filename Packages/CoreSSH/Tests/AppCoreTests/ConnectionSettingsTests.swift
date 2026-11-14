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

    func testDisplayOrderAndCopy() async {
        XCTAssertEqual(DroppedConnectionDetection.allCases, [.fast, .normal, .relaxed, .off])
        XCTAssertEqual(DroppedConnectionDetection.allCases.map(\.title), ["Fast", "Normal", "Relaxed", "Off"])
        XCTAssertEqual(DroppedConnectionDetection.fast.detail,
                       "Checks every 15 seconds. A dropped connection shows up in about 30–45 seconds.")
        XCTAssertEqual(DroppedConnectionDetection.normal.detail,
                       "Checks every 30 seconds. A dropped connection shows up in about 1½–2 minutes. Recommended.")
        XCTAssertEqual(DroppedConnectionDetection.relaxed.detail,
                       "Checks every 60 seconds. A dropped connection shows up in about 5–6 minutes. For shaky Wi-Fi.")
        XCTAssertEqual(DroppedConnectionDetection.off.detail,
                       "Never checks. A dead connection can go unnoticed for a long time.")
    }

    func testPolicies() async {
        XCTAssertEqual(DroppedConnectionDetection.fast.policy, .fast)
        XCTAssertEqual(DroppedConnectionDetection.normal.policy, .normal)
        XCTAssertEqual(DroppedConnectionDetection.relaxed.policy, .relaxed)
        XCTAssertEqual(DroppedConnectionDetection.off.policy, .off)
    }

    func testDefaultsToNormalWhenNothingStored() async {
        XCTAssertEqual(ConnectionSettings(defaults: defaults).detection, .normal)
    }

    func testUnknownStoredValueIsNormal() async {
        defaults.set("paranoid", forKey: "connection.droppedConnectionDetection")
        XCTAssertEqual(ConnectionSettings(defaults: defaults).detection, .normal)
        defaults.set(42, forKey: "connection.droppedConnectionDetection")
        XCTAssertEqual(ConnectionSettings(defaults: defaults).detection, .normal)
    }

    func testChangesPersist() async {
        let settings = ConnectionSettings(defaults: defaults)
        settings.detection = .relaxed
        XCTAssertEqual(defaults.string(forKey: "connection.droppedConnectionDetection"), "relaxed")
        XCTAssertEqual(ConnectionSettings(defaults: defaults).detection, .relaxed)
        settings.detection = .off
        XCTAssertEqual(ConnectionSettings(defaults: defaults).detection, .off)
    }
}
