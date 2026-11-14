import AppKit
import AppCore

/// Redraws any decodable image (SVG, PNG, JPEG, PDF…) into a square badge PNG: 256×256 pixels
/// (128 pt at 2x), transparent background, the image aspect-fitted inside a 12% margin.
@MainActor
enum BadgeImageRenderer {
    static func pngData(from image: NSImage) -> Data? {
        let pixels = BadgeImageRules.canvasPixels
        let canvas = CGFloat(pixels)
        guard image.isValid,
              let rect = BadgeImageRules.fitRect(imageSize: image.size, canvas: canvas),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        // One point per pixel while drawing, so `rect` (in canvas pixels) maps 1:1.
        bitmap.size = NSSize(width: canvas, height: canvas)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
