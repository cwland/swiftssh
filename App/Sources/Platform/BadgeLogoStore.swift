import AppKit
import AppCore
import CoreModels

/// Optional user-supplied OS logos from `~/Library/Application Support/TermiusReimagined/Badges/`,
/// named `<name>.svg` or `<name>.png` (SVG preferred; names from `BadgeStyle.logoFileName(for:)`).
/// Read once per launch and cached; a missing folder or file just means "no logo".
/// The app never ships logo files.
@MainActor
final class BadgeLogoStore {
    static let shared = BadgeLogoStore(directory: BadgeLogoStore.directoryURL)

    private var logos: [OSBadge: NSImage] = [:]

    init(directory: URL?) {
        guard let directory else { return }
        for badge in OSBadge.allCases {
            if let image = Self.loadLogo(named: BadgeStyle.logoFileName(for: badge), in: directory) {
                logos[badge] = image
            }
        }
    }

    /// The logo for `badge`, if the user supplied a readable one.
    func logo(for badge: OSBadge?) -> NSImage? {
        badge.flatMap { logos[$0] }
    }

    /// `~/Library/Application Support/TermiusReimagined/Badges`, nil if Application Support is unknown.
    static var directoryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TermiusReimagined", isDirectory: true)
            .appendingPathComponent(BadgeStyle.logoFolderName, isDirectory: true)
    }

    /// Creates the (empty) Badges folder so users can find where logos go. Called once at launch.
    static func createDirectoryIfNeeded() {
        guard let directory = directoryURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("Could not create the badge logo folder: %@", error.localizedDescription)
        }
    }

    private static func loadLogo(named name: String, in directory: URL) -> NSImage? {
        for fileExtension in BadgeStyle.logoFileExtensions {
            let url = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // NSImage reads SVG natively on macOS 14 and later.
            guard let image = NSImage(contentsOf: url), image.isValid,
                  image.size.width > 0, image.size.height > 0 else { continue }
            image.isTemplate = true
            return image
        }
        return nil
    }
}
