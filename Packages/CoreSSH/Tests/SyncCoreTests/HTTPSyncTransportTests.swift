import XCTest
@testable import SyncCore

final class HTTPSyncTransportTests: XCTestCase {
    func testURLJoiningHandlesTrailingSlash() {
        for base in ["http://nas:8080/", "http://nas:8080"] {
            let transport = HTTPSyncTransport(baseURL: URL(string: base)!, apiKey: "k")
            XCTAssertEqual(transport.url("/v1/records?since=0&limit=500").absoluteString,
                           "http://nas:8080/v1/records?since=0&limit=500")
        }
    }
}
