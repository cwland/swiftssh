import CoreModels
import Foundation
import Synchronization

/// Terminal session that runs the system's `/usr/bin/ssh` in a pseudo-terminal, for hosts the built-in
/// engine can't handle (RSA keys, or hosts that opt in).
///
/// - **Host keys** are checked by the app before ssh runs: `ssh-keyscan` fetches the server's keys, the
///   preferred one (ed25519, then ecdsa, then rsa) goes through the `HostKeyEvaluator` once, and ssh is
///   started with a `known_hosts` file holding exactly that key for the host, `StrictHostKeyChecking=yes`
///   and `HostKeyAlgorithms` limited to that key's type. If the server presents anything else, ssh refuses.
/// - **Secrets** never appear in arguments, the environment or output: a password or key passphrase is
///   written to a one-time 0600 file that the askpass helper prints and deletes; a private key goes to a
///   0600 file passed with `-i`. Both are deleted as soon as the session has started or ssh exits
///   (whichever comes first), and on `close()`.
/// - **Session start** is detected when ssh switches the terminal out of canonical mode, which it does
///   only after authentication, right before the remote session's output; it emits `.ready`. With a
///   stored secret, ssh's own messages before that point are held back and, if ssh fails (exit status
///   255), turned into the error; `.connected` and `.ready` come together. Without a stored secret, ssh
///   asks in the terminal, so `.connected` is emitted as soon as ssh runs (its prompts are shown as
///   output) and `.ready` once the user has signed in.
/// - **Commands** (`runCommand`) reuse the session's connection through ssh's control socket
///   (`ControlMaster=auto`, socket in `SSHRuntimeDirectory.controlDirectory`), in batch mode, without
///   askpass.
public final class SystemSSHSession: TerminalSession {
    public let events: AsyncStream<SessionEvent>

    static let commandOutputLimit = 1_048_576
    /// Output kept from before the session started (for the error message and to show once connected).
    static let heldOutputLimit = 262_144
    static let keyscanTimeout: Duration = .seconds(30)
    static let controlExitTimeout: Duration = .seconds(2)
    /// Host key types in order of preference.
    static let keyTypePreference = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
                                    "ecdsa-sha2-nistp521", "ssh-rsa"]

    private let plan: ConnectionPlan
    private let host: String
    private let hostKeys: any HostKeyEvaluator
    private let knownHostsLines: @Sendable () async -> [String]
    private let runtime: SSHRuntimeDirectory
    private let sshPath: String
    private let keyscanPath: String
    private let commandTimeout: Duration
    private let eventContinuation: AsyncStream<SessionEvent>.Continuation
    private let inputQueue = DispatchQueue(label: "SystemSSHSession.input")
    /// Resolved once `.connected` or `.closed` was emitted; `start` waits for it.
    private let startGate = OneShot<Void>()
    private let state = Mutex(State())

    private struct State {
        var started = false
        /// `.closed` was emitted and the event stream finished.
        var ended = false
        var connectedEmitted = false
        /// ssh's interactive session began (authentication succeeded).
        var sessionStarted = false
        var keyscan: PTYProcess?
        var ssh: PTYProcess?
        var commands: [ObjectIdentifier: PTYProcess] = [:]
        /// Key and secret files still on disk.
        var tempFiles: [URL] = []
        /// Output not yet shown because the session hasn't started (askpass mode only).
        var heldOutput: [UInt8] = []
        /// Output before the session started, for the error message.
        var preSessionOutput: [UInt8] = []
        /// Input sent before ssh was launched.
        var backlog: [[UInt8]] = []
        var cols = 80
        var rows = 24
        var hostKeyAlgorithms: String?
        /// This session's entry in the control master registry, while ssh runs.
        var controlKey: String?
    }

    public convenience init(plan: ConnectionPlan, hostKeys: any HostKeyEvaluator,
                            knownHostsLines: @escaping @Sendable () async -> [String],
                            runtime: SSHRuntimeDirectory, sshPath: String = "/usr/bin/ssh",
                            keyscanPath: String = "/usr/bin/ssh-keyscan") {
        self.init(plan: plan, hostKeys: hostKeys, knownHostsLines: knownHostsLines, runtime: runtime,
                  sshPath: sshPath, keyscanPath: keyscanPath, commandTimeout: .seconds(15))
    }

    /// `commandTimeout` bounds `runCommand`; only tests change it.
    init(plan: ConnectionPlan, hostKeys: any HostKeyEvaluator, knownHostsLines: @escaping @Sendable () async -> [String],
         runtime: SSHRuntimeDirectory, sshPath: String, keyscanPath: String, commandTimeout: Duration) {
        self.plan = plan
        self.host = Self.normalizedHost(plan.host)
        self.hostKeys = hostKeys
        self.knownHostsLines = knownHostsLines
        self.runtime = runtime
        self.sshPath = sshPath
        self.keyscanPath = keyscanPath
        self.commandTimeout = commandTimeout
        (events, eventContinuation) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
    }

    // MARK: TerminalSession

    public func start(cols: Int, rows: Int) async {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.started, !state.ended else { return false }
            state.started = true
            state.cols = cols
            state.rows = rows
            return true
        }
        guard shouldStart else { return }
        // The connection runs on its own task so that `close()` can end `start` at once, even while the
        // host key evaluator is waiting for the user.
        Task { await self.connect() }
        await startGate.wait()
    }

    public func send(_ bytes: [UInt8]) async {
        guard !bytes.isEmpty else { return }
        state.withLock { state in
            guard !state.ended else { return }
            if let ssh = state.ssh {
                inputQueue.async { ssh.write(bytes) }
            } else {
                state.backlog.append(bytes)
            }
        }
    }

    public func resize(cols: Int, rows: Int) async {
        state.withLock { state in
            guard !state.ended else { return }
            if let ssh = state.ssh {
                inputQueue.async { ssh.resize(cols: cols, rows: rows) }
            } else {
                state.cols = cols
                state.rows = rows
            }
        }
    }

    /// Runs `command` through the session's control socket (`-T -o BatchMode=yes`): stdout and stderr
    /// merged in order. A non-zero exit status still returns the output; ssh's own failure (status 255)
    /// throws. Output above 1 MB or a run longer than 15 s kills the command's ssh and throws
    /// (`.connectionFailed("Command output too large")` / `.timedOut`).
    public func runCommand(_ command: String) async throws -> String {
        let (algorithms, ended) = state.withLock { state in
            (state.sessionStarted && state.ssh != nil ? state.hostKeyAlgorithms : nil, state.ended)
        }
        guard !ended else { throw SessionError.connectionFailed("Session closed") }
        guard let algorithms else { throw SessionError.connectionFailed("The session is not connected.") }

        let arguments = Self.optionArguments(port: plan.port, username: plan.username, runtime: runtime)
            + ["-o", "HostKeyAlgorithms=\(algorithms)", "-T", "-o", "BatchMode=yes", "--", host, command]
        let process: PTYProcess
        do {
            process = try PTYProcess(executable: sshPath, arguments: arguments, environment: [:],
                                     cols: 80, rows: 24, rawMode: true)
        } catch {
            throw SessionError.connectionFailed("Could not run ssh")
        }
        let id = ObjectIdentifier(process)
        let registered = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.commands[id] = process
            return true
        }
        guard registered else {
            process.kill()
            throw SessionError.connectionFailed("Session closed")
        }
        defer { state.withLock { _ = $0.commands.removeValue(forKey: id) } }

        switch await Self.collect(process, limit: Self.commandOutputLimit, timeout: commandTimeout) {
        case .tooLarge:
            throw SessionError.connectionFailed("Command output too large")
        case .timedOut:
            throw SessionError.timedOut
        case .finished(let output, let status):
            if isEnded { throw SessionError.connectionFailed("Session closed") }
            if status == 255 { throw Self.classifyFailure(output, secrets: secrets) }
            return String(decoding: output, as: UTF8.self)
        }
    }

    /// Ends the session: emits `.closed(.userClosed)` (once), hangs up ssh (SIGHUP, then SIGKILL after
    /// 2 s), deletes the key and secret files and, when no other session of this app uses the same
    /// control master, asks it to exit (`ssh -O exit`, at most 2 s).
    public func close() async {
        let taken = state.withLock { state in
            if !state.ended {
                state.ended = true
                eventContinuation.yield(.closed(.userClosed))
                eventContinuation.finish()
            }
            defer {
                state.keyscan = nil
                state.ssh = nil
                state.commands = [:]
                state.tempFiles = []
                state.controlKey = nil
            }
            return (keyscan: state.keyscan, ssh: state.ssh, commands: Array(state.commands.values),
                    files: state.tempFiles, controlKey: state.controlKey)
        }
        startGate.resolve(())
        taken.keyscan?.kill()
        taken.commands.forEach { $0.kill() }
        taken.ssh?.terminate()
        taken.files.forEach(runtime.remove)
        if let key = taken.controlKey, Self.controlMasters.release(key) {
            await stopControlMaster()
        }
    }

    // MARK: Connecting

    private func connect() async {
        guard Self.isSafeHost(host), Self.isSafeUsername(plan.username), (1...65_535).contains(plan.port) else {
            finish(.failed(.connectionFailed("Invalid host, port or user name")))
            return
        }
        do {
            try runtime.prepare()
        } catch {
            finish(.failed(.connectionFailed("Could not prepare the runtime directory")))
            return
        }
        do {
            try runtime.prepareControlDirectory()
        } catch SSHRuntimeError.unsafeControlDirectory(let path) {
            finish(.failed(.connectionFailed("Unsafe control socket directory \(path)")))
            return
        } catch {
            finish(.failed(.connectionFailed("Could not prepare the control socket directory")))
            return
        }

        // 1. Fetch the server's host keys.
        guard let candidate = await scanHostKey() else { return }

        // 2. One trust decision, before ssh runs.
        guard await hostKeys.evaluate(candidate) == .trusted else {
            finish(.failed(.hostKeyRejected))
            return
        }
        guard !isEnded else { return }

        // 3. known_hosts: the vault's lines for other hosts, plus exactly the key just trusted for this one.
        let trustedLine = "\(candidate.hostPort) \(candidate.keyType) \(candidate.publicKeyBlob.base64EncodedString())"
        let otherLines = await knownHostsLines().filter { line in
            line.split(separator: " ", maxSplits: 1).first.map(String.init) != candidate.hostPort
        }
        do {
            _ = try runtime.writeKnownHosts(otherLines + [trustedLine])
        } catch {
            finish(.failed(.connectionFailed("Could not write the known hosts file")))
            return
        }

        // 4. Key and secret files.
        var keyFile: URL?
        var secretFile: URL?
        do {
            switch plan.credential {
            case .password(let password):
                secretFile = try track(runtime.writeSecret(password))
            case .privateKey(_, let pem, let passphrase):
                keyFile = try track(runtime.writeKey(pem))
                if let passphrase, !passphrase.isEmpty {
                    secretFile = try track(runtime.writeSecret(passphrase))
                }
            case .none:
                break
            }
        } catch is SessionEndedError {
            return
        } catch {
            finish(.failed(.connectionFailed("Could not write temporary files")))
            return
        }

        // 5. Launch ssh.
        let algorithms = Self.hostKeyAlgorithms(for: candidate.keyType)
        let arguments = Self.sshArguments(host: host, port: plan.port, username: plan.username,
                                          runtime: runtime, keyFile: keyFile, hostKeyAlgorithms: algorithms)
        var environment: [String: String] = [:]
        if let secretFile {
            environment = ["SSH_ASKPASS": runtime.askpassURL.path, "SSH_ASKPASS_REQUIRE": "force",
                           "DISPLAY": ":0", "TR_SECRET_FILE": secretFile.path]
        }
        let interactive = secretFile == nil
        let (cols, rows) = state.withLock { ($0.cols, $0.rows) }
        let ssh: PTYProcess
        do {
            ssh = try PTYProcess(executable: sshPath, arguments: arguments, environment: environment,
                                 cols: cols, rows: rows, rawMode: false)
        } catch {
            finish(.failed(.connectionFailed("Could not run ssh")))
            return
        }
        let controlKey = [runtime.controlDirectory.path, host, String(plan.port), plan.username].joined(separator: "\n")
        let launched = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.ssh = ssh
            state.hostKeyAlgorithms = algorithms
            state.controlKey = controlKey
            Self.controlMasters.retain(controlKey)
            for bytes in state.backlog { inputQueue.async { ssh.write(bytes) } }
            state.backlog = []
            if interactive {
                // ssh will ask in the terminal: its prompts must be visible.
                state.connectedEmitted = true
                eventContinuation.yield(.connected)
            }
            return true
        }
        guard launched else {
            ssh.kill()
            return
        }
        if interactive { startGate.resolve(()) }

        Task { await self.watchForSessionStart(ssh) }
        for await chunk in ssh.output { received(chunk) }
        sshExited(status: ssh.exitStatus)
    }

    /// Runs ssh-keyscan and returns the preferred key, or ends the session.
    private func scanHostKey() async -> HostKeyCandidate? {
        let scan: PTYProcess
        do {
            scan = try PTYProcess(executable: keyscanPath,
                                  arguments: ["-T", "10", "-p", String(plan.port), "-t", "ed25519,ecdsa,rsa", host],
                                  environment: [:], cols: 200, rows: 24, rawMode: true)
        } catch {
            finish(.failed(.connectionFailed("Could not run ssh-keyscan")))
            return nil
        }
        let registered = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.keyscan = scan
            return true
        }
        guard registered else {
            scan.kill()
            return nil
        }
        let result = await Self.collect(scan, limit: Self.commandOutputLimit, timeout: Self.keyscanTimeout)
        state.withLock { $0.keyscan = nil }
        guard !isEnded else { return nil }
        var candidate: HostKeyCandidate?
        if case .finished(let output, _) = result {
            candidate = Self.preferredCandidate(Self.parseKeyscan(String(decoding: output, as: UTF8.self),
                                                                  host: host, port: plan.port))
        }
        guard let candidate else {
            finish(.failed(.connectionFailed("Could not reach \(host):\(plan.port)")))
            return nil
        }
        return candidate
    }

    /// Records a key or secret file for deletion; deletes it at once if the session already ended.
    private func track(_ url: URL) throws -> URL {
        let kept = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.tempFiles.append(url)
            return true
        }
        guard kept else {
            runtime.remove(url)
            throw SessionEndedError()
        }
        return url
    }

    /// Polls the terminal mode until ssh starts the session (canonical mode off) or exits.
    private func watchForSessionStart(_ ssh: PTYProcess) async {
        while true {
            let (ended, started) = state.withLock { ($0.ended, $0.sessionStarted) }
            if ended || started { return }
            switch ssh.isCanonicalMode {
            case .none:
                return // ssh exited
            case .some(false):
                sessionStarted()
                return
            case .some(true):
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func sessionStarted() {
        let files = state.withLock { state -> [URL] in
            guard !state.ended, !state.sessionStarted else { return [] }
            state.sessionStarted = true
            state.preSessionOutput = []
            if !state.connectedEmitted {
                state.connectedEmitted = true
                eventContinuation.yield(.connected)
                if !state.heldOutput.isEmpty { eventContinuation.yield(.output(state.heldOutput)) }
                state.heldOutput = []
            }
            eventContinuation.yield(.ready)
            defer { state.tempFiles = [] }
            return state.tempFiles
        }
        files.forEach(runtime.remove)
        startGate.resolve(())
    }

    private func received(_ chunk: [UInt8]) {
        state.withLock { state in
            guard !state.ended else { return }
            if !state.sessionStarted {
                state.preSessionOutput = Self.appendingTail(state.preSessionOutput, chunk)
            }
            if state.connectedEmitted {
                eventContinuation.yield(.output(chunk))
            } else {
                state.heldOutput = Self.appendingTail(state.heldOutput, chunk)
            }
        }
    }

    private func sshExited(status: Int32?) {
        let taken = state.withLock { state in
            if !state.ended {
                let reason: SessionEndReason
                if !state.sessionStarted && status == 255 {
                    reason = .failed(Self.classifyFailure(state.preSessionOutput, secrets: secrets))
                } else {
                    // Ended normally; if the session was too short to notice its start, show it anyway.
                    if !state.connectedEmitted {
                        state.connectedEmitted = true
                        eventContinuation.yield(.connected)
                        if !state.heldOutput.isEmpty { eventContinuation.yield(.output(state.heldOutput)) }
                    }
                    reason = .remoteClosed
                }
                state.ended = true
                eventContinuation.yield(.closed(reason))
                eventContinuation.finish()
            }
            defer {
                state.ssh = nil
                state.tempFiles = []
                state.controlKey = nil
                state.heldOutput = []
            }
            return (files: state.tempFiles, controlKey: state.controlKey)
        }
        taken.files.forEach(runtime.remove)
        if let key = taken.controlKey {
            // The master keeps running for ControlPersist; a later session or `-O exit` deals with it.
            _ = Self.controlMasters.release(key)
        }
        startGate.resolve(())
    }

    /// Emits the single `.closed` event (unless the session already ended) and cleans up.
    private func finish(_ reason: SessionEndReason) {
        let taken = state.withLock { state in
            if !state.ended {
                state.ended = true
                eventContinuation.yield(.closed(reason))
                eventContinuation.finish()
            }
            defer {
                state.keyscan = nil
                state.tempFiles = []
            }
            return (keyscan: state.keyscan, files: state.tempFiles)
        }
        taken.keyscan?.kill()
        taken.files.forEach(runtime.remove)
        startGate.resolve(())
    }

    private var isEnded: Bool { state.withLock { $0.ended } }

    private var secrets: [String] {
        switch plan.credential {
        case .password(let password): [password].filter { !$0.isEmpty }
        case .privateKey(_, _, let passphrase): [passphrase ?? ""].filter { !$0.isEmpty }
        case .none: []
        }
    }

    /// `ssh -O exit` for this host's control socket, bounded.
    private func stopControlMaster() async {
        let arguments = ["-p", String(plan.port), "-l", plan.username,
                         "-o", "ControlPath=\(Self.controlPath(runtime))",
                         "-O", "exit", "--", host]
        guard let process = try? PTYProcess(executable: sshPath, arguments: arguments, environment: [:],
                                            cols: 80, rows: 24, rawMode: true) else { return }
        _ = await Self.collect(process, limit: 65_536, timeout: Self.controlExitTimeout)
    }

    // MARK: Command line

    /// The interactive session's arguments (after the executable), exactly as the global constraints
    /// specify, plus `HostKeyAlgorithms` limited to the trusted key's type.
    static func sshArguments(host: String, port: Int, username: String, runtime: SSHRuntimeDirectory,
                             keyFile: URL?, hostKeyAlgorithms: String) -> [String] {
        var arguments = ["-tt"] + optionArguments(port: port, username: username, runtime: runtime)
        if let keyFile {
            arguments += ["-o", "IdentitiesOnly=yes", "-i", keyFile.path]
        }
        arguments += ["-o", "HostKeyAlgorithms=\(hostKeyAlgorithms)", "--", host]
        return arguments
    }

    /// Port, user and the `-o` options shared by the session and its commands. Paths are double-quoted
    /// because ssh splits `-o` values at spaces ("Application Support").
    static func optionArguments(port: Int, username: String, runtime: SSHRuntimeDirectory) -> [String] {
        [
            "-p", String(port), "-l", username,
            "-o", "UserKnownHostsFile=\(quoted(runtime.knownHostsURL.path))",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath(runtime))",
            "-o", "ControlPersist=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=15",
        ]
    }

    /// `"<controlDirectory>/%C"`: short enough for the Unix socket path limit.
    static func controlPath(_ runtime: SSHRuntimeDirectory) -> String {
        quoted(runtime.controlDirectory.appendingPathComponent("%C").path)
    }

    /// `ssh-rsa` host keys are verified with SHA-2 signatures only.
    static func hostKeyAlgorithms(for keyType: String) -> String {
        keyType == "ssh-rsa" ? "rsa-sha2-512,rsa-sha2-256" : keyType
    }

    private static func quoted(_ path: String) -> String {
        "\"\(path)\""
    }

    // MARK: Parsing

    /// Parses ssh-keyscan output (`host keytype base64` lines; `#` comment lines and anything else are
    /// ignored). Keeps the first key of each supported type whose blob decodes and names that type.
    static func parseKeyscan(_ output: String, host: String, port: Int) -> [HostKeyCandidate] {
        var candidates: [HostKeyCandidate] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: " ")
            guard fields.count >= 3 else { continue }
            let keyType = String(fields[1])
            guard keyTypePreference.contains(keyType),
                  !candidates.contains(where: { $0.keyType == keyType }),
                  let blob = Data(base64Encoded: String(fields[2])),
                  blobKeyType(blob) == keyType else { continue }
            candidates.append(HostKeyCandidate(host: host, port: port, keyType: keyType, publicKeyBlob: blob))
        }
        return candidates
    }

    static func preferredCandidate(_ candidates: [HostKeyCandidate]) -> HostKeyCandidate? {
        for keyType in keyTypePreference {
            if let candidate = candidates.first(where: { $0.keyType == keyType }) { return candidate }
        }
        return nil
    }

    /// The key type string at the start of a public key wire blob.
    private static func blobKeyType(_ blob: Data) -> String? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return nil }
        let length = bytes[0..<4].reduce(0) { $0 << 8 | Int($1) }
        guard length <= bytes.count - 4 else { return nil }
        return String(bytes: bytes[4..<(4 + length)], encoding: .utf8)
    }

    /// Maps ssh's messages before the session started (exit status 255) to an error. The message is the
    /// last non-empty line without terminal control sequences; secrets are redacted as a last line of
    /// defence (ssh never prints them).
    static func classifyFailure(_ output: [UInt8], secrets: [String]) -> SessionError {
        let lines = stripTerminalSequences(String(decoding: output, as: UTF8.self))
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.contains(where: { $0.contains("Host key verification failed") }) { return .hostKeyRejected }
        let last = lines.last ?? ""
        if last.contains("Permission denied") || last.contains("Too many authentication failures") {
            if lines.contains(where: { $0.hasPrefix("Load key ") && $0.contains("invalid format") }) {
                return .keyUnreadable
            }
            return .authenticationFailed
        }
        guard !last.isEmpty else { return .connectionFailed("ssh exited before the session started") }
        var message = last
        for secret in secrets where !secret.isEmpty {
            message = message.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return .connectionFailed(message)
    }

    /// Removes escape sequences (CSI, OSC and two-byte ones) and control characters other than line breaks.
    static func stripTerminalSequences(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if scalar == "\u{1B}" {
                guard let kind = scalars.next() else { break }
                if kind == "[" {
                    while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
                } else if kind == "]" {
                    var previous: Unicode.Scalar?
                    while let next = scalars.next() {
                        if next == "\u{07}" || (previous == "\u{1B}" && next == "\\") { break }
                        previous = next
                    }
                }
                continue
            }
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || !(scalar.value < 0x20 || scalar.value == 0x7F) {
                result.append(scalar)
            }
        }
        return String(result)
    }

    // MARK: Helpers

    private static func appendingTail(_ buffer: [UInt8], _ chunk: [UInt8]) -> [UInt8] {
        var buffer = buffer + chunk
        if buffer.count > heldOutputLimit { buffer.removeFirst(buffer.count - heldOutputLimit) }
        return buffer
    }

    /// Lowercased, one trailing dot removed: the form used for `known_hosts` (`HostKeyFormat.hostPort`),
    /// so ssh looks up exactly the line written for it.
    static func normalizedHost(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// No whitespace or control characters, and nothing ssh or ssh-keyscan could read as an option.
    static func isSafeHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-")
            && host.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value != 0x7F }
    }

    static func isSafeUsername(_ username: String) -> Bool {
        !username.isEmpty && !username.hasPrefix("-")
            && username.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    enum CollectResult: Sendable {
        case finished([UInt8], Int32?)
        case tooLarge
        case timedOut
    }

    /// Collects a process's output until it exits; kills it when the output passes `limit` or the time
    /// runs out.
    static func collect(_ process: PTYProcess, limit: Int, timeout: Duration) async -> CollectResult {
        let result = OneShot<CollectResult>()
        Task {
            var output: [UInt8] = []
            for await chunk in process.output {
                output.append(contentsOf: chunk)
                if output.count > limit {
                    if result.resolve(.tooLarge) { process.kill() }
                    return
                }
            }
            result.resolve(.finished(output, process.exitStatus))
        }
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            if result.resolve(.timedOut) { process.kill() }
        }
        let value = await result.wait()
        timer.cancel()
        return value
    }

    static let controlMasters = ControlMasterRegistry()
}

private struct SessionEndedError: Error {}

/// Counts this app's running ssh sessions per control socket, so closing one session doesn't end the
/// shared control master while another session still uses it.
final class ControlMasterRegistry: Sendable {
    private let counts = Mutex([String: Int]())

    func retain(_ key: String) {
        counts.withLock { $0[key, default: 0] += 1 }
    }

    /// Returns true when this was the last session using `key`.
    func release(_ key: String) -> Bool {
        counts.withLock { counts in
            let remaining = (counts[key] ?? 1) - 1
            counts[key] = remaining > 0 ? remaining : nil
            return remaining <= 0
        }
    }
}
