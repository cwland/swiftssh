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
        try roundTrip(Host(id: id, label: "Docker", address: "10.0.0.1", port: 2200, groupID: other, tags: ["a", "b"], username: "root", identityID: other, password: "pw", sshKeyID: other, osBadge: .raspbian, osBadgeIsManual: true, themeID: "dracula", startupSnippetID: other, lastConnectedAt: date, updatedAt: date, deleted: true))
        try roundTrip(Identity(id: id, label: "Me", username: "cory", password: "pw", sshKeyID: other, updatedAt: date, deleted: true))
        try roundTrip(SSHKey(id: id, label: "k", keyType: .rsa, publicKey: "pub", privateKey: "priv", passphrase: "pp", updatedAt: date, deleted: true))
        try roundTrip(Snippet(id: id, name: "n", script: "ls", package: "pkg", targetHostIDs: [other, id], updatedAt: date, deleted: true))
        try roundTrip(KnownHost(id: id, hostPort: "h:22", keyType: "ssh-ed25519", fingerprintSHA256: "abc", firstSeen: date, updatedAt: date, deleted: true))
        try roundTrip(ConnectionLog(id: id, hostID: other, hostLabel: "Docker", username: "root", deviceName: "mini", startedAt: date, endedAt: date, saved: true, updatedAt: date, deleted: true))
        try roundTrip(ShellHistoryEntry(id: id, command: "ls", hostID: other, executedAt: date, updatedAt: date, deleted: true))
        try roundTrip(AISettings(id: id, provider: .anthropic, baseURL: "https://x", model: "m", apiKey: "k", updatedAt: date, deleted: true))
        try roundTrip(TerminalHighlightRules(id: id, rules: [
            HighlightRule(id: other, pattern: "prod\\d+", isRegularExpression: true, matchCase: true, color: "#E5484D",
                          isBold: true, isEnabled: false),
        ], updatedAt: date, deleted: true))
    }

    func testRecordTypesAreUniquePerModel() {
        let types: [SyncRecordType] = [
            Host.recordType, HostGroup.recordType, Identity.recordType, SSHKey.recordType,
            Snippet.recordType, KnownHost.recordType, ConnectionLog.recordType,
            ShellHistoryEntry.recordType, AISettings.recordType,
        ]
        XCTAssertEqual(Set(types).count, SyncRecordType.allCases.count)
        // The one deliberate exception: the highlight rules share the settings slot, so app versions
        // before v0.11 never see an unknown record type (see `TerminalHighlightRules`).
        XCTAssertEqual(TerminalHighlightRules.recordType, .aiSettings)
    }

    func testHighlightRulesRecordIsASingleton() {
        XCTAssertEqual(TerminalHighlightRules(rules: []).id, TerminalHighlightRules.singletonID)
        XCTAssertEqual(TerminalHighlightRules.singletonID.uuidString, "6C1B2E1A-0B5D-4E0C-9D6A-48494C495445")
    }

    func testHighlightRuleDecodesLeniently() throws {
        let json = #"{"pattern":"prod","isBold":"yes","future":1}"#
        let rule = try CoreJSON.decoder.decode(HighlightRule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.pattern, "prod")
        XCTAssertFalse(rule.isRegularExpression)
        XCTAssertFalse(rule.matchCase)
        XCTAssertFalse(rule.isBold)
        XCTAssertTrue(rule.isEnabled)
        XCTAssertEqual(rule.color, "")
        XCTAssertThrowsError(try CoreJSON.decoder.decode(HighlightRule.self, from: Data(##"{"color":"#FFFFFF"}"##.utf8)))
    }

    func testHighlightRulesAndAISettingsNeverDecodeAsEachOther() throws {
        let rules = try CoreJSON.encoder.encode(TerminalHighlightRules(rules: [HighlightRule(pattern: "x", color: "#000000")]))
        XCTAssertThrowsError(try CoreJSON.decoder.decode(AISettings.self, from: rules))
        let ai = try CoreJSON.encoder.encode(AISettings(baseURL: "https://x", model: "m"))
        XCTAssertThrowsError(try CoreJSON.decoder.decode(TerminalHighlightRules.self, from: ai))
    }

    func testHostDefaults() {
        let h = Host(label: "Docker", address: "192.168.50.10")
        XCTAssertNil(h.port)
        XCTAssertEqual(h.tags, [])
        XCTAssertFalse(h.deleted)
    }

    func testOldVaultHostWithoutFlagDecodes() throws {
        var h = Host(label: "Old", address: "10.0.0.2", updatedAt: Date(timeIntervalSince1970: 1_700_000_000.123))
        h.useSystemSSH = true
        let data = try CoreJSON.encoder.encode(h)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["useSystemSSH"] as? Bool, true)
        object.removeValue(forKey: "useSystemSSH")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try CoreJSON.decoder.decode(Host.self, from: old)
        XCTAssertNil(decoded.useSystemSSH)
        XCTAssertEqual(decoded.label, "Old")
        try roundTrip(h)
    }

    func testOldKnownHostWithoutPublicKeyDecodes() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let k = KnownHost(hostPort: "h", keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:x",
                          publicKeyBase64: "AAAA", firstSeen: date, updatedAt: date)
        let data = try CoreJSON.encoder.encode(k)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["publicKeyBase64"] as? String, "AAAA")
        object.removeValue(forKey: "publicKeyBase64")
        let decoded = try CoreJSON.decoder.decode(KnownHost.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.publicKeyBase64)
        XCTAssertEqual(decoded.hostPort, "h")
        try roundTrip(k)
    }

    func testOldSnippetWithoutTargetsDecodes() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let target = UUID()
        let s = Snippet(name: "up", script: "apt update", package: "ops", targetHostIDs: [target], updatedAt: date)
        let data = try CoreJSON.encoder.encode(s)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["targetHostIDs"] as? [String], [target.uuidString])
        object.removeValue(forKey: "targetHostIDs")
        let decoded = try CoreJSON.decoder.decode(Snippet.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.targetHostIDs)
        XCTAssertEqual(decoded.name, "up")
        XCTAssertEqual(decoded.package, "ops")
        XCTAssertNil(Snippet(name: "n", script: "ls").targetHostIDs, "defaults to none")
        try roundTrip(s)
    }
}
