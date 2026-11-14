import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import CoreModels

/// Why a badge image couldn't be used, with the message shown in Settings.
public enum BadgeImageError: Error, Equatable, Sendable {
    case notAWebLink
    case notAnImage
    case notAnImageFile
    case tooLarge
    case tooManyPixels
    case downloadFailed(String)
    case couldNotRead(String)
    case couldNotSave(String)
    /// The new PNG was written but the old file of the same name (which is preferred) wasn't removed.
    case oldFileNotRemoved(name: String, reason: String)

    public var message: String {
        switch self {
        case .notAWebLink: "Enter a link that starts with http:// or https://."
        case .notAnImage: "That link isn't an image."
        case .notAnImageFile: "That file isn't an image."
        case .tooLarge: "That image is larger than 2 MB."
        case .tooManyPixels: "That image has too many pixels (over 50 megapixels)."
        case .downloadFailed(let reason): "Couldn't download it: \(reason)"
        case .couldNotRead(let reason): "Couldn't read that file: \(reason)"
        case .couldNotSave(let reason): "Couldn't save the image: \(reason)"
        case .oldFileNotRemoved(let name, let reason):
            "The new image is saved and shown, but the old \(name) couldn't be removed (\(reason)). You can delete it in Finder."
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

    /// Bitmaps are decoded as a thumbnail no larger than this many pixels on the long side.
    public static let maximumDecodePixelSize = 1024
    /// Bitmaps that announce more pixels than this are refused before decoding.
    public static let maximumSourcePixels = 50_000_000

    /// How image bytes are decoded: vectors (SVG, PDF) by the system's vector renderer, everything
    /// else by ImageIO with the thumbnail pixel limit.
    public enum ImageKind: Equatable, Sendable {
        case vector
        case bitmap
    }

    /// Bytes looked at by `kind(of:)`.
    static let sniffLength = 4096

    /// `.vector` for a PDF (`%PDF-`) or an SVG (`<svg` near the start, not inside an HTML page).
    public static func kind(of data: Data) -> ImageKind {
        let head = data.prefix(sniffLength)
        let pdfMagic: [UInt8] = Array("%PDF-".utf8)
        if head.starts(with: pdfMagic) { return .vector }
        var text = String(decoding: head, as: UTF8.self).lowercased()
        let bom = CharacterSet(charactersIn: "\u{FEFF}")
        let trimSet: CharacterSet = CharacterSet.whitespacesAndNewlines.union(bom)
        text = text.trimmingCharacters(in: trimSet)
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") { return .bitmap }
        return text.contains("<svg") ? .vector : .bitmap
    }

    /// nil when the announced size may be decoded; `.tooManyPixels` above the limit, `.notAnImage`
    /// for an empty size. Unknown sizes pass (the thumbnail limit still applies).
    public static func problem(pixelWidth: Int?, pixelHeight: Int?) -> BadgeImageError? {
        guard let pixelWidth, let pixelHeight else { return nil }
        guard pixelWidth > 0, pixelHeight > 0 else { return .notAnImage }
        let (pixels, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        if overflow { return .tooManyPixels }
        if pixels > maximumSourcePixels { return .tooManyPixels }
        return nil
    }

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
        let limit = Int64(maximumDownloadBytes)
        if contentLength > limit { return .tooLarge }
        return nil
    }

    /// True once a download has received more bytes than allowed.
    public static func exceedsLimit(byteCount: Int) -> Bool {
        byteCount > maximumDownloadBytes
    }

    /// nil for a 2xx answer, otherwise why the download failed.
    public static func problem(httpStatus: Int) -> BadgeImageError? {
        if (200..<300).contains(httpStatus) { return nil }
        let reason: String = "the server answered " + String(httpStatus)
        return BadgeImageError.downloadFailed(reason)
    }

    /// Where an image of `imageSize` is drawn on a square canvas of `canvas` units: as large as
    /// fits inside the padding, aspect ratio kept, centered. nil for empty or non-finite sizes.
    public static func fitRect(imageSize: CGSize, canvas: CGFloat) -> CGRect? {
        let width = imageSize.width
        let height = imageSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0, canvas.isFinite, canvas > 0 else {
            return nil
        }
        let margin: CGFloat = 2 * paddingFraction
        let inner: CGFloat = canvas * (1 - margin)
        let scale: CGFloat = min(inner / width, inner / height)
        let fittedWidth: CGFloat = width * scale
        let fittedHeight: CGFloat = height * scale
        let x: CGFloat = (canvas - fittedWidth) / 2
        let y: CGFloat = (canvas - fittedHeight) / 2
        return CGRect(x: x, y: y, width: fittedWidth, height: fittedHeight)
    }
}
