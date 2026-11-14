import Foundation
import Observation
import AppCore
import SyncCore

/// App-wide state: navigation plus the local vault, opened once at launch.
@MainActor @Observable
final class AppEnvironment {
    enum State {
        case loading
        case ready(LocalVault)
        case failed(String)
    }

    private(set) var state: State = .loading
    let navigation: AppNavigation

    @ObservationIgnored private let keyProvider: any VaultKeyProvider
    @ObservationIgnored private var didStartLoading = false

    init(keyProvider: any VaultKeyProvider = KeychainVaultKeyProvider()) {
        self.keyProvider = keyProvider
        self.navigation = AppNavigation()
    }

    /// Loads the Keychain key and opens `~/Library/Application Support/TermiusReimagined/vault.bin`.
    /// Runs once; later calls return immediately, unless the last attempt ended in `.failed`,
    /// in which case calling again tries again.
    func load() async {
        guard !didStartLoading else { return }
        didStartLoading = true
        defer {
            if case .failed = state {
                didStartLoading = false
            }
        }
        state = .loading
        // When this process is the host app for unit tests, don't touch the real Keychain item
        // or vault file: an ad-hoc signed rebuild would raise a Keychain prompt on every test
        // run, and tests must never create or move aside the user's vault. Stay `.loading`.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        var keyWasCreated = false
        do {
            let fileURL = try Self.vaultFileURL()
            let provider = keyProvider
            // Keychain calls can block (e.g. an access prompt), so keep them off the main actor.
            let loaded = try await Task.detached(priority: .userInitiated) { () throws -> (key: VaultKey, created: Bool) in
                if let keychain = provider as? KeychainVaultKeyProvider {
                    return try keychain.loadOrCreateKeyReportingCreation()
                }
                return (try provider.loadOrCreateKey(), false)
            }.value
            keyWasCreated = loaded.created
            let persistence = EncryptedFileVaultPersistence(fileURL: fileURL, key: loaded.key)
            let vault = try await LocalVault.open(persistence: persistence)
            state = .ready(vault)
        } catch VaultLoadError.unreadable(let movedTo) {
            if keyWasCreated {
                state = .failed(
                    "A new vault key was created because none was found in your Keychain, so the existing "
                        + "vault file couldn't be opened. It was moved to \(movedTo.path)."
                )
            } else {
                state = .failed(
                    "The vault file could not be read. It was moved aside, not deleted, to:\n\(movedTo.path)"
                )
            }
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            state = .failed("The vault could not be opened: \(detail)")
        }
    }

    /// `~/Library/Application Support/TermiusReimagined/vault.bin`; creates the folder if needed.
    static func vaultFileURL() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("TermiusReimagined", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("vault.bin", isDirectory: false)
    }
}
