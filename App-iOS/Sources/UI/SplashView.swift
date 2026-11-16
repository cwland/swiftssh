import SwiftUI
import SwiftSSHUI

/// The app logo, name and version on the navy background. Shown while the app opens (it matches
/// the launch screen, so there is no jump) and under the app lock.
struct SplashView<Accessory: View>: View {
    /// Shown under the version: a spinner while opening, the unlock button when locked.
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 14) {
            Image("AppLogo")
                .resizable()
                .frame(width: 120, height: 120)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text("SwiftSSH")
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.topBarForeground)
            Text("Version \(Self.version)")
                .font(.footnote)
                .foregroundStyle(Theme.topBarForeground.opacity(0.65))
            accessory
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.topBarBackground)
        .ignoresSafeArea()
    }

    /// "1.0.0 (12)": the marketing version and build number.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
