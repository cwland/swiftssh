import SwiftUI
import AppCore
import SwiftSSHUI

/// SSH keys imported on this device.
struct KeysScreen: View {
    let vault: LocalVault

    var body: some View {
        ContentUnavailableView("Keys", systemImage: "key")
            .navigationTitle("Keys")
    }
}
