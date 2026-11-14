import XCTest
@testable import CoreModels

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

final class AgentKeyChoiceTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000.123)

    func testChoiceRoundTripsPinnedAndUnpinned() throws {
        for choice in [AgentKeyChoice(publicKey: "ssh-ed25519 AAAAC3Nz me@mac"), AgentKeyChoice(publicKey: nil)] {
            let data = try CoreJSON.encoder.encode(choice)
            XCTAssertEqual(try CoreJSON.decoder.decode(AgentKeyChoice.self, from: data), choice)
        }
        XCTAssertNotEqual(AgentKeyChoice(publicKey: nil), AgentKeyChoice(publicKey: "ssh-ed25519 AAAA"))
        XCTAssertEqual(try CoreJSON.decoder.decode(AgentKeyChoice.self, from: Data("{}".utf8)), AgentKeyChoice(publicKey: nil))
    }

    func testHostAndIdentityCarryAgentKey() throws {
        let pinned = AgentKeyChoice(publicKey: "ssh-ed25519 AAAA k")
        var host = Host(label: "H", address: "a", sshKeyID: UUID(), agentKey: pinned, updatedAt: date)
        XCTAssertEqual(host.agentKey, pinned)
        let identity = Identity(label: "I", username: "u", agentKey: AgentKeyChoice(publicKey: nil), updatedAt: date)
        XCTAssertEqual(identity.agentKey, AgentKeyChoice(publicKey: nil))
        XCTAssertNil(Host(label: "x", address: "y").agentKey, "defaults to nil")
        XCTAssertNil(Identity(label: "x", username: "y").agentKey)

        for value in [host, { host.agentKey = nil; return host }()] {
            let data = try CoreJSON.encoder.encode(value)
            XCTAssertEqual(try CoreJSON.decoder.decode(Host.self, from: data), value)
        }
        let data = try CoreJSON.encoder.encode(identity)
        XCTAssertEqual(try CoreJSON.decoder.decode(Identity.self, from: data), identity)
    }

    func testRecordsWithoutAgentKeyDecode() throws {
        let host = Host(label: "Old", address: "10.0.0.2", agentKey: AgentKeyChoice(publicKey: "ssh-ed25519 AAAA"), updatedAt: date)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CoreJSON.encoder.encode(host)) as? [String: Any])
        XCTAssertNotNil(object["agentKey"])
        object.removeValue(forKey: "agentKey")
        let decodedHost = try CoreJSON.decoder.decode(Host.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decodedHost.agentKey)
        XCTAssertEqual(decodedHost.label, "Old")

        let identity = Identity(label: "Me", username: "cory", agentKey: AgentKeyChoice(publicKey: nil), updatedAt: date)
        var idObject = try XCTUnwrap(JSONSerialization.jsonObject(with: CoreJSON.encoder.encode(identity)) as? [String: Any])
        XCTAssertNotNil(idObject["agentKey"])
        idObject.removeValue(forKey: "agentKey")
        let decodedIdentity = try CoreJSON.decoder.decode(Identity.self, from: JSONSerialization.data(withJSONObject: idObject))
        XCTAssertNil(decodedIdentity.agentKey)
        XCTAssertEqual(decodedIdentity.username, "cory")
    }
}
