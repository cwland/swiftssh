import XCTest
import CoreModels
import SyncCore
@testable import AppCore

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

final class JoinDeduplicatorTests: XCTestCase {
    private func records(_ models: [any SyncableModel], device: String) throws -> [PlainRecord] {
        try models.map { try record($0, device: device) }
    }

    private func record<M: SyncableModel>(_ model: M, device: String) throws -> PlainRecord {
        try PlainRecord(model, deviceID: device)
    }

    private func updated<M: SyncableModel>(_ plan: JoinDeduplicator.Plan, _: M.Type, id: UUID) throws -> M? {
        try plan.updated.first { $0.id == id }?.decode(M.self)
    }

    func testHostMatchesOnLowercasedAddressPortDefault22AndUsername() throws {
        let vaultHost = Host(label: "NAS", address: "nas.lan", port: 22, username: "cory")
        let dup = Host(label: "my nas", address: " NAS.lan ", port: nil, username: "cory")
        let otherPort = Host(label: "nas ssh2", address: "nas.lan", port: 2222, username: "cory")
        let otherUser = Host(label: "nas root", address: "nas.lan", username: "root")
        let plan = JoinDeduplicator.plan(
            local: try records([dup, otherPort, otherUser], device: "mini"),
            vault: try records([vaultHost], device: "mbp"))
        XCTAssertEqual(plan.removedIDs, [dup.id])
        XCTAssertEqual(plan.idMap, [dup.id: vaultHost.id])
        XCTAssertTrue(plan.updated.isEmpty)
    }

    func testIdentityMatchesOnLabelAndUsernameAndKeyOnPublicKeyIgnoringComment() throws {
        let vaultKey = SSHKey(label: "main", keyType: .ed25519, publicKey: "ssh-ed25519 AAAAC3Nz cory@mbp", privateKey: "x")
        let localKey = SSHKey(label: "mine", keyType: .ed25519, publicKey: "ssh-ed25519 AAAAC3Nz cory@mini\n", privateKey: "x")
        let otherKey = SSHKey(label: "other", keyType: .ed25519, publicKey: "ssh-ed25519 BBBB cory@mini", privateKey: "y")
        let vaultIdentity = Identity(label: "Home", username: "cory")
        let localIdentity = Identity(label: "Home", username: "cory", password: "p")
        let otherIdentity = Identity(label: "Home", username: "root")
        let plan = JoinDeduplicator.plan(
            local: try records([localKey, otherKey, localIdentity, otherIdentity], device: "mini"),
            vault: try records([vaultKey, vaultIdentity], device: "mbp"))
        XCTAssertEqual(plan.removedIDs, [localKey.id, localIdentity.id])
        XCTAssertEqual(plan.idMap, [localKey.id: vaultKey.id, localIdentity.id: vaultIdentity.id])
    }

    func testReferencesToDroppedDuplicatesArePointedAtTheVaultIDs() throws {
        let vaultKey = SSHKey(label: "k", keyType: .ed25519, publicKey: "ssh-ed25519 AAAA", privateKey: "x")
        let vaultIdentity = Identity(label: "Home", username: "cory")
        let vaultHost = Host(label: "nas", address: "nas.lan", username: "cory")
        let localKey = SSHKey(label: "k", keyType: .ed25519, publicKey: "ssh-ed25519 AAAA", privateKey: "x")
        let localIdentity = Identity(label: "Home", username: "cory")
        let localHost = Host(label: "nas", address: "nas.lan", username: "cory")
        let keptIdentity = Identity(label: "Work", username: "cory", sshKeyID: localKey.id)
        let keptHost = Host(label: "pi", address: "pi.lan", identityID: localIdentity.id, sshKeyID: localKey.id)
        let group = HostGroup(name: "Lab", defaultIdentityID: localIdentity.id)
        let log = ConnectionLog(hostID: localHost.id, hostLabel: "nas", username: "cory", deviceName: "mini")
        let history = ShellHistoryEntry(command: "ls", hostID: localHost.id)
        let untouched = Snippet(name: "s", script: "ls")

        let plan = JoinDeduplicator.plan(
            local: try records([localKey, localIdentity, localHost, keptIdentity, keptHost, group, log, history,
                                untouched], device: "mini"),
            vault: try records([vaultKey, vaultIdentity, vaultHost], device: "mbp"))

        XCTAssertEqual(plan.removedIDs, [localKey.id, localIdentity.id, localHost.id])
        XCTAssertEqual(Set(plan.updated.map(\.id)), [keptIdentity.id, keptHost.id, group.id, log.id, history.id])
        XCTAssertEqual(try updated(plan, Identity.self, id: keptIdentity.id)?.sshKeyID, vaultKey.id)
        let host = try XCTUnwrap(try updated(plan, Host.self, id: keptHost.id))
        XCTAssertEqual(host.identityID, vaultIdentity.id)
        XCTAssertEqual(host.sshKeyID, vaultKey.id)
        XCTAssertEqual(host.label, "pi")
        XCTAssertEqual(try updated(plan, HostGroup.self, id: group.id)?.defaultIdentityID, vaultIdentity.id)
        XCTAssertEqual(try updated(plan, ConnectionLog.self, id: log.id)?.hostID, vaultHost.id)
        XCTAssertEqual(try updated(plan, ShellHistoryEntry.self, id: history.id)?.hostID, vaultHost.id)
    }

    func testDeletedRecordsAndSameIDsNeverMatch() throws {
        let tombstone = Host(label: "nas", address: "nas.lan", deleted: true)
        let localHost = Host(label: "nas", address: "nas.lan")
        let shared = Host(label: "pi", address: "pi.lan")
        let deletedLocal = Host(label: "pi", address: "pi.lan", deleted: true)
        let plan = JoinDeduplicator.plan(
            local: try records([localHost, shared, deletedLocal], device: "mini"),
            vault: try records([tombstone, shared], device: "mbp"))
        XCTAssertTrue(plan.removedIDs.isEmpty)
        XCTAssertTrue(plan.idMap.isEmpty)
    }

    func testRestampSetsUpdatedAtInThePayload() throws {
        let host = Host(label: "pi", address: "pi.lan", updatedAt: Date(timeIntervalSince1970: 1))
        let date = Date(timeIntervalSince1970: 1_000)
        let payload = try JoinDeduplicator.restamp(try record(host, device: "d").payload, type: .host, updatedAt: date)
        let decoded = try CoreJSON.decoder.decode(Host.self, from: payload)
        XCTAssertEqual(decoded.updatedAt, date)
        XCTAssertEqual(decoded.label, "pi")
    }

    // Fields a newer app version wrote survive the join's rewrites (forward-compatible sync).

    private func withExtra(_ record: PlainRecord) throws -> PlainRecord {
        var record = record
        var json = try JSONSerialization.jsonObject(with: record.payload) as! [String: Any]
        json["futureColor"] = "teal"
        record.payload = try JSONSerialization.data(withJSONObject: json)
        return record
    }

    private func futureColor(_ payload: Data) throws -> String? {
        (try JSONSerialization.jsonObject(with: payload) as! [String: Any])["futureColor"] as? String
    }

    func testRestampKeepsUnknownFields() throws {
        let host = Host(label: "pi", address: "pi.lan")
        let payload = try JoinDeduplicator.restamp(try withExtra(record(host, device: "d")).payload,
                                                   type: .host, updatedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(try futureColor(payload), "teal")
        XCTAssertEqual(try CoreJSON.decoder.decode(Host.self, from: payload).updatedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testRepointKeepsUnknownFields() throws {
        let localKey = SSHKey(label: "k", keyType: .ed25519, publicKey: "ssh-ed25519 AAAA k", privateKey: "x")
        let vaultKey = SSHKey(label: "k", keyType: .ed25519, publicKey: "ssh-ed25519 AAAA k", privateKey: "x")
        var host = Host(label: "pi", address: "pi.lan")
        host.sshKeyID = localKey.id
        let plan = JoinDeduplicator.plan(
            local: try records([localKey], device: "mini") + [try withExtra(record(host, device: "mini"))],
            vault: try records([vaultKey], device: "mbp"))
        let updated = try XCTUnwrap(plan.updated.first { $0.id == host.id })
        XCTAssertEqual(try updated.decode(Host.self).sshKeyID, vaultKey.id)
        XCTAssertEqual(try futureColor(updated.payload), "teal")
    }

    /// The forward-compatible merge treats a model's stored property names as its JSON keys; a model
    /// with custom CodingKeys would break that (cleared fields would come back). Guarded here.
    func testEveryModelsJSONKeysAreItsPropertyNames() throws {
        func check<M: SyncableModel>(_ model: M) throws {
            let keys = Set((try JSONSerialization.jsonObject(with: CoreJSON.encoder.encode(model)) as! [String: Any]).keys)
            let labels = Set(Mirror(reflecting: model).children.compactMap(\.label))
            XCTAssertTrue(keys.isSubset(of: labels), "\(M.self): \(keys.subtracting(labels))")
        }
        try check(Host(label: "a", address: "b"))
        try check(HostGroup(name: "g"))
        try check(Identity(label: "i", username: "u"))
        try check(SSHKey(label: "k", keyType: .ed25519, publicKey: "p", privateKey: "x"))
        try check(Snippet(name: "s", script: "x"))
    }
}
