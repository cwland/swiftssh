import SwiftUI
import AppCore
import SwiftSSHUI

/// Snippets from the Mac (read-only).
struct SnippetsScreen: View {
    let vault: LocalVault

    var body: some View {
        ContentUnavailableView("Snippets", systemImage: "text.alignleft")
            .navigationTitle("Snippets")
    }
}
