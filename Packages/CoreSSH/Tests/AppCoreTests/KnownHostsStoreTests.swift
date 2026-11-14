import XCTest
import CoreModels
import SSHCore
@testable import AppCore

@MainActor
final class KnownHostsStoreTests: XCTestCase {
    private func makeStore() async throws -> (KnownHostsStore, LocalVault) {
        let vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        return (KnownHostsStore(vault: vault), vault)
    }

    private func candidate(host: String = "a.example", port: Int = 22, type: String = "ssh-ed25519",
                           blob: [UInt8] = [1, 2, 3]) -> HostKeyCandidate {
        HostKeyCandidate(host: host, port: port, keyType: type, publicKeyBlob: wireBlob(type, blob))
    }

    /// SSH wire format: uint32 length + key type string, then key material.
    private func wireBlob(_ type: String, _ material: [UInt8]) -> Data {
        let t = Array(type.utf8)
        let n = t.count
        return Data([UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + t + material)
    }

    private final class Recorder: @unchecked Sendable {
        var asked: [(HostKeyCandidate, HostKeyCheck)] = []
    }

    private func evaluator(_ store: KnownHostsStore, _ rec: Recorder,
                           answer: HostKeyDecision) -> PromptingHostKeyEvaluator {
        PromptingHostKeyEvaluator(store: store) { c, check in
            rec.asked.append((c, check))
            return answer
        }
    }

    func testUnknownKeyAsksAndTrustStoresRecord() async throws {
        let (store, vault) = try await makeStore()
        let rec = Recorder()
        let c = candidate()
        let decision = await evaluator(store, rec, answer: .trusted).evaluate(c)
        XCTAssertEqual(decision, .trusted)
        XCTAssertEqual(rec.asked.count, 1)
        XCTAssertEqual(rec.asked[0].1, .unknown)
        XCTAssertEqual(store.check(c), .known)
        let records = vault.all(KnownHost.self)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].hostPort, "a.example")
        XCTAssertEqual(records[0].fingerprintSHA256, c.fingerprint)
        XCTAssertEqual(records[0].publicKeyBase64, candidate(blob: [1, 2, 3]).publicKeyBlob.base64EncodedString())
    }

    func testUnknownKeyRejectedStoresNothing() async throws {
        let (store, vault) = try await makeStore()
        let rec = Recorder()
        let decision = await evaluator(store, rec, answer: .rejected).evaluate(candidate())
        XCTAssertEqual(decision, .rejected)
        XCTAssertTrue(vault.all(KnownHost.self).isEmpty)
    }

    func testKnownKeyIsTrustedWithoutAsking() async throws {
        let (store, _) = try await makeStore()
        store.trust(candidate())
        let rec = Recorder()
        let decision = await evaluator(store, rec, answer: .rejected).evaluate(candidate())
        XCTAssertEqual(decision, .trusted)
        XCTAssertTrue(rec.asked.isEmpty)
    }

    func testChangedKeyAsksWithPreviousFingerprintAndRejectionKeepsOldRecord() async throws {
        let (store, vault) = try await makeStore()
        let old = candidate(blob: [1])
        store.trust(old)
        let new = candidate(blob: [9])
        let rec = Recorder()
        let decision = await evaluator(store, rec, answer: .rejected).evaluate(new)
        XCTAssertEqual(decision, .rejected)
        XCTAssertEqual(rec.asked.count, 1)
        XCTAssertEqual(rec.asked[0].1, .changed(previousFingerprint: old.fingerprint))
        XCTAssertEqual(store.check(old), .known)
        XCTAssertEqual(vault.all(KnownHost.self).count, 1)
    }

    func testChangedKeyTrustedReplacesOldRecord() async throws {
        let (store, vault) = try await makeStore()
        let old = candidate(blob: [1])
        store.trust(old)
        let new = candidate(blob: [9])
        let decision = await evaluator(store, Recorder(), answer: .trusted).evaluate(new)
        XCTAssertEqual(decision, .trusted)
        XCTAssertEqual(store.check(new), .known)
        XCTAssertEqual(store.check(old), .changed(previousFingerprint: new.fingerprint))
        XCTAssertEqual(vault.all(KnownHost.self).count, 1)
    }

    func testReplaceTombstonesOldRecords() async throws {
        let (store, vault) = try await makeStore()
        store.trust(candidate(type: "ssh-ed25519", blob: [1]))
        store.trust(candidate(type: "ecdsa-sha2-nistp256", blob: [2]))
        store.trust(candidate(host: "other.example", blob: [3]))
        XCTAssertEqual(vault.all(KnownHost.self).count, 3)
        let new = candidate(type: "ssh-ed25519", blob: [7])
        store.replace(new)
        let live = vault.all(KnownHost.self)
        XCTAssertEqual(Set(live.map(\.hostPort)), ["a.example", "other.example"])
        XCTAssertEqual(live.filter { $0.hostPort == "a.example" }.map(\.fingerprintSHA256), [new.fingerprint])
        XCTAssertEqual(store.check(candidate(host: "other.example", blob: [3])), .known)
        await vault.flush()
    }

    func testDifferentKeyTypeForSameHostIsNewKeyTypeNotChanged() async throws {
        let (store, _) = try await makeStore()
        store.trust(candidate(type: "ssh-ed25519", blob: [1]))
        XCTAssertEqual(store.check(candidate(type: "ssh-rsa", blob: [2])),
                       .newKeyType(knownKeyTypes: ["ssh-ed25519"]))
        XCTAssertEqual(store.check(candidate(host: "other.example")), .unknown)
        XCTAssertEqual(store.check(candidate(type: "ssh-ed25519", blob: [3])).isChanged, true)
    }

    func testChangedUsesMostRecentRecordOfSameType() async throws {
        let (store, vault) = try await makeStore()
        let c1 = candidate(blob: [1]), c2 = candidate(blob: [2])
        // Duplicate live same-type records can only arrive via sync; `trust` refuses to create them.
        for c in [c1, c2] {
            vault.saveNow(KnownHost(hostPort: c.hostPort, keyType: c.keyType, fingerprintSHA256: c.fingerprint,
                                    publicKeyBase64: c.publicKeyBlob.base64EncodedString()))
        }
        XCTAssertEqual(vault.all(KnownHost.self).count, 2)
        XCTAssertEqual(store.check(candidate(blob: [3])), .changed(previousFingerprint: c2.fingerprint))
    }

    func testTrustTwiceDoesNotDuplicate() async throws {
        let (store, vault) = try await makeStore()
        store.trust(candidate())
        store.trust(candidate())
        XCTAssertEqual(vault.all(KnownHost.self).count, 1)
    }

    func testDifferentPortsAreDifferentHosts() async throws {
        let (store, _) = try await makeStore()
        store.trust(candidate(port: 22))
        XCTAssertEqual(store.check(candidate(port: 2222)), .unknown)
        store.trust(candidate(port: 2222, blob: [5]))
        XCTAssertEqual(store.check(candidate(port: 2222, blob: [5])), .known)
        XCTAssertEqual(store.check(candidate(port: 22)), .known)
        XCTAssertEqual(store.knownHostsFileLines().map { $0.split(separator: " ")[0] }, ["a.example", "[a.example]:2222"])
    }

    func testKnownHostsFileLinesFormat() async throws {
        let (store, vault) = try await makeStore()
        store.trust(candidate(blob: [1, 2, 3]))
        store.trust(candidate(port: 2200, type: "ssh-rsa", blob: [4, 5]))
        // Record without a stored key blob is skipped.
        vault.saveNow(KnownHost(hostPort: "legacy", keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:x"))
        // Tombstoned records are skipped.
        let gone = candidate(host: "gone.example")
        store.trust(gone)
        store.replace(candidate(host: "gone.example", blob: [8]))
        let lines = store.knownHostsFileLines()
        XCTAssertEqual(lines, [
            "a.example ssh-ed25519 \(candidate(blob: [1, 2, 3]).publicKeyBlob.base64EncodedString())",
            "[a.example]:2200 ssh-rsa \(candidate(port: 2200, type: "ssh-rsa", blob: [4, 5]).publicKeyBlob.base64EncodedString())",
            "gone.example ssh-ed25519 \(candidate(host: "gone.example", blob: [8]).publicKeyBlob.base64EncodedString())",
        ])
    }

    func testKnownHostsFileLinesSkipInjectedRecords() async throws {
        let (store, vault) = try await makeStore()
        let good = candidate(blob: [1])
        let goodB64 = good.publicKeyBlob.base64EncodedString()
        func add(_ hostPort: String, _ type: String, _ b64: String) {
            vault.saveNow(KnownHost(hostPort: hostPort, keyType: type, fingerprintSHA256: good.fingerprint, publicKeyBase64: b64))
        }
        add("ok.example", "ssh-ed25519", goodB64)
        add("evil.example", "ssh-ed25519", goodB64 + "\nevil.example ssh-ed25519 BBBB")
        add("evil2.example", "ssh-ed25519 extra", goodB64)
        add("evil3.example", "ssh-ed25519", "AA AA")
        add("evil4.example\n*", "ssh-ed25519", goodB64)
        add("*", "ssh-ed25519", goodB64)
        add("a,b", "ssh-ed25519", goodB64)
        add("@cert-authority", "ssh-ed25519", goodB64)
        add("tab.example", "ssh-ed25519", "AA\tAA")
        add("cr.example", "ssh-ed25519", goodB64 + "\r")
        add("empty.example", "", goodB64)
        add("nob64.example", "ssh-ed25519", "")
        add("", "ssh-ed25519", goodB64)
        XCTAssertEqual(store.knownHostsFileLines(), ["ok.example ssh-ed25519 \(goodB64)"])
    }

    func testKnownHostsFileLinesRequireBlobToMatchFingerprintAndKeyType() async throws {
        let (store, vault) = try await makeStore()
        let a = candidate(blob: [1])
        let b = candidate(blob: [2])
        let rsa = candidate(type: "ssh-rsa", blob: [3])
        // Blob does not hash to the stored fingerprint.
        vault.saveNow(KnownHost(hostPort: "h1", keyType: "ssh-ed25519", fingerprintSHA256: a.fingerprint,
                                publicKeyBase64: b.publicKeyBlob.base64EncodedString()))
        // Blob (and its fingerprint) belongs to a different key type than the record claims.
        vault.saveNow(KnownHost(hostPort: "h2", keyType: "ssh-ed25519", fingerprintSHA256: rsa.fingerprint,
                                publicKeyBase64: rsa.publicKeyBlob.base64EncodedString()))
        // Not decodable / too short.
        vault.saveNow(KnownHost(hostPort: "h3", keyType: "ssh-ed25519", fingerprintSHA256: a.fingerprint, publicKeyBase64: "AAA"))
        let short = Data([0, 0])
        vault.saveNow(KnownHost(hostPort: "h4", keyType: "ssh-ed25519",
                                fingerprintSHA256: HostKeyFormat.fingerprintSHA256(publicKeyBlob: short),
                                publicKeyBase64: short.base64EncodedString()))
        // Declared length longer than the blob.
        let lying = Data([0, 0, 0, 200, 1, 2])
        vault.saveNow(KnownHost(hostPort: "h5", keyType: "ssh-ed25519",
                                fingerprintSHA256: HostKeyFormat.fingerprintSHA256(publicKeyBlob: lying),
                                publicKeyBase64: lying.base64EncodedString()))
        XCTAssertTrue(store.knownHostsFileLines().isEmpty)
    }

    func testHostNamesAreNormalized() async throws {
        let (store, _) = try await makeStore()
        store.trust(candidate(host: "Host.Local."))
        XCTAssertEqual(store.check(candidate(host: "host.local")), .known)
    }

    func testTrustRefusesToAddSecondSameTypeKey() async throws {
        let (store, vault) = try await makeStore()
        XCTAssertTrue(store.trust(candidate(blob: [1])))
        XCTAssertFalse(store.trust(candidate(blob: [2])))
        XCTAssertEqual(vault.all(KnownHost.self).count, 1)
        XCTAssertTrue(store.trust(candidate(blob: [1])))
        XCTAssertTrue(store.trust(candidate(type: "ssh-rsa", blob: [3])))
        XCTAssertEqual(vault.all(KnownHost.self).count, 2)
    }

    func testNewKeyTypeAsksWithKnownTypesAndTrustAddsAlongside() async throws {
        let (store, vault) = try await makeStore()
        store.trust(candidate(type: "ssh-ed25519", blob: [1]))
        let rec = Recorder()
        let rsa = candidate(type: "ssh-rsa", blob: [2])
        let decision = await evaluator(store, rec, answer: .trusted).evaluate(rsa)
        XCTAssertEqual(decision, .trusted)
        XCTAssertEqual(rec.asked[0].1, .newKeyType(knownKeyTypes: ["ssh-ed25519"]))
        XCTAssertEqual(vault.all(KnownHost.self).count, 2)
        XCTAssertEqual(store.check(candidate(type: "ssh-ed25519", blob: [1])), .known)
        XCTAssertEqual(store.check(rsa), .known)
    }

    private actor Gate {
        var waiting: [CheckedContinuation<HostKeyDecision, Never>] = []
        func wait() async -> HostKeyDecision { await withCheckedContinuation { waiting.append($0) } }
        var count: Int { waiting.count }
        func release(_ i: Int, _ d: HostKeyDecision) { waiting[i].resume(returning: d) }
    }

    func testConcurrentEvaluationsOfDifferentKeysReAskAsChanged() async throws {
        let (store, vault) = try await makeStore()
        let gate = Gate()
        let seen = Recorder()
        let ev = PromptingHostKeyEvaluator(store: store) { c, check in
            seen.asked.append((c, check))
            return await gate.wait()
        }
        let k1 = candidate(blob: [1]), k2 = candidate(blob: [2])
        async let d1 = ev.evaluate(k1)
        async let d2 = ev.evaluate(k2)
        while await gate.count < 2 { await Task.yield() }
        XCTAssertEqual(seen.asked.map(\.1), [.unknown, .unknown])
        await gate.release(0, .trusted)
        while vault.all(KnownHost.self).isEmpty { await Task.yield() }
        await gate.release(1, .trusted)
        while await gate.count < 3 { await Task.yield() }
        // The second connection is asked again, now as a changed key.
        XCTAssertEqual(seen.asked.count, 3)
        XCTAssertEqual(seen.asked[2].1, .changed(previousFingerprint: k1.fingerprint))
        XCTAssertEqual(vault.all(KnownHost.self).count, 1)
        await gate.release(2, .rejected)
        let r1 = await d1, r2 = await d2
        XCTAssertEqual([r1, r2].filter { $0 == .trusted }.count, 1)
        XCTAssertEqual(vault.all(KnownHost.self).count, 1)
        XCTAssertEqual(store.check(k1), .known)
    }
}

private extension HostKeyCheck {
    var isChanged: Bool { if case .changed = self { true } else { false } }
}
