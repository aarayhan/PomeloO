import CoreGraphics
import CoreImage
import Foundation
import ImageIO

// MARK: options

public struct CompressOptions: Sendable, Equatable {
    /// Aim for this share of the original size.
    public var percent: Int
    /// Aim for exactly this many kilobytes; wins over `percent` when above zero.
    public var targetKB: Int
    /// Scale the picture to this percentage of its size first (10...100).
    public var resizePercent: Int

    public init(percent: Int = 50, targetKB: Int = 0, resizePercent: Int = 100) {
        self.percent = percent
        self.targetKB = targetKB
        self.resizePercent = resizePercent
    }

    /// "high quality" 75, "balanced" 50, "smallest" 25, the presets of the Windows dialog.
    public enum Preset: Int, Sendable, CaseIterable {
        case highQuality = 75, balanced = 50, smallest = 25
    }

    public init(preset: Preset, resizePercent: Int = 100) {
        self.init(percent: preset.rawValue, resizePercent: resizePercent)
    }
}

public struct CropOptions: Sendable, Equatable {
    /// The area to keep as fractions of the picture (x, y, width, height), y down from the top. Nil takes the
    /// biggest area of the chosen aspect (or exact size's ratio) from the middle.
    public var rect: CGRect?
    /// "free", "1:1", "4:5", "4:3", "3:2", "16:9", "9:16" or "3:4".
    public var aspect: String
    /// With both above zero the result has exactly these pixels.
    public var width: Int
    public var height: Int

    public init(rect: CGRect? = nil, aspect: String = "free", width: Int = 0, height: Int = 0) {
        self.rect = rect
        self.aspect = aspect
        self.width = width
        self.height = height
    }

    static let aspects: [String: Double] = [
        "1:1": 1, "4:5": 4.0 / 5, "4:3": 4.0 / 3, "3:2": 3.0 / 2, "16:9": 16.0 / 9, "9:16": 9.0 / 16, "3:4": 3.0 / 4,
    ]
}

public struct RedactOptions: Sendable, Equatable {
    public enum Style: String, Sendable { case pixelate, blur, color }
    public enum Auto: String, Sendable { case none, faces, text, both }

    /// Areas as fractions of the picture (x, y, width, height), y down from the top.
    public var rects: [CGRect]
    public var style: Style
    public var color: String
    /// Find faces and/or text with Vision and cover those too.
    public var auto: Auto

    public init(rects: [CGRect] = [], style: Style = .pixelate, color: String = "#000000", auto: Auto = .none) {
        self.rects = rects
        self.style = style
        self.color = color
        self.auto = auto
    }
}

// MARK: tools

/// What the picture tools do (`pomeloo/tools/image.py`). Each reads the source the way conversions do (first
/// frame, upright, as sRGB), changes it, and writes it back in the source's own format.
enum ImageTools {
    private static let coreImage = CIContext()

    // MARK: compress

    /// Writes a copy no bigger than the target: for JPEG, WebP, HEIC and AVIF the best quality that fits (a binary
    /// search over 5 to 92), and for every format a smaller picture (85% at a time) as the last resort.
    /// Camera data is not carried over, like the Windows app. [Parity gap] PNG is not reduced to 256 colours
    /// first, so a PNG that is too big gets smaller by losing pixels sooner than on Windows.
    /// Returns a sentence for the user when the result is not what was asked for: the pixels had to shrink, or the
    /// target was out of reach.
    @discardableResult
    static func compress(_ source: URL, to destination: URL, options: CompressOptions, cancel: CancelFlag) throws -> String? {
        let format = try outputFormat(destination)
        let sourceSize = try fileSize(source)
        let target = options.targetKB > 0 ? options.targetKB * 1024 : sourceSize * options.percent / 100
        var (image, _) = try ImageEngine.read(source)
        if options.resizePercent < 100 {
            let factor = Double(max(10, options.resizePercent)) / 100
            image = try ImagePixels.resized(image, width: Int(Double(image.width) * factor), height: Int(Double(image.height) * factor))
        }

        var quality = 0.9
        if format.isLossy {
            var low = 5, high = 92
            var best: Int?
            while low <= high {
                try cancel.check()
                let q = (low + high) / 2
                try ImageEncoders.write(image, as: format, quality: Double(q) / 100, to: destination, cancel: cancel)
                if try fileSize(destination) <= target { best = q; low = q + 1 } else { high = q - 1 }
            }
            if let best {
                try ImageEncoders.write(image, as: format, quality: Double(best) / 100, to: destination, cancel: cancel)
                return nil
            }
            quality = 0.05
        } else {
            try ImageEncoders.write(image, as: format, to: destination, cancel: cancel)
        }
        let original = (image.width, image.height)
        while try fileSize(destination) > target, min(image.width, image.height) > 32 {
            try cancel.check()
            image = try ImagePixels.resized(image, width: Int(Double(image.width) * 0.85), height: Int(Double(image.height) * 0.85))
            try ImageEncoders.write(image, as: format, quality: quality, to: destination, cancel: cancel)
        }
        let finalSize = try fileSize(destination)
        if (image.width, image.height) != original {
            let reached = finalSize <= target ? "" : " and the size is still above the target"
            return "Made smaller to \(image.width) × \(image.height) px to get near the target size\(reached)."
        }
        return nil
    }

    // MARK: metadata

    /// A copy without camera, location and caption data. The colour profile stays.
    static func removeMetadata(_ source: URL, to destination: URL, cancel: CancelFlag) throws {
        let format = try outputFormat(destination)
        let (image, _) = try ImageEngine.read(source)
        try ImageEncoders.write(image, as: format, to: destination, cancel: cancel)
    }

    /// A copy with some fields set. Keys (any case, a `Group/` prefix is ignored): title, imagedescription,
    /// artist, author, copyright, make, model, software, datetime.
    static func editMetadata(_ source: URL, fields: [String: String], to destination: URL, cancel: CancelFlag) throws {
        let format = try outputFormat(destination)
        let (image, existing) = try ImageEngine.read(source)
        var metadata = existing
        var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let tags: [String: CFString] = [
            "title": kCGImagePropertyTIFFImageDescription, "imagedescription": kCGImagePropertyTIFFImageDescription,
            "artist": kCGImagePropertyTIFFArtist, "author": kCGImagePropertyTIFFArtist,
            "copyright": kCGImagePropertyTIFFCopyright, "make": kCGImagePropertyTIFFMake, "model": kCGImagePropertyTIFFModel,
            "software": kCGImagePropertyTIFFSoftware, "datetime": kCGImagePropertyTIFFDateTime,
        ]
        for (key, value) in fields {
            let name = key.split(separator: "/").last.map { String($0).lowercased() } ?? key.lowercased()
            if let tag = tags[name] { tiff[tag] = value }
        }
        metadata[kCGImagePropertyTIFFDictionary] = tiff
        try ImageEncoders.write(image, as: format, metadata: metadata, to: destination, cancel: cancel)
    }

    // MARK: crop

    static func crop(_ source: URL, options: CropOptions, to destination: URL, cancel: CancelFlag) throws {
        let format = try outputFormat(destination)
        let (image, metadata) = try ImageEngine.read(source)
        let width = Double(image.width), height = Double(image.height)

        var rect = options.rect
        if rect == nil {
            if options.width > 0, options.height > 0 {
                rect = centredRect(width, height, ratio: Double(options.width) / Double(options.height))
            } else {
                rect = centredRect(width, height, ratio: CropOptions.aspects[options.aspect] ?? width / height)
            }
        }
        let fractions = rect!
        let left = (fractions.minX * width).rounded(.toNearestOrEven)
        let top = (fractions.minY * height).rounded(.toNearestOrEven)
        let right = ((fractions.minX + fractions.width) * width).rounded(.toNearestOrEven)
        let bottom = ((fractions.minY + fractions.height) * height).rounded(.toNearestOrEven)
        var cropped = try ImagePixels.cropped(image, to: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        if options.width > 0, options.height > 0 {
            cropped = try ImagePixels.coverFit(cropped, width: options.width, height: options.height)
        }
        try ImageEncoders.write(cropped, as: format, metadata: metadata, to: destination, cancel: cancel)
    }

    /// The biggest centred area of this aspect ratio, as fractions of the picture (`centre_rect`).
    static func centredRect(_ width: Double, _ height: Double, ratio: Double) -> CGRect {
        let (w, h) = width / height < ratio ? (width, width / ratio) : (height * ratio, height)
        return CGRect(x: (width - w) / 2 / width, y: (height - h) / 2 / height, width: w / width, height: h / height)
    }

    // MARK: edit photo

    static func adjust(_ source: URL, options: AdjustOptions, to destination: URL, cancel: CancelFlag) throws {
        let format = try outputFormat(destination)
        let (image, metadata) = try ImageEngine.read(source)
        let result = try ImageAdjust.apply(image, options, cancel: cancel)
        try ImageEncoders.write(result, as: format, metadata: metadata, to: destination, cancel: cancel)
    }

    // MARK: redact

    /// Covers the areas (and the faces and text Vision finds, when asked). The result carries no camera data.
    static func redact(_ source: URL, options: RedactOptions, to destination: URL, cancel: CancelFlag) throws {
        let format = try outputFormat(destination)
        let (image, _) = try ImageEngine.read(source)
        var areas = options.rects
        if options.auto == .faces || options.auto == .both { areas += try VisionTools.faceBoxes(in: image) }
        try cancel.check()
        if options.auto == .text || options.auto == .both { areas += try VisionTools.textBoxes(in: image) }
        try cancel.check()
        let covered = try cover(image, areas: areas, style: options.style, color: HexColor.cgColor(options.color))
        try ImageEncoders.write(covered, as: format, to: destination, cancel: cancel)
    }

    /// The picture with the areas (fractions, y down) pixelated, blurred or filled.
    static func cover(_ image: CGImage, areas: [CGRect], style: RedactOptions.Style, color: CGColor) throws -> CGImage {
        let width = image.width, height = image.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return try ImagePixels.draw(width: width, height: height) { context, _ in
            context.draw(image, in: bounds)
            for fractions in areas {
                // pixel box, y down, then flipped for Core Graphics
                let box = CGRect(x: (fractions.minX * Double(width)).rounded(.toNearestOrEven),
                                 y: (fractions.minY * Double(height)).rounded(.toNearestOrEven),
                                 width: (fractions.width * Double(width)).rounded(.toNearestOrEven),
                                 height: (fractions.height * Double(height)).rounded(.toNearestOrEven))
                    .intersection(bounds)
                guard !box.isNull, box.width >= 1, box.height >= 1 else { continue }
                let target = CGRect(x: box.minX, y: Double(height) - box.maxY, width: box.width, height: box.height)
                switch style {
                case .color:
                    context.setFillColor(color)
                    context.fill(target)
                case .pixelate:
                    guard let region = image.cropping(to: box) else { continue }
                    let small = max(1, Int(box.width) / 16), smallHeight = max(1, Int(box.height) / 16)
                    guard let reduced = try? ImagePixels.resized(region, width: small, height: smallHeight) else { continue }
                    context.saveGState()
                    context.interpolationQuality = .none  // blocks, not a smooth enlargement
                    context.draw(reduced, in: target)
                    context.restoreGState()
                case .blur:
                    guard let region = image.cropping(to: box),
                          let blurred = blur(region, radius: max(box.width, box.height) / 6 + 4) else { continue }
                    context.draw(blurred, in: target)
                }
            }
        }
    }

    private static func blur(_ region: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: region)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        return coreImage.createCGImage(blurred, from: input.extent)
    }

    // MARK: helpers

    static func outputFormat(_ destination: URL) throws -> ImageFormat {
        let ext = FileName.ext(of: destination)
        guard let format = ImageFormat(rawValue: ext), format.isWritable else {
            throw ConversionError.failed("This Mac cannot write \(ext.uppercased()).")
        }
        return format
    }

    /// The size on disk now. Not `URL.resourceValues`: a URL remembers the size it was asked about first, and a
    /// file that is written again and again (the quality search) would keep reporting the first one.
    static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
