import Foundation

/// Every 1Password link, path and command the app uses, in one place so they're easy to adjust.
/// Values from the 1Password research report and interface amendments (2026-11-14).
enum OnePasswordLinks {
    /// 1Password 8 for Mac.
    static let appBundleID = "com.1password.1password"
    /// Where 1Password is normally installed; `appBundleID` finds it anywhere else.
    static let appPath = "/Applications/1Password.app"
    /// "Download 1Password".
    static let appDownloadURL = URL(string: "https://1password.com/downloads/mac")!
    /// 1Password documents no link into its Developer settings, so "Open 1Password" opens the app
    /// and the checklist names the place instead.
    static let developerSettingsPath = "Settings \u{2192} Developer"
    /// "Download installer": the official 1Password CLI get-started page (install section).
    static let cliDownloadURL = URL(string: "https://developer.1password.com/docs/cli/get-started/")!
    /// "Open Privacy Settings": System Settings → Privacy & Security → App Management, where macOS
    /// lets an app access other apps' data (1Password's Group Container holds the agent socket).
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
    /// Homebrew on Apple silicon, then on Intel. "Install with Homebrew" shows only if one exists.
    static let homebrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    /// "Copy command", and what the Homebrew install runs in Terminal.
    static let homebrewInstallArguments = ["install", "--cask", "1password-cli"]
    static var homebrewInstallCommand: String {
        (["brew"] + homebrewInstallArguments).joined(separator: " ")
    }
}
