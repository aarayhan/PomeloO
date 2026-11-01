import AppKit

/// SVG through the system renderer (NSImage, CoreSVG): vectors, gradients, blur and text are drawn by
/// macOS. Like the Windows app it rasterises to about 2000 px on the long side and never below the
/// image's own size, with transparency kept.
///
/// [BELUM DIUJI] on macOS 13 (tested on 26), and from a background thread other than through the job
/// runner's tests.
enum SVGRasterizer {
    static let longSide = 2000.0

    static var isAvailable: Bool {
        NSImage.imageTypes.contains(ImageFormat.svg.utTypeIdentifier)
    }

    static func rasterize(_ url: URL) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw ConversionError.cannotRead(url.lastPathComponent)
        }
        let zoom = max(1, longSide / max(image.size.width, image.size.height, 1))
        let width = max(1, Int((image.size.width * zoom).rounded()))
        let height = max(1, Int((image.size.height * zoom).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.failed("Not enough memory to draw \(url.lastPathComponent).")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        guard let result = context.makeImage() else { throw ConversionError.cannotRead(url.lastPathComponent) }
        return result
    }
}
