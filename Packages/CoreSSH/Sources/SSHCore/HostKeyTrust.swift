import Crypto
import Foundation

/// Host key identity and fingerprint formats shared by both SSH engines.
public enum HostKeyFormat {
    /// OpenSSH `known_hosts` convention: `host` for port 22, otherwise `[host]:port`.
    /// The host is lowercased and a single trailing dot is removed first.
    public static func hostPort(host: String, port: Int) -> String {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return port == 22 ? host : "[\(host)]:\(port)"
    }

    /// `SHA256:` + unpadded base64 of SHA-256 over the public key wire blob (same as `ssh-keygen -l`).
    public static func fingerprintSHA256(publicKeyBlob: Data) -> String {
        let digest = SHA256.hash(data: publicKeyBlob)
        var b64 = Data(digest).base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "SHA256:" + b64
    }
}

public struct HostKeyCandidate: Sendable, Equatable {
    public var hostPort: String
    public var keyType: String
    public var publicKeyBlob: Data
    public var fingerprint: String

    public init(host: String, port: Int, keyType: String, publicKeyBlob: Data) {
        self.hostPort = HostKeyFormat.hostPort(host: host, port: port)
        self.keyType = keyType
        self.publicKeyBlob = publicKeyBlob
        self.fingerprint = HostKeyFormat.fingerprintSHA256(publicKeyBlob: publicKeyBlob)
    }
}

public enum HostKeyDecision: Sendable, Equatable {
    case trusted, rejected
}

public enum HostKeyCheck: Sendable, Equatable {
    /// A live record matches this key.
    case known
    /// No live records exist for the host at all.
    case unknown
    /// The host has live records, but none for this key type (e.g. a possible algorithm downgrade).
    case newKeyType(knownKeyTypes: [String])
    /// A live record of the same key type has a different fingerprint.
    case changed(previousFingerprint: String)
}

/// Decides whether a presented host key is trusted. Implemented by the app layer; both engines call it.
public protocol HostKeyEvaluator: Sendable {
    func evaluate(_ candidate: HostKeyCandidate) async -> HostKeyDecision
}
