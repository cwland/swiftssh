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
            try writeDurably(sealed, to: temp)
            if rename(temp.path, fileURL.path) != 0 { throw Self.posixError() }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Creates `url` (mode 0600, must not exist), writes all of `data` and fsyncs it.
    private func writeDurably(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 { throw Self.posixError() }
        defer { close(fd) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                offset += n
            }
        }
        if fsync(fd) != 0 { throw Self.posixError() }
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
