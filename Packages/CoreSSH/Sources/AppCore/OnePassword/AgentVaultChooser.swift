import Foundation
import Observation
import SSHCore

/// "Your SSH keys aren't offered" → "Choose vaults…": lists the 1Password vaults with check boxes,
/// writes `~/.config/1Password/ssh/agent.toml` for the chosen ones ("Use these vaults"), then asks the
/// agent again after a few seconds and shows what it offers.
///
/// Asks `op` only for vault names (`op vault list`) and for which vaults hold SSH Key items (`op item
/// list --categories "SSH Key"`, metadata only): never a secret. Without `op` (or when it fails) the
/// user can still type vault names.
@MainActor @Observable
public final class AgentVaultChooser {
    public struct Row: Equatable, Identifiable, Sendable {
        /// The vault's ID, or "name:<name>" for one typed in or only known from agent.toml.
        public let id: String
        public let name: String
        /// SSH Key items in the vault; nil when unknown.
        public let sshKeyCount: Int?
        public var isSelected: Bool
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        /// `op` couldn't list the vaults; names can still be typed.
        case listFailed(OnePasswordError)
        case saving
        /// agent.toml written; waiting, then asking the agent again.
        case checking
        case done(AgentRecheck)
        /// agent.toml couldn't be written (the message to show).
        case saveFailed(String)
    }

    /// What the agent offered after agent.toml was written.
    public enum AgentRecheck: Equatable, Sendable {
        case offers([AgentKey])
        case offersNone
        case failed(String)

        public var message: String {
            switch self {
            case .offers(let keys):
                keys.count == 1 ? "Done. The agent now offers 1 key." : "Done. The agent now offers \(keys.count) keys."
            case .offersNone:
                "The agent still offers no keys. Lock 1Password and unlock it again (it may need that to read a new file), then click Recheck."
            case .failed(let reason):
                "The file was saved, but the agent didn\u{2019}t answer: \(reason)"
            }
        }
    }

    /// The vaults 1Password's agent offers by itself, while agent.toml doesn't exist.
    public static let defaultVaultNames: Set<String> = ["Private", "Personal", "Employee"]
    /// What to wait for before asking the agent again (1Password reads the saved file by itself).
    public static let standardRecheckDelay: Duration = .seconds(3)

    public private(set) var phase: Phase = .idle
    public private(set) var rows: [Row] = []
    /// agent.toml as it was when loaded (or after "Use these vaults"); nil = no file, or a file that
    /// couldn't be read (`existingReadError`).
    public private(set) var existingText: String?
    /// Why the agent.toml that is there couldn't be read (not UTF-8, no permission…); nil when it was
    /// read or there is none.
    public private(set) var existingReadError: String?
    /// Set by `apply()` when `needsConfirmation`: the view asks, then calls `apply(confirmed: true)`.
    public var isAskingToConfirm = false
    /// Where the previous file was copied by the last "Use these vaults".
    public private(set) var backupURL: URL?

    @ObservationIgnored private let cli: @MainActor () -> (any OnePasswordCLI)?
    @ObservationIgnored private let file: OnePasswordAgentConfigFile
    @ObservationIgnored private let listAgentKeys: @Sendable () async throws -> [AgentKey]
    @ObservationIgnored private let recheckDelay: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(cli: @escaping @MainActor () -> (any OnePasswordCLI)?, file: OnePasswordAgentConfigFile,
                listAgentKeys: @escaping @Sendable () async throws -> [AgentKey],
                recheckDelay: Duration = AgentVaultChooser.standardRecheckDelay,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.cli = cli
        self.file = file
        self.listAgentKeys = listAgentKeys
        self.recheckDelay = recheckDelay
        self.sleep = sleep
        self.now = now
    }

    public var selectedNames: [String] { rows.filter(\.isSelected).map(\.name) }

    /// The file "Use these vaults" would write.
    public var preview: String { OnePasswordAgentConfig.toml(vaults: selectedNames, keeping: keptEntries) }

    /// Entries of agent.toml that aren't a plain vault (an item, an account): written back unchanged.
    public var keptEntries: [String] {
        existingText.map(OnePasswordAgentConfig.keptEntries(in:)) ?? []
    }

    /// What "Use these vaults" would take out of agent.toml: vaults it names that aren't chosen any
    /// more, and lines it can't keep. The backup still has them.
    public var removals: [String] {
        guard let existingText else { return [] }
        let chosen = rows.filter(\.isSelected)
        let vaults = OnePasswordAgentConfig.vaultNames(in: existingText)
            .filter { name in !chosen.contains { $0.name == name || $0.id == name } }
            .map { "The vault \u{201C}\($0)\u{201D}" }
        let lines = OnePasswordAgentConfig.unreadLines(in: existingText).map { "The line \u{201C}\($0)\u{201D}" }
        return vaults + lines
    }

    /// Whether "Use these vaults" asks first: it would take something out of agent.toml, or replace a
    /// file that couldn't be read.
    public var needsConfirmation: Bool { existingReadError != nil || !removals.isEmpty }

    /// The question to ask when `needsConfirmation`.
    public var confirmationMessage: String {
        let path = OnePasswordAgentConfigFile.displayPath
        if var reason = existingReadError {
            while reason.hasSuffix(".") { reason.removeLast() }
            return "\(path) exists but couldn\u{2019}t be read: \(reason). Saving replaces it; the old file is kept as a backup next to it."
        }
        return "Saving takes these out of \(path):\n" + removals.map { "\u{2022} \($0)" }.joined(separator: "\n")
            + "\nThe old file is kept as a backup next to it."
    }

    public var isBusy: Bool {
        switch phase {
        case .loading, .saving, .checking: true
        default: false
        }
    }

    public var canApply: Bool { !isBusy && !selectedNames.isEmpty }

    /// Reads agent.toml and lists the vaults. With agent.toml, preselects only the vaults it names (the
    /// SSH key counts are a hint); without it, the vaults that hold SSH Key items and the vaults the agent
    /// offers by itself. A file that can't be read preselects nothing.
    public func load() async {
        phase = .loading
        readExisting()
        let fileExists = existingText != nil || existingReadError != nil
        let fromFile = existingText.map(OnePasswordAgentConfig.vaultNames(in:)) ?? []
        guard let client = cli() else {
            rows = fromFile.map { Row(id: "name:\($0)", name: $0, sshKeyCount: nil, isSelected: true) }
            phase = .listFailed(.cliNotFound)
            return
        }
        let vaults: [OnePasswordVault]
        do {
            vaults = try await client.listVaults()
        } catch {
            rows = fromFile.map { Row(id: "name:\($0)", name: $0, sshKeyCount: nil, isSelected: true) }
            phase = .listFailed(error)
            return
        }
        // Which vaults hold SSH keys: nice to have, so a failure just leaves the counts unknown.
        let keyItems = try? await client.listItems(categories: ["SSH Key"])
        var counts: [String: Int] = [:]
        for item in keyItems ?? [] where item.category == "SSH_KEY" || item.category.isEmpty {
            counts[item.vaultID, default: 0] += 1
        }
        var result = vaults.map { vault -> Row in
            let count = keyItems == nil ? nil : counts[vault.id] ?? 0
            let preselected = fileExists
                ? fromFile.contains(vault.name) || fromFile.contains(vault.id)
                : (count ?? 0) > 0 || Self.defaultVaultNames.contains(vault.name)
            return Row(id: vault.id, name: vault.name, sshKeyCount: count, isSelected: preselected)
        }
        // Vaults agent.toml names that `op` didn't list (another account, a typo) stay visible, chosen.
        for name in fromFile where !result.contains(where: { $0.name == name || $0.id == name }) {
            result.append(Row(id: "name:\(name)", name: name, sshKeyCount: nil, isSelected: true))
        }
        rows = result
        phase = .ready
    }

    public func toggle(_ id: String) {
        guard !isBusy, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].isSelected.toggle()
    }

    /// Adds a vault by name (chosen); a name already listed is just chosen. Returns false for a blank name.
    @discardableResult
    public func addVault(named text: String) -> Bool {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !name.isEmpty else { return false }
        if let index = rows.firstIndex(where: { $0.name == name }) {
            rows[index].isSelected = true
        } else {
            rows.append(Row(id: "name:\(name)", name: name, sshKeyCount: nil, isSelected: true))
        }
        return true
    }

    /// "Use these vaults": backs up an existing agent.toml, writes the new one (the kept entries after the
    /// chosen vaults), waits a few seconds and asks the agent for its keys. When `needsConfirmation` and
    /// not `confirmed`, only sets `isAskingToConfirm`.
    public func apply(confirmed: Bool = false) async {
        guard canApply else { return }
        if needsConfirmation && !confirmed {
            isAskingToConfirm = true
            return
        }
        isAskingToConfirm = false
        phase = .saving
        do {
            let result = try file.write(vaults: selectedNames, keeping: keptEntries, date: now())
            backupURL = result.backupURL
            readExisting()
        } catch {
            phase = .saveFailed("Couldn\u{2019}t save \(OnePasswordAgentConfigFile.displayPath): \(Self.describe(error))")
            return
        }
        await recheck(after: recheckDelay)
    }

    /// Asks the agent again (also the "Recheck" button after "Use these vaults").
    public func recheck() async {
        await recheck(after: .zero)
    }

    private func recheck(after delay: Duration) async {
        phase = .checking
        if delay > .zero {
            do { try await sleep(delay) } catch { phase = .ready; return }
        }
        do {
            let keys = try await listAgentKeys()
            phase = .done(keys.isEmpty ? .offersNone : .offers(keys))
        } catch {
            phase = .done(.failed(Self.describe(error)))
        }
    }

    /// Sets `existingText` and `existingReadError` from the file; never treats a read error as "no file".
    private func readExisting() {
        do {
            existingText = try file.read()
            existingReadError = nil
        } catch {
            existingText = nil
            existingReadError = Self.describe(error)
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
