import AppKit
import ImageIO

/// The raster and vector formats of the catalog and what this Mac can do with each. Availability is read
/// from the system at run time: HEIC and AVIF encoders depend on the macOS version and hardware.
public enum ImageFormat: String, CaseIterable, Sendable {
    case jpg, png, webp, heic, tiff, avif, bmp, pdf
    /// Input only: drawn by the system's SVG renderer.
    case svg

    public var fileExtension: String { rawValue }

    public var utTypeIdentifier: String {
        switch self {
        case .jpg: "public.jpeg"
        case .png: "public.png"
        case .webp: "org.webmproject.webp"
        case .heic: "public.heic"
        case .tiff: "public.tiff"
        case .avif: "public.avif"
        case .bmp: "com.microsoft.bmp"
        case .pdf: "com.adobe.pdf"
        case .svg: "public.svg-image"
        }
    }

    /// Written with a quality setting (the Windows app uses 90).
    public var isLossy: Bool {
        switch self {
        case .jpg, .webp, .heic, .avif: true
        case .png, .tiff, .bmp, .pdf, .svg: false
        }
    }

    /// False means transparency is flattened onto white when writing (JPEG, BMP and PDF, as on Windows).
    public var supportsAlpha: Bool {
        switch self {
        case .png, .webp, .heic, .tiff, .avif, .svg: true
        case .jpg, .bmp, .pdf: false
        }
    }

    /// Something here can decode it. PDF is output-only.
    public var isReadable: Bool {
        switch self {
        case .pdf: false
        case .svg: SVGRasterizer.isAvailable
        default: ImageIOTypes.readable.contains(utTypeIdentifier)
        }
    }

    /// An encoder here can write it: ImageIO for most, Core Graphics for PDF, libwebp for WebP.
    public var isWritable: Bool {
        ImageEncoders.standard.contains { $0.formats.contains(self) }
    }
}

private enum ImageIOTypes {
    static let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
}
