import Foundation
import Observation

/// The iPhone/iPad app's first-launch form: join the sync server that the Mac set up (server address,
/// an API key for this device, the vault passphrase). Join only: the app has no local data to merge
/// and can't create a vault. Secrets go straight to `SyncCoordinator` (which keeps them in the
/// Keychain) and are cleared from the form after a successful join.
@MainActor @Observable
public final class CompanionJoin {
    public var serverAddress: String
    public var apiKey = ""
    public var passphrase = ""
    public private(set) var isJoining = false
    /// Why the last attempt failed; nil while none has.
    public private(set) var errorMessage: String?

    /// Shown when the server has no vault yet: the vault is created on the Mac.
    public static let noVaultMessage =
        "This sync server has no vault yet. Set up sync on your Mac first, then join from here."

    @ObservationIgnored private let coordinator: SyncCoordinator

    /// Starts with the saved server address, if there is one (a device that has to join again).
    public init(coordinator: SyncCoordinator) {
        self.coordinator = coordinator
        serverAddress = coordinator.serverURL?.absoluteString ?? ""
    }

    /// Whether sync is set up far enough for the app to be used; otherwise it shows this form.
    public static func isJoined(_ phase: SyncCoordinator.Phase) -> Bool {
        switch phase {
        case .notConfigured, .needsVault(_), .locked: false
        case .idle, .syncing, .offline, .failed: true
        }
    }

    /// Every field is filled in and nothing is running.
    public var canJoin: Bool {
        !isJoining && !Self.isBlank(serverAddress) && !Self.isBlank(apiKey) && !passphrase.isEmpty
    }

    /// Connects, then joins the vault and runs the first sync. Returns whether it worked; when it
    /// didn't, `errorMessage` says why.
    @discardableResult
    public func join() async -> Bool {
        guard canJoin else { return false }
        errorMessage = nil
        let url: URL
        switch SyncCoordinator.validateServerURL(serverAddress) {
        case .success(let valid): url = valid
        case .failure(let error):
            errorMessage = error.message
            return false
        }
        isJoining = true
        defer { isJoining = false }
        do {
            try await coordinator.connect(serverURL: url, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            guard coordinator.phase == .needsVault(exists: true) else {
                errorMessage = Self.noVaultMessage
                return false
            }
            // Merge, not replace: anything this device already wrote (known hosts, connection logs) is kept.
            try await coordinator.joinVault(passphrase: passphrase, mode: .merge)
        } catch {
            errorMessage = error == .noVault ? Self.noVaultMessage : error.message
            return false
        }
        apiKey = ""
        passphrase = ""
        return true
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
