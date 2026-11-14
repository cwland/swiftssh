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

    /// Folder (inside Application Support/TermiusReimagined) holding user-supplied logos.
    public static let logoFolderName = "Badges"

    /// Logo file extensions, in order of preference.
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

    /// Rows of Settings → OS Icons, in catalog order.
    public static var settingsOrder: [OSBadge] {
        OSCatalog.shared.entries.map(\.id)
    }

    /// Row name in Settings → OS Icons.
    public static func settingsName(for badge: OSBadge) -> String {
        displayName(for: badge)
    }
}
