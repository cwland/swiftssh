import Foundation
import CoreModels

/// Why a badge image couldn't be used, with the message shown in Settings.
public enum BadgeImageError: Error, Equatable, Sendable {
    case notAWebLink
    case notAnImage
    case notAnImageFile
    case tooLarge
    case downloadFailed(String)
    case couldNotSave(String)

    public var message: String {
        switch self {
        case .notAWebLink: "Enter a link that starts with http:// or https://."
        case .notAnImage: "That link isn't an image."
        case .notAnImageFile: "That file isn't an image."
        case .tooLarge: "That image is larger than 2 MB."
        case .downloadFailed(let reason): "Couldn't download it: \(reason)"
        case .couldNotSave(let reason): "Couldn't save the image: \(reason)"
        }
    }
}

/// Rules for images chosen in Settings → OS Icons. Every source (file or link) is only ever
/// decoded as an image and redrawn into a square PNG; nothing in it is run or followed.
public enum BadgeImageRules {
    /// Downloads larger than this are rejected (2 MB).
    public static let maximumDownloadBytes = 2 * 1024 * 1024
    /// Request and resource timeout for downloads, in seconds.
    public static let downloadTimeout: TimeInterval = 15
    /// File types offered by Choose Image….
    public static let allowedFileExtensions = ["svg", "png", "jpg", "jpeg", "pdf"]
    /// Stored images are square PNGs of this many pixels per side (128 pt at 2x).
    public static let canvasPixels = 256
    /// Empty margin on each side, as a fraction of the canvas.
    public static let paddingFraction: CGFloat = 0.12

    /// The http(s) URL typed by the user, or `.notAWebLink`.
    public static func webURL(from text: String) throws(BadgeImageError) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw .notAWebLink
        }
        return url
    }

    /// `.tooLarge` when the server announces more than the limit; nil or negative means unknown.
    public static func problem(contentLength: Int64?) -> BadgeImageError? {
        guard let contentLength, contentLength >= 0 else { return nil }
        return contentLength > Int64(maximumDownloadBytes) ? .tooLarge : nil
    }

    /// True once a download has received more bytes than allowed.
    public static func exceedsLimit(byteCount: Int) -> Bool {
        byteCount > maximumDownloadBytes
    }

    /// nil for a 2xx answer, otherwise why the download failed.
    public static func problem(httpStatus: Int) -> BadgeImageError? {
        (200..<300).contains(httpStatus) ? nil : .downloadFailed("the server answered \(httpStatus)")
    }

    /// Where an image of `imageSize` is drawn on a square canvas of `canvas` units: as large as
    /// fits inside the padding, aspect ratio kept, centered. nil for empty or non-finite sizes.
    public static func fitRect(imageSize: CGSize, canvas: CGFloat) -> CGRect? {
        let width = imageSize.width
        let height = imageSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0, canvas.isFinite, canvas > 0 else {
            return nil
        }
        let inner = canvas * (1 - 2 * paddingFraction)
        let scale = min(inner / width, inner / height)
        let fitted = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (canvas - fitted.width) / 2, y: (canvas - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}
