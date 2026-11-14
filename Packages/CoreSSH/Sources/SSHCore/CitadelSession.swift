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

    static let terminalType = "xterm-256color"
    static let commandOutputLimit = 1_048_576

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
    }

    private enum PTYInput: Sendable {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    public convenience init(plan: ConnectionPlan, hostKeys: any HostKeyEvaluator, connectTimeout: Duration = .seconds(15)) {
        self.init(plan: plan, hostKeys: hostKeys, connectTimeout: connectTimeout, commandTimeout: .seconds(15))
    }

    /// `commandTimeout` bounds `runCommand`; only tests change it.
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
        // This task owns the group: it is the only place that shuts it down for a failed or lost attempt.
        Task {
            do {
                let client = try await SSHClient.connect(
                    host: host,
                    port: port,
                    authenticationMethod: authentication(),
                    hostKeyValidator: .custom(validator),
                    reconnect: .never,
                    group: group,
                    connectTimeout: Self.timeAmount(timeout)
                )
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
            term: Self.terminalType,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        var reason = SessionEndReason.remoteClosed
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

                // Authenticated with the PTY open: live and ready at once. `emit` drops both after `.closed`,
                // and this closure runs once per session, so `.ready` comes at most once.
                self.emit(.connected)
                self.emit(.ready)
                opening.resolve(.opened)
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buffer), .stderr(let buffer):
                        self.emit(.output(Array(buffer.readableBytesView)))
                    }
                }
            }
        } catch {
            reason = endReason(for: error)
        }
        finish(reason)
        opening.resolve(.failedOrClosed)
        await connection.shutdown()
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
        case .none: []
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
        return .connectionFailed(redact(String(describing: error), secrets: secrets))
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
