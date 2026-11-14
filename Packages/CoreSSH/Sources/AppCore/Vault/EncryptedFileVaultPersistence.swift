import Foundation
import Crypto
import CoreModels
import SyncCore

public enum VaultLoadError: Error, Equatable {
    /// The vault file could not be decrypted or decoded. It was renamed (never deleted) to `movedTo`.
    case unreadable(movedTo: URL)
}

/// Stores `VaultFileContents` as `CoreJSON`, sealed with AES-256-GCM (`combined`), in one file.
/// Writes are atomic; a file that can't be opened is moved aside, never overwritten.
public actor EncryptedFileVaultPersistence: VaultPersistence {
    static let aad = Data("termius-reimagined-vault-v1".utf8)

    private let fileURL: URL
    private let key: VaultKey
    private let now: @Sendable () -> Date

    public init(fileURL: URL, key: VaultKey, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.key = key
        self.now = now
    }

    public func load() async throws -> VaultFileContents? {
        let sealed: Data
        do {
            sealed = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plain = try AES.GCM.open(box, using: key.symmetricKey, authenticating: Self.aad)
            return try CoreJSON.decoder.decode(VaultFileContents.self, from: plain)
        } catch {
            throw VaultLoadError.unreadable(movedTo: try moveAside())
        }
    }

    public func save(_ contents: VaultFileContents) async throws {
        let plain = try CoreJSON.encoder.encode(contents)
        let sealed = try AES.GCM.seal(plain, using: key.symmetricKey, authenticating: Self.aad).combined!
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try sealed.write(to: temp)
            try replace(fileURL, with: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Atomically puts `temp` at `target`, replacing any existing file.
    private func replace(_ target: URL, with temp: URL) throws {
        let fm = FileManager.default
        #if canImport(Darwin)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: target)
        }
        #else
        // swift-corelibs-foundation's `replaceItemAt` fails with "file doesn't exist" for an
        // existing target on Linux; rename(2) replaces atomically.
        if rename(temp.path, target.path) != 0 {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
        #endif
    }

    private func moveAside() throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(fileURL.lastPathComponent).unreadable-\(formatter.string(from: now()))"
        let dir = fileURL.deletingLastPathComponent()
        var target = dir.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        try fm.moveItem(at: fileURL, to: target)
        return target
    }
}
