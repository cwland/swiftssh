import AppKit
import Observation
import AppCore
import CoreModels

/// OS badge logos and appearance from `~/Library/Application Support/TermiusReimagined/Badges/`:
/// `<name>.svg` or `<name>.png` (SVG preferred; names from `BadgeStyle.logoFileName(for:)`) and
/// `settings.json` (per-OS "show in white" and color, see `BadgeSettings`; local only).
///
/// Observable: every `BadgeView` reads through `shared`, so a change made in Settings → OS Icons
/// redraws every badge in the app at once. Files are read at launch and again whenever the
/// OS Icons pane opens, so logos dropped into the folder by hand are picked up then too.
/// A missing folder or file just means "no logo". The app never ships logo files.
@MainActor @Observable
final class BadgeLogoStore {
    static let shared = BadgeLogoStore(directory: BadgeLogoStore.directoryURL)

    @ObservationIgnored let directory: URL?
    private var logos: [OSBadge: NSImage] = [:]
    private(set) var settings = BadgeSettings()
    /// Why `settings.json` couldn't be written last time, nil after a successful write.
    private(set) var settingsSaveError: String?

    init(directory: URL?) {
        self.directory = directory
        reload()
    }

    // MARK: Reading

    /// The logo for `badge`, if there is a readable one.
    func logo(for badge: OSBadge?) -> NSImage? {
        badge.flatMap { logos[$0] }
    }

    func hasLogo(_ badge: OSBadge) -> Bool {
        logos[badge] != nil
    }

    /// Badge background "#RRGGBB": the Settings override or the standard color.
    func hexColor(for badge: OSBadge?) -> String {
        settings.hexColor(for: badge)
    }

    /// Whether the logo is drawn as a white template (true) or in its own colors.
    func showsInWhite(for badge: OSBadge?) -> Bool {
        settings.showsInWhite(for: badge)
    }

    /// True when Reset would change something (a logo file, a color or the white setting).
    func isCustomized(_ badge: OSBadge) -> Bool {
        hasLogo(badge) || settings.hasCustomAppearance(for: badge)
    }

    /// Reads every logo and `settings.json` from the folder again.
    func reload() {
        guard let directory else { return }
        var loaded: [OSBadge: NSImage] = [:]
        for badge in OSBadge.allCases {
            if let image = Self.loadLogo(for: badge, in: directory) {
                loaded[badge] = image
            }
        }
        logos = loaded
        settings = Self.loadSettings(in: directory)
    }

    // MARK: Changes from Settings

    func setShowsInWhite(_ showsInWhite: Bool, for badge: OSBadge) {
        guard showsInWhite != settings.showsInWhite(for: badge) else { return }
        settings.setShowsInWhite(showsInWhite, for: badge)
        saveSettings()
    }

    func setColor(_ hex: String, for badge: OSBadge) {
        guard BadgeColor.normalizedHex(hex) != settings.hexColor(for: badge) else { return }
        settings.setColor(hex, for: badge)
        saveSettings()
    }

    /// Decodes `data` as an image (nothing else is done with it), fits it into a square PNG and
    /// saves it as `<name>.png`, replacing any SVG or PNG of that name. `notAnImage` is thrown when
    /// the data doesn't decode.
    func install(imageData data: Data, for badge: OSBadge, notAnImage: BadgeImageError) throws(BadgeImageError) {
        guard let directory else {
            throw .couldNotSave("the Application Support folder could not be found")
        }
        guard let image = NSImage(data: data), image.isValid,
              let png = BadgeImageRenderer.pngData(from: image) else {
            throw notAnImage
        }
        let fileManager = FileManager.default
        let installedName = BadgeStyle.installedLogoFileName(for: badge)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(installedName), options: .atomic)
            // An SVG of the same name would win over the new PNG, so it goes.
            for name in BadgeStyle.logoFileNames(for: badge) where name != installedName {
                let url = directory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        } catch {
            logos[badge] = Self.loadLogo(for: badge, in: directory)
            throw .couldNotSave(error.localizedDescription)
        }
        logos[badge] = Self.loadLogo(for: badge, in: directory)
    }

    /// Back to the standard symbol, color and white drawing. Logo files are moved to the Trash
    /// (so a hand-made logo can be recovered). Returns a message when a file couldn't be removed.
    func reset(_ badge: OSBadge) -> String? {
        var failure: String?
        if let directory {
            let fileManager = FileManager.default
            for name in BadgeStyle.logoFileNames(for: badge) {
                let url = directory.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                do {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    do {
                        try fileManager.removeItem(at: url)
                    } catch {
                        failure = "Couldn't remove \(name): \(error.localizedDescription)"
                    }
                }
            }
            logos[badge] = Self.loadLogo(for: badge, in: directory)
        }
        if settings.hasCustomAppearance(for: badge) {
            settings.reset(badge)
            saveSettings()
            if failure == nil {
                failure = settingsSaveError
            }
        }
        return failure
    }

    // MARK: Files

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

    private func saveSettings() {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try settings.jsonData().write(to: directory.appendingPathComponent(BadgeStyle.settingsFileName),
                                          options: .atomic)
            settingsSaveError = nil
        } catch {
            settingsSaveError = "Couldn't save the OS icon settings: \(error.localizedDescription)"
            NSLog("Could not save badge settings: %@", error.localizedDescription)
        }
    }

    private static func loadSettings(in directory: URL) -> BadgeSettings {
        let url = directory.appendingPathComponent(BadgeStyle.settingsFileName)
        guard let data = try? Data(contentsOf: url) else { return BadgeSettings() }
        do {
            return try BadgeSettings(jsonData: data)
        } catch {
            // Left as is on disk until the next change in Settings rewrites it.
            NSLog("Ignoring unreadable badge settings: %@", error.localizedDescription)
            return BadgeSettings()
        }
    }

    private static func loadLogo(for badge: OSBadge, in directory: URL) -> NSImage? {
        for name in BadgeStyle.logoFileNames(for: badge) {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // NSImage reads SVG natively on macOS 14 and later. Template or not is decided when
            // drawing (BadgeView), from the "show in white" setting.
            guard let image = NSImage(contentsOf: url), image.isValid,
                  image.size.width > 0, image.size.height > 0 else { continue }
            return image
        }
        return nil
    }
}
