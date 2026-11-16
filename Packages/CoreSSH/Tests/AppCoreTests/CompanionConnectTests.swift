import XCTest
import CoreModels
import SSHCore
import SyncCore
@testable import AppCore

private typealias SavedHost = CoreModels.Host

/// Connecting on iPhone/iPad: which hosts need the imported keys (and so Face ID first), the password
/// prompt's AutoFill details, and what a session tab shows.
@MainActor
final class CompanionConnectTests: XCTestCase {
    private func makeVault() async throws -> LocalVault {
        try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "phone" })
    }

    // MARK: Imported keys

    func testOnlyOnePasswordKeyHostsNeedTheImportedKeys() async throws {
        let vault = try await makeVault()
        let agent = try await vault.save(SavedHost(label: "a", address: "a", username: "u",
                                                   agentKey: AgentKeyChoice(publicKey: nil)))
        let identity = try await vault.save(Identity(label: "i", username: "u", agentKey: AgentKeyChoice(publicKey: "ssh-ed25519 X")))
        let viaIdentity = try await vault.save(SavedHost(label: "b", address: "b", identityID: identity.id))
        let password = try await vault.save(SavedHost(label: "c", address: "c", username: "u", password: "pw"))
        let prompt = try await vault.save(SavedHost(label: "d", address: "d", username: "u"))
        let noAddress = try await vault.save(SavedHost(label: "e", address: " ", username: "u",
                                                       agentKey: AgentKeyChoice(publicKey: nil)))
        XCTAssertTrue(CompanionConnect.needsImportedKeys(hostID: agent.id, vault: vault))
        XCTAssertTrue(CompanionConnect.needsImportedKeys(hostID: viaIdentity.id, vault: vault))
        XCTAssertFalse(CompanionConnect.needsImportedKeys(hostID: password.id, vault: vault))
        XCTAssertFalse(CompanionConnect.needsImportedKeys(hostID: prompt.id, vault: vault))
        XCTAssertFalse(CompanionConnect.needsImportedKeys(hostID: noAddress.id, vault: vault),
                       "a host that can't connect anyway never asks for Face ID")
        XCTAssertFalse(CompanionConnect.needsImportedKeys(hostID: UUID(), vault: vault))
    }

    // MARK: Password prompt

    func testPasswordPromptForAOnePasswordHostNamesTheItem() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "web", address: "web", username: "deploy",
                                                  password: "op://Work/Web login/password"))
        let info = CompanionConnect.passwordPrompt(hostID: host.id, vault: vault)
        XCTAssertEqual(info.username, "deploy")
        XCTAssertEqual(info.onePasswordHint,
                       "On your Mac this password comes from 1Password (\u{201C}Web login\u{201D}). Choose that login from AutoFill above the keyboard.")
    }

    func testPasswordPromptForAPlainHostHasNoHint() async throws {
        let vault = try await makeVault()
        let host = try await vault.save(SavedHost(label: "nas", address: "nas", username: "cory"))
        let info = CompanionConnect.passwordPrompt(hostID: host.id, vault: vault)
        XCTAssertEqual(info.username, "cory")
        XCTAssertNil(info.onePasswordHint)
        let none = CompanionConnect.passwordPrompt(hostID: nil, vault: vault)
        XCTAssertNil(none.username)
        XCTAssertNil(none.onePasswordHint)
    }

    // MARK: What a tab shows

    func testConnectionScreenWhileConnectingAndAfterAFirstFailure() async {
        typealias P = TerminalTabPresentation
        XCTAssertTrue(P.showsConnectionScreen(state: .connecting, autoReconnect: nil, hadLiveSession: false))
        XCTAssertTrue(P.showsConnectionScreen(state: .awaitingPassword(prompt: "p"), autoReconnect: nil, hadLiveSession: true))
        XCTAssertTrue(P.showsConnectionScreen(state: .disconnected("no"), autoReconnect: nil, hadLiveSession: false))
        XCTAssertFalse(P.showsConnectionScreen(state: .disconnected("dropped"), autoReconnect: nil, hadLiveSession: true),
                       "a tab that was live keeps its scrollback and shows the banner")
        XCTAssertFalse(P.showsConnectionScreen(state: .connected, autoReconnect: nil, hadLiveSession: true))
    }

    func testConnectionScreenDuringAutoReconnect() async {
        typealias P = TerminalTabPresentation
        let now = Date()
        XCTAssertFalse(P.showsConnectionScreen(state: .disconnected("x"),
                                               autoReconnect: .waiting(attempt: 1, deadline: now, delay: 5), hadLiveSession: true))
        XCTAssertTrue(P.showsConnectionScreen(state: .disconnected("x"),
                                              autoReconnect: .waiting(attempt: 2, deadline: now, delay: 5), hadLiveSession: true))
        XCTAssertTrue(P.showsConnectionScreen(state: .connecting, autoReconnect: .reconnecting(attempt: 1), hadLiveSession: true))
        XCTAssertTrue(P.showsConnectionScreen(state: .disconnected("x"), autoReconnect: .gaveUp(attempts: 18), hadLiveSession: true))
    }

    func testBannerOnlyForADroppedLiveSessionNotReconnecting() async {
        typealias P = TerminalTabPresentation
        XCTAssertEqual(P.banner(state: .disconnected("Connection lost"), autoReconnect: nil, hadLiveSession: true),
                       .some("Connection lost"))
        XCTAssertEqual(P.banner(state: .disconnected(nil), autoReconnect: nil, hadLiveSession: true),
                       .some("Connection closed"))
        XCTAssertNil(P.banner(state: .disconnected("x"), autoReconnect: .waiting(attempt: 1, deadline: Date(), delay: 5),
                              hadLiveSession: true))
        XCTAssertNil(P.banner(state: .connected, autoReconnect: nil, hadLiveSession: true))
        XCTAssertNil(P.banner(state: .disconnected("x"), autoReconnect: nil, hadLiveSession: false))
    }
}
