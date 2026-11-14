import AppKit
import Observation
import AppCore
import CoreModels

/// OS badge images and settings from `~/Library/Application Support/TermiusReimagined/Badges/`:
/// `<id>.svg` or `<id>.png` (the newer one wins; ids from the bundled `OSCatalog`) and `settings.json`
/// (per-OS "show in white", color, icon link and image source; see `BadgeSettings`; local only).
///
/// Observable: every `BadgeView` reads through `shared`, so a new image, a finished download,
/// Reset, the white switch or a color change redraws every badge in the app at once.
///
/// Also the download service for Settings → OS Icons: per-row progress and inline errors,
/// Download All Defaults (four at a time), and the image pipeline (download → decode and redraw
/// off the main actor → PNG in the Badges folder). On failure the previous image stays.
/// Nothing is ever downloaded except on an explicit action in Settings.
///
/// Files are read at launch and again whenever the OS Icons pane opens, so logos dropped into the
/// folder by hand are picked up then too. A missing folder or file just means "no logo".
@MainActor @Observable
final class BadgeLogoStore {
    static let shared = BadgeLogoStore(directory: BadgeLogoStore.directoryURL)

    /// What a Settings row is doing.
    enum RowStatus: Equatable {
        case working(String)
        case failed(String)
    }

    /// Progress of Download All Defaults.
    struct BatchProgress: Equatable {
        var total: Int
        var finished: Int
    }

    @ObservationIgnored let directory: URL?
    @ObservationIgnored let catalog = OSCatalog.shared
    private var logos: [OSBadge: NSImage] = [:]
    private(set) var settings = BadgeSettings()
    /// Why `settings.json` couldn't be written last time, nil after a successful write.
    private(set) var settingsSaveError: String?
    private(set) var rowStatus: [OSBadge: RowStatus] = [:]
    private(set) var batch: BatchProgress?
    /// A short note after Download All Defaults (e.g. nothing to do, or how many failed).
    private(set) var batchMessage: String?

    /// In-memory settings not yet on disk (a pending debounced write, or a failed one).
    @ObservationIgnored private var hasUnsavedSettings = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rowTasks: [OSBadge: Task<Void, Never>] = [:]
    /// The newest job per row; an older job that finishes later is ignored.
    @ObservationIgnored private var rowTokens: [OSBadge: UUID] = [:]
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var batchFailures = 0
    /// Tokens of the jobs Download All Defaults started; only their failures count in its summary.
    @ObservationIgnored private var batchTokens: Set<UUID> = []
    /// Per badge id: the modification date of the `<id>.png` our last download wrote. A logo whose
    /// file doesn't match wasn't (or is no longer) a plain download of its link.
    @ObservationIgnored private var downloadStamps: [String: Date] = [:]

    /// Color changes are written this long after the last change.
    static let colorSaveDelay: Duration = .milliseconds(300)
    static let waitingLabel = "Waiting…"
    /// Downloads running at once during Download All Defaults.
    static let batchConcurrency = 4

    init(directory: URL?) {
        self.directory = directory
        downloadStamps = Self.loadDownloadStamps(for: downloadStampsKey)
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

    /// The icon link shown in the row: the user's link or the catalog default.
    func link(for badge: OSBadge) -> String {
        settings.link(for: badge)
    }

    /// The link the current image was downloaded from (only while there is an image).
    func imageSource(for badge: OSBadge) -> String? {
        hasLogo(badge) ? settings.imageSource(for: badge) : nil
    }

    func status(for badge: OSBadge) -> RowStatus? {
        rowStatus[badge]
    }

    func isWorking(_ badge: OSBadge) -> Bool {
        if case .working = rowStatus[badge] { return true }
        return false
    }

    /// True when Reset would change something (a logo file, a color, white, a link or a source).
    func isCustomized(_ badge: OSBadge) -> Bool {
        hasLogo(badge) || settings.hasCustomSettings(for: badge)
    }

    /// Reads every logo (after moving old file names to catalog ids) and `settings.json` again.
    /// Settings changed in memory but not yet written (pending, or a failed write) are kept and
    /// written now instead of being replaced by the file.
    func reload() {
        guard let directory else { return }
        Self.migrateLegacyFiles(in: directory)
        var loaded: [OSBadge: NSImage] = [:]
        for entry in catalog.entries {
            if let image = Self.loadLogo(for: entry.id, in: directory) {
                loaded[entry.id] = image
            }
        }
        logos = loaded
        if hasUnsavedSettings {
            saveSettingsNow()
        } else {
            settings = Self.loadSettings(in: directory)
        }
    }

    // MARK: Appearance

    func setShowsInWhite(_ showsInWhite: Bool, for badge: OSBadge) {
        guard showsInWhite != settings.showsInWhite(for: badge) else { return }
        settings.setShowsInWhite(showsInWhite, for: badge)
        saveSettingsNow()
    }

    /// Updates every badge at once; the file is written once the color stops changing.
    func setColor(_ hex: String, for badge: OSBadge) {
        guard BadgeColor.normalizedHex(hex) != settings.hexColor(for: badge) else { return }
        settings.setColor(hex, for: badge)
        scheduleSave()
    }

    /// Writes a pending color change now (Settings closing, app quitting).
    func flushPendingSave() {
        guard saveTask != nil || hasUnsavedSettings else { return }
        saveSettingsNow()
    }

    // MARK: Links and downloads

    /// The user edited the row's link (Return or leaving the field): saves it and downloads it at
    /// once. An invalid link shows its error on the row and changes nothing.
    func commitLink(_ text: String, for badge: OSBadge) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != settings.link(for: badge) else { return }
        let url: URL
        do throws(BadgeImageError) {
            url = try settings.setLink(trimmed, for: badge)
        } catch {
            rowStatus[badge] = .failed(error.message)
            return
        }
        saveSettingsNow()
        startDownload(badge, from: url)
    }

    /// Download button: fetches the row's current link.
    func download(_ badge: OSBadge) {
        let url: URL
        do throws(BadgeImageError) {
            url = try BadgeImageRules.webURL(from: settings.link(for: badge))
        } catch {
            rowStatus[badge] = .failed(error.message)
            return
        }
        startDownload(badge, from: url)
    }

    /// Downloads the default icon of every entry that has no image yet, or whose image came from
    /// its default link. Entries with a custom link or a chosen image are left alone.
    func downloadAllDefaults() {
        guard batch == nil else { return }
        batchMessage = nil
        var targets: [(OSBadge, URL)] = []
        for entry in catalog.entries where settings.wantsDefaultDownload(entry.id, hasLogo: hasLogo(entry.id)) {
            // A logo that isn't the file a download of this link wrote (dropped in by hand, chosen,
            // or changed since) is never replaced by a batch.
            if hasLogo(entry.id), !ownsDownloadedLogo(entry.id) { continue }
            guard !isWorking(entry.id), let url = try? BadgeImageRules.webURL(from: entry.defaultLink) else { continue }
            targets.append((entry.id, url))
        }
        guard !targets.isEmpty else {
            batchMessage = "Nothing to download: every entry has its own image or link."
            return
        }
        batch = BatchProgress(total: targets.count, finished: 0)
        batchFailures = 0
        batchTokens = []
        for (badge, _) in targets {
            rowStatus[badge] = .working(Self.waitingLabel)
        }
        batchTask = Task { [weak self] in
            guard let self else { return }
            for start in stride(from: 0, to: targets.count, by: Self.batchConcurrency) {
                if Task.isCancelled { break }
                let chunk = Array(targets[start..<min(start + Self.batchConcurrency, targets.count)])
                await withTaskGroup(of: Void.self) { group in
                    for (badge, url) in chunk {
                        group.addTask {
                            await self.runBatchItem(badge, from: url)
                        }
                    }
                }
            }
            self.finishBatch()
        }
    }

    /// Stops Download All Defaults; finished rows keep their new images.
    func cancelBatch() {
        batchTask?.cancel()
    }

    /// Clears a row's error (e.g. when the user edits the link again).
    func clearError(for badge: OSBadge) {
        if case .failed = rowStatus[badge] {
            rowStatus[badge] = nil
        }
    }

    /// Choose Image…: reads, checks and installs a local file.
    func installFile(at url: URL, for badge: OSBadge) {
        rowTasks[badge]?.cancel()
        let token = beginJob(badge, label: "Importing…")
        rowTasks[badge] = Task { [weak self] in
            let result = await BadgeImageRenderer.renderFile(at: url)
            self?.finishJob(badge, token: token, result: result, source: nil)
        }
    }

    private func startDownload(_ badge: OSBadge, from url: URL) {
        rowTasks[badge]?.cancel()
        // Begun here, not inside the task: a cancelled older job finishing before the new task
        // starts must see the new token and leave this row's task handle alone.
        let token = beginJob(badge, label: "Downloading…")
        rowTasks[badge] = Task { [weak self] in
            await self?.runDownload(badge, from: url, token: token)
        }
    }

    private func runDownload(_ badge: OSBadge, from url: URL, token: UUID) async {
        let result: Result<Data, BadgeImageError>
        do throws(BadgeImageError) {
            let data = try await BadgeImageDownloader.download(from: url)
            result = await BadgeImageRenderer.render(data, notAnImage: .notAnImage)
        } catch {
            result = .failure(error)
        }
        finishJob(badge, token: token, result: result, source: url.absoluteString)
    }

    /// Marks the row busy; its token supersedes any earlier job on the row (whose result is then
    /// ignored). Callers cancel the earlier task first.
    private func beginJob(_ badge: OSBadge, label: String) -> UUID {
        let token = UUID()
        rowTokens[badge] = token
        rowStatus[badge] = .working(label)
        return token
    }

    /// Installs a rendered PNG, or shows why it failed; the previous image stays on failure.
    private func finishJob(_ badge: OSBadge, token: UUID, result: Result<Data, BadgeImageError>, source: String?) {
        guard rowTokens[badge] == token else { return } // a newer job (or Reset) took over
        rowTokens[badge] = nil
        defer { batchTokens.remove(token) }
        rowTasks[badge] = nil
        if Task.isCancelled {
            rowStatus[badge] = nil
            return
        }
        switch result {
        case .success(let png):
            do throws(BadgeImageError) {
                try writeInstalledLogo(png, for: badge, fromDownload: source != nil)
                rowStatus[badge] = nil
                recordSource(source, for: badge)
            } catch {
                if case .oldFileNotRemoved = error {
                    recordSource(source, for: badge) // the new image is shown
                }
                rowStatus[badge] = .failed(error.message)
                if batchTokens.remove(token) != nil { batchFailures += 1 }
            }
        case .failure(let error):
            rowStatus[badge] = .failed(error.message)
            if batchTokens.remove(token) != nil { batchFailures += 1 }
        }
    }

    private func recordSource(_ source: String?, for badge: OSBadge) {
        guard settings.imageSource(for: badge) != source else { return }
        settings.setImageSource(source, for: badge)
        saveSettingsNow()
    }

    /// One Download All Defaults item; skipped when the row was taken over meanwhile (its own
    /// Download, Choose Image… or Reset).
    private func runBatchItem(_ badge: OSBadge, from url: URL) async {
        if rowStatus[badge] == .working(Self.waitingLabel), !Task.isCancelled {
            let token = beginJob(badge, label: "Downloading…")
            batchTokens.insert(token)
            await runDownload(badge, from: url, token: token)
        }
        batch?.finished += 1
    }

    private func finishBatch() {
        let wasCancelled = batchTask?.isCancelled ?? false
        // Rows that never started (cancelled) stop waiting.
        for (badge, status) in rowStatus where status == .working(Self.waitingLabel) && rowTokens[badge] == nil {
            rowStatus[badge] = nil
        }
        if wasCancelled {
            batchMessage = "Stopped."
        } else if batchFailures > 0 {
            batchMessage = batchFailures == 1 ? "1 icon couldn't be downloaded; see its row."
                : "\(batchFailures) icons couldn't be downloaded; see their rows."
        } else {
            batchMessage = nil
        }
        batch = nil
        batchTask = nil
        batchTokens = []
    }

    // MARK: Files

    /// Writes `<id>.png`, shows it, then moves an older `<id>.svg` to the Trash. An existing
    /// `<id>.png` that isn't our own earlier download (a hand-made or chosen logo) is moved to the
    /// Trash first; nothing is ever deleted outright. The new image is written to a temporary file
    /// first, so a failure before the swap leaves the old image untouched. If the `.svg` can't be
    /// trashed the new image is still saved and shown (and, being the newest file, keeps winning on
    /// later reads); the error says so.
    private func writeInstalledLogo(_ png: Data, for badge: OSBadge, fromDownload: Bool) throws(BadgeImageError) {
        guard let directory else {
            throw .couldNotSave("the Application Support folder could not be found")
        }
        guard let installedName = BadgeStyle.installedLogoFileName(for: badge) else {
            throw .couldNotSave("this OS has no file name")
        }
        let fileManager = FileManager.default
        let target = directory.appendingPathComponent(installedName)
        let temporary = directory.appendingPathComponent(".\(installedName).\(UUID().uuidString).tmp")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: target.path), !ownsDownloadedLogo(badge) {
                try fileManager.trashItem(at: target, resultingItemURL: nil)
            }
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: temporary) // our own temporary file
            throw .couldNotSave(error.localizedDescription)
        }
        if fromDownload {
            downloadStamps[badge.rawValue] = Self.modificationDate(of: target)
        } else {
            downloadStamps[badge.rawValue] = nil
        }
        persistDownloadStamps()
        logos[badge] = NSImage(data: png) ?? Self.loadLogo(for: badge, in: directory)
        for name in BadgeStyle.logoFileNames(for: badge) where name != installedName {
            let url = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw .oldFileNotRemoved(name: name, reason: error.localizedDescription)
            }
        }
    }

    /// True when the badge's logo is exactly the file one of our downloads wrote: the only logo
    /// file, with the modification date recorded at that write. A logo dropped in by hand (even
    /// over a download), a chosen image or a leftover `.svg` makes this false, so such a logo is
    /// never replaced by Download All Defaults.
    private func ownsDownloadedLogo(_ badge: OSBadge) -> Bool {
        guard let directory, let installedName = BadgeStyle.installedLogoFileName(for: badge),
              let stamp = downloadStamps[badge.rawValue] else { return false }
        let fileManager = FileManager.default
        for name in BadgeStyle.logoFileNames(for: badge) where name != installedName {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(name).path) { return false }
        }
        return Self.modificationDate(of: directory.appendingPathComponent(installedName)) == stamp
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private var downloadStampsKey: String {
        "BadgeLogoStore.downloadStamps." + (directory?.path ?? "")
    }

    /// Reads the stamps saved by earlier launches (modification date per badge id, in seconds).
    private static func loadDownloadStamps(for key: String) -> [String: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return stored.mapValues { Date(timeIntervalSinceReferenceDate: $0) }
    }

    private func persistDownloadStamps() {
        let stored = downloadStamps.mapValues { $0.timeIntervalSinceReferenceDate }
        UserDefaults.standard.set(stored, forKey: downloadStampsKey)
    }

    /// Back to the standard symbol, color, white drawing and default link. Logo files are moved to
    /// the Trash (so a hand-made logo can be recovered). Returns a message when a file couldn't be
    /// removed or the settings couldn't be saved.
    func reset(_ badge: OSBadge) -> String? {
        rowTasks[badge]?.cancel()
        rowTasks[badge] = nil
        rowTokens[badge] = nil
        rowStatus[badge] = nil
        var failure: String?
        if let directory {
            let fileManager = FileManager.default
            for name in BadgeStyle.logoFileNames(for: badge) {
                let url = directory.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                do {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    failure = "Couldn't move \(name) to the Trash: \(error.localizedDescription)"
                }
            }
            downloadStamps[badge.rawValue] = nil
            persistDownloadStamps()
            logos[badge] = Self.loadLogo(for: badge, in: directory)
        }
        if settings.hasCustomSettings(for: badge) {
            settings.reset(badge)
            saveSettingsNow()
            if failure == nil {
                failure = settingsSaveError
            }
        }
        return failure
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

    private func scheduleSave() {
        hasUnsavedSettings = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.colorSaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveSettingsNow()
        }
    }

    private func saveSettingsNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try settings.jsonData().write(to: directory.appendingPathComponent(BadgeStyle.settingsFileName),
                                          options: .atomic)
            settingsSaveError = nil
            hasUnsavedSettings = false
        } catch {
            hasUnsavedSettings = true
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

    /// Moves logos saved under names from before the catalog (`raspberry-pi.*`) to their ids.
    private static func migrateLegacyFiles(in directory: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for rename in BadgeStyle.logoFileMigrations(existingFileNames: Set(names)) {
            do {
                try fileManager.moveItem(at: directory.appendingPathComponent(rename.from),
                                         to: directory.appendingPathComponent(rename.to))
            } catch {
                NSLog("Could not rename badge logo %@: %@", rename.from, error.localizedDescription)
            }
        }
    }

    /// The newest of `<id>.svg` / `<id>.png` that decodes (see `BadgeStyle.logoFilesInReadOrder`).
    private static func loadLogo(for badge: OSBadge, in directory: URL) -> NSImage? {
        var modified: [String: Date] = [:]
        for name in BadgeStyle.logoFileNames(for: badge) {
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            modified[name] = values.contentModificationDate ?? .distantPast
        }
        for name in BadgeStyle.logoFilesInReadOrder(for: badge, modified: modified) {
            let url = directory.appendingPathComponent(name)
            // NSImage reads SVG natively on macOS 14 and later. Template or not is decided when
            // drawing (BadgeView), from the "show in white" setting.
            guard let image = NSImage(contentsOf: url), image.isValid,
                  image.size.width > 0, image.size.height > 0 else { continue }
            return image
        }
        return nil
    }
}
