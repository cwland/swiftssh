import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs the 1Password CLI (`op`) as a child process: no shell, an arguments array, a minimal
/// environment, capped output, a timeout, and Task cancellation, both of which kill `op`.
///
/// Secrets: the output of `read` is returned to the caller only; it is never logged and never put
/// in an error. Errors carry `op`'s stderr (see `details(_:)`), which names references, not values.
public struct ProcessOnePasswordCLI: OnePasswordCLI {
    public let executablePath: String
    /// The longest a single `op` call may take. Generous, because `op` waits for the user to approve
    /// with Touch ID; `op`'s own "authorization timeout" should come first.
    public let timeout: Duration
    private let environment: [String: String]
    private let stdoutLimit: Int
    private let stderrLimit: Int
    /// Categories and vault IDs seen in the latest `listItems`, so `fields` can offer the right ones.
    private let seenItems = SeenItems()
    /// Whether this app may look into 1Password's group container; asked only after `op` said "No
    /// accounts configured", to tell a blocked container apart from the CLI integration being off.
    private let containerAccess: @Sendable () -> OnePasswordPaths.Probe

    public init(executablePath: String, timeout: Duration = .seconds(120)) {
        let home = NSHomeDirectory()
        self.init(executablePath: executablePath, timeout: timeout, environment: ProcessInfo.processInfo.environment,
                  containerAccess: { OnePasswordPaths.groupContainerAccess(home: home) })
    }

    /// `environment` is the app's environment, from which only the minimal set is passed (see `environment(executablePath:from:)`).
    init(executablePath: String, timeout: Duration = .seconds(120), environment: [String: String],
         stdoutLimit: Int = 16 * 1024 * 1024, stderrLimit: Int = 64 * 1024,
         containerAccess: @escaping @Sendable () -> OnePasswordPaths.Probe = { .missing }) {
        self.executablePath = executablePath
        self.timeout = timeout
        self.environment = Self.environment(executablePath: executablePath, from: environment)
        self.stdoutLimit = stdoutLimit
        self.stderrLimit = stderrLimit
        self.containerAccess = containerAccess
    }

    /// The environment `op` gets: HOME, USER, LOGNAME and TMPDIR from `base` (when set), and
    /// PATH=/usr/bin:/bin:/usr/sbin:/sbin plus the folder `op` is in.
    static func environment(executablePath: String, from base: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = base[key] { result[key] = value }
        }
        var path = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let folder = (executablePath as NSString).deletingLastPathComponent
        if !folder.isEmpty, !path.contains(folder) { path.append(folder) }
        result["PATH"] = path.joined(separator: ":")
        return result
    }

    // MARK: OnePasswordCLI

    public func read(reference: String) async throws(OnePasswordError) -> String {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SecretReference.isReference(reference) else {
            throw .failed("That isn't a 1Password secret reference (op://…).")
        }
        let output = try await run(["read", "--no-newline", reference], outputIsSecret: true)
        return String(decoding: output, as: UTF8.self)
    }

    public func listItems() async throws(OnePasswordError) -> [OnePasswordItemSummary] {
        try await listItems(arguments: ["item", "list", "--format", "json"])
    }

    /// `op item list --categories "SSH Key" --format json`: metadata only, never field values.
    public func listItems(categories: [String]) async throws(OnePasswordError) -> [OnePasswordItemSummary] {
        try await listItems(arguments: ["item", "list", "--categories", categories.joined(separator: ","),
                                        "--format", "json"])
    }

    public func listVaults() async throws(OnePasswordError) -> [OnePasswordVault] {
        let output = try await run(["vault", "list", "--format", "json"])
        if String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        do {
            return try JSONDecoder().decode([ListedVault].self, from: output)
                .map { OnePasswordVault(id: $0.id, name: $0.name ?? $0.id) }
        } catch {
            throw .failed("Couldn't read the vault list from 1Password.")
        }
    }

    private func listItems(arguments: [String]) async throws(OnePasswordError) -> [OnePasswordItemSummary] {
        let output = try await run(arguments)
        if String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let decoded: [ListedItem]
        do {
            decoded = try JSONDecoder().decode([ListedItem].self, from: output)
        } catch {
            throw .failed("Couldn't read the item list from 1Password.")
        }
        let items = decoded.map { item in
            OnePasswordItemSummary(id: item.id, title: item.title ?? "", vault: item.vault.name ?? item.vault.id,
                                   vaultID: item.vault.id, category: item.category ?? "")
        }
        seenItems.remember(items)
        return items
    }

    /// Built locally, without running `op` (see `OnePasswordField.standardFields`).
    public func fields(itemID: String, vault: String) async throws(OnePasswordError) -> [OnePasswordField] {
        let seen = seenItems.item(itemID)
        return OnePasswordField.standardFields(itemID: itemID, vault: vault, vaultID: seen?.vaultID, category: seen?.category)
    }

    public func check() async throws(OnePasswordError) {
        _ = try await run(["vault", "list", "--format", "json"])
    }

    // MARK: Running op

    /// `outputIsSecret`: stdout is a secret (`read`) and is never looked at for an error. Otherwise, when a
    /// failed `op` printed nothing to stderr, its stdout explains the failure instead.
    private func run(_ arguments: [String], outputIsSecret: Bool = false) async throws(OnePasswordError) -> Data {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { throw .cliNotFound }
        guard let result = await ChildProcess.run(executablePath: executablePath, arguments: arguments,
                                                  environment: environment, timeout: timeout,
                                                  stdoutLimit: stdoutLimit, stderrLimit: stderrLimit) else {
            throw .cliNotFound
        }
        let stderrDetails = Self.details(result.stderr)
        switch result.stop {
        case .timedOut: throw .timedOut(details: stderrDetails.isEmpty ? nil : stderrDetails)
        case .cancelled: throw .cancelled(details: stderrDetails.isEmpty ? nil : stderrDetails)
        case .overflow: throw .failed("op printed more output than expected.")
        case nil: break
        }
        guard result.status == 0 else {
            let explanation = stderrDetails.isEmpty && !outputIsSecret ? result.stdout : result.stderr
            throw Self.refine(Self.error(stderr: explanation, status: result.status), containerAccess: containerAccess)
        }
        return result.stdout
    }

    /// Classifies a failed call by `op`'s stderr (its exit status is always 1; see research.md §2–3).
    static func error(stderr: Data, status: Int32) -> OnePasswordError {
        let detail = details(stderr)
        let text = detail.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        if has("authorization timeout") { return .timedOut(details: detail) }
        if has("authorization prompt dismissed") { return .cancelled(details: detail) }
        // macOS refused `op` (as this app's child) a look into 1Password's group container, e.g.
        // "open …/Group Containers/2BUA8C4S2C.com.1password/…/settings.json: operation not permitted".
        if has("operation not permitted"), has("group containers", "2bua8c4s2c.com.1password") {
            return .containerBlocked(details: detail)
        }
        // Nothing listens on the desktop app's socket: 1Password isn't running.
        if has("connecting to desktop app"), has("connection refused", "is 1password running", "not running") {
            return .appNotRunning(details: detail)
        }
        // "No accounts configured for use with 1Password CLI." comes with a list of options and an
        // interactive prompt (stdin is /dev/null, so it ends); seen on macOS 27 with the integration off or
        // 1Password's data not shared with the app.
        if has("connecting to desktop app", "lostconnectiontoapp", "connection reset", "not currently signed in",
               "no accounts configured") {
            return .integrationOff(details: detail)
        }
        if has("isn't a vault", "isn't an item", "isn't a field", "could not find", "not found", "does not exist") {
            return .notFound(detail)
        }
        if has("is locked") { return .appLocked(details: detail) } // [UNVERIFIED] wording; see research.md §3
        if detail.isEmpty { return .failed("op exited with status \(status)") }
        return .failed(detail)
    }

    /// "No accounts configured" is what `op` says both when the CLI integration is off and when macOS
    /// blocks 1Password's group container: when this app's own look into the container is refused
    /// too, it is the container (`op` runs as this app's child, so macOS treats both alike).
    static func refine(_ error: OnePasswordError, containerAccess: () -> OnePasswordPaths.Probe) -> OnePasswordError {
        guard case .integrationOff(let details) = error,
              details?.lowercased().contains("no accounts configured") == true,
              containerAccess() == .denied else { return error }
        return .containerBlocked(details: details)
    }

    /// The longest `details` text, in characters.
    static let detailsLimit = 500

    /// `op`'s text as one safe line: terminal escape sequences and other control characters (and bidi
    /// overrides) removed, tabs as spaces, `[ERROR] yyyy/mm/dd hh:mm:ss ` prefixes dropped, lines trimmed and
    /// joined with spaces, at most `detailsLimit` characters (the last one "…" when cut).
    static func details(_ output: Data) -> String {
        let escape = try! Regex(#"\x{1B}(\[[0-?]*[ -/]*[@-~]|\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)?|[@-_])"#)
        let prefix = try! Regex(#"^\[ERROR\] (\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} )?"#)
        let lines = String(decoding: output, as: UTF8.self)
            .replacing(escape, with: "")
            .split(whereSeparator: \.isNewline)
            .map { line in
                let cleaned = String(String.UnicodeScalarView(line.unicodeScalars.compactMap(Self.cleaned)))
                return cleaned.replacing(prefix, with: "").trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: " ")
        return joined.count > detailsLimit ? String(joined.prefix(detailsLimit - 1)) + "\u{2026}" : joined
    }

    /// A tab becomes a space; control characters and bidi controls are dropped.
    private static func cleaned(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        if scalar == "\t" { return " " }
        if scalar.properties.generalCategory == .control { return nil }
        switch scalar.value {
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return nil
        default: return scalar
        }
    }
}

/// One element of `op vault list --format json`; other keys are ignored.
private struct ListedVault: Decodable {
    let id: String
    let name: String?
}

/// One element of `op item list --format json`; other keys are ignored.
private struct ListedItem: Decodable {
    struct Vault: Decodable {
        let id: String
        let name: String?
    }

    let id: String
    let title: String?
    let vault: Vault
    let category: String?
}

private final class SeenItems: Sendable {
    private let items = Mutex<[String: (vaultID: String, category: String)]>([:])

    func remember(_ list: [OnePasswordItemSummary]) {
        items.withLock { items in
            for item in list { items[item.id] = (item.vaultID, item.category) }
        }
    }

    func item(_ id: String) -> (vaultID: String, category: String)? {
        items.withLock { $0[id] }
    }
}

/// A child process with captured, capped stdout and stderr, killed (SIGKILL) on timeout, on
/// cancellation of the calling Task, or when stdout grows past its limit.
final class ChildProcess: Sendable {
    enum Stop: Sendable { case timedOut, cancelled, overflow }

    struct Result: Sendable {
        var stdout: Data
        var stderr: Data
        var status: Int32
        /// Why the process was stopped; nil when it ended by itself.
        var stop: Stop?
    }

    private struct State {
        var stdout = Data()
        var stderr = Data()
        var stdoutEOF = false
        var stderrEOF = false
        var pid: pid_t?
        /// Set (with the stop reason still nil) just before the process is started.
        var launching = false
        var launchFailed = false
        var exited = false
        var status: Int32 = 0
        var stop: Stop?
        var continuation: CheckedContinuation<Result?, Never>?
        var finished = false
        var timer: Task<Void, Never>?
    }

    /// After the process exits, how long to wait for the pipes to close (a stray grandchild may hold them).
    private static let drainGrace: DispatchTimeInterval = .seconds(1)

    private let stdoutLimit: Int
    private let stderrLimit: Int
    private let state = Mutex(State())

    private init(stdoutLimit: Int, stderrLimit: Int) {
        self.stdoutLimit = stdoutLimit
        self.stderrLimit = stderrLimit
    }

    /// nil when the process couldn't be launched.
    static func run(executablePath: String, arguments: [String], environment: [String: String],
                    timeout: Duration, stdoutLimit: Int, stderrLimit: Int) async -> Result? {
        let child = ChildProcess(stdoutLimit: stdoutLimit, stderrLimit: stderrLimit)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
                child.state.withLock { $0.continuation = continuation }
                child.launch(executablePath: executablePath, arguments: arguments, environment: environment,
                             timeout: timeout)
            }
        } onCancel: {
            child.stop(.cancelled)
        }
    }

    private func launch(executablePath: String, arguments: [String], environment: [String: String], timeout: Duration) {
        // Cancelled before it started: don't start it.
        let cancelled = state.withLock { state -> Bool in
            if state.stop != nil { return true }
            state.launching = true
            return false
        }
        if cancelled { return finishIfDone() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [self] process in
            exited(status: process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            state.withLock { $0.launchFailed = true }
            return finishIfDone()
        }
        let pid = process.processIdentifier
        let stopEarly = state.withLock { state -> Bool in
            state.pid = pid
            return state.stop != nil
        }
        if stopEarly { kill(pid, SIGKILL) }

        drain(stdout.fileHandleForReading, isStdout: true)
        drain(stderr.fileHandleForReading, isStdout: false)
        let timer = Task { [self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            stop(.timedOut)
        }
        let finished = state.withLock { state -> Bool in
            state.timer = timer
            return state.finished
        }
        if finished { timer.cancel() }
    }

    private func drain(_ handle: FileHandle, isStdout: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let chunk: Data?
                do { chunk = try handle.read(upToCount: 64 * 1024) } catch { chunk = nil }
                guard let chunk, !chunk.isEmpty else { break }
                append(chunk, isStdout: isStdout)
            }
            try? handle.close()
            state.withLock { state in
                if isStdout { state.stdoutEOF = true } else { state.stderrEOF = true }
            }
            finishIfDone()
        }
    }

    private func append(_ chunk: Data, isStdout: Bool) {
        let overflow = state.withLock { state -> Bool in
            if isStdout {
                guard state.stop == nil else { return false }
                if state.stdout.count + chunk.count > stdoutLimit { return true }
                state.stdout.append(chunk)
            } else {
                let room = stderrLimit - state.stderr.count
                if room > 0 { state.stderr.append(chunk.prefix(room)) }
            }
            return false
        }
        if overflow { stop(.overflow) }
    }

    /// Kills the process (if still running) and records why; the first reason wins.
    private func stop(_ reason: Stop) {
        let pid = state.withLock { state -> pid_t? in
            guard state.stop == nil, !state.exited, !state.finished else { return nil }
            state.stop = reason
            return state.pid
        }
        if let pid { kill(pid, SIGKILL) }
        finishIfDone()
    }

    private func exited(status: Int32) {
        state.withLock { state in
            state.exited = true
            state.status = status
        }
        finishIfDone()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGrace) { [self] in finishIfDone(force: true) }
    }

    private func finishIfDone(force: Bool = false) {
        let done = state.withLock { state -> (CheckedContinuation<Result?, Never>, Result?, Task<Void, Never>?)? in
            guard !state.finished, let continuation = state.continuation else { return nil }
            let result = Result(stdout: state.stdout, stderr: state.stderr, status: state.status, stop: state.stop)
            if state.launchFailed {
                state.finished = true
                return (continuation, nil, state.timer)
            }
            let notLaunched = !state.launching && state.stop != nil
            let drained = state.stdoutEOF && state.stderrEOF
            // After a stop (timeout, cancel, overflow) still wait for the pipes to drain, so stderr
            // written before the kill is kept; `force` (drainGrace after exit) covers a grandchild
            // that holds a pipe open.
            guard notLaunched || (state.exited && (drained || force)) else { return nil }
            state.finished = true
            state.stdout = Data()
            return (continuation, result, state.timer)
        }
        guard let (continuation, result, timer) = done else { return }
        timer?.cancel()
        continuation.resume(returning: result)
    }
}
