import XCTest
@testable import CoreModels

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

final class ModelsTests: XCTestCase {
    private func roundTrip<T: SyncableModel>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try CoreJSON.encoder.encode(value)
        let decoded = try CoreJSON.decoder.decode(T.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    func testEveryModelRoundTripsThroughJSON() throws {
        let id = UUID()
        let other = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        try roundTrip(HostGroup(id: id, name: "Prod", parentID: other, defaultIdentityID: other, defaultPort: 2222, defaultThemeID: "nord", updatedAt: date, deleted: true))
        try roundTrip(Host(id: id, label: "Docker", address: "10.0.0.1", port: 2200, groupID: other, tags: ["a", "b"], username: "root", identityID: other, password: "pw", sshKeyID: other, osBadge: .ubuntu, osBadgeIsManual: true, themeID: "dracula", startupSnippetID: other, lastConnectedAt: date, updatedAt: date, deleted: true))
        try roundTrip(Identity(id: id, label: "Me", username: "cory", password: "pw", sshKeyID: other, updatedAt: date, deleted: true))
        try roundTrip(SSHKey(id: id, label: "k", keyType: .rsa, publicKey: "pub", privateKey: "priv", passphrase: "pp", updatedAt: date, deleted: true))
        try roundTrip(Snippet(id: id, name: "n", script: "ls", package: "pkg", updatedAt: date, deleted: true))
        try roundTrip(KnownHost(id: id, hostPort: "h:22", keyType: "ssh-ed25519", fingerprintSHA256: "abc", firstSeen: date, updatedAt: date, deleted: true))
        try roundTrip(ConnectionLog(id: id, hostID: other, hostLabel: "Docker", username: "root", deviceName: "mini", startedAt: date, endedAt: date, saved: true, updatedAt: date, deleted: true))
        try roundTrip(ShellHistoryEntry(id: id, command: "ls", hostID: other, executedAt: date, updatedAt: date, deleted: true))
        try roundTrip(AISettings(id: id, provider: .anthropic, baseURL: "https://x", model: "m", apiKey: "k", updatedAt: date, deleted: true))
    }

    func testRecordTypesAreUniquePerModel() {
        let types: [SyncRecordType] = [
            Host.recordType, HostGroup.recordType, Identity.recordType, SSHKey.recordType,
            Snippet.recordType, KnownHost.recordType, ConnectionLog.recordType,
            ShellHistoryEntry.recordType, AISettings.recordType,
        ]
        XCTAssertEqual(Set(types).count, SyncRecordType.allCases.count)
    }

    func testHostDefaults() {
        let h = Host(label: "Docker", address: "192.168.50.10")
        XCTAssertNil(h.port)
        XCTAssertEqual(h.tags, [])
        XCTAssertFalse(h.deleted)
    }
}
