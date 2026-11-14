import Foundation

/// The version shown in the sidebar's bottom-left corner, e.g. "v0.3.1 (d59ec5f)".
/// The commit is stamped into Info.plist by the "Stamp git commit" build phase.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let commit = info["TRGitCommit"] as? String ?? "unknown"
        return "v\(version) (\(commit))"
    }
}
