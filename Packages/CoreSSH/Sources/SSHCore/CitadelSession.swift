import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization

/// Terminal session on the built-in Citadel (SwiftNIO SSH) engine.
///
/// - The host key is checked inside the SSH handshake, before authentication: a rejected key fails the
///   handshake, so no credentials are sent.
/// - Every connection attempt runs on its own one-thread event loop group, which is shut down when the
///   session ends or the attempt is abandoned, so no half-open connection outlives the session.
/// - `connectTimeout` covers TCP connect, handshake and authentication (time spent in the host key
///   evaluator, which may be waiting for the user, is not counted), and separately the opening of the
///   PTY channel.
public final class CitadelSession: TerminalSession {
    public let events: AsyncStream<SessionEvent>

    static let commandOutputLimit = 1_048_576
    static let unresponsiveMessage = "The server stopped responding."
    /// The connection ended underneath the terminal (socket closed or reset) without the shell exiting.
    static let connectionLostMessage = "The connection to the server was lost."

    private let plan: ConnectionPlan
    private let hostKeys: any HostKeyEvaluator
    private let connectTimeout: Duration
    private let commandTimeout: Duration
    private let eventContinuation: AsyncStream<SessionEvent>.Continuation
    private let input: AsyncStream<PTYInput>
    private let inputContinuation: AsyncStream<PTYInput>.Continuation
    private let state = Mutex(State())

    private struct State {
        var started = false
        /// `.closed` was emitted and the event stream finished.
        var ended = false
        /// The live connection; detached (set to nil) as soon as the session ends.
        var connection: Connection?
        /// Wakes up `start` (and abandons the work) while it waits on a connection attempt or the PTY.
        var cancelPending: (@Sendable () -> Void)?
        /// Keep-alive probes the server answered (accepted or refused); for tests.
        var answeredProbes = 0
        /// A keep-alive probe loop was started for this session; for tests.
        var keepAliveLoopStarted = false
    }

    private enum PTYInput: Sendable {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    public convenience init(plan: ConnectionPlan, hostKeys: any HostKeyEvaluator, connectTimeout: Duration = .seconds(15)) {
        self.init(plan: plan, hostKeys: hostKeys, connectTimeout: connectTimeout, commandTimeout: .seconds(15))
    }

    /// `commandTimeout` bounds `runCommand`; only tests change it. Liveness probes follow `plan.keepAlive`.
    init(plan: ConnectionPlan, hostKeys: any HostKeyEvaluator, connectTimeout: Duration, commandTimeout: Duration) {
        self.plan = plan
        self.hostKeys = hostKeys
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
        (events, eventContinuation) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        (input, inputContinuation) = AsyncStream.makeStream(of: PTYInput.self, bufferingPolicy: .unbounded)
    }

    // MARK: TerminalSession

    public func start(cols: Int, rows: Int) async {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.started, !state.ended else { return false }
            state.started = true
            return true
        }
        guard shouldStart else { return }

        let authentication: AuthenticationFactory
        switch Self.authenticationFactory(for: plan) {
        case .success(let factory): authentication = factory
        case .failure(let error):
            finish(.failed(error))
            return
        }

        switch await connect(authentication) {
        case .userClosed:
            return
        case .failed(let error):
            finish(.failed(error))
        case .connected(let connection):
            await openShell(on: connection, cols: cols, rows: rows)
        }
    }

    public func send(_ bytes: [UInt8]) async {
        guard !bytes.isEmpty else { return }
        inputContinuation.yield(.bytes(bytes))
    }

    public func resize(cols: Int, rows: Int) async {
        inputContinuation.yield(.resize(cols: cols, rows: rows))
    }

    /// Runs `command` on a separate exec channel of the same connection. stdout and stderr are merged in
    /// arrival order. A non-zero exit status still returns the output. Output above 1 MB or a run longer
    /// than 15 s closes the exec channel and throws (`.connectionFailed("Command output too large")` /
    /// `.timedOut`).
    public func runCommand(_ command: String) async throws -> String {
        let (connection, ended) = state.withLock { ($0.connection, $0.ended) }
        guard let connection else {
            throw SessionError.connectionFailed(ended ? "Session closed" : "The session is not connected.")
        }
        let limit = Self.commandOutputLimit
        let timeout = commandTimeout
        let secrets = secretStrings
        let work = Task {
            try await connection.withClient { client in
                try await Self.execute(command, on: client, limit: limit, timeout: timeout, secrets: secrets)
            }
        }
        // Backstop: even if the server keeps the exec channel open after the kill signal (closing waits
        // for the server's confirmation), runCommand returns shortly after the timeout.
        let result = OneShot<Result<[UInt8]?, Error>>()
        Task { result.resolve(await work.result) }
        let backstop = Task {
            try await Task.sleep(for: timeout + .seconds(3))
            result.resolve(.failure(SessionError.timedOut))
        }
        let finished = await result.wait()
        backstop.cancel()
        guard let output = try finished.get() else { throw SessionError.connectionFailed("Session closed") }
        return String(decoding: output, as: UTF8.self)
    }

    public func close() async {
        let (connection, cancel) = state.withLock { state -> (Connection?, (@Sendable () -> Void)?) in
            if !state.ended {
                state.ended = true
                eventContinuation.yield(.closed(.userClosed))
                eventContinuation.finish()
            }
            let connection = state.connection
            state.connection = nil
            return (connection, state.cancelPending)
        }
        inputContinuation.finish()
        cancel?()
        // Closing the TCP connection ends the PTY; the shell task then shuts the event loop group down.
        // Does nothing when teardown has already begun.
        await connection?.closeClient()
    }

    // MARK: Events

    /// Yields an event unless the session already ended (no event ever follows `.closed`).
    private func emit(_ event: SessionEvent) {
        state.withLock { state in
            if !state.ended { eventContinuation.yield(event) }
        }
    }

    /// Emits the single `.closed` event, finishes the stream and detaches the connection.
    /// Later calls do nothing.
    private func finish(_ reason: SessionEndReason) {
        state.withLock { state in
            state.connection = nil
            guard !state.ended else { return }
            state.ended = true
            eventContinuation.yield(.closed(reason))
            eventContinuation.finish()
        }
        inputContinuation.finish()
    }

    private var isEnded: Bool { state.withLock { $0.ended } }

    /// Keep-alive probes the server has answered so far (tests only).
    var answeredKeepAliveProbes: Int { state.withLock { $0.answeredProbes } }

    /// Whether this session started a keep-alive probe loop (tests only).
    var startedKeepAliveLoop: Bool { state.withLock { $0.keepAliveLoopStarted } }

    // MARK: Authentication

    typealias AuthenticationFactory = @Sendable () -> SSHAuthenticationMethod

    /// Decides the credential locally, before any connection is made.
    static func authenticationFactory(for plan: ConnectionPlan) -> Result<AuthenticationFactory, SessionError> {
        let username = plan.username
        switch plan.credential {
        case .password(let password):
            return .success { .passwordBased(username: username, password: password) }
        case .privateKey(let type, let pem, let passphrase):
            switch type {
            case .rsa:
                // Citadel only signs with legacy ssh-rsa (SHA-1); RSA keys go through system ssh.
                return .failure(.unsupportedKey("rsa"))
            case .ed25519:
                let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
                do {
                    // An immutable key value; swift-crypto does not mark it Sendable on every platform.
                    let key = UncheckedSendable(value: try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: decryptionKey))
                    return .success { .ed25519(username: username, privateKey: key.value) }
                } catch {
                    // Wrong or missing passphrase, or a corrupt key.
                    return .failure(.keyUnreadable)
                }
            }
        case .agent:
            // Signing with an agent needs system ssh (plans with an agent credential always use it).
            return .failure(.connectionFailed("The built-in SSH engine can't sign in with an SSH agent."))
        case .none:
            // Asking for a password is the session manager's job; there is nothing to sign in with.
            return .failure(.authenticationFailed)
        }
    }

    // MARK: Connecting

    private enum AttemptOutcome: Sendable {
        case connected(Connection)
        case failed(SessionError)
        case userClosed
    }

    private func connect(_ authentication: @escaping AuthenticationFactory) async -> AttemptOutcome {
        // Upstream limit: Citadel 0.12.1's ClientHandshakeHandler fails every connect 10 s after the TCP
        // channel opens, and this can't be configured. A user who takes longer than that to answer the
        // host key prompt makes the first attempt fail; the session then reconnects once and accepts
        // the byte-identical key without asking again. A server slower than 10 s to authenticate still
        // fails with `.timedOut`.
        var preapproved: HostKeyCandidate?
        for attempt in 1...2 {
            let tracker = HostKeyTracker(preapproved: preapproved)
            let outcome = await attemptConnection(authentication, tracker: tracker)
            if case .failed(.timedOut) = outcome, attempt == 1, let trusted = tracker.slowlyTrustedCandidate {
                preapproved = trusted
                continue
            }
            return outcome
        }
        return .failed(.timedOut)
    }

    private func attemptConnection(_ authentication: @escaping AuthenticationFactory,
                                   tracker: HostKeyTracker) async -> AttemptOutcome {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let outcome = OneShot<AttemptOutcome>()
        let registered = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.cancelPending = {
                outcome.resolve(.userClosed)
                // Fails a pending host key validation at once: the handshake stops and the connect task
                // below shuts the group down without waiting for the evaluator.
                tracker.abandon()
            }
            return true
        }
        guard registered else {
            try? await group.shutdownGracefully()
            return .userClosed
        }

        let validator = HostKeyValidationDelegate(host: plan.host, port: plan.port, evaluator: hostKeys, tracker: tracker)
        let host = plan.host
        let port = plan.port
        let timeout = connectTimeout
        let secrets = secretStrings
        let method = Self.authenticationMethodName(for: plan.credential)
        // Steps are reported only while this attempt is still undecided.
        let progress: @Sendable (ConnectionStep) -> Void = { [weak self] step in
            if !outcome.isResolved { self?.emit(.progress(step)) }
        }
        // This task owns the group: it is the only place that shuts it down for a failed or lost attempt.
        Task {
            do {
                let channel = try await Self.openTCPConnection(host: host, port: port, group: group, timeout: timeout,
                                                               isAbandoned: { outcome.isResolved }, progress: progress)
                progress(.handshake)
                let settings = SSHClientSettings(
                    host: host, port: port,
                    authenticationMethod: {
                        .custom(ProgressReportingAuthentication(authentication()) { progress(.authenticating(method: method)) })
                    },
                    hostKeyValidator: .custom(validator))
                let client: SSHClient
                do {
                    // Citadel installs its handlers with the pipeline's synchronous API, which must run on the
                    // channel's event loop: run the call there.
                    let executor = EventLoopTaskExecutor(channel.eventLoop)
                    client = try await withTaskExecutorPreference(executor) {
                        try await SSHClient.connect(on: channel, settings: settings)
                    }
                } catch {
                    try? await channel.close()
                    throw error
                }
                progress(.authenticated)
                let connection = Connection(client: client, group: group)
                if !outcome.resolve(.connected(connection)) {
                    // Timed out or closed meanwhile.
                    await connection.shutdown()
                }
            } catch {
                outcome.resolve(.failed(Self.connectError(error, tracker: tracker, secrets: secrets)))
                tracker.abandon()
                try? await group.shutdownGracefully()
            }
        }
        let watchdog = Task { await Self.watch(outcome, tracker: tracker, timeout: timeout) }

        let result = await outcome.wait()
        watchdog.cancel()
        state.withLock { $0.cancelPending = nil }

        switch result {
        case .connected(let connection):
            let attached = state.withLock { state -> Bool in
                guard !state.ended else { return false }
                state.connection = connection
                return true
            }
            guard attached else {
                await connection.shutdown()
                return .userClosed
            }
            return result
        case .userClosed:
            tracker.abandon()
            return result
        case .failed:
            // A late "trusted" must not lead to authentication on this attempt.
            tracker.abandon()
            // Wait for a pending host key decision (the user may still be answering) so the outcome
            // reflects it: rejected, or trusted slowly enough to retry. `close()` ends the wait.
            await tracker.waitForDecision(orUntil: { [weak self] in self?.isEnded ?? true })
            if isEnded { return .userClosed }
            if tracker.wasRejected { return .failed(.hostKeyRejected) }
            return result
        }
    }

    /// Resolves `outcome` with `.timedOut` once `timeout` has passed, not counting host key evaluation time.
    private static func watch(_ outcome: OneShot<AttemptOutcome>, tracker: HostKeyTracker, timeout: Duration) async {
        let clock = ContinuousClock()
        let start = clock.now
        while !Task.isCancelled && !outcome.isResolved {
            let now = clock.now
            let (evaluationTime, evaluating) = tracker.evaluationTime(now: now)
            if !evaluating && now - start - evaluationTime >= timeout {
                outcome.resolve(.failed(.timedOut))
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Shell

    private enum ShellOpening: Sendable {
        case opened, failedOrClosed, timedOut
    }

    private func openShell(on connection: Connection, cols: Int, rows: Int) async {
        let opening = OneShot<ShellOpening>()
        let registered = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.cancelPending = { opening.resolve(.failedOrClosed) }
            return true
        }
        guard registered else {
            await connection.shutdown()
            return
        }
        emit(.progress(.openingShell))
        Task { await self.runShell(on: connection, cols: cols, rows: rows, opening: opening) }
        let timeout = connectTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { opening.resolve(.timedOut) }
        }
        let result = await opening.wait()
        timer.cancel()
        state.withLock { $0.cancelPending = nil }
        if result == .timedOut {
            // The PTY/shell request was never answered. Ending the connection makes the shell task
            // finish and shut the group down.
            finish(.failed(.timedOut))
            await connection.closeClient()
        }
    }

    private func runShell(on connection: Connection, cols: Int, rows: Int, opening: OneShot<ShellOpening>) async {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: plan.terminalType.rawValue,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        var reason = SessionEndReason.remoteClosed
        // Why the terminal's output ended. Citadel closes the channel on the way out and that close can throw
        // ("Already closed"), hiding the original error; this keeps it.
        let outputError = LockedBox<Error?>(nil)
        do {
            try await connection.client.withPTY(request) { inbound, outbound in
                let writer = UncheckedSendable(value: outbound)
                let input = self.input
                // One task writes all input in order (keystrokes and resizes share the queue).
                let writerTask = Task {
                    for await item in input {
                        switch item {
                        case .bytes(let bytes):
                            try? await writer.value.write(ByteBuffer(bytes: bytes))
                        case .resize(let cols, let rows):
                            try? await writer.value.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                        }
                    }
                }
                defer { writerTask.cancel() }

                // The keep-alive loop starts before `.ready` is announced, so whoever sees `.ready` also sees
                // the loop running (its first probe waits one interval).
                // The PTY channel's parent is the TCP channel that carries the SSH connection.
                let root = Self.channel(of: outbound)?.parent
                assert(root != nil, "Keep-alive disabled: Citadel's TTYStdinWriter no longer exposes its channel (or it has no parent)")
                let keepAliveTask = root.flatMap { root in
                    plan.keepAlive.interval.map { interval in
                        self.state.withLock { $0.keepAliveLoopStarted = true }
                        return Task { await self.runKeepAlive(on: root, connection: connection,
                                                       interval: interval, maxUnanswered: plan.keepAlive.maxUnanswered) }
                    }
                }
                defer { keepAliveTask?.cancel() }

                // Authenticated with the PTY open: live and ready at once. `emit` drops both after `.closed`,
                // and this closure runs once per session, so `.ready` comes at most once.
                self.emit(.connected)
                self.emit(.ready)
                opening.resolve(.opened)
                do {
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            self.emit(.output(Array(buffer.readableBytesView)))
                        }
                    }
                } catch {
                    outputError.withLock { $0 = error }
                    throw error
                }
            }
        } catch {
            reason = endReason(for: outputError.withLock { $0 } ?? error)
        }
        finish(reason)
        opening.resolve(.failedOrClosed)
        await connection.shutdown()
    }

    // MARK: Keep-alive

    /// Global request used as the keep-alive probe. Citadel 0.12.1 and swift-nio-ssh expose no public
    /// way to send an arbitrary global request (such as `keepalive@openssh.com`); the only public
    /// want-reply global request is the TCP forwarding one (`NIOSSHHandler.sendTCPForwardingRequest`).
    /// Cancelling a forward this client never set up is harmless: the server answers
    /// SSH_MSG_REQUEST_FAILURE (RFC 4254 §4), and any answer proves the connection is alive.
    static var keepAliveProbe: GlobalRequest.TCPForwardingRequest {
        .cancel(host: "keepalive@termius-reimagined", port: 0)
    }

    private enum ProbeResult: Sendable {
        case replied, noReply, failed
    }

    /// Probes the server every `interval`. After `maxUnanswered` probes in a row without a reply
    /// (each given `interval` to answer) the session ends with `unresponsiveMessage`. Stops when the
    /// session ends or the connection fails (the shell task reports that).
    private func runKeepAlive(on root: Channel, connection: Connection,
                              interval: Duration, maxUnanswered: Int) async {
        var unanswered = 0
        var wait = interval
        while true {
            try? await Task.sleep(for: wait)
            if Task.isCancelled || isEnded { return }
            // Scheduled through `withClient`, so nothing is submitted to a loop that is shutting down.
            let scheduled = (try? await connection.withClient { _ in Self.probe(root) }) ?? nil
            guard let probe = scheduled else { return } // teardown has begun
            let result = OneShot<ProbeResult>()
            probe.whenComplete { outcome in
                switch outcome {
                case .success: result.resolve(.replied)
                case .failure: result.resolve(.failed)
                }
            }
            let timer = Task {
                try? await Task.sleep(for: interval)
                result.resolve(.noReply)
            }
            let clock = ContinuousClock()
            let sent = clock.now
            let outcome = await result.wait()
            timer.cancel()
            if Task.isCancelled || isEnded { return }
            switch outcome {
            case .replied:
                state.withLock { $0.answeredProbes += 1 }
                unanswered = 0
                let elapsed = clock.now - sent
                wait = elapsed < interval ? interval - elapsed : .zero
            case .noReply:
                unanswered += 1
                wait = .zero // the reply wait already took one interval
                if unanswered >= maxUnanswered {
                    finish(.failed(.connectionFailed(Self.unresponsiveMessage)))
                    await connection.closeClient()
                    return
                }
            case .failed:
                // The connection itself failed; the shell task ends the session with its own reason.
                return
            }
        }
    }

    /// Sends one keep-alive probe. Succeeds when the server answered, whether it accepted or refused.
    private static func probe(_ root: Channel) -> EventLoopFuture<Void> {
        root.eventLoop.flatSubmit {
            let promise = root.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            do {
                let handler = try root.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                handler.sendTCPForwardingRequest(keepAliveProbe, promise: promise)
            } catch {
                // A closed channel has an empty pipeline; on a live one this means Citadel's layout changed.
                assert(!root.isActive, "Keep-alive disabled: no NIOSSHHandler in the connection's pipeline (\(error))")
                promise.fail(error)
            }
            return promise.futureResult.map { _ in () }.flatMapErrorThrowing { error in
                if let error = error as? NIOSSHError, error.type == .globalRequestRefused { return }
                throw error
            }
        }
    }

    // MARK: Commands

    private static func execute(_ command: String, on client: SSHClient, limit: Int, timeout: Duration,
                                secrets: [String]) async throws -> [UInt8] {
        let collected = LockedBox<[UInt8]>([])
        let failure = LockedBox<SessionError?>(nil)
        let completed = LockedBox(false)
        do {
            // `withExec` closes the exec channel when the closure returns or throws.
            try await client.withExec(command) { inbound, outbound in
                let stream = UncheckedSendable(value: inbound)
                let channel = UncheckedSendable(value: Self.channel(of: outbound))
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            for try await chunk in stream.value {
                                let buffer: ByteBuffer
                                switch chunk {
                                case .stdout(let data), .stderr(let data): buffer = data
                                }
                                let fits = collected.withLock { output -> Bool in
                                    guard output.count + buffer.readableBytes <= limit else { return false }
                                    output.append(contentsOf: buffer.readableBytesView)
                                    return true
                                }
                                guard fits else {
                                    let error = SessionError.connectionFailed("Command output too large")
                                    failure.withLock { $0 = error }
                                    throw error
                                }
                            }
                        } catch is SSHClient.CommandFailed {
                            // Non-zero exit status: the output collected so far is still the answer.
                        }
                        completed.withLock { $0 = true }
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        failure.withLock { $0 = $0 ?? .timedOut }
                        throw SessionError.timedOut
                    }
                    do {
                        try await group.next()
                        group.cancelAll()
                    } catch {
                        // Over the cap or out of time: stop the remote command so the server closes the
                        // channel promptly (closing an exec channel waits for the server to agree).
                        if let channel = channel.value {
                            try? await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.SignalRequest(signal: "KILL"))
                        }
                        throw error
                    }
                }
            }
        } catch {
            if let failure = failure.withLock({ $0 }) { throw failure }
            // Citadel's own close of a channel the server already closed ("Already closed") is fine.
            if !completed.withLock({ $0 }) {
                throw error as? SessionError ?? .connectionFailed(redact(String(describing: error), secrets: secrets))
            }
        }
        if let failure = failure.withLock({ $0 }) { throw failure }
        return collected.withLock { $0 }
    }

    /// The exec channel behind Citadel's writer (not public API; nil if Citadel changes its layout).
    private static func channel(of writer: TTYStdinWriter) -> Channel? {
        Mirror(reflecting: writer).children.first { $0.label == "channel" }?.value as? Channel
    }

    // MARK: Error mapping

    /// Passwords and passphrases of this plan, removed from any error text as a last line of defence.
    private var secretStrings: [String] {
        switch plan.credential {
        case .password(let password): [password].filter { !$0.isEmpty }
        case .privateKey(_, _, let passphrase): [passphrase].compactMap { $0 }.filter { !$0.isEmpty }
        case .agent, .none: []
        }
    }

    private func describe(_ error: Error) -> String {
        Self.redact(String(describing: error), secrets: secretStrings)
    }

    static func redact(_ text: String, secrets: [String]) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
    }

    static func connectError(_ error: Error, tracker: HostKeyTracker, secrets: [String]) -> SessionError {
        if tracker.wasRejected { return .hostKeyRejected }
        switch error {
        case let error as SSHClientError:
            switch error {
            case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication, .unsupportedHostBasedAuthentication:
                return .authenticationFailed
            case .channelCreationFailed:
                return .connectionFailed("The server did not open a session.")
            }
        case is AuthenticationFailed:
            return .authenticationFailed
        case let error as ChannelError:
            if case .connectTimeout = error { return .timedOut }
        case let error as TCPConnectFailure:
            if error.timedOut { return .timedOut }
            let detail = error.reason.map { " (\($0))" } ?? ""
            return .connectionFailed(redact("Could not connect to \(error.host):\(error.port)\(detail)", secrets: secrets))
        case let error as NameResolutionFailure:
            return .connectionFailed("Could not resolve \(error.host) (\(error.reason))")
        case let error as NIOConnectionError:
            if error.connectionErrors.contains(where: { if case ChannelError.connectTimeout = $0.error { true } else { false } }) {
                return .timedOut
            }
            let reasons = error.connectionErrors.map { String(describing: $0.error) }
            let detail = reasons.isEmpty ? "" : " (\(reasons.joined(separator: "; ")))"
            return .connectionFailed(redact("Could not connect to \(error.host):\(error.port)\(detail)", secrets: secrets))
        default:
            break
        }
        if let reason = lowLevelReason(error) {
            return .connectionFailed("The connection to the server failed (\(reason)).")
        }
        if closedDuringHandshake(error) {
            return .connectionFailed(closedDuringHandshakeMessage)
        }
        return .connectionFailed(redact(String(describing: error), secrets: secrets))
    }

    static let closedDuringHandshakeMessage = "The server closed the connection before signing in."

    /// The connection went away before authentication finished without a socket error: Citadel's
    /// handshake handler fails with its private `Disconnected` error when the channel closes under it.
    static func closedDuringHandshake(_ error: Error) -> Bool {
        if let error = error as? ChannelError {
            switch error {
            case .eof, .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed: return true
            default: return false
            }
        }
        if let error = error as? NIOSSHError, error.type == .tcpShutdown { return true }
        return String(describing: type(of: error)) == "Disconnected"
    }

    /// A plain name for a socket-level error ("connection refused", "connection reset by peer"…); nil
    /// when the error isn't one.
    static func lowLevelReason(_ error: Error) -> String? {
        guard let error = error as? IOError else { return nil }
        switch error.errnoCode {
        case ECONNREFUSED: return "connection refused"
        case ECONNRESET: return "connection reset by peer"
        case EHOSTUNREACH: return "no route to host"
        case ENETUNREACH: return "network is unreachable"
        case ETIMEDOUT: return "operation timed out"
        case EPIPE: return "broken pipe"
        case ECONNABORTED: return "connection aborted"
        case EADDRNOTAVAIL: return "address not available"
        case EHOSTDOWN: return "host is down"
        default: return nil
        }
    }

    /// The step log's name for how this credential signs in.
    static func authenticationMethodName(for credential: SSHCredential) -> String {
        switch credential {
        case .password, .none: "password"
        case .privateKey: "key"
        case .agent: "1Password agent"
        }
    }

    // MARK: TCP

    /// Resolves `host` (unless it is an IP address), reporting `.resolving`, then tries its addresses in
    /// order the way OpenSSH does, reporting `.connecting` for each and `.connected` for the one that
    /// answers. The channel comes back with reading off: `ReadGate` turns it on once Citadel's SSH
    /// handler is installed and speaks first, so the server's version line can't be read (and dropped)
    /// before anyone handles it.
    static func openTCPConnection(host: String, port: Int, group: EventLoopGroup, timeout: Duration,
                                  isAbandoned: @escaping @Sendable () -> Bool,
                                  progress: @escaping @Sendable (ConnectionStep) -> Void) async throws -> Channel {
        let addresses: [SocketAddress]
        if let literal = try? SocketAddress(ipAddress: host, port: port) {
            addresses = [literal]
        } else {
            progress(.resolving(host: host))
            addresses = try await NameResolver.resolve(host: host, port: port)
        }
        var reasons: [String] = []
        var timedOut = false
        for address in addresses {
            if isAbandoned() { throw CancellationError() }
            let shown = address.ipAddress ?? host
            progress(.connecting(address: shown, port: port))
            let bootstrap = ClientBootstrap(group: group)
                .connectTimeout(timeAmount(timeout))
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(ReadGate()) }
                }
            do {
                let channel = try await bootstrap.connect(to: address).get()
                if isAbandoned() {
                    try? await channel.close()
                    throw CancellationError()
                }
                progress(.connected(address: channel.remoteAddress?.ipAddress ?? shown))
                return channel
            } catch let error as ChannelError {
                if case .connectTimeout = error { timedOut = true } else { reasons.append(String(describing: error)) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reasons.append(lowLevelReason(error) ?? String(describing: error))
            }
        }
        var unique: [String] = []
        for reason in reasons where !unique.contains(reason) { unique.append(reason) }
        throw TCPConnectFailure(host: host, port: port, reason: unique.isEmpty ? nil : unique.joined(separator: "; "),
                                timedOut: timedOut && unique.isEmpty)
    }

    private func endReason(for error: Error) -> SessionEndReason {
        switch error {
        case let error as ChannelError:
            switch error {
            // Citadel's own channel close after the remote end finished ("Already closed"), and friends.
            case .alreadyClosed, .ioOnClosedChannel, .eof, .outputClosed, .inputClosed:
                return .remoteClosed
            default:
                break
            }
        case let error as NIOSSHError where error.type == .tcpShutdown:
            // The TCP connection closed while the terminal's channel was still open: no exit status, no
            // channel close from the server. A dropped connection, not the end of the session.
            return .failed(.connectionFailed(Self.connectionLostMessage))
        case is SSHClient.CommandFailed:
            // The remote shell exited with a non-zero status: still a normal end of session.
            return .remoteClosed
        case CitadelError.channelFailure:
            return .failed(.connectionFailed("The server refused to open a terminal."))
        default:
            break
        }
        return .failed(.connectionFailed(describe(error)))
    }

    static func timeAmount(_ duration: Duration) -> TimeAmount {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
    }
}

// MARK: - Connection plumbing

/// An authenticated client and the event loop group that owns its socket.
///
/// Teardown happens once (`shutdown`). After it has begun, `withClient` and `closeClient` do nothing,
/// so nobody ever schedules work on a loop that is shut down (such work would never complete).
private final class Connection: Sendable {
    /// `SSHClient` is not `Sendable`; it is only used through its async API, which hops to its event loop.
    private let clientBox: UncheckedSendable<SSHClient>
    let group: MultiThreadedEventLoopGroup

    private struct State {
        var shuttingDown = false
        var users = 0
    }

    private let state = Mutex(State())

    init(client: SSHClient, group: MultiThreadedEventLoopGroup) {
        clientBox = UncheckedSendable(value: client)
        self.group = group
    }

    /// For the shell task only, which calls `shutdown` itself when it is done.
    var client: SSHClient { clientBox.value }

    /// Runs `body` with the client, or returns nil when teardown has begun. Teardown waits for running bodies.
    func withClient<T: Sendable>(_ body: (SSHClient) async throws -> T) async throws -> T? {
        let admitted = state.withLock { state -> Bool in
            guard !state.shuttingDown else { return false }
            state.users += 1
            return true
        }
        guard admitted else { return nil }
        defer { state.withLock { $0.users -= 1 } }
        return try await body(clientBox.value)
    }

    func closeClient() async {
        _ = try? await withClient { try await $0.close() }
    }

    func shutdown() async {
        let first = state.withLock { state -> Bool in
            guard !state.shuttingDown else { return false }
            state.shuttingDown = true
            return true
        }
        guard first else { return }
        // Closing the socket ends any running exec channel, so in-flight users finish promptly.
        try? await clientBox.value.close()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while state.withLock({ $0.users > 0 }) && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await group.shutdownGracefully()
    }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// A small lock-protected value shared with child tasks.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

struct HostKeyNotTrusted: Error {}

/// No address of the host accepted the TCP connection.
struct TCPConnectFailure: Error {
    let host: String
    let port: Int
    /// The socket errors, plainly named where known; nil when every address timed out.
    let reason: String?
    let timedOut: Bool
}

/// The host name could not be looked up.
struct NameResolutionFailure: Error {
    let host: String
    /// "host name not found", or getaddrinfo's own message.
    let reason: String
}

/// Looks up host names with `getaddrinfo` on a background thread (it blocks and can't be cancelled; the
/// connect timeout bounds the wait for it).
enum NameResolver {
    static func resolve(host: String, port: Int) async throws -> [SocketAddress] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try lookup(host: host, port: port) })
            }
        }
    }

    private static func lookup(host: String, port: Int) throws -> [SocketAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        hints.ai_protocol = Int32(IPPROTO_TCP)
        #else
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0, let list else {
            throw NameResolutionFailure(host: host, reason: reason(for: status))
        }
        defer { freeaddrinfo(list) }
        var addresses: [SocketAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let info = cursor?.pointee {
            cursor = info.ai_next
            guard let raw = info.ai_addr else { continue }
            let address: SocketAddress?
            switch info.ai_family {
            case AF_INET:
                address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { SocketAddress($0.pointee, host: host) }
            case AF_INET6:
                address = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { SocketAddress($0.pointee, host: host) }
            default:
                address = nil
            }
            if let address, !addresses.contains(address) { addresses.append(address) }
        }
        guard !addresses.isEmpty else { throw NameResolutionFailure(host: host, reason: "host name not found") }
        return addresses
    }

    private static func reason(for status: Int32) -> String {
        switch status {
        case EAI_NONAME: return "host name not found"
        case EAI_AGAIN: return "temporary failure in name resolution"
        default: return String(cString: gai_strerror(status)).lowercased()
        }
    }
}

/// Runs task jobs on a NIO event loop, so code that must run on the loop (Citadel's pipeline setup) can
/// be awaited there.
final class EventLoopTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let loop: any EventLoop

    init(_ loop: any EventLoop) { self.loop = loop }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        loop.execute { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// Keeps a new connection from reading until Citadel's SSH handler is installed: that handler sends the
/// client's version line as soon as it is added, and the first write through here turns reading on.
private final class ReadGate: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = Any
    private var opened = false

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if !opened {
            opened = true
            do {
                try context.channel.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
            } catch {
                context.close(promise: nil)
            }
        }
        context.write(data, promise: promise)
    }
}

/// Reports the start of authentication (once), then lets Citadel's method do the work.
private final class ProgressReportingAuthentication: NIOSSHClientUserAuthenticationDelegate {
    private let inner: SSHAuthenticationMethod
    private let started: @Sendable () -> Void
    private var reported = false

    init(_ inner: SSHAuthenticationMethod, started: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.started = started
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        if !reported {
            reported = true
            started()
        }
        inner.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: nextChallengePromise)
    }
}

/// Host key decisions of one connection attempt.
final class HostKeyTracker: Sendable {
    /// A decision that took at least this long involved the user.
    static let slowDecision: Duration = .seconds(2)

    private struct State {
        var preapproved: HostKeyCandidate?
        var trusted: HostKeyCandidate?
        var trustedSlowly = false
        var rejected = false
        var abandoned = false
        var evaluatingSince: ContinuousClock.Instant?
        var evaluationTime: Duration = .zero
        /// The validation promise of the running evaluation; completed exactly once.
        var pendingPromise: EventLoopPromise<Void>?
    }

    // Initialised empty and filled in `init`: `Mutex(State(preapproved:))` in an initialiser crashes the
    // Swift 6.0.3 compiler (IRGen "Element number out of range").
    private let state = Mutex(State())
    private let clock = ContinuousClock()

    init(preapproved: HostKeyCandidate?) {
        state.withLock { $0.preapproved = preapproved }
    }

    /// The same key was already trusted in this session (a retry, or a re-key during the session).
    func isPreapproved(_ candidate: HostKeyCandidate) -> Bool {
        state.withLock { !$0.abandoned && ($0.preapproved == candidate || $0.trusted == candidate) }
    }

    /// Returns false when the attempt was abandoned and the key must not be accepted.
    func beginEvaluation(promise: EventLoopPromise<Void>) -> Bool {
        let now = clock.now
        return state.withLock { state in
            guard !state.abandoned else { return false }
            state.evaluatingSince = now
            state.pendingPromise = promise
            return true
        }
    }

    /// Records the decision and completes the validation promise, unless `abandon()` already failed it.
    func endEvaluation(of candidate: HostKeyCandidate, decision: HostKeyDecision) {
        let now = clock.now
        let (promise, proceed) = state.withLock { state -> (EventLoopPromise<Void>?, Bool) in
            let took = state.evaluatingSince.map { now - $0 } ?? .zero
            state.evaluationTime += took
            state.evaluatingSince = nil
            let promise = state.pendingPromise
            state.pendingPromise = nil
            switch decision {
            case .trusted:
                state.trusted = candidate
                state.trustedSlowly = took >= Self.slowDecision
                return (promise, !state.abandoned)
            case .rejected:
                state.rejected = true
                return (promise, false)
            }
        }
        if proceed {
            promise?.succeed(())
        } else {
            promise?.fail(HostKeyNotTrusted())
        }
    }

    func markRejected() {
        state.withLock { $0.rejected = true }
    }

    /// Stops the attempt: a pending validation fails now; a later answer is recorded but ignored.
    func abandon() {
        let promise = state.withLock { state -> EventLoopPromise<Void>? in
            state.abandoned = true
            let promise = state.pendingPromise
            state.pendingPromise = nil
            return promise
        }
        promise?.fail(HostKeyNotTrusted())
    }

    var wasRejected: Bool { state.withLock { $0.rejected } }

    var slowlyTrustedCandidate: HostKeyCandidate? {
        state.withLock { $0.trustedSlowly ? $0.trusted : nil }
    }

    /// Total time spent in the evaluator so far, and whether an evaluation is running now.
    func evaluationTime(now: ContinuousClock.Instant) -> (Duration, Bool) {
        state.withLock { state in
            let running = state.evaluatingSince.map { now - $0 } ?? .zero
            return (state.evaluationTime + running, state.evaluatingSince != nil)
        }
    }

    private var isEvaluating: Bool { state.withLock { $0.evaluatingSince != nil } }

    /// Waits until a running evaluation has produced its decision, or `stop` returns true.
    func waitForDecision(orUntil stop: @Sendable () -> Bool = { false }) async {
        while isEvaluating && !stop() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Converts the server's host key to a `HostKeyCandidate` and asks the evaluator, before authentication.
final class HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let host: String
    let port: Int
    let evaluator: any HostKeyEvaluator
    let tracker: HostKeyTracker

    init(host: String, port: Int, evaluator: any HostKeyEvaluator, tracker: HostKeyTracker) {
        self.host = host
        self.port = port
        self.evaluator = evaluator
        self.tracker = tracker
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let candidate = Self.candidate(for: hostKey, host: host, port: port) else {
            tracker.markRejected()
            validationCompletePromise.fail(HostKeyNotTrusted())
            return
        }
        if tracker.isPreapproved(candidate) {
            validationCompletePromise.succeed(())
            return
        }
        guard tracker.beginEvaluation(promise: validationCompletePromise) else {
            validationCompletePromise.fail(HostKeyNotTrusted())
            return
        }
        let evaluator = evaluator
        let tracker = tracker
        Task {
            let decision = await evaluator.evaluate(candidate)
            tracker.endEvaluation(of: candidate, decision: decision)
        }
    }

    /// `String(openSSHPublicKey:)` gives "type base64(blob)".
    static func candidate(for key: NIOSSHPublicKey, host: String, port: Int) -> HostKeyCandidate? {
        let fields = String(openSSHPublicKey: key).split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        return HostKeyCandidate(host: host, port: port, keyType: String(fields[0]), publicKeyBlob: blob)
    }
}

/// A value set once; any number of waiters get it.
final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var resolved = false
        var waiters: [CheckedContinuation<Value, Never>] = []
    }

    private let state = Mutex(State())

    /// Returns true when this call set the value.
    @discardableResult
    func resolve(_ value: Value) -> Bool {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, Never>]? in
            guard !state.resolved else { return nil }
            state.resolved = true
            state.value = value
            defer { state.waiters = [] }
            return state.waiters
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(returning: value) }
        return true
    }

    var isResolved: Bool { state.withLock { $0.resolved } }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let value = state.withLock { state -> Value? in
                if state.resolved { return state.value }
                state.waiters.append(continuation)
                return nil
            }
            if let value { continuation.resume(returning: value) }
        }
    }
}
