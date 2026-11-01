import CoreGraphics
import Foundation
import ImageIO

/// Writes a decoded picture in some formats. ImageIO writes most of them, libwebp writes WebP; the
/// engine picks the first encoder that lists the format, and which formats the wheel offers follows
/// from what the encoders really report on this Mac.
protocol ImageEncoder: Sendable {
    /// Formats this encoder can write here and now.
    var formats: Set<ImageFormat> { get }

    /// `metadata` is what ImageIO read from the source (camera, location, caption), already without the
    /// orientation because the pixels are upright. `progress` takes 0...1; `cancel` is polled where possible.
    func write(_ image: CGImage, as format: ImageFormat, metadata: [CFString: Any], to url: URL,
               progress: @escaping @Sendable (Double) -> Void, cancel: CancelFlag) throws
}

enum ImageEncoders {
    static let standard: [any ImageEncoder] = [ImageIOEncoder(), LibWebPEncoder()]
}

/// JPEG, PNG, HEIC, TIFF, AVIF and BMP through ImageIO, and PDF through Core Graphics. Behaviour follows
/// pomeloo/engines/image.py: quality 90, transparency flattened onto white for formats without alpha, PDF
/// pages sized for 300 dpi.
struct ImageIOEncoder: ImageEncoder {
    private static let quality = 0.9
    private static let pdfDPI = 300.0

    private static let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    var formats: Set<ImageFormat> {
        var set: Set<ImageFormat> = [.pdf]  // drawn by Core Graphics: always there
        for format in [ImageFormat.jpg, .png, .heic, .tiff, .avif, .bmp]
        where Self.writableTypes.contains(format.utTypeIdentifier) { set.insert(format) }
        return set
    }

    func write(_ image: CGImage, as format: ImageFormat, metadata: [CFString: Any], to url: URL,
               progress: @escaping @Sendable (Double) -> Void, cancel: CancelFlag) throws {
        let flat = format.supportsAlpha ? image : try ImagePixels.flattened(image)
        if format == .pdf {
            try Self.writePDF(flat, to: url)
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utTypeIdentifier as CFString, 1, nil) else {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
        var properties = metadata
        if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = Self.quality }
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
}

/// Pixel handling shared by the encoders.
enum ImagePixels {
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
