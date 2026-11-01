import ImageIO

/// The raster formats of the catalog and what ImageIO can do with each on this Mac. Availability is read
/// from the system at run time: HEIC and AVIF encoders depend on the macOS version and hardware.
public enum ImageFormat: String, CaseIterable, Sendable {
    case jpg, png, webp, heic, tiff, avif, bmp, pdf

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
        }
    }

    /// Written with a quality setting (the Windows app uses 90).
    public var isLossy: Bool {
        switch self {
        case .jpg, .webp, .heic, .avif: true
        case .png, .tiff, .bmp, .pdf: false
        }
    }

    /// False means transparency is flattened onto white when writing (JPEG, BMP and PDF, as on Windows).
    public var supportsAlpha: Bool {
        switch self {
        case .png, .webp, .heic, .tiff, .avif: true
        case .jpg, .bmp, .pdf: false
        }
    }

    /// ImageIO can decode it here. PDF is output-only.
    public var isReadable: Bool {
        self != .pdf && ImageIOTypes.readable.contains(utTypeIdentifier)
    }

    /// ImageIO can encode it here (PDF is drawn with Core Graphics and is always available).
    public var isWritable: Bool {
        self == .pdf || ImageIOTypes.writable.contains(utTypeIdentifier)
    }
}

private enum ImageIOTypes {
    static let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    static let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
}
