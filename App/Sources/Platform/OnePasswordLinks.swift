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
    /// Where the checklist sends the user inside 1Password.
    static let developerSettingsPath = "Settings \u{2192} Developer"
    /// "Open 1Password Developer Settings". The Developer pane only shows while an account is selected
    /// at the top of 1Password's sidebar; if the link can't be opened, the app opens 1Password instead.
    static let developerSettingsURL = URL(string: "onepassword://settings/developers")!
    /// "Download installer": the official 1Password CLI get-started page (install section).
    static let cliDownloadURL = URL(string: "https://developer.1password.com/docs/cli/get-started/")!
    /// "Open Privacy & Security": System Settings → Privacy & Security → Files & Folders, where macOS 27
    /// lists "Data shared by 1Password" per app (1Password's Group Container holds the agent socket).
    /// The anchor `Privacy_FilesAndFolders` is the Files & Folders pane's (found in System Settings'
    /// own strings); newer macOS also knows the form
    /// `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders`.
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders")!
    /// Homebrew on Apple silicon, then on Intel. "Install with Homebrew" shows only if one exists.
    static let homebrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    /// "Copy install command", and what the Homebrew install runs in Terminal (Homebrew finds the
    /// 1password-cli cask by its name).
    static let homebrewInstallArguments = ["install", "1password-cli"]
    static var homebrewInstallCommand: String {
        (["brew"] + homebrewInstallArguments).joined(separator: " ")
    }

    /// The agent socket as the shell sees it, for the key-install command (Terminal runs it, not the app).
    static let agentSocketShellPath = "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    /// Creates 1Password's SSH agent config file (which picks the vaults the agent offers) and opens it
    /// in TextEdit. Shown for the user to run in Terminal.
    static let agentConfigCommand = "mkdir -p ~/.config/1Password/ssh && touch ~/.config/1Password/ssh/agent.toml && open -e ~/.config/1Password/ssh/agent.toml"

    /// Example agent.toml: the Private vault plus one more.
    static let agentConfigExample = """
    [[ssh-keys]]
    vault = "Private"

    [[ssh-keys]]
    vault = "Your vault name"
    """
}
