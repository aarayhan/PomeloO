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
    /// orientation because the pixels are upright. `quality` is 0...1 and matters for the lossy formats.
    /// `progress` takes 0...1; `cancel` is polled where possible.
    func write(_ image: CGImage, as format: ImageFormat, metadata: [CFString: Any], quality: Double, to url: URL,
               progress: @escaping @Sendable (Double) -> Void, cancel: CancelFlag) throws
}

enum ImageEncoders {
    static let standard: [any ImageEncoder] = [ImageIOEncoder(), LibWebPEncoder()]

    /// The quality conversions use (the Windows app writes 90).
    static let defaultQuality = 0.9

    static func encoder(for format: ImageFormat) -> (any ImageEncoder)? {
        standard.first { $0.formats.contains(format) }
    }

    /// Writes in a format with whichever encoder has it.
    static func write(_ image: CGImage, as format: ImageFormat, metadata: [CFString: Any] = [:], quality: Double = defaultQuality,
                      to url: URL, cancel: CancelFlag) throws {
        guard let encoder = encoder(for: format) else {
            throw ConversionError.failed("This Mac cannot write \(format.fileExtension.uppercased()).")
        }
        try encoder.write(image, as: format, metadata: metadata, quality: quality, to: url, progress: { _ in }, cancel: cancel)
    }
}

/// JPEG, PNG, HEIC, TIFF, AVIF and BMP through ImageIO, and PDF through Core Graphics. Behaviour follows
/// pomeloo/engines/image.py: quality 90, transparency flattened onto white for formats without alpha, PDF
/// pages sized for 300 dpi.
struct ImageIOEncoder: ImageEncoder {
    private static let pdfDPI = 300.0

    private static let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    var formats: Set<ImageFormat> {
        var set: Set<ImageFormat> = [.pdf]  // drawn by Core Graphics: always there
        for format in [ImageFormat.jpg, .png, .heic, .tiff, .avif, .bmp]
        where Self.writableTypes.contains(format.utTypeIdentifier) { set.insert(format) }
        return set
    }

    func write(_ image: CGImage, as format: ImageFormat, metadata: [CFString: Any], quality: Double, to url: URL,
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
        if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality)) }
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

/// Pixel handling shared by the encoders and the image tools.
enum ImagePixels {
    /// 8-bit sRGB red-green-blue-alpha with the alpha NOT multiplied into the colours (what libwebp and the
    /// adjustments want). Core Graphics draws premultiplied, so the multiplication is undone.
    static func straightRGBA(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError.failed("Not enough memory to convert this image.") }
        data.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                let a = Int(p[i + 3])
                if a != 0 && a != 255 {
                    p[i] = UInt8(min(255, (Int(p[i]) * 255 + a / 2) / a))
                    p[i + 1] = UInt8(min(255, (Int(p[i + 1]) * 255 + a / 2) / a))
                    p[i + 2] = UInt8(min(255, (Int(p[i + 2]) * 255 + a / 2) / a))
                }
                i += 4
            }
        }
        return data
    }

    /// The reverse: a picture from straight (not multiplied) sRGB RGBA bytes.
    static func image(fromStraightRGBA data: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ConversionError.failed("Not enough memory to build this image.")
        }
        return image
    }

    /// A new picture of the given size (high-quality interpolation).
    static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        try draw(width: max(1, width), height: max(1, height)) { context, rect in context.draw(image, in: rect) }
    }

    /// The part of the picture inside `box` (pixels, y down from the top, clamped to the picture).
    static func cropped(_ image: CGImage, to box: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let part = image.cropping(to: box.integral.intersection(bounds)) else {
            throw ConversionError.failed("The crop area is outside the picture.")
        }
        return part
    }

    /// Scales to cover the size and cuts the middle, like `ImageOps.fit`.
    static func coverFit(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        return try draw(width: width, height: height) { context, _ in
            context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        }
    }

    /// An 8-bit sRGB picture drawn by `body`, with alpha.
    static func draw(width: Int, height: Int, _ body: (CGContext, CGRect) -> Void) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.failed("Not enough memory to build this image.")
        }
        context.interpolationQuality = .high
        body(context, CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ConversionError.failed("Not enough memory to build this image.") }
        return result
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
