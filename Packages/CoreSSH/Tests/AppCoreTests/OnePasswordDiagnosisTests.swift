import XCTest
import SSHCore
import CoreModels
@testable import AppCore

final class OnePasswordDiagnosisTests: XCTestCase {
    private let socket = AgentSocketStatus.available("/Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
    private let key = AgentKey(publicKeyLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHomelab Homelab key",
                               type: "ssh-ed25519", comment: "Homelab key", fingerprint: "SHA256:abc")

    /// Everything set up (Cory's MacBook).
    private var healthy: OnePasswordFacts {
        OnePasswordFacts(appInstalled: true, appRunning: true, socket: socket, agent: .keys([key]),
                         cliInstalled: true, cliError: nil, containerAccess: .exists)
    }

    private func ids(_ facts: OnePasswordFacts) -> [String] {
        OnePasswordDiagnosis.problems(facts).map(\.id)
    }

    func testHealthySetupHasNoProblems() {
        XCTAssertEqual(OnePasswordDiagnosis.problems(healthy), [])
    }

    func testAppNotInstalledHidesEverythingButTheCLI() {
        var facts = healthy
        facts.appInstalled = false
        facts.socket = .notFound
        facts.cliInstalled = false
        XCTAssertEqual(ids(facts), ["appNotInstalled", "cliNotInstalled"])
    }

    func testAppNotRunning() {
        var facts = healthy
        facts.appRunning = false
        facts.agent = .failed("Nothing is listening on the agent's socket.")
        XCTAssertEqual(ids(facts), ["appNotRunning"])
        facts.appRunning = true
        facts.cliError = .appNotRunning(details: "connect: connection refused")
        XCTAssertEqual(ids(facts), ["appNotRunning"])
    }

    /// (a) on Cory's second Mac: `op` said "No accounts configured" and the container was readable.
    func testCLIIntegrationOff() {
        var facts = healthy
        facts.cliError = .integrationOff(details: "No accounts configured for use with 1Password CLI.")
        let problems = OnePasswordDiagnosis.problems(facts)
        XCTAssertEqual(problems.map(\.id), ["cliIntegrationOff"])
        XCTAssertEqual(problems[0].fixes, [.openDeveloperSettings])
        XCTAssertTrue(problems[0].message.contains("select your account at the top of 1Password\u{2019}s sidebar"))
        XCTAssertTrue(problems[0].message.contains("menu bar"))
    }

    /// (b): macOS blocked "Data shared by 1Password"; any one sign is enough, and the agent's own
    /// failures that follow from it are not shown separately.
    func testContainerBlocked() {
        var bySocket = healthy
        bySocket.socket = .blocked("/Users/cory/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
        bySocket.agent = .notChecked
        var byAgent = healthy
        byAgent.agent = .denied
        var byProbe = healthy
        byProbe.containerAccess = .denied
        byProbe.agent = .failed("x")
        var byCLI = healthy
        byCLI.cliError = .containerBlocked(details: "settings.json: operation not permitted")
        for facts in [bySocket, byAgent, byProbe, byCLI] {
            let problems = OnePasswordDiagnosis.problems(facts)
            XCTAssertEqual(problems.map(\.id), ["containerBlocked"], "\(facts)")
            XCTAssertEqual(problems.first?.fixes, [.openPrivacySettings])
            XCTAssertTrue(problems.first?.message.contains("quit and reopen SwiftSSH") == true)
        }
    }

    func testCLINotInstalledOffersTheInstallCommand() {
        var facts = healthy
        facts.cliInstalled = false
        let problems = OnePasswordDiagnosis.problems(facts)
        XCTAssertEqual(problems.map(\.id), ["cliNotInstalled"])
        XCTAssertEqual(problems[0].fixes, [.copyCLIInstallCommand, .openCLIDownloadPage])
        XCTAssertEqual(OnePasswordDiagnosis.cliInstallCommand, "brew install 1password-cli")
    }

    func testLocked() {
        var facts = healthy
        facts.cliError = .appLocked(details: "1Password app is locked")
        XCTAssertEqual(ids(facts), ["locked"])
    }

    func testAgentOffAndNotAnswering() {
        var off = healthy
        off.socket = .notFound
        off.agent = .notChecked
        XCTAssertEqual(ids(off), ["agentOff"])
        var silent = healthy
        silent.agent = .failed("The SSH agent didn't answer in time.")
        XCTAssertEqual(OnePasswordDiagnosis.problems(silent), [.agentNotAnswering("The SSH agent didn't answer in time.")])
    }

    /// (c): keys in "SSH Key Vault", no agent.toml.
    func testAgentOffersNoKeys() {
        var facts = healthy
        facts.agent = .keys([])
        let problems = OnePasswordDiagnosis.problems(facts)
        XCTAssertEqual(problems.map(\.id), ["agentOffersNoKeys"])
        XCTAssertEqual(problems[0].fixes, [.chooseVaults])
    }

    func testPinnedKeyNotOffered() {
        var facts = healthy
        facts.pinnedKeys = [
            PinnedAgentKey(publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHomelab renamed", usedBy: "nas"),
            PinnedAgentKey(publicKey: "ssh-ed25519 AAAAOTHER web key", usedBy: "web"),
            PinnedAgentKey(publicKey: "ssh-ed25519 AAAAOTHER web key", usedBy: "web"),
            PinnedAgentKey(publicKey: "ssh-rsa AAAAB3RSA", usedBy: "db"),
        ]
        let problems = OnePasswordDiagnosis.problems(facts)
        XCTAssertEqual(problems, [.pinnedKeysNotOffered(["web", "db"])])
        XCTAssertTrue(problems[0].message.contains("web and db use"), problems[0].message)
        XCTAssertEqual(OnePasswordProblem.pinnedKeysNotOffered(["web"]).message,
                       "The agent doesn\u{2019}t offer the key web uses. Its vault may not be one the agent uses.")
    }

    func testOtherCLIFailuresAreShownAsTheyAre() {
        var facts = healthy
        facts.cliError = .timedOut(details: "authorization timeout")
        let problems = OnePasswordDiagnosis.problems(facts)
        XCTAssertEqual(problems, [.cliFailed(.timedOut(details: "authorization timeout"))])
        XCTAssertEqual(problems[0].message, OnePasswordError.timedOut(details: nil).message)
        XCTAssertEqual(problems[0].fixes, [])
    }

    func testSeveralProblemsInOrder() {
        let facts = OnePasswordFacts(appInstalled: true, appRunning: true, socket: socket, agent: .keys([]),
                                     cliInstalled: true, cliError: .integrationOff(details: "No accounts configured"),
                                     containerAccess: .exists)
        XCTAssertEqual(ids(facts), ["cliIntegrationOff", "agentOffersNoKeys"])
    }

    func testEveryProblemHasWordsAndEveryFixATitle() {
        let all: [OnePasswordProblem] = [.appNotInstalled, .appNotRunning, .locked, .containerBlocked, .cliNotInstalled,
                                         .cliIntegrationOff, .agentOff, .agentNotAnswering("x"), .agentOffersNoKeys,
                                         .pinnedKeysNotOffered(["a"]), .cliFailed(.failed("y"))]
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        for problem in all {
            XCTAssertFalse(problem.title.isEmpty)
            XCTAssertFalse(problem.message.isEmpty)
        }
        let fixes: [OnePasswordFix] = [.downloadApp, .openOnePassword, .openDeveloperSettings, .openPrivacySettings,
                                       .copyCLIInstallCommand, .openCLIDownloadPage, .chooseVaults]
        for fix in fixes {
            XCTAssertFalse(fix.title.isEmpty)
            XCTAssertFalse(fix.accessibilityHint.isEmpty)
        }
        XCTAssertEqual(OnePasswordFix.openDeveloperSettings.title, "Open 1Password Developer Settings")
        XCTAssertEqual(OnePasswordFix.openPrivacySettings.title, "Open Privacy & Security")
        XCTAssertEqual(OnePasswordFix.copyCLIInstallCommand.title, "Copy install command")
    }

    func testProblemForEachCLIError() {
        XCTAssertEqual(OnePasswordDiagnosis.problem(for: .cliNotFound), .cliNotInstalled)
        XCTAssertEqual(OnePasswordDiagnosis.problem(for: .integrationOff(details: nil)), .cliIntegrationOff)
        XCTAssertEqual(OnePasswordDiagnosis.problem(for: .containerBlocked(details: nil)), .containerBlocked)
        XCTAssertEqual(OnePasswordDiagnosis.problem(for: .appNotRunning(details: nil)), .appNotRunning)
        XCTAssertEqual(OnePasswordDiagnosis.problem(for: .appLocked(details: nil)), .locked)
        XCTAssertEqual(OnePasswordDiagnosis.problem(for: .failed("x")), .cliFailed(.failed("x")))
    }

    func testKeyMatching() {
        XCTAssertTrue(AgentKeyMatch.same("ssh-ed25519 AAAA one", "ssh-ed25519 AAAA two"))
        XCTAssertTrue(AgentKeyMatch.same("ssh-ed25519 AAAA", " ssh-ed25519  AAAA comment\n"))
        XCTAssertFalse(AgentKeyMatch.same("ssh-ed25519 AAAA", "ssh-ed25519 AAAB"))
        XCTAssertFalse(AgentKeyMatch.same("ssh-ed25519 AAAA", "ssh-rsa AAAA"))
        XCTAssertFalse(AgentKeyMatch.same("garbage", "garbage"))
        XCTAssertTrue(AgentKeyMatch.offers([key], "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHomelab"))
        XCTAssertEqual(AgentKeyMatch.displayName("ssh-ed25519 AAAA Homelab key"), "Homelab key")
        XCTAssertEqual(AgentKeyMatch.displayName("ssh-ed25519 AAAA"), "ssh-ed25519")
    }

    @MainActor
    func testPinnedKeysFromTheVault() async throws {
        let vault = try await LocalVault.open(persistence: InMemoryVaultPersistence(), newDeviceID: { "dev" })
        vault.saveNow(CoreModels.Host(label: "nas", address: "nas.lan", agentKey: AgentKeyChoice(publicKey: "ssh-ed25519 AAAA nas")))
        vault.saveNow(CoreModels.Host(label: "any", address: "any.lan", agentKey: AgentKeyChoice(publicKey: nil)))
        vault.saveNow(CoreModels.Host(label: "pw", address: "pw.lan", password: "x"))
        vault.saveNow(Identity(label: "root", username: "root", agentKey: AgentKeyChoice(publicKey: "ssh-ed25519 BBBB root")))
        XCTAssertEqual(PinnedAgentKey.all(in: vault), [PinnedAgentKey(publicKey: "ssh-ed25519 AAAA nas", usedBy: "nas"),
                                                      PinnedAgentKey(publicKey: "ssh-ed25519 BBBB root", usedBy: "root")])
    }

    func testAgentAuthFailureDiagnosis() {
        let key = self.key
        XCTAssertEqual(AgentAuthFailure.diagnose(pinnedPublicKey: nil, listing: .success([])), .offersNoKeys)
        XCTAssertEqual(AgentAuthFailure.diagnose(pinnedPublicKey: "ssh-ed25519 ZZZZ Work key", listing: .success([key])),
                       .pinnedKeyNotOffered(name: "Work key"))
        XCTAssertEqual(AgentAuthFailure.diagnose(pinnedPublicKey: key.publicKeyLine, listing: .success([key])), .serverRejected)
        XCTAssertEqual(AgentAuthFailure.diagnose(pinnedPublicKey: nil, listing: .failure(SSHAgentError.permissionDenied)), .blocked)
        XCTAssertEqual(AgentAuthFailure.diagnose(pinnedPublicKey: nil, listing: .failure(SSHAgentError.timedOut)), .notAnswering)
        for failure in [AgentAuthFailure.offersNoKeys, .pinnedKeyNotOffered(name: "k"), .blocked, .notAnswering, .serverRejected] {
            let message = failure.message(who: "root@web")
            XCTAssertFalse(message.contains("AAAA"), "never the key itself")
            XCTAssertFalse(message.isEmpty)
        }
    }
}
