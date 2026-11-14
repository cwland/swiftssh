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
    /// Set when "Install with Homebrew" couldn't hand the command to Terminal.
    private(set) var installError: String?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
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
    /// Found and not blocked, by the file check or by the agent itself.
    var isAgentReady: Bool {
        guard case .available = agentSocketStatus else { return false }
        return agentKeys != .blocked
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
        return ProcessOnePasswordCLI(executablePath: path)
    }

    // MARK: Checking

    /// Re-checks the app, the socket, `op` (and its version), Homebrew and the agent's keys.
    /// A CLI test result is kept unless `op` moved.
    func refresh() {
        appURL = Self.findApp()
        homebrewPath = OnePasswordLinks.homebrewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        let status = currentAgentSocketStatus()
        agentSocketStatus = status
        let socket = agentSocketPath
        let cli = cli()
        if cli != cliPath {
            cliVersion = nil
            testTask?.cancel()
            cliTest = .idle
        }
        cliPath = cli
        hasChecked = true

        if socket == nil {
            agentKeys = .unknown
        } else if case .loaded = agentKeys {
            // Keep showing the old list while it reloads.
        } else {
            agentKeys = .loading
        }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if let cli {
                let version = await OnePasswordCLIVersion.read(executablePath: cli)
                guard !Task.isCancelled, let self else { return }
                if self.cliPath == cli { self.cliVersion = version }
            }
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

    /// Refreshes once, the first time an editor needs the status.
    func refreshIfNeeded() {
        if !hasChecked { refresh() }
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

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(OnePasswordLinks.homebrewInstallCommand, forType: .string)
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

/// Reads `op --version` without a shell: arguments array, minimal environment, output capped,
/// killed after 5 seconds. `--version` never talks to the 1Password app.
enum OnePasswordCLIVersion {
    static func read(executablePath: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(executablePath: executablePath))
            }
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    private static func run(executablePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--version"]
        process.environment = environment(executablePath: executablePath)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let box = ProcessBox(process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if box.process.isRunning { box.process.terminate() }
        }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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
