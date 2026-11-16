import SwiftUI
import AppCore
import SwiftSSHUI

/// Loading → (vault problem) → join screen → the app, with the lock cover on top.
struct AppRootView: View {
    @Environment(IOSEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    /// Ask to unlock when the app becomes active at launch or after the background (not after
    /// the Face ID sheet itself, which only makes the app inactive for a moment).
    @State private var promptsOnActive = true

    var body: some View {
        ZStack {
            // While locked the app's views are taken out, not just covered: that closes any sheet
            // (sheets sit above the cover) and takes the keyboard away from the terminal, so nothing
            // can be read or typed into a session until the lock is opened.
            if !environment.appLock.isLocked {
                content
            }
            if environment.appLock.showsCover(isActive: scenePhase == .active) {
                LockCoverView(lock: environment.appLock)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: environment.appLock.isLocked)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .background:
                environment.didEnterBackground()
                promptsOnActive = true
            case .active:
                environment.didBecomeActive()
                if promptsOnActive {
                    promptsOnActive = false
                    if environment.appLock.isLocked {
                        Task { await environment.appLock.unlock() }
                    }
                }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch environment.state {
        case .loading:
            SplashView {
                ProgressView()
                    .tint(Theme.topBarForeground)
                    .accessibilityLabel("Opening SwiftSSH")
            }
        case .failed(let message):
            VaultProblemView(message: message) {
                Task { await environment.retry() }
            }
        case .ready:
            if environment.isJoined {
                RootView()
            } else if let join = environment.join {
                JoinView(form: join)
            }
        }
    }
}

/// The vault couldn't be opened.
struct VaultProblemView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("SwiftSSH Can\u{2019}t Open Its Data", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .background(Theme.contentBackground)
    }
}
