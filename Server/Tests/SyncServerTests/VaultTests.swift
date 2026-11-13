import XCTVapor
import SyncCore
@testable import SyncServer

final class VaultTests: XCTestCase {
    private let auth: HTTPHeaders = ["Authorization": "Bearer k1"]

    private func meta(
        id: UUID = UUID(), salt: UInt8 = 1, key: UInt8 = 2, iterations: Int = 1000
    ) -> VaultMetadata {
        VaultMetadata(
            vaultID: id, salt: Data(repeating: salt, count: 16), iterations: iterations,
            wrappedKey: Data(repeating: key, count: 60), version: 1)
    }

    func testGetVaultIs404BeforeSetup() async throws {
        try await withApp { app in
            try await app.test(.GET, "v1/vault", headers: auth) { res async in
                XCTAssertEqual(res.status, .notFound)
            }
        }
    }

    func testPutThenGetReturnsSameMetadata() async throws {
        try await withApp { app in
            let m = meta()
            try await app.test(.PUT, "v1/vault", headers: auth, beforeRequest: { try $0.content.encode(m) }) { res async in
                XCTAssertEqual(res.status, .created)
            }
            try await app.test(.GET, "v1/vault", headers: auth) { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(try res.content.decode(VaultMetadata.self), m)
            }
        }
    }

    func testSecondPutIs409AndDoesNotOverwrite() async throws {
        try await withApp { app in
            let first = meta(), second = meta(salt: 9, key: 9)
            try await app.test(.PUT, "v1/vault", headers: auth, beforeRequest: { try $0.content.encode(first) }) { _ async in }
            try await app.test(.PUT, "v1/vault", headers: auth, beforeRequest: { try $0.content.encode(second) }) { res async in
                XCTAssertEqual(res.status, .conflict)
            }
            try await app.test(.GET, "v1/vault", headers: auth) { res async throws in
                XCTAssertEqual(try res.content.decode(VaultMetadata.self), first)
            }
        }
    }

    func testRewrapWithMatchingOldKeyUpdatesSaltAndKeyButKeepsVaultID() async throws {
        try await withApp { app in
            let m = meta()
            try await app.test(.PUT, "v1/vault", headers: auth, beforeRequest: { try $0.content.encode(m) }) { _ async in }
            let req = RewrapRequest(
                oldWrappedKey: m.wrappedKey, salt: Data(repeating: 7, count: 16),
                iterations: 2000, wrappedKey: Data(repeating: 8, count: 60))
            try await app.test(.POST, "v1/vault/rewrap", headers: auth, beforeRequest: { try $0.content.encode(req) }) { res async throws in
                XCTAssertEqual(res.status, .ok)
                let out = try res.content.decode(VaultMetadata.self)
                XCTAssertEqual(out.vaultID, m.vaultID)
                XCTAssertEqual(out.version, 1)
                XCTAssertEqual(out.salt, req.salt)
                XCTAssertEqual(out.iterations, 2000)
                XCTAssertEqual(out.wrappedKey, req.wrappedKey)
            }
            try await app.test(.GET, "v1/vault", headers: auth) { res async throws in
                XCTAssertEqual(try res.content.decode(VaultMetadata.self).wrappedKey, req.wrappedKey)
            }
        }
    }

    func testRewrapWithStaleOldKeyIs409() async throws {
        try await withApp { app in
            let m = meta()
            try await app.test(.PUT, "v1/vault", headers: auth, beforeRequest: { try $0.content.encode(m) }) { _ async in }
            let req = RewrapRequest(
                oldWrappedKey: Data(repeating: 0, count: 60), salt: Data(repeating: 7, count: 16),
                iterations: 2000, wrappedKey: Data(repeating: 8, count: 60))
            try await app.test(.POST, "v1/vault/rewrap", headers: auth, beforeRequest: { try $0.content.encode(req) }) { res async in
                XCTAssertEqual(res.status, .conflict)
            }
            try await app.test(.GET, "v1/vault", headers: auth) { res async throws in
                XCTAssertEqual(try res.content.decode(VaultMetadata.self), m)
            }
        }
    }

    func testRewrapWithoutVaultIs404() async throws {
        try await withApp { app in
            let req = RewrapRequest(
                oldWrappedKey: Data(repeating: 2, count: 60), salt: Data(repeating: 7, count: 16),
                iterations: 2000, wrappedKey: Data(repeating: 8, count: 60))
            try await app.test(.POST, "v1/vault/rewrap", headers: auth, beforeRequest: { try $0.content.encode(req) }) { res async in
                XCTAssertEqual(res.status, .notFound)
            }
        }
    }

    func testConcurrentRewrapsOnlyOneSucceeds() async throws {
        try await withApp { app in
            let m = meta()
            try await app.test(.PUT, "v1/vault", headers: auth, beforeRequest: { try $0.content.encode(m) }) { _ async in }
            let auth = self.auth
            let results: [(UInt8, HTTPStatus)] = try await withThrowingTaskGroup(of: (UInt8, HTTPStatus).self) { group in
                for n in 10..<20 {
                    group.addTask {
                        let req = RewrapRequest(
                            oldWrappedKey: m.wrappedKey, salt: Data(repeating: 7, count: 16),
                            iterations: 2000, wrappedKey: Data(repeating: UInt8(n), count: 60))
                        var status = HTTPStatus.internalServerError
                        try await app.test(.POST, "v1/vault/rewrap", headers: auth, beforeRequest: { try $0.content.encode(req) }) { res async in
                            status = res.status
                        }
                        return (UInt8(n), status)
                    }
                }
                var all: [(UInt8, HTTPStatus)] = []
                for try await r in group { all.append(r) }
                return all
            }
            let winners = results.filter { $0.1 == .ok }
            XCTAssertEqual(winners.count, 1)
            XCTAssertEqual(results.filter { $0.1 == .conflict }.count, 9)
            try await app.test(.GET, "v1/vault", headers: auth) { res async throws in
                XCTAssertEqual(try res.content.decode(VaultMetadata.self).wrappedKey,
                               Data(repeating: winners[0].0, count: 60))
            }
        }
    }
}
