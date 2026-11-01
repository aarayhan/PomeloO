import Foundation

/// How a tool's result is named and shaped (`TOOLS` in pomeloo/catalog.py): the label that follows the file
/// name (`report Merged.pdf`), the extension of the result, and whether the whole selection becomes one result.
/// docs/catalog.json lists tools by id and name only, so these three columns are repeated here;
/// `ToolSpecTests` reads pomeloo/catalog.py and fails if the two ever disagree.
public struct ToolSpec: Sendable, Equatable {
    public let id: String
    /// Added to the name of the result; nil for tools that give no file (reading a QR code).
    public let label: String?
    /// Extension of the result; nil means the source's own; "folder" means a directory.
    public let outputExtension: String?
    /// One result for the whole selection (merging) rather than one per file.
    public let combinesSelection: Bool

    public init(id: String, label: String?, outputExtension: String?, combinesSelection: Bool) {
        self.id = id
        self.label = label
        self.outputExtension = outputExtension
        self.combinesSelection = combinesSelection
    }
}

public enum ToolSpecs {
    /// The PDF tools of this group.
    public static let pdf: [ToolSpec] = [
        ToolSpec(id: "splitPDF", label: "Pages", outputExtension: "folder", combinesSelection: false),
        ToolSpec(id: "organizePDF", label: "Organized", outputExtension: "pdf", combinesSelection: false),
        ToolSpec(id: "mergePDF", label: "Merged", outputExtension: "pdf", combinesSelection: true),
        ToolSpec(id: "unlockPDF", label: "Unlocked", outputExtension: "pdf", combinesSelection: false),
        ToolSpec(id: "watermarkPDF", label: "Watermarked", outputExtension: "pdf", combinesSelection: false),
        ToolSpec(id: "numberPDF", label: "Numbered", outputExtension: "pdf", combinesSelection: false),
    ]

    /// The picture tools of this group. `readQR` and `extractText` give text, not a file.
    public static let image: [ToolSpec] = [
        ToolSpec(id: "compress", label: "Compressed", outputExtension: nil, combinesSelection: false),
        ToolSpec(id: "removeMetadata", label: "No Metadata", outputExtension: nil, combinesSelection: false),
        ToolSpec(id: "editImage", label: "Edited", outputExtension: nil, combinesSelection: false),
        ToolSpec(id: "cropImage", label: "Cropped", outputExtension: nil, combinesSelection: false),
        ToolSpec(id: "redactImage", label: "Redacted", outputExtension: nil, combinesSelection: false),
        ToolSpec(id: "readQR", label: nil, outputExtension: nil, combinesSelection: false),
        ToolSpec(id: "extractText", label: nil, outputExtension: nil, combinesSelection: false),
    ]

    public static let all: [String: ToolSpec] = Dictionary(uniqueKeysWithValues: (pdf + image).map { ($0.id, $0) })

    /// Tools that still make sense with several files selected (`MULTI_OK` in pomeloo/catalog.py).
    static let multipleFilesOK: Set<String> = [
        "compress", "removeMetadata", "cropImage", "normalizeAudio", "muteVideo", "splitPDF", "extractArchive",
        "createPDF", "mergePDF", "joinVideos", "createCollage", "extractText", "searchablePDF", "protectPDF",
        "unlockPDF", "watermarkPDF", "numberPDF",
    ]
}

extension Catalog {
    /// The tools the catalog lists for a selection of `count` files of this extension, in catalog order
    /// (`tools()` in pomeloo/catalog.py): one file gets `tools`; several get `tools` and `tools_many` limited to
    /// the tools that work on a selection.
    public func tools(forExtension ext: String, count: Int) -> [String] {
        guard count >= 1, let format = formats[ext] else { return [] }
        if count == 1 { return format.tools }
        return (format.tools + format.toolsMany).filter(ToolSpecs.multipleFilesOK.contains)
    }
}
