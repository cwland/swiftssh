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

    /// A 302 (e.g. a proxy sending http → https or adding a slash) must not be followed: the
    /// redirect target never sees the request, so the Bearer key can't leak to it.
    func testRedirectsAreNotFollowedAndMapToRedirected() async throws {
        let target = try LoopbackHTTPServer { _ in
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        }
        defer { target.stop() }
        let targetPort = target.port
        let redirector = try LoopbackHTTPServer { head in
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            return "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(targetPort)\(path)\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        }
        defer { redirector.stop() }

        let t = HTTPSyncTransport(baseURL: redirector.baseURL, apiKey: "secret-key-123")
        let calls: [() async throws -> Void] = [
            { _ = try await t.getVault() },
            { try await t.health() },
            { _ = try await t.fetch(since: 0, limit: 500) },
        ]
        for call in calls {
            do {
                try await call()
                XCTFail("expected redirected")
            } catch let error as SyncTransportError {
                XCTAssertEqual(error, .redirected)
            }
        }
        XCTAssertEqual(redirector.requests.count, 3)
        XCTAssertTrue(redirector.requests[0].contains("Bearer secret-key-123"), "sanity: the key went to the first hop")
        XCTAssertEqual(target.requests, [], "the redirect target never received a request")
        XCTAssertFalse(target.requests.joined().contains("secret-key-123"))
    }

    func testAnyThreeHundredStatusMapsToRedirected() {
        for status in [301, 302, 303, 307, 308] {
            XCTAssertEqual(HTTPSyncTransport.statusError(status, Data()) as? SyncTransportError, .redirected)
        }
    }

    func testATSBlockMapsToInsecureConnectionBlocked() {
        XCTAssertEqual(HTTPSyncTransport.transportError(for: URLError(.appTransportSecurityRequiresSecureConnection))
                       as? SyncTransportError, .insecureConnectionBlocked)
        XCTAssertEqual(HTTPSyncTransport.transportError(for: URLError(.cannotConnectToHost)) as? SyncTransportError,
                       .unreachable("the connection was refused"))
        XCTAssertTrue(HTTPSyncTransport.transportError(for: URLError(.cancelled)) is CancellationError)
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
