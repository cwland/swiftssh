import CoreModels
import Crypto
import Foundation
import Observation
import SSHCore
import Synchronization

/// A private key imported on this iPhone or iPad (for example exported from 1Password), described without
/// its secret. The key itself lives only in `ImportedKeyStorage` (the device Keychain); it is never written
/// to the vault and never synced.
public struct ImportedKeyInfo: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var type: KeyType
    /// authorized_keys line, "ssh-ed25519 AAAA… [comment]".
    public var publicKey: String
    /// `SHA256:…`, as `ssh-keygen -l` prints it.
    public var fingerprint: String
    public var importedAt: Date

    public init(id: UUID = UUID(), name: String, type: KeyType, publicKey: String, fingerprint: String, importedAt: Date) {
        self.id = id
        self.name = name
        self.type = type
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.importedAt = importedAt
    }
}

/// Where imported keys are kept. The iOS app stores them in the Keychain, this device only; tests use
/// `InMemoryImportedKeyStorage`. `list()` returns keys in the order they were saved.
public protocol ImportedKeyStorage: Sendable {
    func list() throws -> [ImportedKeyInfo]
    func save(_ info: ImportedKeyInfo, privateKey: String) throws
    func privateKey(id: UUID) throws -> String
    func delete(id: UUID) throws
}

/// Imported keys in memory (tests and previews).
public final class InMemoryImportedKeyStorage: ImportedKeyStorage {
    public struct NotFound: Error {}

    private let entries = Mutex<[(info: ImportedKeyInfo, privateKey: String)]>([])

    public init() {}

    public func list() throws -> [ImportedKeyInfo] { entries.withLock { $0.map(\.info) } }

    public func save(_ info: ImportedKeyInfo, privateKey: String) throws {
        entries.withLock { entries in
            entries.removeAll { $0.info.id == info.id }
            entries.append((info, privateKey))
        }
    }

    public func privateKey(id: UUID) throws -> String {
        guard let key = entries.withLock({ $0.first { $0.info.id == id }?.privateKey }) else { throw NotFound() }
        return key
    }

    public func delete(id: UUID) throws { entries.withLock { $0.removeAll { $0.info.id == id } } }
}

/// Why a key couldn't be imported. Never carries key material or the passphrase.
public enum ImportedKeyError: Error, Equatable, LocalizedError {
    /// The key is encrypted and no passphrase was given.
    case needsPassphrase
    case wrongPassphrase
    case rsaNotSupported
    /// Not a private key (garbage, or a public key).
    case notAPrivateKey
    /// The same key (same public key) is already imported, under this name.
    case duplicate(existingName: String)
    /// A key type other than Ed25519 or RSA, e.g. "ecdsa".
    case unsupportedKeyType(String)
    /// Encrypted in a way this app can't undo (encrypted PKCS#8, or an OpenSSH cipher other than AES-CTR).
    case unsupportedEncryption

    public var errorDescription: String? {
        switch self {
        case .needsPassphrase:
            "This key is protected with a passphrase. Enter it to import the key."
        case .wrongPassphrase:
            "That passphrase isn't right for this key."
        case .rsaNotSupported:
            "RSA keys aren't supported on iPhone/iPad yet; use an Ed25519 key."
        case .notAPrivateKey:
            "This isn't a private key. Import the private key (it starts with \u{201C}-----BEGIN\u{201D}), not the public key."
        case .duplicate(let name):
            "This key is already imported as \u{201C}\(name)\u{201D}."
        case .unsupportedKeyType(let type):
            "\(type) keys aren't supported. Use an Ed25519 key."
        case .unsupportedEncryption:
            "This key's encryption isn't supported. Export the key without a passphrase, or in OpenSSH format, and import it again."
        }
    }
}

/// The keys imported on this device, for 1Password hosts on iPhone/iPad (see `ConnectionPlanner`'s
/// `.ios` routing). Import accepts OpenSSH keys, encrypted (with the passphrase, asked once) or not, and
/// unencrypted PKCS#8; Ed25519 only. The stored copy is the unencrypted OpenSSH key: the Keychain item
/// is its protection.
@MainActor @Observable
public final class ImportedKeyLibrary {
    /// In import order.
    public private(set) var keys: [ImportedKeyInfo]

    /// Name used when neither a name nor the key's comment is known (an encrypted key hides its comment).
    public static let defaultName = "Ed25519 key"

    @ObservationIgnored private let storage: any ImportedKeyStorage
    @ObservationIgnored private let now: () -> Date

    public init(storage: any ImportedKeyStorage, now: @escaping () -> Date = { Date() }) {
        self.storage = storage
        self.now = now
        keys = (try? storage.list()) ?? []
    }

    /// Reads the list from storage again.
    public func reload() throws {
        keys = try storage.list()
    }

    /// Imports a private key pasted or read from a file. `name` (trimmed) wins; otherwise the key's
    /// comment, otherwise `defaultName`. Nothing is stored when it throws.
    @discardableResult
    public func importKey(text: String, name: String?, passphrase: String?) throws -> ImportedKeyInfo {
        let pem = SSHKeyImporter.normalizePastedKey(text)
        let inspected: ImportedKey
        do {
            inspected = try SSHKeyImporter.inspect(privateKey: pem)
        } catch SSHKeyImportError.unsupportedKeyType(let type) {
            throw ImportedKeyError.unsupportedKeyType(type)
        } catch SSHKeyImportError.encryptedPKCS8Unsupported {
            throw ImportedKeyError.unsupportedEncryption
        } catch {
            throw ImportedKeyError.notAPrivateKey
        }
        guard inspected.keyType == .ed25519 else { throw ImportedKeyError.rsaNotSupported }

        let key = try Self.ed25519Key(pem: pem, isEncrypted: inspected.isEncrypted, passphrase: passphrase)
        let comment = inspected.publicKey.flatMap { Self.comment(ofPublicKey: $0) } ?? ""
        let converted = SSHKeyGenerator.openSSH(key, comment: comment)
        // The decrypted key must be the one whose public half the file shows in the clear.
        if let shown = inspected.publicKey,
           SSHKeyCandidate.keyIdentity(shown) != SSHKeyCandidate.keyIdentity(converted.publicKey) {
            throw ImportedKeyError.notAPrivateKey
        }

        let identity = SSHKeyCandidate.keyIdentity(converted.publicKey)
        if let existing = keys.first(where: { SSHKeyCandidate.keyIdentity($0.publicKey) == identity }) {
            throw ImportedKeyError.duplicate(existingName: existing.name)
        }
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let info = ImportedKeyInfo(name: !given.isEmpty ? given : (!comment.isEmpty ? comment : Self.defaultName),
                                   type: .ed25519, publicKey: converted.publicKey,
                                   fingerprint: Self.fingerprint(ofPublicKey: converted.publicKey), importedAt: now())
        try storage.save(info, privateKey: converted.privateKey)
        keys.append(info)
        return info
    }

    public func delete(_ id: UUID) throws {
        try storage.delete(id: id)
        keys.removeAll { $0.id == id }
    }

    /// Deletes every imported key (leaving sync).
    public func deleteAll() throws {
        for info in keys { try delete(info.id) }
        keys = try storage.list()
    }

    /// Every imported key with its private key, in import order, for `ConnectionPlanner`'s `.ios` routing.
    /// Reads every key from storage (on iOS this may ask for Face ID).
    public func candidates() throws -> [SSHKeyCandidate] {
        try keys.map { info in
            SSHKeyCandidate(type: info.type, pem: try storage.privateKey(id: info.id), label: info.name,
                            publicKey: info.publicKey)
        }
    }

    /// Saved hosts whose 1Password key (their own, or their identity's in effect) is pinned to this key,
    /// by label.
    public func hosts(using key: ImportedKeyInfo, vault: LocalVault) -> [SavedHost] {
        let identity = SSHKeyCandidate.keyIdentity(key.publicKey)
        let hosts = vault.all(SavedHost.self)
        let directory = HostDirectory(hosts: hosts, groups: vault.all(HostGroup.self))
        return hosts.filter { host in
            guard let pinned = CredentialResolution.resolve(host: host, directory: directory, vault: vault).agentKey?.publicKey
            else { return false }
            return SSHKeyCandidate.keyIdentity(pinned) == identity
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    // MARK: Reading keys

    private nonisolated static func ed25519Key(pem: String, isEncrypted: Bool, passphrase: String?) throws -> Curve25519.Signing.PrivateKey {
        switch SSHKeyImporter.armorLabel(pem) {
        case "OPENSSH PRIVATE KEY":
            if isEncrypted {
                guard let passphrase, !passphrase.isEmpty else { throw ImportedKeyError.needsPassphrase }
                guard let cipher = SSHKeyImporter.openSSHCipher(pem), OpenSSHKeyReader.supportedCiphers.contains(cipher) else {
                    throw ImportedKeyError.unsupportedEncryption
                }
                do {
                    return try OpenSSHKeyReader.ed25519(pem: pem, passphrase: passphrase)
                } catch {
                    throw ImportedKeyError.wrongPassphrase
                }
            }
            do {
                return try OpenSSHKeyReader.ed25519(pem: pem, passphrase: nil)
            } catch {
                throw ImportedKeyError.notAPrivateKey
            }
        case "PRIVATE KEY":
            do {
                return try SSHKeyImporter.pkcs8Ed25519(pem)
            } catch {
                throw ImportedKeyError.notAPrivateKey
            }
        default:
            throw ImportedKeyError.notAPrivateKey
        }
    }

    private nonisolated static func comment(ofPublicKey line: String) -> String? {
        let fields = line.split(separator: " ", maxSplits: 2)
        guard fields.count == 3 else { return nil }
        let comment = fields[2].trimmingCharacters(in: .whitespaces)
        return comment.isEmpty ? nil : comment
    }

    private nonisolated static func fingerprint(ofPublicKey line: String) -> String {
        let fields = line.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return "" }
        return HostKeyFormat.fingerprintSHA256(publicKeyBlob: blob)
    }
}
