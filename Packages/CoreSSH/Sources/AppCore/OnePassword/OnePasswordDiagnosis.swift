import Foundation
import CoreModels
import SSHCore

/// What 1Password's SSH agent answered when asked for its keys.
public enum AgentListing: Equatable, Sendable {
    /// Not asked (no socket, or not checked yet).
    case notChecked
    case keys([AgentKey])
    /// macOS refused access to the socket (1Password's group container is blocked).
    case denied
    /// The socket exists but the agent didn't answer; the reason, for the checklist.
    case failed(String)
}

/// A key a saved host or identity is pinned to (`AgentKeyChoice.publicKey`), with who uses it.
public struct PinnedAgentKey: Equatable, Sendable {
    /// "type base64 [comment]".
    public let publicKey: String
    /// The host's (or identity's) label, for "the key web.example uses".
    public let usedBy: String

    public init(publicKey: String, usedBy: String) {
        self.publicKey = publicKey
        self.usedBy = usedBy
    }
}

/// Everything the 1Password checklist found on this Mac. Nothing here is secret: paths, yes/no
/// answers, public keys and `op`'s error text.
public struct OnePasswordFacts: Equatable, Sendable {
    public var appInstalled: Bool
    public var appRunning: Bool
    public var socket: AgentSocketStatus
    public var agent: AgentListing
    public var cliInstalled: Bool
    /// The latest CLI test's error; nil when it passed or hasn't run.
    public var cliError: OnePasswordError?
    /// Whether this app may look into 1Password's group container; nil when not checked.
    public var containerAccess: OnePasswordPaths.Probe?
    /// Keys hosts and identities are pinned to.
    public var pinnedKeys: [PinnedAgentKey]
    /// Whether `~/.config/1Password/ssh/agent.toml` exists (then the agent offers only what it lists).
    public var agentConfigExists: Bool

    public init(appInstalled: Bool, appRunning: Bool, socket: AgentSocketStatus, agent: AgentListing,
                cliInstalled: Bool, cliError: OnePasswordError? = nil,
                containerAccess: OnePasswordPaths.Probe? = nil, pinnedKeys: [PinnedAgentKey] = [],
                agentConfigExists: Bool = false) {
        self.appInstalled = appInstalled
        self.appRunning = appRunning
        self.socket = socket
        self.agent = agent
        self.cliInstalled = cliInstalled
        self.cliError = cliError
        self.containerAccess = containerAccess
        self.pinnedKeys = pinnedKeys
        self.agentConfigExists = agentConfigExists
    }
}

/// A button the checklist (and the welcome sheet) offers to fix a problem. The app decides what each
/// one does; the titles live here so every place says the same.
public enum OnePasswordFix: Equatable, Hashable, Sendable {
    case downloadApp
    case openOnePassword
    /// `onepassword://settings/developers`.
    case openDeveloperSettings
    /// System Settings → Privacy & Security → Files & Folders.
    case openPrivacySettings
    /// Puts `brew install 1password-cli` on the clipboard.
    case copyCLIInstallCommand
    case openCLIDownloadPage
    /// Choose the vaults 1Password's SSH agent offers keys from (writes agent.toml).
    case chooseVaults
    /// Check everything again (the checklist's `refresh()`).
    case recheck

    public var title: String {
        switch self {
        case .downloadApp: "Download 1Password"
        case .openOnePassword: "Open 1Password"
        case .openDeveloperSettings: "Open 1Password Developer Settings"
        case .openPrivacySettings: "Open Privacy & Security"
        case .copyCLIInstallCommand: "Copy install command"
        case .openCLIDownloadPage: "Download the CLI"
        case .chooseVaults: "Choose vaults\u{2026}"
        case .recheck: "Recheck"
        }
    }

    /// For VoiceOver: what the button does.
    public var accessibilityHint: String {
        switch self {
        case .downloadApp: "Opens 1Password\u{2019}s download page in your browser"
        case .openOnePassword: "Opens the 1Password app"
        case .openDeveloperSettings: "Opens 1Password\u{2019}s Developer settings"
        case .openPrivacySettings: "Opens System Settings, Privacy and Security, Files and Folders"
        case .copyCLIInstallCommand: "Copies \(OnePasswordDiagnosis.cliInstallCommand) to the clipboard"
        case .openCLIDownloadPage: "Opens the 1Password CLI download page in your browser"
        case .chooseVaults: "Choose which 1Password vaults the SSH agent offers keys from"
        case .recheck: "Checks 1Password again"
        }
    }
}

/// One thing that keeps 1Password from working with SwiftSSH, with plain words and the fixes.
public enum OnePasswordProblem: Equatable, Sendable, Identifiable {
    case appNotInstalled
    case appNotRunning
    case locked
    /// macOS blocks "Data shared by 1Password" for SwiftSSH.
    case containerBlocked
    case cliNotInstalled
    /// "Integrate with 1Password CLI" is off ("No accounts configured").
    case cliIntegrationOff
    /// No agent socket: "Use the SSH agent" is off.
    case agentOff
    case agentNotAnswering(String)
    /// The agent lists no keys; whether agent.toml exists decides the words.
    case agentOffersNoKeys(agentConfigExists: Bool)
    /// The agent lists keys, but not the ones these hosts are pinned to (their labels).
    case pinnedKeysNotOffered([String])
    /// Any other CLI failure (a timeout, a dismissed prompt…).
    case cliFailed(OnePasswordError)

    public var id: String {
        switch self {
        case .appNotInstalled: "appNotInstalled"
        case .appNotRunning: "appNotRunning"
        case .locked: "locked"
        case .containerBlocked: "containerBlocked"
        case .cliNotInstalled: "cliNotInstalled"
        case .cliIntegrationOff: "cliIntegrationOff"
        case .agentOff: "agentOff"
        case .agentNotAnswering: "agentNotAnswering"
        case .agentOffersNoKeys: "agentOffersNoKeys"
        case .pinnedKeysNotOffered: "pinnedKeysNotOffered"
        case .cliFailed: "cliFailed"
        }
    }

    public var title: String {
        switch self {
        case .appNotInstalled: "1Password isn\u{2019}t installed"
        case .appNotRunning: "1Password isn\u{2019}t running"
        case .locked: "1Password is locked"
        case .containerBlocked: "macOS is blocking 1Password\u{2019}s data"
        case .cliNotInstalled: "The 1Password CLI isn\u{2019}t installed"
        case .cliIntegrationOff: "The CLI isn\u{2019}t connected to 1Password"
        case .agentOff: "1Password\u{2019}s SSH agent is off"
        case .agentNotAnswering: "1Password\u{2019}s SSH agent isn\u{2019}t answering"
        case .agentOffersNoKeys: "Your SSH keys aren\u{2019}t offered"
        case .pinnedKeysNotOffered: "A host\u{2019}s key isn\u{2019}t offered"
        case .cliFailed: "The CLI test didn\u{2019}t pass"
        }
    }

    public var message: String {
        switch self {
        case .appNotInstalled:
            "Install 1Password 8 for Mac and sign in. You can skip this if you don\u{2019}t use 1Password."
        case .appNotRunning:
            "Open 1Password and unlock it. Keep it in the menu bar so SwiftSSH can reach it."
        case .locked:
            "Unlock 1Password (sign in if it asks), then click Recheck."
        case .containerBlocked:
            "In System Settings \u{2192} Privacy & Security \u{2192} Files & Folders, turn on \u{201C}Data shared by 1Password\u{201D} under SwiftSSH. Then quit and reopen SwiftSSH."
        case .cliNotInstalled:
            "Needed only to fill passwords from 1Password. Install it with Homebrew: \(OnePasswordDiagnosis.cliInstallCommand)"
        case .cliIntegrationOff:
            "First select your account at the top of 1Password\u{2019}s sidebar (the Developer option only shows then). Then open Settings \u{2192} Developer and turn on \u{201C}Integrate with 1Password CLI\u{201D}. Keep 1Password in the menu bar."
        case .agentOff:
            "In 1Password, open Settings \u{2192} Developer and turn on \u{201C}Use the SSH agent\u{201D}."
        case .agentNotAnswering(let reason):
            "Make sure 1Password is open and unlocked, then click Recheck. (\(reason))"
        case .agentOffersNoKeys(let agentConfigExists):
            agentConfigExists
                ? "Your agent.toml lists vaults with no SSH keys. Choose the vaults that hold your SSH keys."
                : "Without agent.toml, the agent offers keys only from the Private, Personal or Employee vault. Choose the vaults that hold your SSH keys."
        case .pinnedKeysNotOffered(let labels):
            labels.count == 1
                ? "The agent doesn\u{2019}t offer the key \(labels[0]) uses. Its vault may not be one the agent uses."
                : "The agent doesn\u{2019}t offer the keys used by \(OnePasswordDiagnosis.list(labels)). Their vaults may not be ones the agent uses."
        case .cliFailed(let error):
            error.message
        }
    }

    public var fixes: [OnePasswordFix] {
        switch self {
        case .appNotInstalled: [.downloadApp]
        case .appNotRunning: [.openOnePassword]
        case .locked, .agentNotAnswering: [.openOnePassword, .recheck]
        case .containerBlocked: [.openPrivacySettings]
        case .cliNotInstalled: [.copyCLIInstallCommand, .openCLIDownloadPage]
        case .cliIntegrationOff, .agentOff: [.openDeveloperSettings]
        case .agentOffersNoKeys, .pinnedKeysNotOffered: [.chooseVaults]
        case .cliFailed: []
        }
    }
}

/// Turns what the checklist found into the problems to show, most basic first.
public enum OnePasswordDiagnosis {
    /// "Copy install command".
    public static let cliInstallCommand = "brew install 1password-cli"

    /// Each problem once, in this order: the app (missing, not running, locked), macOS blocking its
    /// data, the CLI, then the agent. With the app missing or not running, nothing else is judged
    /// (every other check would fail for that reason) except whether the CLI is installed. A blocked
    /// container hides the agent's own failures (they follow from it).
    public static func problems(_ facts: OnePasswordFacts) -> [OnePasswordProblem] {
        var result: [OnePasswordProblem] = []
        func add(_ problem: OnePasswordProblem) {
            if !result.contains(where: { $0.id == problem.id }) { result.append(problem) }
        }
        let cliProblem = facts.cliError.flatMap(problem(for:))

        if !facts.appInstalled {
            add(.appNotInstalled)
            if !facts.cliInstalled { add(.cliNotInstalled) }
            return result
        }
        if !facts.appRunning || cliProblem == .appNotRunning {
            add(.appNotRunning)
            if !facts.cliInstalled { add(.cliNotInstalled) }
            return result
        }
        if cliProblem == .locked { add(.locked) }

        let blocked: Bool = {
            if case .blocked = facts.socket { return true }
            return facts.agent == .denied || facts.containerAccess == .denied || cliProblem == .containerBlocked
        }()
        if blocked { add(.containerBlocked) }

        if !facts.cliInstalled {
            add(.cliNotInstalled)
        } else if let cliProblem, cliProblem != .locked, cliProblem != .containerBlocked {
            add(cliProblem)
        }

        if !blocked {
            switch facts.socket {
            case .notFound:
                add(.agentOff)
            case .blocked:
                break
            case .available:
                switch facts.agent {
                case .failed(let reason): add(.agentNotAnswering(reason))
                case .keys(let keys) where keys.isEmpty: add(.agentOffersNoKeys(agentConfigExists: facts.agentConfigExists))
                case .keys(let keys):
                    let missing = facts.pinnedKeys.filter { pinned in
                        !keys.contains { AgentKeyMatch.same($0.publicKeyLine, pinned.publicKey) }
                    }
                    var labels: [String] = []
                    for key in missing where !labels.contains(key.usedBy) { labels.append(key.usedBy) }
                    if !labels.isEmpty { add(.pinnedKeysNotOffered(labels)) }
                case .notChecked, .denied: break
                }
            }
        }
        return result
    }

    /// The problem a failed CLI call points to. Failures that need no setup (a timeout, a dismissed
    /// prompt, a missing item) are `.cliFailed`. Optional for callers that may have no error.
    public static func problem(for error: OnePasswordError) -> OnePasswordProblem? {
        switch error {
        case .cliNotFound: .cliNotInstalled
        case .integrationOff: .cliIntegrationOff
        case .containerBlocked: .containerBlocked
        case .appNotRunning: .appNotRunning
        case .appLocked: .locked
        case .cancelled, .timedOut, .notFound, .failed: .cliFailed(error)
        }
    }

    /// "web", "web and nas", "web, nas and db".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

/// Comparing public keys as the agent and the vault write them.
public enum AgentKeyMatch {
    /// Same key type and base64 blob; the comment is ignored.
    public static func same(_ a: String, _ b: String) -> Bool {
        guard let left = parts(a), let right = parts(b) else { return false }
        return left == right
    }

    /// Whether the agent's `keys` include `publicKey`.
    public static func offers(_ keys: [AgentKey], _ publicKey: String) -> Bool {
        keys.contains { same($0.publicKeyLine, publicKey) }
    }

    /// The pinned key's comment (its name in 1Password), else its type; never the key itself.
    public static func displayName(_ publicKey: String) -> String {
        let fields = publicKey.split(separator: " ", omittingEmptySubsequences: true)
        if fields.count >= 3 { return fields[2...].joined(separator: " ") }
        return fields.first.map(String.init) ?? "key"
    }

    private static func parts(_ line: String) -> [Substring]? {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        return Array(fields.prefix(2))
    }
}

extension PinnedAgentKey {
    /// The 1Password agent keys saved hosts and identities are pinned to (hosts first), for the
    /// checklist's "a host's key isn't offered".
    @MainActor
    public static func all(in vault: LocalVault) -> [PinnedAgentKey] {
        let hosts = vault.all(CoreModels.Host.self).compactMap { host in
            host.agentKey?.publicKey.map { PinnedAgentKey(publicKey: $0, usedBy: host.label) }
        }
        let identities = vault.all(Identity.self).compactMap { identity in
            identity.agentKey?.publicKey.map { PinnedAgentKey(publicKey: $0, usedBy: identity.label) }
        }
        return hosts + identities
    }
}
