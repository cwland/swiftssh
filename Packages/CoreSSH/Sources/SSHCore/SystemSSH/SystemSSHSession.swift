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
/// - **SSH agent** (`.agent`, 1Password): `IdentityAgent` names the agent's socket (`%` written as `%%`;
///   a path ssh can't take fails before ssh runs) and authentication is public key only. Every ssh run
///   here passes `-F /dev/null`, so neither `~/.ssh/config` nor `/etc/ssh/ssh_config` is read and no
///   `IdentityFile` (or any other option) from them applies. A pinned key's public key goes to a 0600
///   `<uuid>.pub` passed as `IdentityFile` with `IdentitiesOnly=yes`, removed with the other per-session
///   files: only that agent key is tried. Unpinned, any agent key is offered, and `IdentityFile=none`
///   stops ssh's built-in default key files (`~/.ssh/id_rsa`, `id_ecdsa`, `id_ed25519`, …), which ssh
///   would otherwise still try despite `-F /dev/null`. No askpass is set; the session behaves like one
///   with a stored secret.
/// - **Session start** is detected when ssh switches the terminal out of canonical mode, which it does
///   only after authentication, right before the remote session's output; it emits `.ready`. With a
///   stored secret, ssh's own messages before that point are held back and, if ssh fails (exit status
///   255), turned into the error; `.connected` and `.ready` come together. Without a stored secret, ssh
///   asks in the terminal, so `.connected` is emitted as soon as ssh runs (its prompts are shown as
///   output) and `.ready` once the user has signed in.
/// - **Progress**: with a stored secret or an agent, ssh runs with `-v -E <file>` so its debug output goes
///   to a 0600 file in the private runtime directory instead of the terminal; the file is unlinked as soon
///   as ssh has written to it and closed when the session ends. Only whitelisted debug lines are read
///   (`SSHDebugLogParser`) and become `.progress` steps before `.connected`; ssh's own messages (which
///   without `-E` would be on stderr) are kept only to explain a failure. Host names are reported as
///   `.resolving` before `ssh-keyscan` looks them up. Without a stored secret (ssh asks in the terminal)
///   and when ssh doesn't take `-E`, ssh runs as before and reports no steps.
/// - **Commands** (`runCommand`) reuse the session's connection through ssh's control socket
///   (`ControlMaster=auto`, socket in `SSHRuntimeDirectory.controlDirectory`), in batch mode, without
///   askpass.
public final class SystemSSHSession: TerminalSession {
    public let events: AsyncStream<SessionEvent>

    static let commandOutputLimit = 1_048_576
    /// Output kept from before the session started (for the error message and to show once connected).
    static let heldOutputLimit = 262_144
    /// Output kept from the end of a running session, for ssh's message when it exits.
    static let recentOutputLimit = 4_096
    /// The message for a connection that ended without a goodbye and without a message from ssh.
    static let connectionLostMessage = "The connection to the server was lost."
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
    private let terminalModeProbe: TerminalModeProbe
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
        /// The last output of the running session, for ssh's message when it exits.
        var recentOutput: [UInt8] = []
        /// Input sent before ssh was launched.
        var backlog: [[UInt8]] = []
        var cols = 80
        var rows = 24
        var hostKeyAlgorithms: String?
        /// This session's own known_hosts file (deleted with the other temp files).
        var knownHostsFile: URL?
        /// The expanded control socket path (`ssh -G`), found on the first `runCommand`.
        var controlSocket: String?
        /// This session's entry in the control master registry, while ssh runs.
        var controlKey: String?
        /// Output chunks received so far (for the session-start fallback).
        var outputChunks = 0
        /// ssh's debug log (`-E`) while ssh runs; nil without one.
        var debugLog: SSHDebugLogReader?
        var debugParser = SSHDebugLogParser(agent: false)
        /// A run of `ssh -E /dev/null -V` checking that ssh takes `-E`; killed by `close()`.
        var probe: PTYProcess?
        /// The debug log showed ssh entering the interactive session (for the session-start fallback).
        var sawOpeningShell = false
    }

    public convenience init(plan: ConnectionPlan, hostKeys: any HostKeyEvaluator,
                            knownHostsLines: @escaping @Sendable () async -> [String],
                            runtime: SSHRuntimeDirectory, sshPath: String = "/usr/bin/ssh",
                            keyscanPath: String = "/usr/bin/ssh-keyscan") {
        self.init(plan: plan, hostKeys: hostKeys, knownHostsLines: knownHostsLines, runtime: runtime,
                  sshPath: sshPath, keyscanPath: keyscanPath, commandTimeout: .seconds(15))
    }

    /// Reads a terminal's mode; tests inject one to exercise the session-start fallback.
    typealias TerminalModeProbe = @Sendable (PTYProcess) -> PTYProcess.TerminalMode

    /// `commandTimeout` bounds `runCommand`; only tests change it and `terminalModeProbe`.
    init(plan: ConnectionPlan, hostKeys: any HostKeyEvaluator, knownHostsLines: @escaping @Sendable () async -> [String],
         runtime: SSHRuntimeDirectory, sshPath: String, keyscanPath: String, commandTimeout: Duration,
         terminalModeProbe: @escaping TerminalModeProbe = { $0.terminalMode }) {
        self.terminalModeProbe = terminalModeProbe
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
        let (algorithms, knownHosts, ended) = state.withLock { state in
            (state.sessionStarted && state.ssh != nil ? state.hostKeyAlgorithms : nil, state.knownHostsFile, state.ended)
        }
        guard !ended else { throw SessionError.connectionFailed("Session closed") }
        guard let algorithms, let knownHosts else { throw SessionError.connectionFailed("The session is not connected.") }
        // Only ever through the session's control master (ControlMaster=no): never a fresh connection.
        guard let socket = await controlSocketPath(knownHosts: knownHosts),
              FileManager.default.fileExists(atPath: socket) else {
            throw SessionError.connectionFailed("Session closed")
        }

        let arguments = Self.commandArguments(host: host, port: plan.port, username: plan.username, runtime: runtime,
                                              knownHosts: knownHosts, controlSocket: socket,
                                              hostKeyAlgorithms: algorithms, command: command,
                                              keepAlive: plan.keepAlive)
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
                state.probe = nil
                state.ssh = nil
                state.commands = [:]
                state.tempFiles = []
                state.controlKey = nil
                state.debugLog = nil
            }
            return (keyscan: state.keyscan, probe: state.probe, ssh: state.ssh, commands: Array(state.commands.values),
                    files: state.tempFiles, controlKey: state.controlKey, debugLog: state.debugLog)
        }
        startGate.resolve(())
        taken.debugLog?.close()
        taken.probe?.kill()
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
        guard Self.isSafeHost(host) else {
            finish(.failed(.connectionFailed("Invalid host name")))
            return
        }
        guard Self.isSafeUsername(plan.username), (1...65_535).contains(plan.port) else {
            finish(.failed(.connectionFailed("Invalid port or user name")))
            return
        }
        if case .agent(let socket, _) = plan.credential, let problem = Self.agentSocketProblem(socket) {
            finish(.failed(.agentUnavailable(problem)))
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

        // 1. Fetch the server's host keys (ssh-keyscan looks up the name).
        if !Self.isIPAddress(host) { emitProgress(.resolving(host: host)) }
        guard let candidate = await scanHostKey() else { return }

        // 2. One trust decision, before ssh runs.
        guard await hostKeys.evaluate(candidate) == .trusted else {
            finish(.failed(.hostKeyRejected))
            return
        }
        guard !isEnded else { return }

        // 3. This session's own known_hosts: the vault's lines for other hosts, plus exactly the key just
        //    trusted for this one.
        let lines = Self.knownHostsFile(vault: await knownHostsLines(), trusted: candidate)

        // 4. known_hosts, key and secret files.
        let knownHostsFile: URL
        var keyFile: URL?
        var secretFile: URL?
        var agentKeyFile: URL?
        do {
            knownHostsFile = try track(runtime.writeKnownHosts(lines))
            switch plan.credential {
            case .agent(_, let publicKey?):
                guard let line = Self.pinnedKeyFileLine(publicKey) else {
                    finish(.failed(.connectionFailed("The pinned 1Password key is not a valid public key.")))
                    return
                }
                agentKeyFile = try track(runtime.writePublicKey(line))
            case .agent(_, nil):
                break
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

        // An agent signs without the user typing anything (1Password asks in its own window), so its
        // sessions behave like ones with a stored secret: ssh's messages before the session become the error.
        // A key that is plainly not encrypted can't make ssh ask anything either (public key only).
        let interactive = secretFile == nil && !usesAgent && !Self.storedKeyNeedsNoPassphrase(plan.credential)

        // ssh's debug log, for the progress steps: only when ssh doesn't ask in the terminal (steps end at
        // `.connected`, which then comes at once) and when this ssh takes `-E`.
        var debugLog: SSHDebugLogReader?
        if !interactive, await debugLogSupported() {
            guard !isEnded else { return }
            do {
                let url = try runtime.writeDebugLog()
                do {
                    debugLog = try SSHDebugLogReader(url: url)
                } catch {
                    runtime.remove(url)
                    throw error
                }
            } catch {
                debugLog = nil // no progress, but the session still works
            }
        }

        // 5. Launch ssh.
        let algorithms = Self.hostKeyAlgorithms(for: candidate.keyType)
        let auth: AuthArguments
        switch plan.credential {
        case .password: auth = .password
        case .privateKey: auth = keyFile.map(AuthArguments.key) ?? .none
        case .agent(let socket, _): auth = .agent(socket: socket, publicKeyFile: agentKeyFile)
        case .none: auth = .none
        }
        let arguments = Self.sshArguments(host: host, port: plan.port, username: plan.username, runtime: runtime,
                                          knownHosts: knownHostsFile, auth: auth, hostKeyAlgorithms: algorithms,
                                          keepAlive: plan.keepAlive, debugLog: debugLog?.url)
        var environment: [String: String] = [:]
        if let secretFile {
            environment = ["SSH_ASKPASS": runtime.askpassURL.path, "SSH_ASKPASS_REQUIRE": "force",
                           "DISPLAY": ":0", "TR_SECRET_FILE": secretFile.path]
        }
        let (cols, rows) = state.withLock { ($0.cols, $0.rows) }
        let ssh: PTYProcess
        do {
            // ssh sends its own TERM in the PTY request.
            ssh = try PTYProcess(executable: sshPath, arguments: arguments, environment: environment,
                                 terminalType: plan.terminalType, cols: cols, rows: rows, rawMode: false)
        } catch {
            debugLog?.close()
            finish(.failed(.connectionFailed("Could not run ssh")))
            return
        }
        let controlKey = [runtime.controlDirectory.path, host, String(plan.port), plan.username].joined(separator: "\n")
        let launched = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.ssh = ssh
            state.debugLog = debugLog
            state.debugParser = SSHDebugLogParser(agent: usesAgent)
            state.hostKeyAlgorithms = algorithms
            state.knownHostsFile = knownHostsFile
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
            debugLog?.close()
            return
        }
        if interactive { startGate.resolve(()) }

        if let debugLog { Task { await self.followDebugLog(debugLog) } }
        Task { await self.watchForSessionStart(ssh, secretFile: secretFile, interactive: interactive) }
        for await chunk in ssh.output { received(chunk) }
        await sshExited(status: ssh.exitStatus)
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
            var reason = ""
            if case .finished(let output, _) = result, Self.keyscanFoundNoHost(String(decoding: output, as: UTF8.self)) {
                reason = " (host name not found)"
            }
            finish(.failed(.connectionFailed("Could not reach \(host):\(plan.port)\(reason)")))
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
    ///
    /// If the mode can't be read, falls back to: with askpass, the helper has consumed the secret file
    /// and output arrived after that; when ssh can't ask anything (agent, unencrypted key), ssh's debug log
    /// shows it entering the session, or 2 s have passed and output arrived; otherwise (ssh asks in the
    /// terminal), the first output once 2 s have passed.
    private func watchForSessionStart(_ ssh: PTYProcess, secretFile: URL?, interactive: Bool) async {
        let clock = ContinuousClock()
        let launched = clock.now
        var outputMark: Int?
        while true {
            let (ended, started, chunks, enteredSession) = state.withLock { state in
                Self.drainDebugLog(&state, continuation: eventContinuation)
                return (state.ended, state.sessionStarted, state.outputChunks, state.sawOpeningShell)
            }
            if ended || started { return }
            switch terminalModeProbe(ssh) {
            case .exited:
                return
            case .raw:
                sessionStarted()
                return
            case .canonical:
                break
            case .unavailable:
                if secretFile == nil && !interactive {
                    if enteredSession || (clock.now - launched >= .seconds(2) && chunks > 0) {
                        sessionStarted()
                        return
                    }
                } else if outputMark == nil {
                    if let secretFile {
                        if !FileManager.default.fileExists(atPath: secretFile.path) { outputMark = chunks }
                    } else if clock.now - launched >= .seconds(2) {
                        outputMark = chunks
                    }
                } else if let mark = outputMark, chunks > mark {
                    sessionStarted()
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func sessionStarted() {
        let files = state.withLock { state -> [URL] in
            guard !state.ended, !state.sessionStarted else { return [] }
            // Steps ssh logged up to now still come before `.connected`.
            Self.drainDebugLog(&state, continuation: eventContinuation)
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
            state.outputChunks += 1
            if state.sessionStarted {
                state.recentOutput = Self.appendingTail(state.recentOutput, chunk, limit: Self.recentOutputLimit)
            } else {
                state.preSessionOutput = Self.appendingTail(state.preSessionOutput, chunk)
            }
            if state.connectedEmitted {
                eventContinuation.yield(.output(chunk))
            } else {
                state.heldOutput = Self.appendingTail(state.heldOutput, chunk)
            }
        }
    }

    private func sshExited(status: Int32?) async {
        let (started, output) = state.withLock { state in
            // ssh's last messages (why it failed) are in its log.
            Self.drainDebugLog(&state, continuation: eventContinuation, includePartial: true)
            state.debugLog?.close()
            state.debugLog = nil
            return (state.sessionStarted, state.sessionStarted ? state.recentOutput : state.preSessionOutput)
        }
        let reason = await Self.classifyExit(status: status, sessionStarted: started, output: output, secrets: secrets,
                                             agent: usesAgent,
                                             controlMasterAlive: { await self.controlMasterIsRunning() })
        let taken = state.withLock { state in
            if !state.ended {
                if reason == .remoteClosed {
                    // Ended normally; if the session was too short to notice its start, show it anyway.
                    if !state.connectedEmitted {
                        state.connectedEmitted = true
                        eventContinuation.yield(.connected)
                        if !state.heldOutput.isEmpty { eventContinuation.yield(.output(state.heldOutput)) }
                    }
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
                state.probe = nil
                state.tempFiles = []
                state.debugLog = nil
            }
            return (keyscan: state.keyscan, probe: state.probe, files: state.tempFiles, debugLog: state.debugLog)
        }
        taken.debugLog?.close()
        taken.probe?.kill()
        taken.keyscan?.kill()
        taken.files.forEach(runtime.remove)
        startGate.resolve(())
    }

    private var isEnded: Bool { state.withLock { $0.ended } }

    private var usesAgent: Bool {
        if case .agent = plan.credential { return true }
        return false
    }

    private var secrets: [String] {
        switch plan.credential {
        case .password(let password): [password].filter { !$0.isEmpty }
        case .privateKey(_, _, let passphrase): [passphrase ?? ""].filter { !$0.isEmpty }
        case .agent, .none: []
        }
    }

    /// `ssh -O exit` for this host's control socket, bounded.
    private func stopControlMaster() async {
        _ = await controlCommand("exit")
    }

    /// `ssh -O check` for this host's control socket, bounded: whether its control master still runs.
    private func controlMasterIsRunning() async -> Bool {
        if case .finished(_, 0) = await controlCommand("check") { return true }
        return false
    }

    private func controlCommand(_ operation: String) async -> CollectResult? {
        let arguments = ["-F", "/dev/null", "-p", String(plan.port), "-l", plan.username,
                         "-o", "ControlPath=\(Self.controlPath(runtime))",
                         "-O", operation, "--", host]
        guard let process = try? PTYProcess(executable: sshPath, arguments: arguments, environment: [:],
                                            cols: 80, rows: 24, rawMode: true) else { return nil }
        return await Self.collect(process, limit: 65_536, timeout: Self.controlExitTimeout)
    }

    // MARK: Progress

    /// Emits a step unless the session is live (`.connected`) or ended: steps only ever precede `.connected`.
    private func emitProgress(_ step: ConnectionStep) {
        state.withLock { state in
            if !state.ended && !state.connectedEmitted { eventContinuation.yield(.progress(step)) }
        }
    }

    /// Reads ssh's debug log as it grows until `.connected` (steps only come before it); after that the
    /// log is read once more only when ssh exits.
    private func followDebugLog(_ log: SSHDebugLogReader) async {
        while true {
            let keepGoing = state.withLock { state -> Bool in
                guard !state.ended, !state.connectedEmitted, state.debugLog === log else { return false }
                Self.drainDebugLog(&state, continuation: eventContinuation)
                return true
            }
            guard keepGoing else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Turns the log's new lines into steps (before `.connected` only) and, before the session started,
    /// keeps ssh's own messages for the failure text. Runs under the state lock, so lines are handled once
    /// and in order.
    private static func drainDebugLog(_ state: inout State, continuation: AsyncStream<SessionEvent>.Continuation,
                                      includePartial: Bool = false) {
        guard let log = state.debugLog else { return }
        for line in log.readLines(includePartial: includePartial) {
            switch state.debugParser.consume(line) {
            case .step(let step):
                if step == .openingShell { state.sawOpeningShell = true }
                if !state.ended && !state.connectedEmitted { continuation.yield(.progress(step)) }
            case .message(let text):
                if !state.sessionStarted {
                    state.preSessionOutput = appendingTail(state.preSessionOutput, Array((text + "\r\n").utf8))
                }
            case .ignored:
                break
            }
        }
    }

    /// Whether this ssh takes `-E` (checked once per ssh path with `ssh -E /dev/null -V`, at most 3 s).
    private func debugLogSupported() async -> Bool {
        if let known = Self.debugLogSupport.withLock({ $0[sshPath] }) { return known }
        guard let probe = try? PTYProcess(executable: sshPath, arguments: ["-E", "/dev/null", "-V"], environment: [:],
                                          cols: 200, rows: 24, rawMode: true) else { return false }
        let registered = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.probe = probe
            return true
        }
        guard registered else {
            probe.kill()
            return false
        }
        let result = await Self.collect(probe, limit: 65_536, timeout: .seconds(3))
        state.withLock { $0.probe = nil }
        guard !isEnded else { return false }
        var supported = false
        if case .finished(let output, 0) = result {
            supported = String(decoding: output, as: UTF8.self).contains("OpenSSH")
        }
        let path = sshPath
        Self.debugLogSupport.withLock { $0[path] = supported }
        return supported
    }

    /// Per ssh path: whether it takes `-E`.
    static let debugLogSupport = Mutex([String: Bool]())

    /// An IPv4 or IPv6 address (nothing to look up).
    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1
    }

    /// A private key credential whose key is certainly unencrypted (OpenSSH format with cipher "none", or
    /// an unencrypted PEM): ssh signs with it without asking. Anything unclear counts as encrypted.
    static func storedKeyNeedsNoPassphrase(_ credential: SSHCredential) -> Bool {
        guard case .privateKey(_, let pem, let passphrase) = credential, passphrase?.isEmpty ?? true else { return false }
        return keyIsUnencrypted(pem)
    }

    static func keyIsUnencrypted(_ pem: String) -> Bool {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.first(where: { $0.hasPrefix("-----BEGIN ") }) else { return false }
        switch begin {
        case "-----BEGIN OPENSSH PRIVATE KEY-----":
            let body = lines.drop { $0 != begin }.dropFirst().prefix { !$0.hasPrefix("-----END ") }.joined()
            guard let data = Data(base64Encoded: body) else { return false }
            let bytes = [UInt8](data)
            let magic = Array("openssh-key-v1\0".utf8)
            guard bytes.count >= magic.count + 4, Array(bytes[0..<magic.count]) == magic else { return false }
            let lengthStart = magic.count
            let length = bytes[lengthStart..<(lengthStart + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard length == 4, bytes.count >= lengthStart + 4 + length else { return false }
            return Array(bytes[(lengthStart + 4)..<(lengthStart + 4 + length)]) == Array("none".utf8)
        case "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN EC PRIVATE KEY-----":
            return !lines.contains { $0.hasPrefix("Proc-Type:") && $0.contains("ENCRYPTED") }
        case "-----BEGIN PRIVATE KEY-----":
            return true
        default:
            return false
        }
    }

    /// ssh-keyscan's message that the name could not be looked up (Linux and macOS wording).
    static func keyscanFoundNoHost(_ output: String) -> Bool {
        output.contains("getaddrinfo") && (output.contains("not known") || output.contains("No address associated"))
    }

    // MARK: Command line

    /// How ssh may authenticate, by credential.
    enum AuthArguments: Equatable {
        /// Public key only, with this key file.
        case key(URL)
        /// Password or keyboard-interactive only (the user's default keys are never tried).
        case password
        /// Public key only, signed by the agent at `socket`: with `publicKeyFile`, only that key
        /// (`IdentitiesOnly`); without, any agent key. The user's ssh config is never read (`-F /dev/null`),
        /// and `IdentityFile=none` stops ssh's built-in defaults (`~/.ssh/id_*`), which `-F /dev/null`
        /// alone does not.
        case agent(socket: String, publicKeyFile: URL?)
        /// No restriction (ssh asks in the terminal).
        case none
    }

    /// The interactive session's arguments (after the executable): the global constraints' flags, plus
    /// `-F /dev/null`, `ConnectTimeout`, the per-credential authentication restrictions and
    /// `HostKeyAlgorithms` limited to the trusted key's type.
    static func sshArguments(host: String, port: Int, username: String, runtime: SSHRuntimeDirectory,
                             knownHosts: URL, auth: AuthArguments, hostKeyAlgorithms: String,
                             keepAlive: KeepAlivePolicy = .standard, debugLog: URL? = nil) -> [String] {
        // `-v -E`: debug output to the log file, never the terminal.
        var arguments = ["-tt"] + (debugLog.map { ["-v", "-E", $0.path] } ?? []) + optionArguments(port: port, username: username, knownHosts: knownHosts,
                                                  controlMaster: "auto", controlPath: controlPath(runtime),
                                                  keepAlive: keepAlive)
        switch auth {
        case .key(let keyFile):
            arguments += ["-o", "IdentitiesOnly=yes", "-i", keyFile.path] + publicKeyOnlyArguments
        case .password:
            arguments += ["-o", "PubkeyAuthentication=no",
                          "-o", "PreferredAuthentications=keyboard-interactive,password"]
        case .agent(let socket, let publicKeyFile):
            arguments += ["-o", "IdentityAgent=\(quoted(socket.replacingOccurrences(of: "%", with: "%%")))"]
            if let publicKeyFile {
                arguments += ["-o", "IdentityFile=\(quoted(publicKeyFile.path))", "-o", "IdentitiesOnly=yes"]
            } else {
                arguments += ["-o", "IdentityFile=none"]
            }
            arguments += publicKeyOnlyArguments
        case .none:
            break
        }
        arguments += ["-o", "HostKeyAlgorithms=\(hostKeyAlgorithms)", "--", host]
        return arguments
    }

    private static let publicKeyOnlyArguments = [
        "-o", "PreferredAuthentications=publickey",
        "-o", "PasswordAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no",
    ]

    /// The `type base64` part of a pinned agent key's public key line, or nil unless it is one line whose
    /// base64 decodes to a key blob of that type. The comment is dropped (it never matters to ssh).
    static func pinnedKeyFileLine(_ publicKeyLine: String) -> String? {
        let trimmed = publicKeyLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline) else { return nil }
        let fields = trimmed.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])),
              blobKeyType(blob) == String(fields[0]) else { return nil }
        return "\(fields[0]) \(fields[1])"
    }

    /// A command through the existing control master only (`ControlMaster=no`, the exact socket).
    static func commandArguments(host: String, port: Int, username: String, runtime: SSHRuntimeDirectory,
                                 knownHosts: URL, controlSocket: String, hostKeyAlgorithms: String,
                                 command: String, keepAlive: KeepAlivePolicy = .standard) -> [String] {
        optionArguments(port: port, username: username, knownHosts: knownHosts,
                        controlMaster: "no", controlPath: quoted(controlSocket), keepAlive: keepAlive)
            + ["-o", "HostKeyAlgorithms=\(hostKeyAlgorithms)", "-T", "-o", "BatchMode=yes", "--", host, command]
    }

    /// `-F /dev/null` (the user's ssh configuration never applies), port, user and the shared `-o` options.
    /// Paths are double-quoted because ssh splits `-o` values at spaces ("Application Support").
    static func optionArguments(port: Int, username: String, knownHosts: URL, controlMaster: String,
                                controlPath: String, keepAlive: KeepAlivePolicy) -> [String] {
        [
            "-F", "/dev/null",
            "-p", String(port), "-l", username,
            "-o", "UserKnownHostsFile=\(quoted(knownHosts.path))",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ControlMaster=\(controlMaster)",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=15",
        ] + aliveArguments(keepAlive) + [
            "-o", "ConnectTimeout=15",
        ]
    }

    /// `ServerAliveInterval`/`ServerAliveCountMax` for the policy; off is `ServerAliveInterval=0`.
    private static func aliveArguments(_ policy: KeepAlivePolicy) -> [String] {
        guard let interval = policy.interval else { return ["-o", "ServerAliveInterval=0"] }
        let seconds = max(1, Int(interval.components.seconds)) // 0 would mean off
        return ["-o", "ServerAliveInterval=\(seconds)", "-o", "ServerAliveCountMax=\(policy.maxUnanswered)"]
    }

    /// The control socket path with `%C` expanded, as ssh computes it (`ssh -G`). Cached.
    private func controlSocketPath(knownHosts: URL) async -> String? {
        if let cached = state.withLock({ $0.controlSocket }) { return cached }
        let arguments = ["-G"] + Self.optionArguments(port: plan.port, username: plan.username, knownHosts: knownHosts,
                                                      controlMaster: "no", controlPath: Self.controlPath(runtime),
                                                      keepAlive: plan.keepAlive)
            + ["--", host]
        guard let process = try? PTYProcess(executable: sshPath, arguments: arguments, environment: [:],
                                            cols: 200, rows: 24, rawMode: true),
              case .finished(let output, 0) = await Self.collect(process, limit: 1_048_576, timeout: .seconds(5))
        else { return nil }
        let path = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("controlpath ") }
            .map { String($0.dropFirst("controlpath ".count)) }
        guard let path, path.hasPrefix(runtime.controlDirectory.path + "/") else { return nil }
        state.withLock { $0.controlSocket = path }
        return path
    }

    /// Builds a session's known_hosts lines: every vault line whose host field names this host (any
    /// comma-separated entry, case-insensitive) is replaced by exactly the trusted key.
    static func knownHostsFile(vault: [String], trusted: HostKeyCandidate) -> [String] {
        let hostPort = trusted.hostPort.lowercased()
        let others = vault.filter { line in
            guard let field = line.split(separator: " ", maxSplits: 1).first else { return false }
            return !field.split(separator: ",").contains { $0.lowercased() == hostPort }
        }
        return others + ["\(trusted.hostPort) \(trusted.keyType) \(trusted.publicKeyBlob.base64EncodedString())"]
    }

    /// `"<controlDirectory>/%C"`: short enough for the Unix socket path limit.
    static func controlPath(_ runtime: SSHRuntimeDirectory) -> String {
        quoted(runtime.controlDirectory.appendingPathComponent("%C").path)
    }

    /// `ssh-rsa` host keys are verified with SHA-2 signatures only.
    static func hostKeyAlgorithms(for keyType: String) -> String {
        keyType == "ssh-rsa" ? "rsa-sha2-512,rsa-sha2-256" : keyType
    }

    /// Why ssh can't be given `path` as `IdentityAgent="…"`, or nil when it can. The value is double-quoted
    /// (ssh has no escape for `"` or `\` inside it), must be one line without control characters, and ssh
    /// expands `${NAME}` from the environment (an error when unset). `%` is fine: it is written as `%%`.
    package static func agentSocketProblem(_ path: String) -> String? {
        let unusable = path.unicodeScalars.contains { scalar in
            scalar == "\"" || scalar == "\\" || scalar.properties.generalCategory == .control
        } || path.contains("${")
        return unusable ? agentPathProblemMessage : nil
    }

    static let agentPathProblemMessage = "The 1Password agent path contains characters ssh can't use."

    /// Shown when an agent attempt fails because the agent couldn't be reached or wouldn't sign.
    static let agentUnavailableMessage =
        "Couldn't reach 1Password's SSH agent. Make sure 1Password is running and unlocked, and that Termius Reimagined may access it."

    /// ssh's messages (from a line before the session started) that the agent couldn't be used.
    static let agentFailureMarkers = [
        "Error connecting to agent",
        "Could not open a connection to your authentication agent",
        "agent refused operation",
        "communication with agent failed",
    ]

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
    ///
    /// For an `agent` attempt, any of ssh's messages that the agent couldn't be reached or refused to sign
    /// (`agentFailureMarkers`) is `.agentUnavailable`. There is no private key file then, so a "Load key"
    /// message (about the pinned key's `.pub`) is never `.keyUnreadable`. OpenSSH 9.6 prints nothing for
    /// a missing socket: that ends as `.authenticationFailed`.
    static func classifyFailure(_ output: [UInt8], secrets: [String], agent: Bool = false) -> SessionError {
        let lines = stripTerminalSequences(String(decoding: output, as: UTF8.self))
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.contains(where: { $0.contains("Host key verification failed") }) { return .hostKeyRejected }
        if agent, lines.contains(where: { line in agentFailureMarkers.contains { line.contains($0) } }) {
            return .agentUnavailable(agentUnavailableMessage)
        }
        let last = lines.last ?? ""
        if last.contains("Permission denied") || last.contains("Too many authentication failures") {
            if !agent, lines.contains(where: { $0.hasPrefix("Load key ") && $0.contains("invalid format") }) {
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

    /// Why ssh exited, from its exit status and the tail of its terminal output.
    ///
    /// - Before the session started: status 255 is ssh's own failure (`classifyFailure`); anything else
    ///   ended normally.
    /// - After it started, any status but 255 is the remote shell's own: a normal end (`.remoteClosed`).
    ///   With 255 (ssh's error status, but also a shell's `exit 255`), the last line of output decides:
    ///   ssh's message for a dropped connection ("Timeout, server … not responding.", "… Broken pipe",
    ///   "… Connection reset …", "Connection to … closed by remote host.", …) is `.connectionFailed` with that
    ///   message; ssh's clean "Connection to … closed." is `.remoteClosed`. Anything else, including
    ///   "Shared connection to … closed." (with `ControlPersist` this ssh is a client of a background
    ///   control master, whose own messages go nowhere), asks `controlMasterAlive`: a master that still
    ///   runs means the shell exited with 255; a master that is gone means the connection was lost
    ///   (`connectionLostMessage`).
    static func classifyExit(status: Int32?, sessionStarted: Bool, output: [UInt8], secrets: [String], agent: Bool = false,
                             controlMasterAlive: @Sendable () async -> Bool) async -> SessionEndReason {
        guard status == 255 else { return .remoteClosed }
        guard sessionStarted else { return .failed(classifyFailure(output, secrets: secrets, agent: agent)) }
        let last = stripTerminalSequences(String(decoding: output, as: UTF8.self))
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        if dropMessageMarkers.contains(where: { last.contains($0) }) {
            return .failed(.connectionFailed(redact(last, secrets: secrets)))
        }
        if last.hasPrefix("Connection to ") && last.hasSuffix(" closed.") { return .remoteClosed }
        return await controlMasterAlive() ? .remoteClosed : .failed(.connectionFailed(connectionLostMessage))
    }

    /// Parts of ssh's messages for a connection that broke (as opposed to one the server ended cleanly).
    static let dropMessageMarkers = [
        "not responding", "Broken pipe", "Connection reset", "closed by remote host", "Connection timed out",
        "Network is unreachable", "No route to host", "Software caused connection abort", "Connection abort",
        "Host is down", "packet_write_wait", "ssh_dispatch_run_fatal", "Corrupted MAC",
    ]

    private static func redact(_ text: String, secrets: [String]) -> String {
        secrets.filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
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

    private static func appendingTail(_ buffer: [UInt8], _ chunk: [UInt8], limit: Int = heldOutputLimit) -> [UInt8] {
        if chunk.count >= limit { return Array(chunk.suffix(limit)) }
        var buffer = buffer + chunk
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        return buffer
    }

    /// Lowercased, one trailing dot removed: the form used for `known_hosts` (`HostKeyFormat.hostPort`),
    /// so ssh looks up exactly the line written for it.
    static func normalizedHost(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// Host name or IP address characters only (letters, digits, `.`, `-`, `_`, `:` and `%` for IPv6 zones),
    /// not starting with `-`: no wildcard, list, marker, whitespace, control or non-ASCII character can
    /// reach ssh, ssh-keyscan or the known_hosts file (the rules of `KnownHostsStore.isSafeHostPort`).
    static func isSafeHost(_ host: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%".unicodeScalars)
        return !host.isEmpty && !host.hasPrefix("-") && host.unicodeScalars.allSatisfy { allowed.contains($0) }
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
