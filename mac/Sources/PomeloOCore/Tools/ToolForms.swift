import Foundation

/// A tool and its settings, ready to run.
public enum ToolInvocation: Sendable, Equatable {
    case pdf(PDFToolRequest)
    case image(ImageToolRequest)
    case text(TextToolRequest)
}

/// What a form says is wrong with what was typed; shown under the form.
public struct ToolFormError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The settings a tool's dialog edits, kept apart from the dialog so they can be tested: each form holds what
/// the person typed or picked, and turns it into a request or says what is wrong. The SwiftUI views only bind to these.
public enum ToolForms {
    /// Tools that show a dialog before they run. Reading QR codes and text recognition need no settings.
    public static let withDialog: Set<String> = [
        "compress", "removeMetadata", "editImage", "cropImage", "redactImage",
        "splitPDF", "organizePDF", "mergePDF", "protectPDF", "unlockPDF", "watermarkPDF", "numberPDF",
    ]

    /// The request of a tool that has no settings.
    public static func invocationWithoutDialog(toolID: String) -> ToolInvocation? {
        switch toolID {
        case "readQR": .text(.readCodes)
        case "extractText": .text(.recognizeText)
        default: nil
        }
    }
}

// MARK: pictures

public struct CompressForm: Sendable, Equatable {
    public enum Quality: String, CaseIterable, Sendable { case custom, highQuality, balanced, smallest }
    public var quality = Quality.custom
    /// Used by "custom": the share of the original size to aim for (5...95), or an exact size in KB (0 = not used).
    public var percent = 50
    public var targetKB = 0
    public var resizePercent = 100

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard (10...100).contains(resizePercent) else { throw ToolFormError("Resize goes from 10% to 100%.") }
        switch quality {
        case .custom:
            guard (5...95).contains(percent) else { throw ToolFormError("The target size goes from 5% to 95%.") }
            guard targetKB >= 0 else { throw ToolFormError("The exact size cannot be negative.") }
            return .image(.compress(CompressOptions(percent: percent, targetKB: targetKB, resizePercent: resizePercent)))
        case .highQuality: return .image(.compress(CompressOptions(preset: .highQuality, resizePercent: resizePercent)))
        case .balanced: return .image(.compress(CompressOptions(preset: .balanced, resizePercent: resizePercent)))
        case .smallest: return .image(.compress(CompressOptions(preset: .smallest, resizePercent: resizePercent)))
        }
    }
}

public struct MetadataForm: Sendable, Equatable {
    public enum Mode: String, CaseIterable, Sendable { case remove, edit }
    public var mode = Mode.remove
    public var title = ""
    public var artist = ""
    public var copyright = ""
    public var make = ""
    public var model = ""
    public var software = ""

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard mode == .edit else { return .image(.removeMetadata) }
        let fields = ["title": title, "artist": artist, "copyright": copyright, "make": make, "model": model, "software": software]
            .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !fields.isEmpty else { throw ToolFormError("Fill in at least one field, or choose Remove.") }
        return .image(.editMetadata(fields: fields))
    }
}

public struct CropForm: Sendable, Equatable {
    public static let aspects = ["free", "1:1", "4:5", "4:3", "3:2", "16:9", "9:16", "3:4"]
    public var aspect = "free"
    public var width = 0
    public var height = 0

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard Self.aspects.contains(aspect) else { throw ToolFormError("Unknown aspect ratio \(aspect).") }
        guard width >= 0, height >= 0, width <= 20_000, height <= 20_000 else { throw ToolFormError("Width and height go from 0 to 20000 px.") }
        guard (width == 0) == (height == 0) else { throw ToolFormError("Give both the width and the height, or neither.") }
        if aspect == "free", width == 0 { throw ToolFormError("Choose an aspect ratio or exact pixels.") }
        return .image(.crop(CropOptions(aspect: aspect, width: width, height: height)))
    }
}

public struct RedactForm: Sendable, Equatable {
    public var style = RedactOptions.Style.pixelate
    public var color = "#000000"
    public var auto = RedactOptions.Auto.both

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard auto != .none else { throw ToolFormError("Choose what to cover: faces, text or both.") }
        return .image(.redact(RedactOptions(style: style, color: color, auto: auto)))
    }
}

public struct AdjustForm: Sendable, Equatable {
    public var options = AdjustOptions()

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard !options.isIdentity else { throw ToolFormError("Move a slider first: nothing would change.") }
        return .image(.adjust(options))
    }
}

// MARK: PDF

/// `1-3, 5`: ranges and single pages, 1-based.
public enum PageList {
    /// The pages in the order written, as 0-based indexes; `1-3` is 1, 2, 3 and `3-1` is 3, 2, 1.
    public static func parse(_ text: String) throws -> [Int] {
        var pages: [Int] = []
        for part in text.split(separator: ",") {
            let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = Int(ends[0]), let last = ends.count > 1 ? Int(ends[1]) : first, first >= 1, last >= 1 else {
                throw ToolFormError("\"\(part.trimmingCharacters(in: .whitespaces))\" is not a page or a range like 2-4.")
            }
            pages += first <= last ? Array(first...last).map { $0 - 1 } : Array((last...first).reversed()).map { $0 - 1 }
        }
        return pages
    }

    /// `2:90, 4:180`: the position in the result (1-based) and the degrees to turn it.
    public static func parseRotations(_ text: String) throws -> [Int: Int] {
        var rotations: [Int: Int] = [:]
        for part in text.split(separator: ",") {
            let pair = part.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let position = Int(pair[0]), position >= 1, let degrees = Int(pair[1]), degrees % 90 == 0 else {
                throw ToolFormError("\"\(part.trimmingCharacters(in: .whitespaces))\" should look like 2:90 (page 2, 90 degrees).")
            }
            rotations[position - 1] = degrees
        }
        return rotations
    }

    /// Whether a split spec is written right (the pages are checked against the document when it runs).
    static func validateRanges(_ text: String) throws {
        for part in text.split(separator: ",") {
            let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard Int(ends[0]) != nil, ends.count == 1 || Int(ends[1]) != nil else {
                throw ToolFormError("Page ranges look like 1-3, 5. \"\(part.trimmingCharacters(in: .whitespaces))\" does not.")
            }
        }
    }
}

public struct SplitForm: Sendable, Equatable {
    /// Empty means every page on its own.
    public var ranges = ""

    public init() {}

    public func invocation() throws -> ToolInvocation {
        try PageList.validateRanges(ranges)
        return .pdf(.split(ranges: ranges))
    }
}

public struct OrganizeForm: Sendable, Equatable {
    /// The pages to keep, in the order wanted ("3, 1, 2-4"); empty keeps all pages as they are.
    public var order = ""
    /// Extra turns by position in the result ("2:90, 4:180").
    public var rotations = ""

    public init() {}

    public func invocation() throws -> ToolInvocation {
        let pages = try PageList.parse(order)
        let turns = try PageList.parseRotations(rotations)
        guard !pages.isEmpty || !turns.isEmpty else { throw ToolFormError("Type a page order or a rotation, or close the window.") }
        return .pdf(.organize(order: pages.isEmpty ? nil : pages, rotations: turns))
    }
}

public struct MergeForm: Sendable, Equatable {
    /// The documents in the order they will be joined.
    public var files: [URL]

    public init(files: [URL]) { self.files = files }

    public mutating func move(from index: Int, by step: Int) {
        let target = index + step
        guard files.indices.contains(index), files.indices.contains(target) else { return }
        files.swapAt(index, target)
    }

    public func invocation() throws -> ToolInvocation {
        guard files.count >= 2 else { throw ToolFormError("Select at least two files.") }
        return .pdf(.merge)
    }
}

public struct PasswordForm: Sendable, Equatable {
    public var password = ""
    /// Only asked when adding a password.
    public var confirmation = ""

    public init() {}

    public func protectInvocation() throws -> ToolInvocation {
        guard !password.isEmpty else { throw ToolFormError("Type a password.") }
        guard password == confirmation else { throw ToolFormError("The two passwords are not the same.") }
        return .pdf(.protect(password: password))
    }

    public func unlockInvocation() -> ToolInvocation {
        .pdf(.unlock(password: password))
    }

    /// What the dialog says about the strength. Not AES-256: Apple's frameworks write AES-128 only.
    public static let strengthNote = "AES-128. Its key comes from the password with MD5, so use a long password."
}

public struct WatermarkForm: Sendable, Equatable {
    public var options = WatermarkOptions()

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard !options.text.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolFormError("Type the text of the watermark.") }
        guard (10...100).contains(options.sizePercent) else { throw ToolFormError("The width goes from 10% to 100%.") }
        guard (5...100).contains(options.opacityPercent) else { throw ToolFormError("The opacity goes from 5% to 100%.") }
        guard [0, 45, 90].contains(options.angle) else { throw ToolFormError("The angle is 0, 45 or 90 degrees.") }
        return .pdf(.watermark(options))
    }
}

public struct NumberForm: Sendable, Equatable {
    public static let positions = ["bottom left", "bottom center", "bottom right", "top left", "top center", "top right"]
    public var options = NumberingOptions()

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard Self.positions.contains(options.position) else { throw ToolFormError("Unknown position \(options.position).") }
        guard (6...36).contains(options.size) else { throw ToolFormError("The size goes from 6 to 36 points.") }
        guard (0...99_999).contains(options.start) else { throw ToolFormError("The first number goes from 0 to 99999.") }
        return .pdf(.number(options))
    }
}
