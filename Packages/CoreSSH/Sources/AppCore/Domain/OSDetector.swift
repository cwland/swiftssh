import CoreModels
import Foundation

/// Finds a host's OS (a catalog id) from the output of `probeCommand`, run once on a new session.
///
/// Precedence: Windows, then marker lines (appliance files; Docker last; the Home Assistant add-on is a container too), then os-release `ID`,
/// then `ID_LIKE`, then `uname -s`. Devices without a POSIX shell (MikroTik, Cisco, Fortinet…)
/// print an error instead, which matches nothing, so they keep whatever badge they had.
public enum OSDetector {
    /// Marker lines look like `TR_OS=<catalog id>`.
    public static let markerPrefix = "TR_OS="
    /// The prefix the probe printed before the catalog; still read.
    static let legacyMarkerPrefix = "TR_OS_MARKER="

    /// Shell checks that print a marker line; each is silent when it doesn't match.
    static let markerChecks: [(check: String, id: String)] = [
        ("[ -e /etc/synoinfo.conf ]", "synology"),           // DSM has no os-release
        ("[ -e /etc/unraid-version ]", "unraid"),
        ("grep -qs TrueNAS /etc/version", "truenas"),
        ("command -v midclt >/dev/null 2>&1", "truenas"),
        ("[ -e /etc/config/uLinux.conf ]", "qnap"),
        ("[ -e /etc/openmediavault ]", "openmediavault"),
        ("[ -e /etc/casaos ]", "casaos"),
        ("command -v casaos >/dev/null 2>&1", "casaos"),
        ("[ -e /home/umbrel/umbrel ]", "umbrel"),
        ("[ -e /usr/bin/pveversion ]", "proxmox"),
        ("[ -e /etc/xcp-ng-release ]", "xcpng"),
        ("grep -qs pfSense /etc/platform", "pfsense"),
        ("[ -e /usr/local/opnsense ]", "opnsense"),
        ("[ -e /etc/rpi-issue ]", "raspbian"),               // Raspberry Pi OS 64-bit says ID=debian
        ("[ -e /config/configuration.yaml -o -e /homeassistant/configuration.yaml ]", "home-assistant"), // SSH add-on
        ("[ -e /.dockerenv ]", "docker"),
    ]

    /// One line for every shell the remote may start:
    /// - POSIX sh, bash, zsh, csh/tcsh, fish: the first echo prints `TR_OS_ENV=%OS%` literally,
    ///   then `sh -c` runs the probe in a known shell. The inner script has no `$`, `%`, `!`,
    ///   backticks or quotes, so neither csh nor cmd.exe can expand or end it. Every check is
    ///   silent when it fails (stderr goes to /dev/null or nothing writes it) and `true` ends it,
    ///   so the exit status is 0. No sudo, nothing written.
    /// - Windows cmd.exe (OpenSSH's default): `echo` prints the rest of the line with `%OS%`
    ///   expanded to `Windows_NT`; the quoted script is just text to it and nothing else runs.
    ///   `followUpCommand(forProbeOutput:)` then asks for the build (Windows 11 vs 10, Server).
    public static let probeCommand: String = {
        let inner = ["uname -s", "cat /etc/os-release 2>/dev/null"]
            + markerChecks.map { "\($0.check) && echo \(markerPrefix)\($0.id)" }
            + ["true"]
        return "echo TR_OS_ENV=%OS%; sh -c \"" + inner.joined(separator: "; ") + "\""
    }()

    /// Marker ids, most specific first; Docker only when nothing else matched.
    static let markerPrecedence: [OSBadge] = [
        .truenas, .synology, .qnap, .unraid, .openmediavault, .proxmox, .xcpng, .pfsense, .opnsense,
        .umbrel, .casaos, .raspbian, .homeAssistant, .docker,
    ]

    /// os-release `ID` / `ID_LIKE` values and their catalog ids.
    static let osReleaseIDs: [String: OSBadge] = [
        "ubuntu": .ubuntu, "debian": .debian, "rhel": .rhel, "fedora": .fedora, "arch": .arch,
        "almalinux": .almalinux, "rocky": .rocky, "centos": .centos, "alpine": .alpine,
        "opensuse": .opensuse, "sles": .opensuse, "sled": .opensuse, "suse": .opensuse,
        "linuxmint": .linuxmint, "kali": .kali, "manjaro": .manjaro, "manjaro-arm": .manjaro,
        "gentoo": .gentoo, "nixos": .nixos, "pop": .pop, "raspbian": .raspbian,
        "ol": .oracle, "amzn": .amzn, "openwrt": .openwrt, "lede": .openwrt, "vyos": .vyos,
        "xenenterprise": .xcpng, "haos": .homeAssistant,
    ]

    /// `uname -s` values and their catalog ids.
    static let unameNames: [String: OSBadge] = [
        "darwin": .macos, "freebsd": .freebsd, "openbsd": .openbsd, "netbsd": .netbsd,
        "vmkernel": .vmware, "linux": .linux,
    ]

    /// Every id a probe can produce.
    public static var detectableBadges: Set<OSBadge> {
        Set(markerPrecedence).union(osReleaseIDs.values).union(unameNames.values).union([.windows, .windows10])
    }

    public static func badge(fromProbeOutput output: String) -> OSBadge? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Windows: cmd.exe expanded %OS% (plus the follow-up's `ver` and InstallationType), or `ver` output.
        if lines.contains(where: { $0.hasPrefix(windowsEnvLine) || $0.hasPrefix("Microsoft Windows") }) {
            return windows(build: lines.lazy.compactMap(verBuild).first, isServer: lines.contains(where: isServerLine))
        }

        let markers = Set(lines.compactMap { line -> OSBadge? in
            for prefix in [markerPrefix, legacyMarkerPrefix] where line.hasPrefix(prefix) {
                return OSBadge(rawValue: String(line.dropFirst(prefix.count)))
            }
            return nil
        })
        if let marker = markerPrecedence.first(where: markers.contains) {
            return marker
        }

        var id: String?
        var idLike: [String] = []
        var uname: String?
        for line in lines {
            if line.hasPrefix("ID=") {
                if id == nil { id = unquote(String(line.dropFirst(3))).lowercased() }
            } else if line.hasPrefix("ID_LIKE=") {
                idLike = unquote(String(line.dropFirst(8))).lowercased()
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            } else if uname == nil, !line.contains("=") {
                uname = line
            }
        }

        if let id, let badge = osReleaseID(id) { return badge }
        for like in idLike { if let badge = osReleaseID(like) { return badge } }

        guard let uname = uname?.lowercased() else { return nil }
        if let badge = unameNames[uname] { return badge }
        // Git for Windows, MSYS2 and Cygwin shells: "MINGW64_NT-10.0-22631" carries the build.
        if ["mingw", "msys_nt", "cygwin_nt"].contains(where: uname.hasPrefix) {
            let build = uname.split(separator: "-").last.flatMap { Int($0) }
            return windows(build: build, isServer: false)
        }
        // An unknown kernel name is not a known OS. (`linux` with any os-release ID, known or not,
        // was handled by the table above, so there is no generic-Linux fallback here.)
        return nil
    }

    // MARK: Windows

    static let windowsEnvLine = "TR_OS_ENV=Windows_NT"

    /// Builds from this one on are Windows 11 (and Server 2025); older client builds are Windows 10.
    public static let firstWindows11Build = 22000

    /// Run only after the probe came back from cmd.exe (it then knows nothing but "Windows"):
    /// `ver` gives the build, the registry's InstallationType tells Server from Client. Both only read.
    public static let windowsVersionCommand =
        #"ver & reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v InstallationType"#

    /// A second command to run when the probe output alone can't decide, else nil.
    public static func followUpCommand(forProbeOutput output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.hasPrefix(windowsEnvLine) }),
              !lines.contains(where: { verBuild($0) != nil }) else { return nil }
        return windowsVersionCommand
    }

    /// Server (any build) and Windows 11 → "windows"; an older client build → "windows-10";
    /// an unknown build → "windows".
    private static func windows(build: Int?, isServer: Bool) -> OSBadge {
        guard !isServer, let build, build < firstWindows11Build else { return .windows }
        return .windows10
    }

    /// The build in "Microsoft Windows [Version 10.0.22631.4317]" (any language): the third
    /// number of the bracketed version.
    private static func verBuild(_ line: String) -> Int? {
        guard line.hasPrefix("Microsoft Windows"), let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]") else { return nil }
        guard let version = line[line.index(after: open)..<close].split(separator: " ").last else { return nil }
        let parts = version.split(separator: ".")
        return parts.count >= 3 ? Int(parts[2]) : nil
    }

    /// `    InstallationType    REG_SZ    Server` (or "Server Core").
    private static func isServerLine(_ line: String) -> Bool {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return words.count >= 3 && words[0] == "InstallationType" && words[1] == "REG_SZ" && words[2] == "Server"
    }

    private static func osReleaseID(_ id: String) -> OSBadge? {
        if let badge = osReleaseIDs[id] { return badge }
        if id.hasPrefix("opensuse") { return .opensuse }   // opensuse-leap, -tumbleweed, -microos…
        return nil
    }

    private static func unquote(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let f = v.first, let l = v.last, f == l, f == "\"" || f == "'" {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}
