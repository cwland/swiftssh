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
    /// Runs once; later calls return immediately.
    func load() async {
        guard !didStartLoading else { return }
        didStartLoading = true
        do {
            let fileURL = try Self.vaultFileURL()
            let provider = keyProvider
            // Keychain calls can block (e.g. an access prompt), so keep them off the main actor.
            let key = try await Task.detached(priority: .userInitiated) {
                try provider.loadOrCreateKey()
            }.value
            let persistence = EncryptedFileVaultPersistence(fileURL: fileURL, key: key)
            let vault = try await LocalVault.open(persistence: persistence)
            state = .ready(vault)
        } catch VaultLoadError.unreadable(let movedTo) {
            state = .failed(
                "The vault file could not be read. It was moved aside, not deleted, to:\n\(movedTo.path)"
            )
        } catch {
            state = .failed("The vault could not be opened: \(error)")
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
