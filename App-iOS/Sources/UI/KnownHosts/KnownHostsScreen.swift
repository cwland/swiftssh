import SwiftUI
import AppCore
import SwiftSSHUI

/// The servers' keys this device and your Macs trust.
struct KnownHostsScreen: View {
    let vault: LocalVault

    var body: some View {
        ContentUnavailableView("Known Hosts", systemImage: "checkmark.shield")
            .navigationTitle("Known Hosts")
    }
}
