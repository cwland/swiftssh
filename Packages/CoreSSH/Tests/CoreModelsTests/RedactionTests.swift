import XCTest
@testable import CoreModels

/// Foundation also exports a `Host` on macOS.
private typealias Host = CoreModels.Host

final class RedactionTests: XCTestCase {
    private func assertRedacted<T>(
        _ value: T, hiding secrets: [String], showing visible: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for text in [String(describing: value), String(reflecting: value), "\(value)"] {
            for secret in secrets {
                XCTAssertFalse(text.contains(secret), "\(secret) leaked", file: file, line: line)
            }
            for shown in visible {
                XCTAssertTrue(text.contains(shown), "\(shown) missing from \(text)", file: file, line: line)
            }
            XCTAssertTrue(text.contains("<redacted>"), text, file: file, line: line)
        }
    }

    func testSSHKeyHidesPrivateKeyAndPassphrase() {
        let key = SSHKey(label: "laptop", keyType: .ed25519, publicKey: "ssh-ed25519 AAAAPUBLIC",
                         privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----SECRETBODY", passphrase: "hunter2")
        assertRedacted(key, hiding: ["SECRETBODY", "hunter2"],
                       showing: ["SSHKey", "laptop", "ed25519", "ssh-ed25519 AAAAPUBLIC"])
    }

    func testSSHKeyWithoutPassphraseStillHidesPrivateKey() {
        let key = SSHKey(label: "k", keyType: .rsa, publicKey: "ssh-rsa AAAA", privateKey: "PRIVATEBODY")
        assertRedacted(key, hiding: ["PRIVATEBODY"], showing: ["rsa", "ssh-rsa AAAA"])
    }

    func testIdentityHidesPassword() {
        let identity = Identity(label: "cory creds", username: "cory", password: "s3cret-pw")
        assertRedacted(identity, hiding: ["s3cret-pw"], showing: ["Identity", "cory creds", "cory"])
    }

    func testHostHidesPassword() {
        let host = Host(label: "docker", address: "10.0.0.5", username: "root", password: "s3cret-pw")
        assertRedacted(host, hiding: ["s3cret-pw"], showing: ["Host", "docker", "10.0.0.5", "root"])
    }

    func testAISettingsHidesAPIKey() {
        let settings = AISettings(baseURL: "https://api.example", model: "m1", apiKey: "sk-SECRETKEY")
        assertRedacted(settings, hiding: ["sk-SECRETKEY"], showing: ["AISettings", "https://api.example", "m1"])
    }

    func testDescriptionsDoNotAffectEqualityOrCoding() throws {
        let key = SSHKey(label: "k", keyType: .ed25519, publicKey: "pub", privateKey: "priv", passphrase: "pp",
                         updatedAt: Date(timeIntervalSince1970: 1_700_000_000.123))
        let decoded = try CoreJSON.decoder.decode(SSHKey.self, from: CoreJSON.encoder.encode(key))
        XCTAssertEqual(decoded, key)
        XCTAssertEqual(decoded.privateKey, "priv")
        XCTAssertEqual(decoded.passphrase, "pp")
    }
}
