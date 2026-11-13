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
            XCTAssertEqual(request.timeoutInterval, 30)
        }
    }
}
