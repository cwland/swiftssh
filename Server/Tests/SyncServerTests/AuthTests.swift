import XCTVapor
import CoreModels
@testable import SyncServer

final class AuthTests: XCTestCase {
    private func bearer(_ key: String) -> HTTPHeaders {
        ["Authorization": "Bearer \(key)"]
    }

    func testHealthNeedsNoAuth() async throws {
        try await withApp(keys: ["k1", "k2"]) { app in
            try await app.test(.GET, "health") { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.body.string, #"{"status":"ok"}"#)
                XCTAssertTrue(res.headers.contentType?.description.hasPrefix("application/json") ?? false)
            }
        }
    }

    func testV1RejectsMissingKey() async throws {
        try await withApp(keys: ["k1", "k2"]) { app in
            try await app.test(.GET, "v1/vault") { res async in
                XCTAssertEqual(res.status, .unauthorized)
                XCTAssertEqual(res.body.string, #"{"error":"Unauthorized"}"#)
            }
        }
    }

    func testV1RejectsWrongKey() async throws {
        try await withApp(keys: ["k1", "k2"]) { app in
            try await app.test(.GET, "v1/vault", headers: bearer("nope")) { res async in
                XCTAssertEqual(res.status, .unauthorized)
            }
        }
    }

    func testV1AcceptsEitherKey() async throws {
        try await withApp(keys: ["k1", "k2"]) { app in
            for key in ["k1", "k2"] {
                try await app.test(.GET, "v1/vault", headers: bearer(key)) { res async in
                    XCTAssertNotEqual(res.status, .unauthorized)
                }
            }
        }
    }

    func testParseTrimsAndDropsEmpties() {
        XCTAssertEqual(APIKeyMiddleware.parse(" a , ,b "), ["a", "b"])
        XCTAssertEqual(APIKeyMiddleware.parse(nil), [])
    }

    func testNoKeysConfiguredRejectsAll() async throws {
        try await withApp(keys: []) { app in
            try await app.test(.GET, "v1/vault", headers: bearer("k1")) { res async in
                XCTAssertEqual(res.status, .unauthorized)
            }
            try await app.test(.GET, "v1/vault", headers: bearer("")) { res async in
                XCTAssertEqual(res.status, .unauthorized)
            }
        }
    }

    func testJSONUsesMillisecondDates() async throws {
        try await withApp(keys: ["k1", "k2"]) { app in
            struct Stamp: Content { var at: Date }
            app.get("test-date") { _ in Stamp(at: Date(timeIntervalSince1970: 1.5)) }
            try await app.test(.GET, "test-date") { res async in
                XCTAssertEqual(res.body.string, #"{"at":1500}"#)
            }
        }
    }
}
