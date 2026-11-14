import XCTest
import Crypto
import _CryptoExtras
import CoreModels
@testable import AppCore

/// Reads the SSH wire encoding (RFC 4251) back out of generated keys.
private struct SSHWireReader {
    private var bytes: ArraySlice<UInt8>

    init(_ bytes: [UInt8]) { self.bytes = bytes[...] }

    var isAtEnd: Bool { bytes.isEmpty }
    var remaining: [UInt8] { Array(bytes) }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, bytes.count >= count else { throw ReadError.truncated }
        let out = Array(bytes.prefix(count))
        bytes = bytes.dropFirst(count)
        return out
    }

    mutating func uint32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string() throws -> [UInt8] {
        try take(Int(uint32()))
    }

    mutating func text() throws -> String {
        String(decoding: try string(), as: UTF8.self)
    }

    enum ReadError: Error { case truncated }
}

private func publicBlob(_ line: String) throws -> [UInt8] {
    let fields = line.split(separator: " ")
    XCTAssertGreaterThanOrEqual(fields.count, 2)
    return try XCTUnwrap(Data(base64Encoded: String(fields[1]))).map { $0 }
}

private func pemBody(_ pem: String, label: String) throws -> [UInt8] {
    let begin = "-----BEGIN \(label)-----\n"
    let end = "-----END \(label)-----\n"
    XCTAssertTrue(pem.hasPrefix(begin), pem)
    XCTAssertTrue(pem.hasSuffix(end), pem)
    let body = pem.dropFirst(begin.count).dropLast(end.count)
    return try XCTUnwrap(Data(base64Encoded: body.replacingOccurrences(of: "\n", with: ""))).map { $0 }
}

final class SSHKeyGeneratorTests: XCTestCase {
    /// RSA-4096 generation takes seconds; generate once for the whole class.
    nonisolated(unsafe) private static var sharedRSA: GeneratedKey?

    private func rsaKey() throws -> GeneratedKey {
        if let key = Self.sharedRSA { return key }
        let key = try SSHKeyGenerator.rsa4096(comment: "cory@mac-mini")
        Self.sharedRSA = key
        return key
    }

    // MARK: - Ed25519

    func testEd25519PublicKeyFormat() throws {
        let key = SSHKeyGenerator.ed25519(comment: "cory@mac-mini")
        XCTAssertEqual(key.keyType, .ed25519)
        XCTAssertTrue(key.publicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"), key.publicKey)
        XCTAssertTrue(key.publicKey.hasSuffix(" cory@mac-mini"), key.publicKey)

        var reader = SSHWireReader(try publicBlob(key.publicKey))
        XCTAssertEqual(try reader.text(), "ssh-ed25519")
        XCTAssertEqual(try reader.string().count, 32)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testEd25519PublicKeyWithoutCommentHasNoTrailingSpace() {
        let key = SSHKeyGenerator.ed25519(comment: "")
        XCTAssertEqual(key.publicKey.split(separator: " ").count, 2)
        XCTAssertFalse(key.publicKey.hasSuffix(" "))
    }

    func testEd25519PrivateKeyStructure() throws {
        let key = SSHKeyGenerator.ed25519(comment: "cory@mac-mini")
        let lines = key.privateKey.split(separator: "\n")
        XCTAssertTrue(lines.dropFirst().dropLast().allSatisfy { $0.count <= 70 })
        XCTAssertEqual(lines.dropFirst().dropLast().dropLast().map(\.count).max(), 70)

        let body = try pemBody(key.privateKey, label: "OPENSSH PRIVATE KEY")
        var reader = SSHWireReader(body)
        XCTAssertEqual(try reader.take(15), Array("openssh-key-v1\0".utf8))
        XCTAssertEqual(try reader.text(), "none")
        XCTAssertEqual(try reader.text(), "none")
        XCTAssertEqual(try reader.string(), [])
        XCTAssertEqual(try reader.uint32(), 1)
        let embeddedPublic = try reader.string()
        XCTAssertEqual(embeddedPublic, try publicBlob(key.publicKey))
        let privateSection = try reader.string()
        XCTAssertTrue(reader.isAtEnd)

        XCTAssertEqual(privateSection.count % 8, 0)
        var section = SSHWireReader(privateSection)
        let check1 = try section.uint32()
        let check2 = try section.uint32()
        XCTAssertEqual(check1, check2)
        XCTAssertEqual(try section.text(), "ssh-ed25519")
        let publicBytes = try section.string()
        let privateBytes = try section.string()
        XCTAssertEqual(try section.text(), "cory@mac-mini")
        let padding = section.remaining
        XCTAssertLessThan(padding.count, 8)
        XCTAssertEqual(padding, (0..<padding.count).map { UInt8($0 + 1) })

        var embedded = SSHWireReader(embeddedPublic)
        _ = try embedded.string()
        XCTAssertEqual(publicBytes, try embedded.string())
        XCTAssertEqual(privateBytes.count, 64)
        XCTAssertEqual(Array(privateBytes.suffix(32)), publicBytes)
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateBytes.prefix(32))
        XCTAssertEqual(Array(signingKey.publicKey.rawRepresentation), publicBytes)
    }

    func testEd25519KeysAreUnique() {
        let first = SSHKeyGenerator.ed25519(comment: "a")
        let second = SSHKeyGenerator.ed25519(comment: "a")
        XCTAssertNotEqual(first.publicKey, second.publicKey)
        XCTAssertNotEqual(first.privateKey, second.privateKey)
    }

    // MARK: - Wire helpers

    func testMpintAddsLeadingZeroWhenHighBitSet() {
        XCTAssertEqual(OpenSSHFormat.mpint([0x80]), [0, 0, 0, 2, 0x00, 0x80])
        XCTAssertEqual(OpenSSHFormat.mpint([0x7f]), [0, 0, 0, 1, 0x7f])
    }

    func testMpintStripsRedundantLeadingZeros() {
        XCTAssertEqual(OpenSSHFormat.mpint([0x00, 0x00, 0x01, 0x00, 0x01]), [0, 0, 0, 3, 0x01, 0x00, 0x01])
        XCTAssertEqual(OpenSSHFormat.mpint([0x00, 0x80]), [0, 0, 0, 2, 0x00, 0x80])
        XCTAssertEqual(OpenSSHFormat.mpint([0x00]), [0, 0, 0, 0])
    }

    func testStringAndUInt32() {
        XCTAssertEqual(OpenSSHFormat.uint32(0x0102_0304), [1, 2, 3, 4])
        XCTAssertEqual(OpenSSHFormat.string("none"), [0, 0, 0, 4] + Array("none".utf8))
        XCTAssertEqual(OpenSSHFormat.string([UInt8]()), [0, 0, 0, 0])
    }

    func testDERReaderRejectsGarbage() {
        XCTAssertThrowsError(try OpenSSHFormat.rsaPublicKeyComponents(der: [0x30, 0x05, 0x02]))
        XCTAssertThrowsError(try OpenSSHFormat.rsaPublicKeyComponents(der: []))
    }

    // MARK: - RSA

    func testRSA4096PublicKeyFormat() throws {
        let key = try rsaKey()
        XCTAssertEqual(key.keyType, .rsa)
        XCTAssertTrue(key.publicKey.hasPrefix("ssh-rsa AAAAB3NzaC1yc2E"), key.publicKey)
        XCTAssertTrue(key.publicKey.hasSuffix(" cory@mac-mini"), key.publicKey)

        var reader = SSHWireReader(try publicBlob(key.publicKey))
        XCTAssertEqual(try reader.text(), "ssh-rsa")
        let e = try reader.string()
        let n = try reader.string()
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertEqual(e, [0x01, 0x00, 0x01])
        // A 4096-bit modulus has its top bit set, so its mpint carries one leading zero byte.
        XCTAssertEqual(n.count, 513)
        XCTAssertEqual(n[0], 0x00)
        XCTAssertGreaterThanOrEqual(n[1], 0x80)
    }

    func testRSAPrivateKeyIsPKCS1PEM() throws {
        let key = try rsaKey()
        let der = try pemBody(key.privateKey, label: "RSA PRIVATE KEY")
        XCTAssertTrue(key.privateKey.split(separator: "\n").dropFirst().dropLast().allSatisfy { $0.count <= 64 })
        // PKCS#1 RSAPrivateKey: SEQUENCE { INTEGER version(0), INTEGER n, ... } — no PKCS#8 AlgorithmIdentifier.
        XCTAssertEqual(der[0], 0x30)
        let headerLength = der[1] & 0x80 == 0 ? 2 : 2 + Int(der[1] & 0x7f)
        XCTAssertEqual(Array(der[headerLength..<headerLength + 3]), [0x02, 0x01, 0x00])
        XCTAssertEqual(der[headerLength + 3], 0x02)

        let reloaded = try _RSA.Signing.PrivateKey(derRepresentation: der)
        XCTAssertEqual(reloaded.keySizeInBits, 4096)
        let components = try OpenSSHFormat.rsaPublicKeyComponents(der: Array(reloaded.publicKey.derRepresentation))
        let expected = OpenSSHFormat.string("ssh-rsa") + OpenSSHFormat.mpint(components.e) + OpenSSHFormat.mpint(components.n)
        XCTAssertEqual(try publicBlob(key.publicKey), expected)
    }

    func testDERReaderAcceptsSPKIAndPKCS1PublicKeys() throws {
        let der = try pemBody(try rsaKey().privateKey, label: "RSA PRIVATE KEY")
        let publicKey = try _RSA.Signing.PrivateKey(derRepresentation: der).publicKey
        let fromSPKI = try OpenSSHFormat.rsaPublicKeyComponents(der: Array(publicKey.derRepresentation))
        let fromPKCS1 = try OpenSSHFormat.rsaPublicKeyComponents(der: Array(publicKey.pkcs1DERRepresentation))
        XCTAssertEqual(fromSPKI.n, fromPKCS1.n)
        XCTAssertEqual(fromSPKI.e, fromPKCS1.e)
        XCTAssertEqual(OpenSSHFormat.mpint(fromSPKI.e), [0, 0, 0, 3, 0x01, 0x00, 0x01])
    }

    func testGeneratedKeyDescriptionHidesPrivateKey() {
        let key = GeneratedKey(keyType: .ed25519, publicKey: "ssh-ed25519 AAAAPUBLIC c",
                               privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----SECRETBODY")
        for text in [String(describing: key), String(reflecting: key)] {
            XCTAssertFalse(text.contains("SECRETBODY"), text)
            XCTAssertTrue(text.contains("<redacted>"), text)
            XCTAssertTrue(text.contains("GeneratedKey"), text)
            XCTAssertTrue(text.contains("ed25519"), text)
            XCTAssertTrue(text.contains("ssh-ed25519 AAAAPUBLIC c"), text)
        }
    }
}
