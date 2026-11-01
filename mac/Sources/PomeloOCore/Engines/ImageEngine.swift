import CoreGraphics
import Foundation
import ImageIO

/// Raster images through ImageIO. Behaviour follows pomeloo/engines/image.py: first frame only, the
/// camera orientation applied to the pixels, camera metadata kept, quality 90, transparency flattened
/// onto white for formats without alpha, PDF pages sized for 300 dpi.
public struct ImageEngine: ConversionEngine {
    public let name = "ImageIO"

    /// Catalog image inputs. SVG is not here: ImageIO cannot draw it.
    static let sources: Set<String> = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp"]
    private static let quality = 0.9
    private static let pdfDPI = 300.0

    public init() {}

    public func canConvert(from: String, to: String) -> Bool {
        guard from != to, Self.sources.contains(from),
              let input = ImageFormat(rawValue: from), let output = ImageFormat(rawValue: to) else { return false }
        return input.isReadable && output.isWritable
    }

    public func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let format = ImageFormat(rawValue: job.target) else {
            throw ConversionError.unsupported(from: job.sourceExtension, to: job.target)
        }
        try await runBlocking { cancel in
            let (image, metadata) = try Self.read(job.source)
            progress(0.4)
            try cancel.check()
            try Self.write(image, metadata: metadata, as: format, to: job.destination)
            progress(1)
        }
    }

    // MARK: read

    static func read(_ url: URL) throws -> (CGImage, [CFString: Any]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ConversionError.cannotRead(url.lastPathComponent)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(width, height) > 0 else { throw ConversionError.cannotRead(url.lastPathComponent) }

        // A "thumbnail" as large as the image is the way to get the pixels with the orientation applied.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.cannotRead(url.lastPathComponent)
        }
        return (image, keptMetadata(properties))
    }

    /// Camera, location and caption data. The orientation is dropped because the pixels are already upright.
    private static func keptMetadata(_ properties: [CFString: Any]) -> [CFString: Any] {
        var kept: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = properties[key] { kept[key] = value }
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        return kept
    }

    // MARK: write

    static func write(_ image: CGImage, metadata: [CFString: Any], as format: ImageFormat, to url: URL) throws {
        let flat = format.supportsAlpha ? image : try flattened(image)
        if format == .pdf {
            try writePDF(flat, to: url)
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utTypeIdentifier as CFString, 1, nil) else {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
        var properties = metadata
        if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        if format == .tiff {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5  // LZW
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(destination, flat, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.cannotWrite(url.lastPathComponent) }
    }

    private static func writePDF(_ image: CGImage, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / pdfDPI, height: Double(image.height) * 72 / pdfDPI)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }

    /// Draws the image over opaque white. Images without alpha come back unchanged.
    static func flattened(_ image: CGImage) throws -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ConversionError.failed("Can't flatten the transparency of this image.") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ConversionError.failed("Can't flatten the transparency of this image.") }
        return result
    }
}
