import Citadel
import Crypto
import Foundation

/// Reads an OpenSSH Ed25519 private key (`-----BEGIN OPENSSH PRIVATE KEY-----`), decrypting it with the
/// passphrase when it is encrypted (bcrypt KDF with aes128-ctr or aes256-ctr, what `ssh-keygen` writes).
/// Errors carry no key material.
public enum OpenSSHKeyReader {
    public enum ReadError: Error, Equatable {
        /// Wrong or missing passphrase, a corrupt key, or an encryption this reader can't undo.
        case unreadable
    }

    /// The ciphers `ed25519(pem:passphrase:)` can decrypt (plus "none").
    public static let supportedCiphers: Set<String> = ["none", "aes128-ctr", "aes256-ctr"]

    public static func ed25519(pem: String, passphrase: String?) throws(ReadError) -> Curve25519.Signing.PrivateKey {
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        do {
            return try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: decryptionKey)
        } catch {
            throw .unreadable
        }
    }
}
