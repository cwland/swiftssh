import Foundation
import CoreModels

/// What the planner needs to know about one catalog entry; built by the app from its files and settings.
public struct BadgeFetchCandidate: Equatable, Sendable {
    public let badge: OSBadge
    /// Catalog default link ("" when there is none).
    public let defaultLink: String
    /// The user's own link, nil when using the default.
    public let customLink: String?
    public let hasLogo: Bool
    /// The link the current image was downloaded from.
    public let imageSource: String?
    /// True when the image is exactly the file one of our downloads wrote (not user-supplied).
    public let ownsDownloadedImage: Bool

    public init(badge: OSBadge, defaultLink: String, customLink: String?, hasLogo: Bool,
                imageSource: String?, ownsDownloadedImage: Bool) {
        self.badge = badge
        self.defaultLink = defaultLink
        self.customLink = customLink
        self.hasLogo = hasLogo
        self.imageSource = imageSource
        self.ownsDownloadedImage = ownsDownloadedImage
    }

    /// The link an automatic download uses.
    var targetLink: String { customLink ?? defaultLink }
}

/// Decides which OS icons to download automatically at launch.
/// First run: every entry with a link, except user-supplied images (chosen or hand-dropped files
/// are never replaced). Later launches: only entries with no image, or whose downloaded image came
/// from a link other than the current one. Failed downloads leave no image, so they are "missing"
/// again next launch.
public enum BadgeFetchPlanner {
    public struct Target: Equatable, Sendable {
        public let badge: OSBadge
        public let link: String
    }

    public static func plan(_ candidates: [BadgeFetchCandidate], isFirstRun: Bool) -> [Target] {
        var targets: [Target] = []
        for candidate in candidates {
            let link = candidate.targetLink
            guard !link.isEmpty else { continue }
            if candidate.hasLogo {
                guard candidate.ownsDownloadedImage else { continue }
                if !isFirstRun, candidate.imageSource == link { continue }
            }
            targets.append(Target(badge: candidate.badge, link: link))
        }
        return targets
    }
}
