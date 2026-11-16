import CoreModels
import Foundation
import XCTest
@testable import SSHCore

/// The `.agent` credential outside of a live connection: description, engine and system ssh arguments.
final class AgentCredentialTests: XCTestCase {
    private let pinned = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOiuxloU1VddeltegKdfeKT9A96Xd+Jowut6BPrjp4tL cory@secret-laptop"

    func testDescriptionShowsSocketAndKeyTypeOnly() {
        let credential = SSHCredential.agent(socketPath: "/Users/c/agent.sock", publicKey: pinned)
        for text in [credential.description, credential.debugDescription, "\(credential)", String(reflecting: credential)] {
            XCTAssertTrue(text.hasPrefix("agent("), text)
            XCTAssertTrue(text.contains("/Users/c/agent.sock"), text)
            XCTAssertTrue(text.contains("ssh-ed25519"), text)
            XCTAssertFalse(text.contains("AAAAC3"), text)
            XCTAssertFalse(text.contains("secret-laptop"), text)
        }
        XCTAssertEqual(SSHCredential.agent(socketPath: "/s", publicKey: nil).description, "agent(socketPath: /s, publicKey: nil)")
        XCTAssertEqual(credential.description, "agent(socketPath: /Users/c/agent.sock, publicKey: ssh-ed25519 <pinned>)")
    }

    func testAgentPlansAlwaysUseSystemSSH() {
        var plan = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                                  credential: .agent(socketPath: "/s", publicKey: nil), engine: .citadel,
                                  startupScript: nil)
        XCTAssertEqual(plan.engine, .systemSSH)

        plan = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                              credential: .none, engine: .citadel, startupScript: nil)
        XCTAssertEqual(plan.engine, .citadel)
        plan.credential = .agent(socketPath: "/s", publicKey: pinned)
        XCTAssertEqual(plan.engine, .systemSSH)
    }

    func testCitadelRefusesTheAgentCredential() {
        let plan = ConnectionPlan(hostID: nil, label: "L", host: "h", port: 22, username: "u",
                                  credential: .agent(socketPath: "/s", publicKey: nil), engine: .systemSSH,
                                  startupScript: nil)
        guard case .failure(.connectionFailed) = CitadelSession.authenticationFactory(for: plan) else {
            return XCTFail("the built-in engine can't sign with an agent")
        }
    }

    func testAgentArgumentsAreExact() {
        let root = URL(fileURLWithPath: "/a b/run")
        let directory = SSHRuntimeDirectory(root: root, controlDirectory: URL(fileURLWithPath: "/tmp/swiftssh-501"))
        let knownHosts = root.appendingPathComponent("S.known_hosts")
        func args(_ auth: SystemSSHSession.AuthArguments) -> [String] {
            SystemSSHSession.sshArguments(host: "example.com", port: 22, username: "cory", runtime: directory,
                                          knownHosts: knownHosts, auth: auth, hostKeyAlgorithms: "ssh-ed25519")
        }
        let common = SystemSSHSession.sshArguments(host: "example.com", port: 22, username: "cory", runtime: directory,
                                                   knownHosts: knownHosts, auth: .none, hostKeyAlgorithms: "ssh-ed25519")
            .dropLast(4) // HostKeyAlgorithms, --, host
        let socket = "/Users/c/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        let publicKeyOnly = ["-o", "PreferredAuthentications=publickey",
                             "-o", "PasswordAuthentication=no",
                             "-o", "KbdInteractiveAuthentication=no"]
        let tail = ["-o", "HostKeyAlgorithms=ssh-ed25519", "--", "example.com"]

        XCTAssertEqual(args(.agent(socket: socket, publicKeyFile: root.appendingPathComponent("P.pub"))),
                       Array(common) + [
                           "-o", "IdentityAgent=\"\(socket)\"",
                           "-o", "IdentityFile=\"/a b/run/P.pub\"",
                           "-o", "IdentitiesOnly=yes",
                       ] + publicKeyOnly + tail)
        // Unpinned: any agent key, but never the user's own key files.
        XCTAssertEqual(args(.agent(socket: socket, publicKeyFile: nil)),
                       Array(common) + ["-o", "IdentityAgent=\"\(socket)\"", "-o", "IdentityFile=none"]
                           + publicKeyOnly + tail)
        // ssh expands `%` tokens in IdentityAgent: a literal `%` is written as `%%`.
        XCTAssertEqual(args(.agent(socket: "/tmp/100%/a%h.sock", publicKeyFile: nil)),
                       Array(common) + ["-o", "IdentityAgent=\"/tmp/100%%/a%%h.sock\"", "-o", "IdentityFile=none"]
                           + publicKeyOnly + tail)
    }

    func testAgentSocketPathsSSHCantUse() {
        let problem = "The 1Password agent path contains characters ssh can't use."
        for good in ["/tmp/a.sock", "/Users/c/Library/Group Containers/x/t/agent.sock", "/tmp/100%/a.sock",
                     "/tmp/caf\u{E9}/a.sock", "/tmp/$x/a.sock"] {
            XCTAssertNil(SystemSSHSession.agentSocketProblem(good), good)
        }
        for bad in ["/tmp/a\".sock", "/tmp/a\\b.sock", "/tmp/a\nb.sock", "/tmp/a\rb.sock", "/tmp/a\tb.sock",
                    "/tmp/a\u{0}b.sock", "/tmp/a\u{7F}.sock", "/tmp/a\u{9B}.sock", "/tmp/${HOME}/a.sock"] {
            XCTAssertEqual(SystemSSHSession.agentSocketProblem(bad), problem, bad.debugDescription)
        }
    }

    func testPinnedKeyFileHoldsOnlyTypeAndKey() throws {
        XCTAssertEqual(SystemSSHSession.pinnedKeyFileLine(pinned),
                       "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOiuxloU1VddeltegKdfeKT9A96Xd+Jowut6BPrjp4tL")
        XCTAssertEqual(SystemSSHSession.pinnedKeyFileLine("  ssh-ed25519   AAAAC3NzaC1lZDI1NTE5AAAAIOiuxloU1VddeltegKdfeKT9A96Xd+Jowut6BPrjp4tL\n"),
                       "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOiuxloU1VddeltegKdfeKT9A96Xd+Jowut6BPrjp4tL")
        for bad in ["", "ssh-ed25519", "ssh-ed25519 not*base64", "ssh-ed25519 AAAA\nssh-rsa BBBB",
                    "ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIOiuxloU1VddeltegKdfeKT9A96Xd+Jowut6BPrjp4tL"] {
            XCTAssertNil(SystemSSHSession.pinnedKeyFileLine(bad), bad)
        }

        let scratch = URL(fileURLWithPath: "/tmp/tr p-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let runtime = SSHRuntimeDirectory(root: scratch.appendingPathComponent("run"),
                                          controlDirectory: scratch.appendingPathComponent("ctl"))
        try runtime.prepare()
        let file = try runtime.writePublicKey("ssh-ed25519 AAAA")
        XCTAssertTrue(file.lastPathComponent.hasSuffix(".pub"))
        XCTAssertEqual(UUID(uuidString: String(file.lastPathComponent.dropLast(4))) != nil, true, file.lastPathComponent)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ssh-ed25519 AAAA\n")
        XCTAssertNotEqual(try runtime.writePublicKey("ssh-ed25519 AAAA"), file, "one file per session")
    }
}
