import CoreGraphics
import Foundation
import ImageIO

/// Pictures in, pictures out. The input is decoded once (first frame only, the camera orientation applied
/// to the pixels, camera metadata kept; SVG drawn by the system), then an encoder writes the output:
/// ImageIO, Core Graphics or libwebp. See pomeloo/engines/image.py for the behaviour followed.
public struct ImageEngine: ConversionEngine {
    public let name = "ImageIO"

    /// Catalog image inputs.
    static let sources: Set<String> = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "svg"]

    private let encoders: [any ImageEncoder]

    public init() {
        encoders = ImageEncoders.standard
    }

    init(encoders: [any ImageEncoder]) {
        self.encoders = encoders
    }

    public func canConvert(from: String, to: String) -> Bool {
        guard from != to, Self.sources.contains(from),
              let input = ImageFormat(rawValue: from), let output = ImageFormat(rawValue: to) else { return false }
        return input.isReadable && encoder(for: output) != nil
    }

    public func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let format = ImageFormat(rawValue: job.target), let encoder = encoder(for: format) else {
            throw ConversionError.unsupported(from: job.sourceExtension, to: job.target)
        }
        try await runBlocking { cancel in
            let (image, metadata) = try Self.read(job.source)
            progress(0.3)
            try cancel.check()
            try encoder.write(image, as: format, metadata: metadata, to: job.destination,
                              progress: { progress(0.3 + 0.7 * $0) }, cancel: cancel)
            progress(1)
        }
    }

    private func encoder(for format: ImageFormat) -> (any ImageEncoder)? {
        encoders.first { $0.formats.contains(format) }
    }

    // MARK: read

    static func read(_ url: URL) throws -> (CGImage, [CFString: Any]) {
        if FileName.ext(of: url) == "svg" { return (try SVGRasterizer.rasterize(url), [:]) }
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

    /// Camera, location and caption data, or nothing when the file has none. ImageIO invents a little EXIF
    /// for every file (pixel size, colour space); that is not the user's data and is not carried over. The
    /// orientation is dropped because the pixels are already upright.
    static func keptMetadata(_ properties: [CFString: Any]) -> [CFString: Any] {
        var kept: [CFString: Any] = [:]
        var meaningful = false

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            kept[kCGImagePropertyExifDictionary] = exif
            let invented: Set<CFString> = [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
                                           kCGImagePropertyExifColorSpace, kCGImagePropertyExifVersion,
                                           kCGImagePropertyExifFlashPixVersion, kCGImagePropertyExifComponentsConfiguration]
            if exif.keys.contains(where: { !invented.contains($0) }) { meaningful = true }
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            kept[kCGImagePropertyTIFFDictionary] = tiff
            let layout: Set<CFString> = [kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
                                         kCGImagePropertyTIFFResolutionUnit]
            if tiff.keys.contains(where: { !layout.contains($0) }) { meaningful = true }
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let dictionary = properties[key] as? [CFString: Any], !dictionary.isEmpty {
                kept[key] = dictionary
                meaningful = true
            }
        }
        return meaningful ? kept : [:]
    }
}
