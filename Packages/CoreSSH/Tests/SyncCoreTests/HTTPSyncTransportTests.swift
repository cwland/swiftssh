import XCTest
@testable import SyncCore

final class HTTPSyncTransportTests: XCTestCase {
    private func transport(_ base: String, key: String = "k") -> HTTPSyncTransport {
        HTTPSyncTransport(baseURL: URL(string: base)!, apiKey: key)
    }

    func testURLJoiningHandlesTrailingSlash() {
        for base in ["http://nas:8080/", "http://nas:8080"] {
            let request = transport(base).makeRequest(method: "GET", path: "/v1/records",
                                                      query: [("since", "0"), ("limit", "500")])
            XCTAssertEqual(request.url?.absoluteString, "http://nas:8080/v1/records?since=0&limit=500")
        }
    }

    func testFetchBuildsSinceAndLimitQuery() {
        let request = transport("http://nas:8080").makeRequest(method: "GET", path: "/v1/records",
                                                               query: [("since", "7"), ("limit", "500")])
        XCTAssertEqual(request.url?.absoluteString, "http://nas:8080/v1/records?since=7&limit=500")
    }

    func testBaseURLPathPrefixIsKept() {
        let request = transport("https://host/sync/").makeRequest(method: "GET", path: "/v1/vault")
        XCTAssertEqual(request.url?.absoluteString, "https://host/sync/v1/vault")
    }

    func testEveryRequestCarriesKeyAndTimeout() {
        let t = transport("http://nas:8080", key: "secret-key")
        for request in [t.makeRequest(method: "GET", path: "/v1/vault"),
                        t.makeRequest(method: "POST", path: "/v1/records", body: Data("{}".utf8))] {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
            XCTAssertEqual(request.timeoutInterval, 20)
        }
    }

    func testPathPrefixWithoutTrailingSlashIsKept() {
        let request = transport("https://h/sync").makeRequest(method: "GET", path: "/v1/records")
        XCTAssertEqual(request.url?.absoluteString, "https://h/sync/v1/records")
    }

    func testHealthRequestHasNoAuthorization() {
        let request = transport("https://h/sync/", key: "secret-key")
            .makeRequest(method: "GET", path: "/health", authenticated: false)
        XCTAssertEqual(request.url?.absoluteString, "https://h/sync/health")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.timeoutInterval, 20)
    }

    func testUnauthorizedAndForbiddenMapToUnauthorized() {
        XCTAssertEqual(HTTPSyncTransport.statusError(401, Data()) as? SyncTransportError, .unauthorized)
        XCTAssertEqual(HTTPSyncTransport.statusError(403, Data()) as? SyncTransportError, .unauthorized)
        XCTAssertNil(HTTPSyncTransport.statusError(204, Data()))
        XCTAssertEqual(HTTPSyncTransport.statusError(502, Data(#"{"error":"Bad gateway"}"#.utf8)) as? SyncTransportError,
                       .http(status: 502, message: "Bad gateway"))
    }

    func testConnectionFailureMapsToUnreachableWithoutTheKey() async {
        // Port 1 on loopback: nothing listens, so the connection is refused at once.
        let t = transport("http://127.0.0.1:1", key: "secret-key-123")
        for call in [{ _ = try await t.getVault() }, { try await t.health() }] as [() async throws -> Void] {
            do {
                try await call()
                XCTFail("expected unreachable")
            } catch SyncTransportError.unreachable(let message) {
                XCTAssertFalse(message.isEmpty)
                XCTAssertFalse(message.contains("secret-key-123"))
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }
}
