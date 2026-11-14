import Foundation
import Crypto
import _CryptoExtras
import CoreModels

public struct GeneratedKey: Equatable, Sendable {
    public var keyType: KeyType
    /// authorized_keys line, e.g. `ssh-ed25519 AAAA… comment`.
    public var publicKey: String
    /// Unencrypted PEM text: OpenSSH format for Ed25519, PKCS#1 for RSA.
    public var privateKey: String

    public init(keyType: KeyType, publicKey: String, privateKey: String) {
        self.keyType = keyType; self.publicKey = publicKey; self.privateKey = privateKey
    }
}

public enum SSHKeyGenerator {
    public static func ed25519(comment: String) -> GeneratedKey {
        let key = Curve25519.Signing.PrivateKey()
        let seed = Array(key.rawRepresentation)
        let publicBytes = Array(key.publicKey.rawRepresentation)
        let algorithm = "ssh-ed25519"
        let publicBlob = OpenSSHFormat.string(algorithm) + OpenSSHFormat.string(publicBytes)

        let check = UInt32.random(in: .min ... .max)
        var privateSection = OpenSSHFormat.uint32(check) + OpenSSHFormat.uint32(check)
        privateSection += OpenSSHFormat.string(algorithm)
        privateSection += OpenSSHFormat.string(publicBytes)
        privateSection += OpenSSHFormat.string(seed + publicBytes)
        privateSection += OpenSSHFormat.string(comment)
        // Cipher "none" has an 8-byte block size; pad with 1, 2, 3, …
        var pad: UInt8 = 1
        while privateSection.count % 8 != 0 {
            privateSection.append(pad)
            pad += 1
        }

        var body = Array("openssh-key-v1\0".utf8)
        body += OpenSSHFormat.string("none") // ciphername
        body += OpenSSHFormat.string("none") // kdfname
        body += OpenSSHFormat.string([UInt8]()) // kdfoptions
        body += OpenSSHFormat.uint32(1) // number of keys
        body += OpenSSHFormat.string(publicBlob)
        body += OpenSSHFormat.string(privateSection)

        return GeneratedKey(
            keyType: .ed25519,
            publicKey: publicLine(algorithm: algorithm, blob: publicBlob, comment: comment),
            privateKey: OpenSSHFormat.pem(label: "OPENSSH PRIVATE KEY", body: body, lineLength: 70)
        )
    }

    public static func rsa4096(comment: String) throws -> GeneratedKey {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits4096)
        let (n, e) = try OpenSSHFormat.rsaPublicKeyComponents(der: Array(key.publicKey.derRepresentation))
        let algorithm = "ssh-rsa"
        let publicBlob = OpenSSHFormat.string(algorithm) + OpenSSHFormat.mpint(e) + OpenSSHFormat.mpint(n)
        let pkcs1 = try OpenSSHFormat.rsaPKCS1PrivateKey(der: Array(key.derRepresentation))

        return GeneratedKey(
            keyType: .rsa,
            publicKey: publicLine(algorithm: algorithm, blob: publicBlob, comment: comment),
            privateKey: OpenSSHFormat.pem(label: "RSA PRIVATE KEY", body: pkcs1, lineLength: 64)
        )
    }

    private static func publicLine(algorithm: String, blob: [UInt8], comment: String) -> String {
        let line = "\(algorithm) \(Data(blob).base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }
}
