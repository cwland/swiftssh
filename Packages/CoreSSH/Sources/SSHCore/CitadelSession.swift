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
/// - `connectTimeout` covers TCP connect, handshake and authentication, but not the time the host key
///   evaluator takes (it may be waiting for the user). If answering the prompt takes longer than Citadel's
///   fixed 10 s login timer, the connection is retried once and the key the user just trusted is accepted
///   without asking again.
public final class CitadelSession: TerminalSession {
    public let events: AsyncStream<SessionEvent>

    static let terminalType = "xterm-256color"
    static let commandOutputLimit = 1_048_576

    private let plan: ConnectionPlan
    private let hostKeys: any HostKeyEvaluator
    private let connectTimeout: Duration
    private let eventContinuation: AsyncStream<SessionEvent>.Continuation
    private let input: AsyncStream<PTYInput>
    private let inputContinuation: AsyncStream<PTYInput>.Continuation
    private let state = Mutex(State())

    private struct State {
        var started = false
        /// `.closed` was emitted and the event stream finished.
        var ended = false
        var connection: Connection?
        /// Wakes up `start` while it waits on a connection attempt or the PTY opening.
        var cancelPending: (@Sendable () -> Void)?
    }

    private enum PTYInput: Sendable {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    public init(plan: ConnectionPlan, hostKeys: any HostKeyEvaluator, connectTimeout: Duration = .seconds(15)) {
        self.plan = plan
        self.hostKeys = hostKeys
        self.connectTimeout = connectTimeout
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

    /// Runs `command` on a separate exec channel of the same connection. stdout and stderr are merged
    /// in arrival order; output above 1 MB throws. A non-zero exit status still returns the output.
    public func runCommand(_ command: String) async throws -> String {
        guard let connection = state.withLock({ $0.ended ? nil : $0.connection }) else {
            throw SessionError.connectionFailed("The session is not connected.")
        }
        var output: [UInt8] = []
        do {
            let stream = try await connection.client.executeCommandStream(command)
            for try await chunk in stream {
                let buffer: ByteBuffer
                switch chunk {
                case .stdout(let data), .stderr(let data): buffer = data
                }
                guard output.count + buffer.readableBytes <= Self.commandOutputLimit else {
                    throw SessionError.connectionFailed("The command produced more than 1 MB of output.")
                }
                output.append(contentsOf: buffer.readableBytesView)
            }
        } catch is SSHClient.CommandFailed {
            // Non-zero exit status: the output collected so far is still the answer.
        } catch let error as SessionError {
            throw error
        } catch {
            throw SessionError.connectionFailed(describe(error))
        }
        return String(decoding: output, as: UTF8.self)
    }

    public func close() async {
        let (connection, cancel) = state.withLock { state -> (Connection?, (@Sendable () -> Void)?) in
            if !state.ended {
                state.ended = true
                eventContinuation.yield(.closed(.userClosed))
                eventContinuation.finish()
            }
            return (state.connection, state.cancelPending)
        }
        inputContinuation.finish()
        cancel?()
        if let connection {
            // Closing the TCP connection ends the PTY; its task then shuts the event loop group down.
            try? await connection.client.close()
        }
    }

    // MARK: Events

    /// Yields an event unless the session already ended (no event ever follows `.closed`).
    private func emit(_ event: SessionEvent) {
        state.withLock { state in
            if !state.ended { eventContinuation.yield(event) }
        }
    }

    /// Emits the single `.closed` event and finishes the stream. Later calls do nothing.
    private func finish(_ reason: SessionEndReason) {
        state.withLock { state in
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
                    // Unreadable key or wrong passphrase.
                    return .failure(.authenticationFailed)
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
        var preapproved: HostKeyCandidate?
        for attempt in 1...2 {
            let tracker = HostKeyTracker(preapproved: preapproved)
            let outcome = await attemptConnection(authentication, tracker: tracker)
            if case .failed(.timedOut) = outcome, attempt == 1, let trusted = tracker.slowlyTrustedCandidate {
                // The user took longer than Citadel's login timer to trust the key; retry once.
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
            state.cancelPending = { outcome.resolve(.userClosed) }
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
                // Shut down only once no host key decision is pending, so its promise is completed first.
                await tracker.waitUntilIdle()
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
            // A late "trusted" must not lead to authentication on this abandoned attempt.
            tracker.abandon()
            // Let a pending host key decision finish so the outcome reflects it.
            await tracker.waitUntilIdle(orUntil: { [weak self] in self?.isEnded ?? true })
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

    private func openShell(on connection: Connection, cols: Int, rows: Int) async {
        let opened = OneShot<Bool>()
        let registered = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.cancelPending = { opened.resolve(false) }
            return true
        }
        guard registered else {
            await connection.shutdown()
            return
        }
        Task { await self.runShell(on: connection, cols: cols, rows: rows, opened: opened) }
        _ = await opened.wait()
        state.withLock { $0.cancelPending = nil }
    }

    private func runShell(on connection: Connection, cols: Int, rows: Int, opened: OneShot<Bool>) async {
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

                self.emit(.connected)
                opened.resolve(true)
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
        opened.resolve(false)
        await connection.shutdown()
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
/// `SSHClient` is not `Sendable`; it is only used through its async API, which hops to its event loop.
private struct Connection: @unchecked Sendable {
    let client: SSHClient
    let group: MultiThreadedEventLoopGroup

    func shutdown() async {
        try? await client.close()
        try? await group.shutdownGracefully()
    }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
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
    }

    private let state: Mutex<State>
    private let clock = ContinuousClock()

    init(preapproved: HostKeyCandidate?) {
        state = Mutex(State(preapproved: preapproved))
    }

    /// The same key was already trusted in this session (a retry, or a re-key during the session).
    func isPreapproved(_ candidate: HostKeyCandidate) -> Bool {
        state.withLock { !$0.abandoned && ($0.preapproved == candidate || $0.trusted == candidate) }
    }

    /// Returns false when the attempt was abandoned and the key must not be accepted.
    func beginEvaluation() -> Bool {
        let now = clock.now
        return state.withLock { state in
            guard !state.abandoned else { return false }
            state.evaluatingSince = now
            return true
        }
    }

    /// Records the decision; returns whether the handshake may continue.
    func endEvaluation(of candidate: HostKeyCandidate, decision: HostKeyDecision) -> Bool {
        let now = clock.now
        return state.withLock { state in
            let took = state.evaluatingSince.map { now - $0 } ?? .zero
            state.evaluationTime += took
            state.evaluatingSince = nil
            switch decision {
            case .trusted:
                state.trusted = candidate
                state.trustedSlowly = took >= Self.slowDecision
                return !state.abandoned
            case .rejected:
                state.rejected = true
                return false
            }
        }
    }

    func markRejected() {
        state.withLock { $0.rejected = true }
    }

    func abandon() {
        state.withLock { $0.abandoned = true }
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

    func waitUntilIdle(orUntil stop: @Sendable () -> Bool = { false }) async {
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
        guard tracker.beginEvaluation() else {
            validationCompletePromise.fail(HostKeyNotTrusted())
            return
        }
        let evaluator = evaluator
        let tracker = tracker
        Task {
            let decision = await evaluator.evaluate(candidate)
            if tracker.endEvaluation(of: candidate, decision: decision) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyNotTrusted())
            }
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
