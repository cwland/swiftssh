import CoreModels
import Fluent
import FluentSQLiteDriver
import Foundation
import SyncCore
import SyncTestSupport
import XCTVapor
@testable import SyncServer

final class EndToEndTests: XCTestCase {
    private let iterations = 1000

    private func engine(_ url: URL, key: String = "k1", device: String) -> (SyncEngine, InMemoryStore) {
        let store = InMemoryStore(deviceID: device)
        let engine = SyncEngine(transport: HTTPSyncTransport(baseURL: url, apiKey: key), store: store,
                                deviceID: device, iterations: iterations)
        return (engine, store)
    }

    func testTwoMacsSyncThroughRealServer() async throws {
        try await withRunningServer { _, url in
            let (a, storeA) = engine(url, device: "mac-a")
            let (b, storeB) = engine(url, device: "mac-b")

            let host = Host(label: "NAS", address: "192.168.99.200", password: "hunter2-secret")
            try await storeA.insert(host)
            _ = try await a.createVault(passphrase: "correct horse")
            _ = try await a.sync()

            _ = try await b.join(passphrase: "correct horse", mode: .replace)
            _ = try await b.sync()

            let received = try await storeB.model(Host.self, id: host.id)
            XCTAssertEqual(received?.address, "192.168.99.200")
            XCTAssertEqual(received?.label, "NAS")
            XCTAssertEqual(received?.password, "hunter2-secret")
        }
    }

    func testServerStoresNoPlaintext() async throws {
        try await withRunningServer { app, url in
            let (a, storeA) = engine(url, device: "mac-a")
            let host = Host(label: "Secret-Label-XYZ", address: "192.168.99.200", password: "hunter2-secret")
            try await storeA.insert(host)
            _ = try await a.createVault(passphrase: "correct horse")
            _ = try await a.sync()

            let sqlite = try XCTUnwrap(app.db(.sqlite) as? SQLiteDatabase)
            let recordRows = try await sqlite.query("SELECT * FROM records").get()
            let vaultRows = try await sqlite.query("SELECT * FROM vault").get()
            XCTAssertEqual(recordRows.count, 1)
            XCTAssertEqual(vaultRows.count, 1)

            // Positive controls: the sensitive columns hold data, and the helper does find a needle.
            func column(_ row: SQLiteRow, _ name: String) -> Data {
                row.column(name).map(Self.bytes(of:)) ?? Data()
            }
            XCTAssertFalse(column(recordRows[0], "ciphertext").isEmpty)
            XCTAssertFalse(column(vaultRows[0], "wrapped_key").isEmpty)
            XCTAssertTrue(Self.contains(Data("host=192.168.99.200;".utf8), "192.168.99.200"))

            let needles = ["192.168.99.200", "Secret-Label-XYZ", "hunter2-secret"]
            for row in recordRows + vaultRows {
                for data in row.columns.map(\.data) {
                    for needle in needles {
                        XCTAssertFalse(Self.contains(Self.bytes(of: data), needle), "found \(needle) in stored row")
                    }
                }
            }
        }
    }

    func testWrongAPIKeyFailsClearly() async throws {
        try await withRunningServer { _, url in
            let (a, _) = engine(url, key: "nope", device: "mac-a")
            do {
                _ = try await a.createVault(passphrase: "x")
                XCTFail("expected unauthorized")
            } catch {
                XCTAssertEqual(error as? SyncTransportError, .unauthorized)
            }
        }
    }

    private static func contains(_ haystack: Data, _ needle: String) -> Bool {
        haystack.range(of: Data(needle.utf8)) != nil
    }

    private static func bytes(of data: SQLiteData) -> Data {
        switch data {
        case .blob(let buffer): return Data(buffer.readableBytesView)
        case .text(let string): return Data(string.utf8)
        case .integer(let value): return Data(String(value).utf8)
        case .float(let value): return Data(String(value).utf8)
        case .null: return Data()
        }
    }
}
