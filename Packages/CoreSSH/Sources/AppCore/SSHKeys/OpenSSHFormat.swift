import Foundation

public enum OpenSSHFormatError: Error, Equatable {
    case malformedDER
}

/// SSH wire encoding (RFC 4251 §5), PEM armor, and the minimal DER reading needed to turn
/// swift-crypto RSA keys into OpenSSH formats.
public enum OpenSSHFormat {
    // MARK: - SSH wire encoding

    public static func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    public static func string(_ bytes: [UInt8]) -> [UInt8] {
        uint32(UInt32(bytes.count)) + bytes
    }

    public static func string(_ text: String) -> [UInt8] {
        string(Array(text.utf8))
    }

    /// Encodes a non-negative big-endian magnitude as an SSH mpint: redundant leading zeros are
    /// dropped, and one 0x00 is prepended when the high bit is set so the value stays positive
    /// in two's complement. Zero encodes as an empty string.
    public static func mpint(_ magnitude: [UInt8]) -> [UInt8] {
        var bytes = Array(magnitude.drop(while: { $0 == 0 }))
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return string(bytes)
    }

    // MARK: - PEM

    /// `-----BEGIN label-----`, base64 body wrapped at `lineLength`, `-----END label-----`, trailing newline.
    public static func pem(label: String, body: [UInt8], lineLength: Int) -> String {
        let encoded = Data(body).base64EncodedString()
        var lines = ["-----BEGIN \(label)-----"]
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let next = encoded.index(index, offsetBy: lineLength, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<next]))
            index = next
        }
        lines.append("-----END \(label)-----")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - DER

    /// Extracts `n` and `e` (big-endian magnitudes) from either a PKCS#1
    /// `RSAPublicKey ::= SEQUENCE { n INTEGER, e INTEGER }` or an X.509
    /// `SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING(RSAPublicKey) }`.
    public static func rsaPublicKeyComponents(der: [UInt8]) throws -> (n: [UInt8], e: [UInt8]) {
        var outer = DERReader(der)
        var sequence = DERReader(try outer.read(tag: DERReader.sequence))
        try outer.expectEnd()

        if sequence.peekTag == DERReader.sequence {
            _ = try sequence.read(tag: DERReader.sequence) // AlgorithmIdentifier
            let bitString = try sequence.read(tag: DERReader.bitString)
            try sequence.expectEnd()
            guard bitString.first == 0 else { throw OpenSSHFormatError.malformedDER } // no unused bits
            return try rsaPublicKeyComponents(der: Array(bitString.dropFirst()))
        }

        let n = try sequence.read(tag: DERReader.integer)
        let e = try sequence.read(tag: DERReader.integer)
        try sequence.expectEnd()
        return (Array(n.drop(while: { $0 == 0 })), Array(e.drop(while: { $0 == 0 })))
    }

    /// Returns the PKCS#1 `RSAPrivateKey` DER, unwrapping a PKCS#8 `PrivateKeyInfo` if needed.
    public static func rsaPKCS1PrivateKey(der: [UInt8]) throws -> [UInt8] {
        var outer = DERReader(der)
        var sequence = DERReader(try outer.read(tag: DERReader.sequence))
        try outer.expectEnd()
        _ = try sequence.read(tag: DERReader.integer) // version
        switch sequence.peekTag {
        case DERReader.integer: // PKCS#1: modulus follows the version
            return der
        case DERReader.sequence: // PKCS#8: AlgorithmIdentifier, then OCTET STRING(RSAPrivateKey)
            _ = try sequence.read(tag: DERReader.sequence)
            return try rsaPKCS1PrivateKey(der: try sequence.read(tag: DERReader.octetString))
        default:
            throw OpenSSHFormatError.malformedDER
        }
    }
}

/// Reads definite-length DER TLVs with single-byte tags.
struct DERReader {
    static let integer: UInt8 = 0x02
    static let bitString: UInt8 = 0x03
    static let octetString: UInt8 = 0x04
    static let sequence: UInt8 = 0x30

    private var bytes: ArraySlice<UInt8>

    init(_ bytes: [UInt8]) { self.bytes = bytes[...] }

    var peekTag: UInt8? { bytes.first }

    mutating func read(tag: UInt8) throws -> [UInt8] {
        guard bytes.count >= 2, bytes[bytes.startIndex] == tag else { throw OpenSSHFormatError.malformedDER }
        var index = bytes.startIndex + 1
        let first = bytes[index]
        index += 1
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7f)
            guard (1...4).contains(count), bytes.endIndex - index >= count else { throw OpenSSHFormatError.malformedDER }
            for byte in bytes[index..<index + count] { length = length << 8 | Int(byte) }
            index += count
        }
        guard bytes.endIndex - index >= length else { throw OpenSSHFormatError.malformedDER }
        let value = Array(bytes[index..<index + length])
        bytes = bytes[(index + length)...]
        return value
    }

    func expectEnd() throws {
        guard bytes.isEmpty else { throw OpenSSHFormatError.malformedDER }
    }
}
