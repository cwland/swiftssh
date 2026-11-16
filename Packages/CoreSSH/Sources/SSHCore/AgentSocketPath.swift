/// The check of a 1Password agent socket path before it is handed to system ssh (`IdentityAgent="…"`).
/// Platform-neutral, so shared settings code can use it on every platform (system ssh itself is Mac-only).
package enum AgentSocketPath {
    /// Why ssh can't be given `path` as `IdentityAgent="…"`, or nil when it can. The value is double-quoted
    /// (ssh has no escape for `"` or `\` inside it), must be one line without control characters, and ssh
    /// expands `${NAME}` from the environment (an error when unset). `%` is fine: it is written as `%%`.
    package static func problem(_ path: String) -> String? {
        let unusable = path.unicodeScalars.contains { scalar in
            scalar == "\"" || scalar == "\\" || scalar.properties.generalCategory == .control
        } || path.contains("${")
        return unusable ? problemMessage : nil
    }

    static let problemMessage = "The 1Password agent path contains characters ssh can't use."
}
