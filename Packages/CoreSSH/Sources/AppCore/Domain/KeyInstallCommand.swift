import Foundation

/// The shell command that copies the 1Password agent's public keys into a server's `authorized_keys`.
public enum KeyInstallCommand {
    private static let head = "SSH_AUTH_SOCK=\"$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\" ssh-add -L | ssh -p "
    private static let tail = " 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"

    /// With a usable user and host the target is single-quoted after `--`; a missing, empty, dash-leading or
    /// control-character user or host gives the placeholder template. A port outside 1...65535 shows `PORT`.
    public static func make(port: Int?, user: String?, host: String?) -> String {
        let portText = port.flatMap { (1...65535).contains($0) ? String($0) : nil } ?? "PORT"
        guard let user = usable(user), let host = usable(host) else { return head + "PORT USER@HOST" + tail }
        let target = "'" + (user + "@" + host).replacingOccurrences(of: "'", with: "'\\''") + "'"
        return head + portText + " -- " + target + tail
    }

    private static func usable(_ text: String?) -> String? {
        guard let text, !text.isEmpty, !text.hasPrefix("-") else { return nil }
        for scalar in text.unicodeScalars where scalar.properties.generalCategory == .control { return nil }
        return text
    }
}
