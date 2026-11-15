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
    /// "Open Privacy Settings": System Settings → Privacy & Security → Files & Folders, where macOS 27
    /// lists "Data shared by 1Password" per app (1Password's Group Container holds the agent socket).
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    /// Homebrew on Apple silicon, then on Intel. "Install with Homebrew" shows only if one exists.
    static let homebrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    /// "Copy command", and what the Homebrew install runs in Terminal.
    static let homebrewInstallArguments = ["install", "--cask", "1password-cli"]
    static var homebrewInstallCommand: String {
        (["brew"] + homebrewInstallArguments).joined(separator: " ")
    }

    /// The agent socket as the shell sees it, for the key-install command (Terminal runs it, not the app).
    static let agentSocketShellPath = "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    /// Puts the public keys 1Password's agent offers into `~/.ssh/authorized_keys` on a server.
    /// With no arguments it is the template with PORT, USER and HOST to replace by hand.
    static func keyInstallCommand(port: String = "PORT", user: String? = "USER", host: String = "HOST") -> String {
        let target = user.map { "\($0)@\(host)" } ?? host
        return "SSH_AUTH_SOCK=\"\(agentSocketShellPath)\" ssh-add -L | ssh -p \(shellWord(port)) \(shellWord(target)) "
            + "'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
    }

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

    /// Bare when it holds only safe characters, else single-quoted for zsh.
    static func shellWord(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+:,./_-")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
