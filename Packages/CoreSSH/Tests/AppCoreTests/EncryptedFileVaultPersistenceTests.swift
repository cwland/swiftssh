import XCTest
import Crypto
import CoreModels
import SyncCore
@testable import AppCore

final class EncryptedFileVaultPersistenceTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL { dir.appendingPathComponent("vault.bin") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func newKey() -> VaultKey { VaultKey(VaultCrypto.newVaultKey()) }

    private func sampleContents(address: String = "192.168.50.200", password: String = "hunter2") throws -> VaultFileContents {
        var host = Host(label: "box", address: address, password: password)
        host.updatedAt = Date(timeIntervalSince1970: 1_700_000_000) // whole ms, survives CoreJSON
        let record = try PlainRecord(host, deviceID: "dev-1")
        return VaultFileContents(deviceID: "dev-1", records: [record], dirty: [host.id])
    }

    func testSaveThenLoadRoundTrips() async throws {
        let p = EncryptedFileVaultPersistence(fileURL: fileURL, key: newKey())
        let contents = try sampleContents()
        try await p.save(contents)
        let loaded = try await p.load()
        XCTAssertEqual(loaded, contents)
    }

    func testFileContainsNoPlaintext() async throws {
        let p = EncryptedFileVaultPersistence(fileURL: fileURL, key: newKey())
        try await p.save(try sampleContents())
        let raw = try Data(contentsOf: fileURL)
        XCTAssertFalse(raw.isEmpty)
        XCTAssertNil(raw.range(of: Data("192.168.50.200".utf8)))
        XCTAssertNil(raw.range(of: Data("hunter2".utf8)))
    }

    func testMissingFileLoadsNil() async throws {
        let p = EncryptedFileVaultPersistence(fileURL: fileURL, key: newKey())
        let loaded = try await p.load()
        XCTAssertNil(loaded)
    }

    func testWrongKeyMovesFileAsideAndThrows() async throws {
        try await EncryptedFileVaultPersistence(fileURL: fileURL, key: newKey()).save(try sampleContents())
        let original = try Data(contentsOf: fileURL)
        let other = EncryptedFileVaultPersistence(fileURL: fileURL, key: newKey())
        try await assertMovedAside(other, original: original)
    }

    func testCorruptFileMovesFileAsideAndThrows() async throws {
        let garbage = Data("this is not a vault".utf8)
        try garbage.write(to: fileURL)
        let p = EncryptedFileVaultPersistence(fileURL: fileURL, key: newKey())
        try await assertMovedAside(p, original: garbage)
    }

    func testMovedAsideNameUsesClockAndNeverOverwrites() async throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let p = EncryptedFileVaultPersistence(fileURL: fileURL, key: newKey(), now: { when })
        var moved: [URL] = []
        for i in 0..<3 {
            try Data("garbage \(i)".utf8).write(to: fileURL)
            do { _ = try await p.load(); XCTFail("expected throw") }
            catch VaultLoadError.unreadable(movedTo: let url) { moved.append(url) }
        }
        XCTAssertEqual(moved.map(\.lastPathComponent), [
            "vault.bin.unreadable-20231114-221320",
            "vault.bin.unreadable-20231114-221320-2",
            "vault.bin.unreadable-20231114-221320-3",
        ])
        for (i, url) in moved.enumerated() {
            XCTAssertEqual(try Data(contentsOf: url), Data("garbage \(i)".utf8))
        }
    }

    func testSaveIsAtomic() async throws {
        let p = EncryptedFileVaultPersistence(fileURL: fileURL, key: newKey())
        try await p.save(try sampleContents(password: "one"))
        let second = try sampleContents(password: "two")
        try await p.save(second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["vault.bin"])
        let loaded = try await p.load()
        XCTAssertEqual(loaded, second)
    }

    func testCreatesParentDirectory() async throws {
        let nested = dir.appendingPathComponent("a/b/vault.bin")
        let p = EncryptedFileVaultPersistence(fileURL: nested, key: newKey())
        try await p.save(try sampleContents())
        let loaded = try await p.load()
        XCTAssertNotNil(loaded)
    }

    func testStaticKeyProviderReturnsItsKey() throws {
        let key = newKey()
        XCTAssertEqual(try StaticKeyProvider(key: key).loadOrCreateKey(), key)
    }

    private func assertMovedAside(_ p: EncryptedFileVaultPersistence, original: Data,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await p.load()
            XCTFail("expected throw", file: file, line: line)
        } catch VaultLoadError.unreadable(movedTo: let url) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), file: file, line: line)
            XCTAssertTrue(url.lastPathComponent.hasPrefix("vault.bin.unreadable-"), file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: url), original, file: file, line: line)
        }
    }
}
