import Foundation
import CoreModels

/// How an OS badge looks, from the bundled `OSCatalog`. Ids the catalog doesn't know (written
/// by a newer build, say) get the generic grey "terminal" badge and are named by their id.
public enum BadgeStyle {
    /// SF Symbol for a host's OS badge when there's no image.
    public static func symbol(for badge: OSBadge?) -> String {
        OSCatalog.shared.entry(for: badge)?.symbol ?? OSCatalog.shared.fallbackSymbol
    }

    /// Standard badge background as "#RRGGBB".
    public static func hexColor(for badge: OSBadge?) -> String {
        OSCatalog.shared.entry(for: badge)?.hexColor ?? OSCatalog.shared.fallbackHexColor
    }

    /// Catalog name; "Automatic" for no badge, the raw id for one the catalog doesn't know.
    public static func displayName(for badge: OSBadge?) -> String {
        guard let badge else { return "Automatic" }
        return OSCatalog.shared.entry(for: badge)?.name ?? badge.rawValue
    }

    /// Folder (inside Application Support/SwiftSSH) holding user-supplied logos.
    public static let logoFolderName = "Badges"

    /// Logo file extensions, in order of preference when two files are equally new.
    public static let logoFileExtensions = ["svg", "png"]

    /// Base file name (without extension) of the logo for a badge: its catalog id. nil for an id
    /// that isn't a safe file name (only possible for ids from outside the catalog).
    public static func logoFileName(for badge: OSBadge) -> String? {
        OSCatalog.isValidID(badge.rawValue) ? badge.rawValue : nil
    }

    /// File name of a logo installed from Settings (always PNG).
    public static func installedLogoFileName(for badge: OSBadge) -> String? {
        logoFileName(for: badge).map { $0 + ".png" }
    }

    /// Every file name the app reads as the logo for `badge`, in order of preference.
    public static func logoFileNames(for badge: OSBadge) -> [String] {
        guard let base = logoFileName(for: badge) else { return [] }
        return logoFileExtensions.map { base + "." + $0 }
    }

    /// The logo files of `badge` that exist (`modified`: file name → modification date), in the
    /// order to try them: newest first, so a just-installed PNG wins over a leftover SVG and an SVG
    /// dropped in later wins over an older PNG; on a tie, `logoFileExtensions` order (SVG first).
    public static func logoFilesInReadOrder(for badge: OSBadge, modified: [String: Date]) -> [String] {
        struct Candidate {
            let name: String
            let date: Date
            let order: Int
        }
        var candidates: [Candidate] = []
        for (order, name) in logoFileNames(for: badge).enumerated() {
            if let date = modified[name] {
                candidates.append(Candidate(name: name, date: date, order: order))
            }
        }
        candidates.sort { (lhs: Candidate, rhs: Candidate) -> Bool in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.order < rhs.order
        }
        return candidates.map { (candidate: Candidate) -> String in candidate.name }
    }

    /// Logo base names used before the catalog, and the badge they now belong to.
    public static let legacyLogoFileNames: [String: OSBadge] = ["raspberry-pi": .raspbian]

    public struct FileRename: Equatable, Sendable {
        public let from: String
        public let to: String
    }

    /// Renames that move logos saved under an old name to the catalog id, given the file names
    /// in the Badges folder. A badge that already has a logo under its new name keeps it, and the
    /// old files are then left alone.
    public static func logoFileMigrations(existingFileNames: Set<String>) -> [FileRename] {
        var renames: [FileRename] = []
        for (oldBase, badge) in legacyLogoFileNames.sorted(by: { $0.key < $1.key }) {
            let newNames = logoFileNames(for: badge)
            guard !newNames.contains(where: existingFileNames.contains) else { continue }
            for ext in logoFileExtensions where existingFileNames.contains(oldBase + "." + ext) {
                guard let base = logoFileName(for: badge) else { continue }
                renames.append(FileRename(from: oldBase + "." + ext, to: base + "." + ext))
            }
        }
        return renames
    }

    /// Per-OS appearance settings inside the Badges folder (see `BadgeSettings`).
    public static let settingsFileName = "settings.json"
}
