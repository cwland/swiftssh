import SwiftUI

/// Fills a content area that a later milestone will implement.
struct PlaceholderView: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.contentBackground)
    }
}
