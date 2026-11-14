import Crypto
import Foundation

/// Host key identity and fingerprint formats shared by both SSH engines.
public enum HostKeyFormat {
    /// OpenSSH `known_hosts` convention: `host` for port 22, otherwise `[host]:port`.
    public static func hostPort(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
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
    case known, unknown, changed(previousFingerprint: String)
}

/// Decides whether a presented host key is trusted. Implemented by the app layer; both engines call it.
public protocol HostKeyEvaluator: Sendable {
    func evaluate(_ candidate: HostKeyCandidate) async -> HostKeyDecision
}
