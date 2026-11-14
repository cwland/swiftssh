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
        HostKeyCandidate(host: host, port: port, keyType: type, publicKeyBlob: Data(blob))
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
        XCTAssertEqual(records[0].publicKeyBase64, Data([1, 2, 3]).base64EncodedString())
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

    func testDifferentKeyTypeForSameHostIsUnknownNotChanged() async throws {
        let (store, _) = try await makeStore()
        store.trust(candidate(type: "ssh-ed25519", blob: [1]))
        XCTAssertEqual(store.check(candidate(type: "ssh-rsa", blob: [2])), .unknown)
        XCTAssertEqual(store.check(candidate(type: "ssh-ed25519", blob: [3])).isChanged, true)
    }

    func testChangedUsesMostRecentRecordOfSameType() async throws {
        let (store, vault) = try await makeStore()
        let c1 = candidate(blob: [1]), c2 = candidate(blob: [2])
        store.trust(c1)
        store.trust(c2)   // legacy duplicate live records (e.g. from sync)
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
            "a.example ssh-ed25519 \(Data([1, 2, 3]).base64EncodedString())",
            "[a.example]:2200 ssh-rsa \(Data([4, 5]).base64EncodedString())",
            "gone.example ssh-ed25519 \(Data([8]).base64EncodedString())",
        ])
    }

    func testKnownHostsFileLinesSkipInjectedRecords() async throws {
        let (store, vault) = try await makeStore()
        func add(_ hostPort: String, _ type: String, _ b64: String) {
            vault.saveNow(KnownHost(hostPort: hostPort, keyType: type, fingerprintSHA256: "SHA256:x", publicKeyBase64: b64))
        }
        add("ok.example", "ssh-ed25519", "AAAA")
        add("evil.example", "ssh-ed25519", "AAAA\nevil.example ssh-ed25519 BBBB")
        add("evil2.example", "ssh-ed25519 extra", "AAAA")
        add("evil3.example", "ssh-ed25519", "AA AA")
        add("evil4.example\n*", "ssh-ed25519", "AAAA")
        add("*", "ssh-ed25519", "AAAA")
        add("a,b", "ssh-ed25519", "AAAA")
        add("@cert-authority", "ssh-ed25519", "AAAA")
        add("tab.example", "ssh-ed25519", "AA\tAA")
        add("cr.example", "ssh-ed25519", "AAAA\r")
        add("empty.example", "", "AAAA")
        add("nob64.example", "ssh-ed25519", "")
        XCTAssertEqual(store.knownHostsFileLines(), ["ok.example ssh-ed25519 AAAA"])
    }
}

private extension HostKeyCheck {
    var isChanged: Bool { if case .changed = self { true } else { false } }
}
