import XCTest
import CoreModels
import SSHCore
@testable import AppCore

private typealias Host = CoreModels.Host

@MainActor
final class KnownHostsViewModelTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func makeVault() async throws -> LocalVault {
        try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @discardableResult
    private func key(_ vault: LocalVault, _ hostPort: String, _ type: String = "ssh-ed25519",
                     _ fingerprint: String = "SHA256:abc", firstSeen: Date = Date()) -> KnownHost {
        vault.saveNow(KnownHost(hostPort: hostPort, keyType: type, fingerprintSHA256: fingerprint, firstSeen: firstSeen))
    }

    // MARK: Rows and grouping

    func testRowFieldsAndPortShownOnlyWhenNot22() async throws {
        let vault = try await makeVault()
        let k = key(vault, "nas.local", "ssh-ed25519", "SHA256:xyz", firstSeen: date(2026, 3, 4))
        key(vault, "[nas.local]:2222", "ssh-rsa", "SHA256:rsa")
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)

        XCTAssertEqual(vm.sections.map(\.address), ["nas.local", "nas.local:2222"])
        let row = try XCTUnwrap(vm.sections.first?.rows.first)
        XCTAssertEqual(row.id, k.id)
        XCTAssertEqual(row.address, "nas.local")
        XCTAssertEqual(row.keyType, "ssh-ed25519")
        XCTAssertEqual(row.fingerprint, "SHA256:xyz")
        XCTAssertEqual(row.firstSeen, date(2026, 3, 4))
        XCTAssertEqual(row.firstSeenText, "Mar 04, 2026")
        XCTAssertEqual(vm.sections[1].hostPort, "[nas.local]:2222", "keeps the stored form")
    }

    func testIPv6AddressKeepsBracketsWithPort() async throws {
        let vault = try await makeVault()
        key(vault, "[fe80::1]:2200")
        key(vault, "fe80::2")
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)
        XCTAssertEqual(vm.sections.map(\.address), ["[fe80::1]:2200", "fe80::2"])
    }

    func testGroupedPerHostPortSortedAToZAndKeyTypesSorted() async throws {
        let vault = try await makeVault()
        key(vault, "zeta.example", "ssh-rsa")
        key(vault, "alpha.example", "ssh-rsa")
        key(vault, "[alpha.example]:10022")
        key(vault, "alpha.example", "ecdsa-sha2-nistp256")
        key(vault, "[alpha.example]:2222")
        key(vault, "Beta.example")
        let gone = key(vault, "gone.example")
        var tomb = gone
        tomb.deleted = true
        vault.saveNow(tomb)
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)

        XCTAssertEqual(vm.sections.map(\.address),
                       ["alpha.example", "alpha.example:2222", "alpha.example:10022", "Beta.example", "zeta.example"],
                       "host A–Z (case-insensitive), then port numerically; deleted keys left out")
        XCTAssertEqual(vm.sections[0].rows.map(\.keyType), ["ecdsa-sha2-nistp256", "ssh-rsa"])
        XCTAssertEqual(vm.keyCount, 6)
        XCTAssertEqual(vm.hostCount, 5)
    }

    // MARK: Search

    func testSearchMatchesHostKeyTypeAndFingerprint() async throws {
        let vault = try await makeVault()
        key(vault, "nas.local", "ssh-ed25519", "SHA256:AAAA")
        key(vault, "nas.local", "ssh-rsa", "SHA256:BBBB")
        key(vault, "[pi.local]:2222", "ecdsa-sha2-nistp256", "SHA256:CCCC")
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)

        vm.searchText = "  NAS "
        XCTAssertEqual(vm.sections.map(\.address), ["nas.local"])
        XCTAssertEqual(vm.sections[0].rows.count, 2)

        vm.searchText = "rsa"
        XCTAssertEqual(vm.sections.map(\.address), ["nas.local"])
        XCTAssertEqual(vm.sections[0].rows.map(\.keyType), ["ssh-rsa"])

        vm.searchText = "cccc"
        XCTAssertEqual(vm.sections.map(\.address), ["pi.local:2222"])

        vm.searchText = "pi.local:2222"
        XCTAssertEqual(vm.sections.map(\.address), ["pi.local:2222"], "the shown address matches")

        vm.searchText = "nothing"
        XCTAssertTrue(vm.sections.isEmpty)
        XCTAssertEqual(vm.keyCount, 3, "the count ignores the search")
    }

    func testSearchMatchesSavedHostLabel() async throws {
        let vault = try await makeVault()
        key(vault, "10.0.0.5")
        key(vault, "10.0.0.6")
        vault.saveNow(Host(label: "Synology", address: "10.0.0.5"))
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)
        vm.searchText = "synology"
        XCTAssertEqual(vm.sections.map(\.address), ["10.0.0.5"])
    }

    // MARK: Saved hosts using the address

    func testSavedHostsMatchByAddressAndEffectivePortLikeTheConnection() async throws {
        let vault = try await makeVault()
        key(vault, "nas.local")
        key(vault, "[nas.local]:2222")
        key(vault, "[pi.local]:2200")
        let group = vault.saveNow(HostGroup(name: "Pis", defaultPort: 2200))
        let nas = vault.saveNow(Host(label: "NAS", address: "  NAS.local. "))       // normalized, port 22
        let nasAlt = vault.saveNow(Host(label: "NAS alt", address: "nas.local", port: 2222))
        let pi = vault.saveNow(Host(label: "Pi", address: "pi.local", groupID: group.id)) // group's port
        vault.saveNow(Host(label: "Pi on 22", address: "pi.local"))                      // other port
        let untitled = vault.saveNow(Host(label: "  ", address: "nas.local"))
        var deleted = vault.saveNow(Host(label: "Deleted", address: "nas.local"))
        deleted.deleted = true
        vault.saveNow(deleted)
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)

        let byAddress = Dictionary(uniqueKeysWithValues: vm.sections.map { ($0.address, $0) })
        XCTAssertEqual(byAddress["nas.local"]?.usedBy.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       [nas.id, untitled.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(byAddress["nas.local"]?.usedBy.map(\.label), ["NAS", "Untitled host"], "A–Z, blank labels named")
        XCTAssertEqual(byAddress["nas.local:2222"]?.usedBy.map(\.id), [nasAlt.id])
        XCTAssertEqual(byAddress["pi.local:2200"]?.usedBy.map(\.id), [pi.id])
        XCTAssertEqual(byAddress["nas.local"]?.rows.first?.usedBy, byAddress["nas.local"]?.usedBy,
                       "each row carries its address's saved hosts")
    }

    func testSavedHostIsAlsoListedUnderItsBackupAddress() async throws {
        let vault = try await makeVault()
        key(vault, "nas.local")
        key(vault, "100.64.0.10")
        let nas = vault.saveNow(Host(label: "NAS", address: "nas.local", fallbackAddress: " 100.64.0.10 "))
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)
        let byAddress = Dictionary(uniqueKeysWithValues: vm.sections.map { ($0.address, $0) })
        XCTAssertEqual(byAddress["nas.local"]?.usedBy.map(\.id), [nas.id])
        XCTAssertEqual(byAddress["100.64.0.10"]?.usedBy.map(\.id), [nas.id], "the backup address's key belongs to it too")
    }

    // MARK: Removal

    func testRemoveOneKeyTombstonesItAndTheStoreAsksAgain() async throws {
        let vault = try await makeVault()
        let store = KnownHostsStore(vault: vault)
        let blob = Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [1, 2, 3])
        let candidate = HostKeyCandidate(host: "nas.local", port: 22, keyType: "ssh-ed25519", publicKeyBlob: blob)
        store.trust(candidate)
        let other = key(vault, "nas.local", "ssh-rsa", "SHA256:rsa")
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)
        let ed = try XCTUnwrap(vm.sections.first?.rows.first { $0.keyType == "ssh-ed25519" })

        vm.remove([ed.id])

        XCTAssertEqual(vault.all(KnownHost.self).map(\.id), [other.id])
        XCTAssertEqual(vault.deletedRecords(KnownHost.self).map(\.id), [ed.id], "a tombstone that syncs")
        XCTAssertEqual(store.check(candidate), .newKeyType(knownKeyTypes: ["ssh-rsa"]),
                       "the next connection asks again")
        XCTAssertEqual(vm.keyCount, 1)
    }

    func testRemoveAllKeysOfHostPortIgnoresSearch() async throws {
        let vault = try await makeVault()
        key(vault, "nas.local", "ssh-ed25519", "SHA256:a")
        key(vault, "nas.local", "ssh-rsa", "SHA256:b")
        let keep = key(vault, "[nas.local]:2222")
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)
        vm.searchText = "rsa"
        XCTAssertEqual(vm.keyCount(hostPort: "nas.local"), 2, "search ignored")
        XCTAssertEqual(vm.keyCount(hostPort: "[nas.local]:2222"), 1)

        vm.removeAll(hostPort: "nas.local")

        XCTAssertEqual(vault.all(KnownHost.self).map(\.id), [keep.id], "every key of the host, shown or not")
        XCTAssertEqual(vault.deletedRecords(KnownHost.self).count, 2)
    }

    func testRemoveSeveralKeysAcrossHostsAndIgnoresUnknownIDs() async throws {
        let vault = try await makeVault()
        let a = key(vault, "a.example")
        let b = key(vault, "b.example")
        let c = key(vault, "c.example")
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)

        vm.remove([a.id, c.id, UUID(), a.id])

        XCTAssertEqual(vault.all(KnownHost.self).map(\.id), [b.id])
        XCTAssertEqual(vault.deletedRecords(KnownHost.self).map(\.id).sorted { $0.uuidString < $1.uuidString },
                       [a.id, c.id].sorted { $0.uuidString < $1.uuidString })
    }

    func testRemoveDoesNotTouchOtherRecordTypes() async throws {
        let vault = try await makeVault()
        let host = vault.saveNow(Host(label: "h", address: "h"))
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)
        vm.remove([host.id])
        XCTAssertNotNil(vault.get(Host.self, id: host.id))
    }

    func testRowLookupForCopyFingerprint() async throws {
        let vault = try await makeVault()
        let k = key(vault, "a.example", "ssh-ed25519", "SHA256:copy")
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)
        XCTAssertEqual(vm.row(k.id)?.fingerprint, "SHA256:copy")
        XCTAssertNil(vm.row(UUID()))
    }

    // MARK: Sidebar count

    func testSidebarCountIsLiveKeysAndMatchesTheScreen() async throws {
        let vault = try await makeVault()
        key(vault, "a.example", "ssh-ed25519")
        key(vault, "a.example", "ssh-rsa")
        let gone = key(vault, "b.example")
        let vm = KnownHostsViewModel(vault: vault, timeZone: utc)
        vm.remove([gone.id])

        let counts = SidebarCounts(vault: vault)
        XCTAssertEqual(counts.count(for: .knownHosts), 2, "one per key, deleted keys left out")
        XCTAssertEqual(counts.count(for: .knownHosts), vm.keyCount)
        XCTAssertEqual(counts.count(for: .knownHosts), vm.sections.flatMap(\.rows).count)
    }
}
