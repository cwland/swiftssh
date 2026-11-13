import Foundation

public enum SyncRecordType: String, Codable, Sendable, CaseIterable {
    case host, hostGroup, identity, sshKey, snippet, knownHost, connectionLog, shellHistory, aiSettings
}

public protocol SyncableModel: Codable, Equatable, Sendable, Identifiable where ID == UUID {
    static var recordType: SyncRecordType { get }
    var id: UUID { get }
    var updatedAt: Date { get set }
    var deleted: Bool { get set }
}

/// Shared JSON coding so every module encodes dates identically (milliseconds since 1970).
public enum CoreJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}
