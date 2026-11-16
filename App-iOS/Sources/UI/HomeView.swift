import SwiftUI
import AppCore
import CoreModels
import SwiftSSHUI

/// The joined app's root. For now: what came through sync, sync status and the app lock switch.
/// The hosts screens (iPad sidebar and grid, iPhone list), sessions and the full Settings replace
/// this as they are built.
struct HomeView: View {
    @Environment(IOSEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            List {
                if let vault = environment.vault {
                    Section("From your Mac") {
                        countRow("Hosts", symbol: "server.rack", count: vault.liveCounts()[.host] ?? 0)
                        countRow("Groups", symbol: "folder", count: vault.liveCounts()[.hostGroup] ?? 0)
                        countRow("Snippets", symbol: "text.alignleft", count: vault.liveCounts()[.snippet] ?? 0)
                    }
                }
                if let sync = environment.sync {
                    Section("Sync") {
                        LabeledContent("Status", value: Self.status(of: sync.phase))
                        if let last = sync.lastSyncedAt {
                            LabeledContent("Last synced") {
                                Text(last, style: .relative)
                            }
                        }
                        Button("Sync Now") {
                            Task { await sync.syncNow() }
                        }
                        .disabled(sync.phase == .syncing)
                    }
                }
                Section {
                    Toggle("\(DeviceAuthenticator.biometryName) app lock",
                           isOn: Binding(get: { environment.appLock.isEnabled },
                                         set: { environment.appLock.isEnabled = $0 }))
                } footer: {
                    Text("Locks SwiftSSH when it opens and when you come back after more than \(Int(AppLock.gracePeriod)) seconds.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.contentBackground)
            .navigationTitle("SwiftSSH")
        }
    }

    private func countRow(_ title: String, symbol: String, count: Int) -> some View {
        LabeledContent {
            Text("\(count)")
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    /// Plain-language sync status.
    static func status(of phase: SyncCoordinator.Phase) -> String {
        switch phase {
        case .notConfigured: "Not set up"
        case .needsVault(_), .locked: "Needs the vault passphrase"
        case .idle: "Up to date"
        case .syncing: "Syncing\u{2026}"
        case .offline(let reason): "Offline: \(reason)"
        case .failed(let reason): reason
        }
    }
}
