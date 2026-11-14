import CoreModels
import Foundation

/// Maps the output of `probeCommand` to an `OSBadge`.
public enum OSDetector {
    public static let probeCommand = "uname -s; cat /etc/os-release 2>/dev/null; cat /etc/synoinfo.conf 2>/dev/null | head -1"

    public static func badge(fromProbeOutput output: String) -> OSBadge? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, !first.isEmpty else { return nil }

        // Synology: synoinfo.conf content (or a synology marker) appears in the output.
        if lines.contains(where: { $0.lowercased().contains("synology") || $0.hasPrefix("upnpmodelname=") }) {
            return .synology
        }

        var id: String?
        var idLike: [String] = []
        for line in lines {
            if line.hasPrefix("ID="), id == nil { id = unquote(String(line.dropFirst(3))).lowercased() }
            else if line.hasPrefix("ID_LIKE=") {
                idLike = unquote(String(line.dropFirst(8))).lowercased()
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
        }

        if id == "haos" { return .homeAssistant }
        if let id, let badge = map(id) { return badge }
        for like in idLike { if let badge = map(like) { return badge } }

        switch first.lowercased() {
        case "darwin": return .macOS
        case "freebsd": return .freeBSD
        case "linux": return .linux
        default: return nil
        }
    }

    private static func map(_ id: String) -> OSBadge? {
        switch id {
        case "ubuntu": return .ubuntu
        case "debian": return .debian
        case "raspbian": return .raspberryPiOS
        case "fedora": return .fedora
        case "rhel", "centos", "rocky", "almalinux": return .rhel
        case "alpine": return .alpine
        case "arch": return .arch
        default: return nil
        }
    }

    private static func unquote(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let f = v.first, let l = v.last, f == l, f == "\"" || f == "'" {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}
