import Foundation
import SSHCore

/// Gives 1Password's Touch ID / approval prompt the keyboard focus. macOS can show the prompt while
/// another window keeps the focus, so the fingerprint sheet sits there unanswered.
///
/// A wait starts when the app asks 1Password for something (an `op` call, or system ssh signing with
/// its agent). If it hasn't finished after `delay` (a prompt is showing; an unlocked 1Password answers
/// in a few milliseconds), `handOff` runs once; when the last wait ends, `takeBack` runs (only after a
/// hand-off). `isEnabled` is read at hand-off time (Settings → 1Password).
@MainActor
public final class OnePasswordPromptFocus {
    public static let delay: Duration = .milliseconds(600)
    /// The step log's method name for 1Password's agent (`SSHDebugLog.methodName`).
    static let agentMethod = "1Password agent"

    private let isEnabled: @MainActor () -> Bool
    private let handOff: @MainActor () -> Void
    private let takeBack: @MainActor () -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var waits = 0
    private var agentWaiting = false
    private var timer: Task<Void, Never>?
    private var handedOff = false

    public init(isEnabled: @escaping @MainActor () -> Bool,
                handOff: @escaping @MainActor () -> Void,
                takeBack: @escaping @MainActor () -> Void,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.isEnabled = isEnabled
        self.handOff = handOff
        self.takeBack = takeBack
        self.sleep = sleep
    }

    /// Whether a tab's connection log shows it signing in with 1Password's agent right now.
    public static func isWaitingForAgent(_ log: [ConnectionLogLine]) -> Bool {
        guard let last = log.last, last.status == .inProgress,
              case .authenticating(let method) = last.step else { return false }
        return method == agentMethod
    }

    public func beginWait() {
        waits += 1
        guard waits == 1 else { return }
        let sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(Self.delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.delayPassed()
        }
    }

    public func endWait() {
        guard waits > 0 else { return }
        waits -= 1
        guard waits == 0 else { return }
        timer?.cancel()
        timer = nil
        if handedOff {
            handedOff = false
            takeBack()
        }
    }

    /// Any tab waiting on the agent counts as one wait (called whenever tabs' logs change).
    public func setAgentWaiting(_ waiting: Bool) {
        guard waiting != agentWaiting else { return }
        agentWaiting = waiting
        if waiting { beginWait() } else { endWait() }
    }

    private func delayPassed() {
        guard waits > 0, !handedOff, isEnabled() else { return }
        handedOff = true
        handOff()
    }
}
