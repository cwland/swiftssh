import Foundation
import AppKit
import Observation
import AppCore
import SSHCore

/// Live status of the 1Password setup checklist (Settings → 1Password) and the shared way the app
/// finds 1Password's SSH agent socket and `op`. One instance, owned by `AppEnvironment` and put in
/// the SwiftUI environment, so the Settings pane, the editors and `SessionManager` agree.
///
/// `refresh()` re-checks everything; the pane calls it on appear and whenever the app becomes
/// active (the user may have just changed something in 1Password or Terminal).
@MainActor @Observable
final class OnePasswordSetup {
    enum CLITest: Equatable {
        case idle
        case running
        case passed
        case failed(OnePasswordError)
    }

    enum AgentKeys: Equatable {
        /// Not checked yet, or there is no agent socket.
        case unknown
        case loading
        case loaded([AgentKey])
        /// macOS refused access to the socket (privacy protection on 1Password's Group Container).
        case blocked
        case failed(String)
    }

    let settings: OnePasswordSettings
    /// Brings 1Password's Touch ID prompt forward (Settings → 1Password → "Bring 1Password's prompt
    /// to the front"); every `op` client from `makeClient()` reports its calls here.
    @ObservationIgnored private(set) lazy var promptFocus: OnePasswordPromptFocus = {
        let settings = settings
        return OnePasswordPromptFocus(isEnabled: { settings.bringsPromptForward },
                                      handOff: { OnePasswordApp.handOff() },
                                      takeBack: { OnePasswordApp.takeBack() })
    }()

    /// nil when 1Password isn't installed.
    private(set) var appURL: URL?
    private(set) var agentSocketStatus: AgentSocketStatus = .notFound
    private(set) var cliPath: String?
    /// `op --version`, once read.
    private(set) var cliVersion: String?
    /// The first Homebrew found, nil without Homebrew.
    private(set) var homebrewPath: String?
    private(set) var cliTest: CLITest = .idle
    private(set) var agentKeys: AgentKeys = .unknown
    /// False until the first `refresh()`; views don't claim "not set up" before that.
    private(set) var hasChecked = false
    /// False until the first `refresh()` or `refreshCLIStatus()`; password fields wait for it.
    private(set) var hasCheckedCLI = false
    /// Items a picker listed this session (never stored), by item ID, to show names for references.
    private(set) var knownItems: [String: OnePasswordItemSummary] = [:]
    /// Set when "Install with Homebrew" couldn't hand the command to Terminal.
    private(set) var installError: String?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var versionTask: Task<Void, Never>?
    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(settings: OnePasswordSettings) {
        self.settings = settings
    }

    var isAppInstalled: Bool { appURL != nil }
    /// The socket found, also when macOS blocks it (ssh may still work once macOS allows access).
    var agentSocketPath: String? {
        switch agentSocketStatus {
        case .available(let path), .blocked(let path): path
        case .notFound: nil
        }
    }
    /// Found, not blocked, and listing its keys didn't fail (by the file check and by the agent itself).
    var isAgentReady: Bool {
        guard case .available = agentSocketStatus else { return false }
        switch agentKeys {
        case .blocked, .failed: return false
        case .unknown, .loading, .loaded: return true
        }
    }
    /// Why the agent answered nothing although its socket exists (not running, error), if it failed.
    var agentFailure: String? {
        if case .failed(let message) = agentKeys { return message }
        return nil
    }
    var isAgentBlocked: Bool {
        if case .blocked = agentSocketStatus { return true }
        return agentKeys == .blocked
    }
    var isCLIReady: Bool { cliPath != nil }

    // MARK: Lookups (also used by SessionManager at connect time)

    /// The 1Password SSH agent socket: the override, else the first standard path, that exists or that
    /// macOS blocks (EPERM/EACCES from stat). A blocked socket is still handed to ssh, since macOS may
    /// allow the access when ssh connects; `FileManager.fileExists` would report it as missing.
    func agentSocket() -> String? {
        OnePasswordPaths.agentSocket(home: NSHomeDirectory(), override: Self.nonEmpty(settings.agentSocketOverride),
                                     probe: OnePasswordPaths.probe)
    }

    /// Like `agentSocket()`, but tells a socket macOS blocks apart.
    func currentAgentSocketStatus() -> AgentSocketStatus {
        OnePasswordPaths.agentSocketStatus(home: NSHomeDirectory(), override: Self.nonEmpty(settings.agentSocketOverride),
                                           probe: OnePasswordPaths.probe)
    }

    /// `op`: the override if it is executable, else the first standard path that is.
    func cli() -> String? {
        OnePasswordPaths.cli(override: Self.nonEmpty(settings.cliPathOverride),
                             isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// A client for the `op` found now; nil without `op`.
    func makeClient() -> (any OnePasswordCLI)? {
        guard let path = cli() else { return nil }
        return FocusHandingOnePasswordCLI(base: ProcessOnePasswordCLI(executablePath: path), focus: promptFocus)
    }

    // MARK: Checking

    /// Re-checks only `op` (its path, and its version when it moved). Cheap: no `op` call, no agent
    /// access; password fields use this, never the full `refresh()`.
    func refreshCLIStatus() {
        let cli = cli()
        if cli != cliPath {
            cliVersion = nil
            versionTask?.cancel()
            testTask?.cancel()
            cliTest = .idle
        }
        cliPath = cli
        hasCheckedCLI = true
    }

    /// Remembers the items a picker listed, so a reference can show "vault / item / field".
    func remember(items: [OnePasswordItemSummary]) {
        knownItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// "<vault name> / <item title> / <field>" for an `op://<vault>/<item ID>/<field>` reference whose
    /// item a picker listed this session; nil otherwise (show the reference text).
    func displayName(for reference: String) -> String? {
        var path = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.lowercased().hasPrefix("op://") else { return nil }
        path.removeFirst(5)
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count == 3, let item = knownItems[parts[1]],
              item.vault == parts[0] || item.vaultID == parts[0] else { return nil }
        let title = item.title.isEmpty ? "Untitled item" : item.title
        return "\(item.vault) / \(title) / \(parts[2])"
    }

    /// Re-checks the app, the socket, `op` (and its version), Homebrew and the agent's keys. This lists
    /// the agent's keys, which can make macOS ask to access data from other apps: call it only from
    /// Settings → 1Password and the agent key picker. A CLI test result is kept unless `op` moved.
    func refresh() {
        appURL = Self.findApp()
        homebrewPath = OnePasswordLinks.homebrewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        let status = currentAgentSocketStatus()
        agentSocketStatus = status
        let socket = agentSocketPath
        refreshCLIStatus()
        let cli = cliPath
        hasChecked = true

        if socket == nil {
            agentKeys = .unknown
        } else if case .loaded = agentKeys {
            // Keep showing the old list while it reloads.
        } else {
            agentKeys = .loading
        }

        versionTask?.cancel()
        versionTask = Task { [weak self] in
            guard let cli else { return }
            let version = await OnePasswordCLIVersion.read(executablePath: cli)
            guard !Task.isCancelled, let self else { return }
            if self.cliPath == cli { self.cliVersion = version }
        }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if let socket {
                let result: AgentKeys
                do {
                    result = .loaded(try await SSHAgentClient.listKeys(socketPath: socket))
                } catch SSHAgentError.permissionDenied {
                    result = .blocked
                } catch {
                    result = .failed(Self.describe(error))
                }
                guard !Task.isCancelled, let self else { return }
                if self.agentSocketPath == socket { self.agentKeys = result }
            }
        }
    }

    /// "Test": runs `op`'s harmless integration check. Touch ID / the 1Password prompt may appear.
    func testCLI() {
        testTask?.cancel()
        guard let client = makeClient() else {
            cliTest = .failed(.cliNotFound)
            return
        }
        cliTest = .running
        testTask = Task { [weak self] in
            let outcome: CLITest
            do throws(OnePasswordError) {
                try await client.check()
                outcome = .passed
            } catch {
                outcome = .failed(error)
            }
            guard !Task.isCancelled, let self else { return }
            self.cliTest = outcome
        }
    }

    // MARK: Actions

    func openDownloadPage() {
        NSWorkspace.shared.open(OnePasswordLinks.appDownloadURL)
    }

    func openCLIDownloadPage() {
        NSWorkspace.shared.open(OnePasswordLinks.cliDownloadURL)
    }

    /// Opens the 1Password app (there is no documented link into its Developer settings).
    func openOnePassword() {
        if let app = appURL ?? Self.findApp() {
            NSWorkspace.shared.open(app)
        } else {
            openDownloadPage()
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(OnePasswordLinks.privacySettingsURL)
    }

    /// Puts `text` on the clipboard (commands the checklist and Host Details offer).
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Writes a one-off `.command` script (0700, in the temporary folder) that runs
    /// `brew install --cask 1password-cli`, waits for a key and deletes itself, and opens it, so
    /// Terminal runs it where the user can see and answer Homebrew. The app runs no shell itself.
    func installWithHomebrew() {
        installError = nil
        guard let brew = homebrewPath else { return }
        let script = """
        #!/bin/zsh
        echo "Installing the 1Password CLI with Homebrew…"
        echo
        \(Self.shellQuoted(brew)) \(OnePasswordLinks.homebrewInstallArguments.map(Self.shellQuoted).joined(separator: " "))
        echo
        echo "Done. Return to Termius Reimagined; the 1Password settings update by themselves."
        read -k 1 -s "?Press any key to close this window."
        rm -f -- "$0"

        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Install 1Password CLI \(UUID().uuidString.prefix(8)).command", isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8),
                                             attributes: [.posixPermissions: 0o700]) else {
            installError = "Couldn\u{2019}t prepare the install command. Copy the command and run it in Terminal."
            return
        }
        if !NSWorkspace.shared.open(url) {
            try? FileManager.default.removeItem(at: url)
            installError = "Couldn\u{2019}t open Terminal. Copy the command and run it in Terminal."
        }
    }

    // MARK: Helpers

    private static func findApp() -> URL? {
        if FileManager.default.fileExists(atPath: OnePasswordLinks.appPath) {
            return URL(fileURLWithPath: OnePasswordLinks.appPath, isDirectory: true)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: OnePasswordLinks.appBundleID)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Single-quoted for zsh.
    nonisolated static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Reads `op --version` without a shell: arguments array, minimal environment, output capped at 256
/// bytes and read without blocking a thread, SIGKILL after 5 seconds. `--version` never talks to the
/// 1Password app. (The core's process runner is internal to AppCore, so this stays a small copy.)
enum OnePasswordCLIVersion {
    static func read(executablePath: String) async -> String? {
        let run = Run()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                run.start(executablePath: executablePath, continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }

    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private var output = Data()
        private var exited = false
        private var reachedEOF = false
        private var succeeded = false
        private var stopped = false
        private var finished = false
        private var continuation: CheckedContinuation<String?, Never>?

        func start(executablePath: String, continuation: CheckedContinuation<String?, Never>) {
            lock.lock()
            self.continuation = continuation
            let cancelled = stopped
            lock.unlock()
            if cancelled { finish(); return }

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["--version"]
            process.environment = OnePasswordCLIVersion.environment(executablePath: executablePath)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    markEOF()
                } else {
                    append(chunk)
                }
            }
            process.terminationHandler = { [self] process in
                markExited(status: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                stopped = true
                lock.unlock()
                finish()
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [self] in
                terminate()
            }
        }

        func cancel() {
            lock.lock()
            stopped = true
            let started = continuation != nil
            lock.unlock()
            if started { terminate() }
        }

        /// SIGKILL, then give up on the pipe after a second (a stray grandchild could hold it open).
        private func terminate() {
            lock.lock()
            let done = finished
            stopped = true
            lock.unlock()
            if done { return }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                finish()
            }
        }

        private func append(_ chunk: Data) {
            lock.lock()
            if output.count < 256 { output.append(chunk.prefix(256 - output.count)) }
            lock.unlock()
        }

        private func markEOF() {
            lock.lock()
            reachedEOF = true
            let ready = exited
            lock.unlock()
            if ready { finish() }
        }

        private func markExited(status: Int32) {
            lock.lock()
            exited = true
            succeeded = status == 0
            let ready = reachedEOF
            lock.unlock()
            if ready { finish() }
        }

        private func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let result: String? = {
                guard succeeded, !stopped else { return nil }
                let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }()
            lock.unlock()
            process.terminationHandler = nil
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            continuation?.resume(returning: result)
        }
    }

    private static func environment(executablePath: String) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = current[key] { environment[key] = value }
        }
        let directory = (executablePath as NSString).deletingLastPathComponent
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:\(directory)"
        return environment
    }
}
