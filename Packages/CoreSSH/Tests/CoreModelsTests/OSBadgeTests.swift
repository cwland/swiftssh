import XCTest
@testable import CoreModels

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

final class OSBadgeTests: XCTestCase {
    /// Every value the 12-case enum ever stored, and the catalog id it now means.
    private let legacy: [String: String] = [
        "ubuntu": "ubuntu", "debian": "debian", "raspberryPiOS": "raspbian", "fedora": "fedora",
        "rhel": "rhel", "alpine": "alpine", "arch": "arch", "macOS": "macos", "freeBSD": "freebsd",
        "linux": "linux", "synology": "synology", "homeAssistant": "home-assistant",
    ]

    func testLegacyRawValuesMapToCatalogIDs() {
        for (old, new) in legacy {
            XCTAssertEqual(OSBadge(rawValue: old).rawValue, new, old)
            XCTAssertEqual(OSBadge(rawValue: new).rawValue, new, new)
        }
        XCTAssertEqual(OSBadge(rawValue: "proxmox").rawValue, "proxmox")
        XCTAssertEqual(OSBadge.raspbian, OSBadge(rawValue: "raspberryPiOS"))
        XCTAssertEqual(OSBadge.macos, OSBadge(rawValue: "macOS"))
        XCTAssertEqual(OSBadge.freebsd, OSBadge(rawValue: "freeBSD"))
        XCTAssertEqual(OSBadge.homeAssistant.rawValue, "home-assistant")
    }

    func testDecodesLegacyStoredValuesAndRoundTrips() throws {
        for (old, new) in legacy {
            let json = Data("[\"\(old)\"]".utf8)
            let decoded = try JSONDecoder().decode([OSBadge].self, from: json)
            XCTAssertEqual(decoded.map(\.rawValue), [new], old)
            let reencoded = try JSONEncoder().encode(decoded)
            XCTAssertEqual(String(decoding: reencoded, as: UTF8.self), "[\"\(new)\"]", old)
            XCTAssertEqual(try JSONDecoder().decode([OSBadge].self, from: reencoded), decoded, old)
        }
    }

    func testUnknownFutureIDsDecodeAndRoundTrip() throws {
        let json = Data("[\"plan9\",\"some-new-os\"]".utf8)
        let decoded = try JSONDecoder().decode([OSBadge].self, from: json)
        XCTAssertEqual(decoded.map(\.rawValue), ["plan9", "some-new-os"])
        XCTAssertEqual(try JSONEncoder().encode(decoded), json)
    }

    func testNonStringIsADecodingError() {
        XCTAssertThrowsError(try JSONDecoder().decode([OSBadge].self, from: Data("[1]".utf8)))
    }

    /// Host records synced from a build with the old enum keep decoding, and re-encode with the catalog id.
    func testHostWithLegacyBadgeDecodesAndRoundTrips() throws {
        let original = Host(label: "pi", address: "10.0.0.2", osBadge: OSBadge(rawValue: "raspbian"), osBadgeIsManual: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CoreJSON.encoder.encode(original)) as? [String: Any])
        for (old, new) in legacy {
            object["osBadge"] = old
            let data = try JSONSerialization.data(withJSONObject: object)
            let host = try CoreJSON.decoder.decode(Host.self, from: data)
            XCTAssertEqual(host.osBadge?.rawValue, new, old)
            XCTAssertTrue(host.osBadgeIsManual)
            let again = try CoreJSON.decoder.decode(Host.self, from: CoreJSON.encoder.encode(host))
            XCTAssertEqual(again, host, old)
        }
        object["osBadge"] = "a-future-os"
        let future = try CoreJSON.decoder.decode(Host.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(future.osBadge?.rawValue, "a-future-os")
        XCTAssertEqual(try CoreJSON.decoder.decode(Host.self, from: CoreJSON.encoder.encode(future)), future)
        object.removeValue(forKey: "osBadge")
        XCTAssertNil(try CoreJSON.decoder.decode(Host.self, from: JSONSerialization.data(withJSONObject: object)).osBadge)
    }
}
