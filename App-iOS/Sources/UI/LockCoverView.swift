import SwiftUI
import AppCore
import SwiftSSHUI

/// Covers the app while it is locked, and in the app switcher snapshot while the lock is on.
struct LockCoverView: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Theme.topBarForeground)
                .accessibilityHidden(true)
            Text("SwiftSSH")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.topBarForeground)
            if lock.isLocked {
                if let message = lock.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(Theme.topBarForeground.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock with \(DeviceAuthenticator.biometryName)", systemImage: "lock.open.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(lock.isAuthenticating)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.topBarBackground)
        .ignoresSafeArea()
    }
}
