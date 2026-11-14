import AppKit
import ImageIO
import UniformTypeIdentifiers
import AppCore

/// Redraws image bytes (SVG, PDF, PNG, JPEG…) into a square badge PNG: 256×256 pixels in sRGB
/// (128 pt at 2x), transparent background, the image aspect-fitted inside a 12% margin.
///
/// Not tied to the main actor: everything here is CoreGraphics / ImageIO, plus a local NSImage for
/// SVG and PDF drawn into our own bitmap context, so it runs on a background task
/// (`render(_:notAnImage:)`). Bitmaps are never decoded at full size: ImageIO makes a thumbnail of at
/// most `BadgeImageRules.maximumDecodePixelSize` pixels, and sources announcing more than
/// `maximumSourcePixels` are refused before decoding. The bytes are only ever decoded as an image.
enum BadgeImageRenderer {
    /// Renders on a detached background task; only the PNG bytes come back.
    static func render(_ data: Data, notAnImage: BadgeImageError) async -> Result<Data, BadgeImageError> {
        await Task.detached(priority: .userInitiated) { () -> Result<Data, BadgeImageError> in
            do throws(BadgeImageError) {
                return .success(try pngData(from: data, notAnImage: notAnImage))
            } catch {
                return .failure(error)
            }
        }.value
    }

    /// Reads a file chosen in Settings and renders it, both off the main actor.
    static func renderFile(at url: URL) async -> Result<Data, BadgeImageError> {
        let read = await Task.detached(priority: .userInitiated) { () -> Result<Data, BadgeImageError> in
            let isScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isScoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                return .success(try Data(contentsOf: url))
            } catch {
                return .failure(.couldNotRead(error.localizedDescription))
            }
        }.value
        switch read {
        case .success(let data):
            return await render(data, notAnImage: .notAnImageFile)
        case .failure(let error):
            return .failure(error)
        }
    }

    static func pngData(from data: Data, notAnImage: BadgeImageError) throws(BadgeImageError) -> Data {
        let pixels = BadgeImageRules.canvasPixels
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw .couldNotSave("the image canvas could not be created")
        }
        context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.interpolationQuality = .high

        switch BadgeImageRules.kind(of: data) {
        case .bitmap:
            try drawBitmap(data, in: context, notAnImage: notAnImage)
        case .vector:
            try drawVector(data, in: context, notAnImage: notAnImage)
        }

        guard let image = context.makeImage(), let png = encodePNG(image) else {
            throw .couldNotSave("the image could not be encoded")
        }
        return png
    }

    private static func drawBitmap(_ data: Data, in context: CGContext,
                                   notAnImage: BadgeImageError) throws(BadgeImageError) {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0 else {
            throw notAnImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        if let problem = BadgeImageRules.problem(pixelWidth: width, pixelHeight: height) {
            throw problem == .notAnImage ? notAnImage : problem
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: BadgeImageRules.maximumDecodePixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              let rect = BadgeImageRules.fitRect(imageSize: CGSize(width: image.width, height: image.height),
                                                 canvas: CGFloat(BadgeImageRules.canvasPixels)) else {
            throw notAnImage
        }
        context.draw(image, in: rect)
    }

    /// SVG (CoreSVG, macOS 14+) and PDF through NSImage, drawn as vectors straight into the
    /// 256-pixel canvas, so their nominal size never allocates anything.
    private static func drawVector(_ data: Data, in context: CGContext,
                                   notAnImage: BadgeImageError) throws(BadgeImageError) {
        guard let image = NSImage(data: data), image.isValid,
              let rect = BadgeImageRules.fitRect(imageSize: image.size,
                                                 canvas: CGFloat(BadgeImageRules.canvasPixels)) else {
            throw notAnImage
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        graphics.flushGraphics()
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData,
                                                                 UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
