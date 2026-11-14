import XCTest
@testable import SSHCore

final class HostKeyTrustTests: XCTestCase {
    func testHostPortFormatting() {
        XCTAssertEqual(HostKeyFormat.hostPort(host: "10.0.0.5", port: 22), "10.0.0.5")
        XCTAssertEqual(HostKeyFormat.hostPort(host: "10.0.0.5", port: 2222), "[10.0.0.5]:2222")
        XCTAssertEqual(HostKeyFormat.hostPort(host: "fe80::1", port: 22), "fe80::1")
        XCTAssertEqual(HostKeyFormat.hostPort(host: "Host.Local.", port: 22), "host.local")
        XCTAssertEqual(HostKeyFormat.hostPort(host: "Host.Local.", port: 2222), "[host.local]:2222")
        XCTAssertEqual(HostKeyFormat.hostPort(host: "a..", port: 22), "a.")
    }

    /// Blob and expected value come from `ssh-keygen -l -f k.pub` on a fixed ed25519 key.
    func testFingerprintMatchesSSHKeygen() throws {
        let b64 = "AAAAC3NzaC1lZDI1NTE5AAAAIOiuxloU1VddeltegKdfeKT9A96Xd+Jowut6BPrjp4tL"
        let blob = try XCTUnwrap(Data(base64Encoded: b64))
        XCTAssertEqual(HostKeyFormat.fingerprintSHA256(publicKeyBlob: blob),
                       "SHA256:RRbmR91glWz3fSs2lRGcStgvHJN15ymZGGyvojei2Uw")
    }

    func testCandidateComputesDerivedFields() throws {
        let blob = try XCTUnwrap(Data(base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIOiuxloU1VddeltegKdfeKT9A96Xd+Jowut6BPrjp4tL"))
        let c = HostKeyCandidate(host: "h", port: 2200, keyType: "ssh-ed25519", publicKeyBlob: blob)
        XCTAssertEqual(c.hostPort, "[h]:2200")
        XCTAssertEqual(c.fingerprint, "SHA256:RRbmR91glWz3fSs2lRGcStgvHJN15ymZGGyvojei2Uw")
    }
}
