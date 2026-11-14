import Foundation
import Crypto
import CoreModels

/// What the importer learned about a private key without decrypting it.
public struct ImportedKey: Equatable, Sendable {
    public var keyType: KeyType
    /// authorized_keys line derived from the key, or nil when it cannot be known without the passphrase.
    public var publicKey: String?
    public var isEncrypted: Bool

    public init(keyType: KeyType, publicKey: String?, isEncrypted: Bool) {
        self.keyType = keyType; self.publicKey = publicKey; self.isEncrypted = isEncrypted
    }
}

/// Import failures. Cases and descriptions never carry key material; `unsupportedKeyType` only
/// carries a short algorithm identifier such as `ecdsa-sha2-nistp256`.
public enum SSHKeyImportError: Error, Equatable, LocalizedError {
    case unrecognizedFormat
    case unsupportedKeyType(String)
    case encryptedPKCS8Unsupported

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            "This doesn't look like an OpenSSH or PEM key."
        case .unsupportedKeyType(let name):
            "\(name) keys aren't supported. Use an Ed25519 or RSA key."
        case .encryptedPKCS8Unsupported:
            "Encrypted PKCS#8 keys aren't supported. Convert the key to OpenSSH format first, for example with ssh-keygen -p -f <file>."
        }
    }
}

/// Identifies OpenSSH, PKCS#1 and PKCS#8 private keys and authorized_keys lines. Never decrypts:
/// encrypted keys are reported as such, with the public key when the format stores it in the clear.
public enum SSHKeyImporter {
    /// Undoes text substitutions (smart dashes) that can hit a key typed or pasted into a text
    /// view: on armor lines (`-----BEGIN …-----` / `-----END …-----`) any leading or trailing run
    /// of "-", U+2013 or U+2014 becomes exactly five hyphens. Other lines are left unchanged.
    public static func normalizePastedKey(_ text: String) -> String {
        let dashes: Set<Character> = ["-", "\u{2013}", "\u{2014}"]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var body = Substring(line)
            var carriageReturn = ""
            if body.hasSuffix("\r") {
                body = body.dropLast()
                carriageReturn = "\r"
            }
            let core = body.drop(while: { dashes.contains($0) })
            guard core.count < body.count else { return String(line) }
            var end = core.endIndex
            while end > core.startIndex, dashes.contains(core[core.index(before: end)]) {
                end = core.index(before: end)
            }
            let label = core[core.startIndex..<end]
            guard end < core.endIndex, label.hasPrefix("BEGIN ") || label.hasPrefix("END ") else {
                return String(line)
            }
            return "-----" + label + "-----" + carriageReturn
        }
        return lines.joined(separator: "\n")
    }

    public static func inspect(privateKey: String) throws -> ImportedKey {
        let armor = try PEMArmor(privateKey)
        switch armor.label {
        case "ENCRYPTED PRIVATE KEY":
            throw SSHKeyImportError.encryptedPKCS8Unsupported
        case "EC PRIVATE KEY":
            throw SSHKeyImportError.unsupportedKeyType("ecdsa")
        case "DSA PRIVATE KEY":
            throw SSHKeyImportError.unsupportedKeyType("dsa")
        case "RSA PRIVATE KEY":
            if armor.isEncrypted { return ImportedKey(keyType: .rsa, publicKey: nil, isEncrypted: true) }
            return try parsing { try rsaKey(pkcs1: armor.body) }
        case "PRIVATE KEY" where armor.headers.isEmpty:
            return try parsing { try pkcs8Key(armor.body) }
        case "OPENSSH PRIVATE KEY" where armor.headers.isEmpty:
            return try parsing { try openSSHKey(armor.body) }
        default:
            throw SSHKeyImportError.unrecognizedFormat
        }
    }

    /// Parses an authorized_keys-style line `algorithm base64 [comment]` and returns its type and the
    /// line normalized to single spaces with surrounding whitespace removed.
    public static func parsePublicKey(_ line: String) throws -> (KeyType, String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline) else { throw SSHKeyImportError.unrecognizedFormat }
        let fields = trimmed.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2, let decoded = Data(base64Encoded: String(fields[1])) else {
            throw SSHKeyImportError.unrecognizedFormat
        }
        let blob = Array(decoded)
        guard try parsing({ try algorithmName(blob) }) == fields[0] else { throw SSHKeyImportError.unrecognizedFormat }
        let (keyType, _) = try parsing { try publicBlob(blob) }
        let comment = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
        return (keyType, try publicLine(blob: blob, comment: comment))
    }

    // MARK: - OpenSSH (openssh-key-v1, PROTOCOL.key)

    private static func openSSHKey(_ body: [UInt8]) throws -> ImportedKey {
        let magic = Array("openssh-key-v1\0".utf8)
        guard body.starts(with: magic) else { throw SSHKeyImportError.unrecognizedFormat }
        var reader = SSHWireReader(Array(body.dropFirst(magic.count)))
        let cipher = try reader.string()
        _ = try reader.string() // kdfname
        _ = try reader.string() // kdfoptions
        guard try reader.uint32() == 1 else { throw SSHKeyImportError.unrecognizedFormat }
        let blob = try reader.string()
        let (keyType, publicKey) = try publicBlob(blob)
        let privateSection = try reader.string()

        guard cipher == Array("none".utf8) else {
            // The public blob is stored in the clear; the private section (and any AEAD tag after it) is not.
            return ImportedKey(keyType: keyType, publicKey: try publicLine(blob: blob, comment: ""), isEncrypted: true)
        }
        try reader.expectEnd()

        var section = SSHWireReader(privateSection)
        guard try section.uint32() == section.uint32() else { throw SSHKeyImportError.unrecognizedFormat }
        guard try section.string() == Array(algorithmName(blob).utf8) else { throw SSHKeyImportError.unrecognizedFormat }
        switch (keyType, publicKey) {
        case (.ed25519, .ed25519(let expected)):
            let embedded = try section.string()
            let secret = try section.string()
            guard embedded == expected, secret.count == 64, Array(secret.suffix(32)) == expected else {
                throw SSHKeyImportError.unrecognizedFormat
            }
        case (.rsa, .rsa(let n, let e)):
            let embeddedN = try section.string()
            let embeddedE = try section.string()
            for _ in 0..<4 { _ = try section.string() } // d, iqmp, p, q
            guard magnitude(embeddedN) == n, magnitude(embeddedE) == e else { throw SSHKeyImportError.unrecognizedFormat }
        default:
            throw SSHKeyImportError.unrecognizedFormat
        }
        let comment = String(decoding: try section.string(), as: UTF8.self)
        // What remains is padding, shorter than the 8-byte block size of cipher "none".
        guard section.remainingCount < 8 else { throw SSHKeyImportError.unrecognizedFormat }
        return ImportedKey(keyType: keyType, publicKey: try publicLine(blob: blob, comment: displayableComment(comment)), isEncrypted: false)
    }

    // MARK: - PKCS#1 / PKCS#8

    private static let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    private static let ed25519OID: [UInt8] = [0x2B, 0x65, 0x70]
    private static let unsupportedOIDs: [[UInt8]: String] = [
        [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]: "ecdsa", // id-ecPublicKey
        [0x2A, 0x86, 0x48, 0xCE, 0x38, 0x04, 0x01]: "dsa",
        [0x2B, 0x65, 0x71]: "ed448",
    ]

    /// `RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dp, dq, qinv, … }`
    private static func rsaKey(pkcs1 der: [UInt8]) throws -> ImportedKey {
        var outer = DERReader(der)
        var sequence = DERReader(try outer.read(tag: DERReader.sequence))
        try outer.expectEnd()
        _ = try sequence.read(tag: DERReader.integer) // version
        let n = magnitude(try sequence.read(tag: DERReader.integer))
        let e = magnitude(try sequence.read(tag: DERReader.integer))
        guard !n.isEmpty, !e.isEmpty else { throw SSHKeyImportError.unrecognizedFormat }
        let blob = OpenSSHFormat.string("ssh-rsa") + OpenSSHFormat.mpint(e) + OpenSSHFormat.mpint(n)
        return ImportedKey(keyType: .rsa, publicKey: try publicLine(blob: blob, comment: ""), isEncrypted: false)
    }

    /// `PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, OCTET STRING privateKey, … }`
    private static func pkcs8Key(_ der: [UInt8]) throws -> ImportedKey {
        var outer = DERReader(der)
        var sequence = DERReader(try outer.read(tag: DERReader.sequence))
        try outer.expectEnd()
        _ = try sequence.read(tag: DERReader.integer) // version
        var algorithm = DERReader(try sequence.read(tag: DERReader.sequence))
        let oid = try algorithm.read(tag: DERReader.objectIdentifier)
        let privateKey = try sequence.read(tag: DERReader.octetString)

        switch oid {
        case rsaEncryptionOID:
            return try rsaKey(pkcs1: privateKey)
        case ed25519OID: // RFC 8410: CurvePrivateKey ::= OCTET STRING (32-byte seed)
            var inner = DERReader(privateKey)
            let seed = try inner.read(tag: DERReader.octetString)
            try inner.expectEnd()
            guard seed.count == 32 else { throw SSHKeyImportError.unrecognizedFormat }
            let publicBytes = Array(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation)
            let blob = OpenSSHFormat.string("ssh-ed25519") + OpenSSHFormat.string(publicBytes)
            return ImportedKey(keyType: .ed25519, publicKey: try publicLine(blob: blob, comment: ""), isEncrypted: false)
        default:
            throw SSHKeyImportError.unsupportedKeyType(unsupportedOIDs[oid] ?? "unknown")
        }
    }

    // MARK: - Public key blobs

    private enum PublicKey: Equatable {
        case ed25519([UInt8])
        case rsa(n: [UInt8], e: [UInt8])
    }

    /// Validates an SSH public key blob, throwing `.unsupportedKeyType` for well-formed names of other algorithms.
    private static func publicBlob(_ blob: [UInt8]) throws -> (KeyType, PublicKey) {
        var reader = SSHWireReader(blob)
        let name = try algorithmName(blob)
        _ = try reader.string()
        switch name {
        case "ssh-ed25519":
            let key = try reader.string()
            try reader.expectEnd()
            guard key.count == 32 else { throw SSHKeyImportError.unrecognizedFormat }
            return (.ed25519, .ed25519(key))
        case "ssh-rsa":
            let e = magnitude(try reader.string())
            let n = magnitude(try reader.string())
            try reader.expectEnd()
            guard !n.isEmpty, !e.isEmpty else { throw SSHKeyImportError.unrecognizedFormat }
            return (.rsa, .rsa(n: n, e: e))
        default:
            throw SSHKeyImportError.unsupportedKeyType(name)
        }
    }

    /// The blob's leading algorithm name, accepted only when it looks like an SSH algorithm
    /// identifier, so that arbitrary bytes are never echoed back in an error.
    private static func algorithmName(_ blob: [UInt8]) throws -> String {
        var reader = SSHWireReader(blob)
        let name = try reader.string()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.@".utf8)
        guard (1...64).contains(name.count), name.allSatisfy(allowed.contains) else {
            throw SSHKeyImportError.unrecognizedFormat
        }
        return String(decoding: name, as: UTF8.self)
    }

    // MARK: - Helpers

    private static func publicLine(blob: [UInt8], comment: String) throws -> String {
        let line = "\(try algorithmName(blob)) \(Data(blob).base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// Drops a comment that would break an authorized_keys line.
    private static func displayableComment(_ comment: String) -> String {
        let trimmed = comment.trimmingCharacters(in: .whitespaces)
        return trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "" : trimmed
    }

    private static func magnitude(_ bytes: [UInt8]) -> [UInt8] {
        Array(bytes.drop(while: { $0 == 0 }))
    }

    /// Maps low-level parse failures to `.unrecognizedFormat`, keeping import errors as they are.
    private static func parsing<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as SSHKeyImportError {
            throw error
        } catch {
            throw SSHKeyImportError.unrecognizedFormat
        }
    }
}

/// PEM armor (RFC 7468, with RFC 1421 `Proc-Type`/`DEK-Info` headers), tolerant of CRLF and
/// stray whitespace. The first BEGIN/END block in the text is used.
private struct PEMArmor {
    var label: String
    var headers: [String]
    var body: [UInt8]

    var isEncrypted: Bool {
        headers.contains { $0.hasPrefix("Proc-Type:") && $0.contains("ENCRYPTED") }
    }

    init(_ text: String) throws {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let prefix = "-----BEGIN ", suffix = "-----"
        guard let begin = lines.firstIndex(where: { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) && $0.count > prefix.count + suffix.count }) else {
            throw SSHKeyImportError.unrecognizedFormat
        }
        label = String(lines[begin].dropFirst(prefix.count).dropLast(suffix.count))
        guard let end = lines[(begin + 1)...].firstIndex(of: "-----END \(label)-----") else {
            throw SSHKeyImportError.unrecognizedFormat
        }
        let content = lines[(begin + 1)..<end].filter { !$0.isEmpty }
        headers = content.filter { $0.contains(":") }
        guard let decoded = Data(base64Encoded: content.filter { !$0.contains(":") }.joined()), !decoded.isEmpty else {
            throw SSHKeyImportError.unrecognizedFormat
        }
        body = Array(decoded)
    }
}
