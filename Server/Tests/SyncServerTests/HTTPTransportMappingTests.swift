import CoreModels
import Foundation
import SyncCore
import XCTest

/// The transport's ruled error mapping, against the real running server.
final class HTTPTransportMappingTests: XCTestCase {
    private func vault(wrapped: UInt8 = 1) -> VaultMetadata {
        VaultMetadata(vaultID: UUID(), salt: Data(repeating: 2, count: 16), iterations: 1000,
                      wrappedKey: Data(repeating: wrapped, count: 60))
    }

    private func transport(_ url: URL) -> HTTPSyncTransport {
        HTTPSyncTransport(baseURL: url, apiKey: "k1")
    }

    func testGetVaultReturnsNilWhenNone() async throws {
        try await withRunningServer { _, url in
            let result = try await transport(url).getVault()
            XCTAssertNil(result)
        }
    }

    func testSecondPutVaultThrowsVaultAlreadyExists() async throws {
        try await withRunningServer { _, url in
            let t = transport(url)
            try await t.putVault(vault())
            do {
                try await t.putVault(vault())
                XCTFail("expected vaultAlreadyExists")
            } catch {
                XCTAssertEqual(error as? SyncError, .vaultAlreadyExists)
            }
        }
    }

    func testRewrapWithoutVaultThrowsNoVault() async throws {
        try await withRunningServer { _, url in
            let request = RewrapRequest(oldWrappedKey: Data(repeating: 1, count: 60), salt: Data(repeating: 3, count: 16),
                                        iterations: 1000, wrappedKey: Data(repeating: 4, count: 60))
            do {
                _ = try await transport(url).rewrap(request)
                XCTFail("expected noVault")
            } catch {
                XCTAssertEqual(error as? SyncError, .noVault)
            }
        }
    }

    func testStaleRewrapThrowsVaultChanged() async throws {
        try await withRunningServer { _, url in
            let t = transport(url)
            try await t.putVault(vault(wrapped: 1))
            let stale = RewrapRequest(oldWrappedKey: Data(repeating: 9, count: 60), salt: Data(repeating: 3, count: 16),
                                      iterations: 1000, wrappedKey: Data(repeating: 4, count: 60))
            do {
                _ = try await t.rewrap(stale)
                XCTFail("expected vaultChanged")
            } catch {
                XCTAssertEqual(error as? SyncError, .vaultChanged)
            }
        }
    }

    func testOtherErrorsCarryStatusAndServerMessage() async throws {
        try await withRunningServer { _, url in
            let big = EncryptedRecord(id: UUID(), type: .host, updatedAt: Date(), deleted: false, deviceID: "d",
                                      ciphertext: Data(repeating: 0, count: 1024 * 1024 + 1))
            do {
                _ = try await transport(url).upsert([big])
                XCTFail("expected http error")
            } catch SyncTransportError.http(let status, let message) {
                XCTAssertEqual(status, 413)
                XCTAssertFalse(message.isEmpty)
            }
        }
    }
}
