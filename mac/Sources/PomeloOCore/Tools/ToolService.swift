import Foundation
import os

/// What a PDF tool is asked to do, with its options.
public enum PDFToolRequest: Sendable, Equatable {
    case merge
    case split(ranges: String)
    case organize(order: [Int]?, rotations: [Int: Int])
    case watermark(WatermarkOptions)
    case number(NumberingOptions)
    case unlock(password: String)
    case protect(password: String)

    public var toolID: String {
        switch self {
        case .merge: "mergePDF"
        case .split: "splitPDF"
        case .organize: "organizePDF"
        case .watermark: "watermarkPDF"
        case .number: "numberPDF"
        case .unlock: "unlockPDF"
        case .protect: "protectPDF"
        }
    }
}

/// What a picture tool is asked to do, with its options.
public enum ImageToolRequest: Sendable, Equatable {
    case compress(CompressOptions)
    case removeMetadata
    /// Sets fields (title, artist, copyright, make, model, software, datetime) instead of removing everything.
    case editMetadata(fields: [String: String])
    case crop(CropOptions)
    case adjust(AdjustOptions)
    case redact(RedactOptions)

    public var toolID: String {
        switch self {
        case .compress: "compress"
        case .removeMetadata, .editMetadata: "removeMetadata"
        case .crop: "cropImage"
        case .adjust: "editImage"
        case .redact: "redactImage"
        }
    }

    /// Editing metadata is named "Edited", not "No Metadata" (`run_tool` in the Windows app does the same).
    var label: String {
        if case .editMetadata = self { return "Edited" }
        return ToolSpecs.all[toolID]?.label ?? ""
    }
}

/// A tool whose result is text for the clipboard.
public enum TextToolRequest: Sendable, Equatable {
    /// QR codes and barcodes.
    case readCodes
    /// Text in a picture (OCR).
    case recognizeText

    public var toolID: String {
        switch self {
        case .readCodes: "readQR"
        case .recognizeText: "extractText"
        }
    }
}

/// Runs tools the way `ConversionService` runs conversions: the result is written to a hidden temporary file
/// beside the source and renamed to its final name (`report Merged.pdf`, `report Pages` for a folder) only when
/// complete, the source is never touched, and a failed or cancelled run leaves nothing behind.
public final class ToolService: Sendable {
    public let catalog: Catalog
    public let runner: JobRunner
    private let names: NameReserver
    private let notes = OSAllocatedUnfairLock(initialState: [URL: String]())

    /// The tools this service can run so far. The wheel offers only these, whatever the catalog lists.
    public static let implemented: Set<String> = Set(ToolSpecs.all.keys)

    /// What is implemented for a kind of file: a PDF has the PDF tools, a photo the picture tools. (The catalog
    /// lists "compress" for both, but only the picture one exists so far.)
    private static func implemented(forExtension ext: String) -> Set<String> {
        if ext == "pdf" { return Set(ToolSpecs.pdf.map(\.id)) }
        if ImageEngine.sources.contains(ext), ext != "svg" { return Set(ToolSpecs.image.map(\.id)) }
        return []
    }

    /// Tools that write a picture in the source's own format, so they need an encoder for it on this Mac.
    private static let writeTheSourceFormat: Set<String> = ["compress", "removeMetadata", "editImage", "cropImage", "redactImage"]

    public init(catalog: Catalog = .bundled, runner: JobRunner = JobRunner(), names: NameReserver = NameReserver()) {
        self.catalog = catalog
        self.runner = runner
        self.names = names
    }

    // MARK: what is possible

    /// The tools for this selection: the catalog's, in its order, limited to what is implemented here and to
    /// what this Mac can write (a HEIC cannot be compressed on a Mac with no HEIC encoder).
    /// [Parity gap] for several files the order is the catalog's single-file order with the multi-file extras
    /// last; the Windows wheel puts them elsewhere, and docs/catalog.json does not say where.
    public func availableTools(for urls: [URL]) -> [String] {
        let extensions = Set(urls.map(FileName.ext(of:)))
        guard extensions.count == 1, let ext = extensions.first else { return [] }
        let writable = ImageFormat(rawValue: ext)?.isWritable ?? false
        let implemented = Self.implemented(forExtension: ext)
        return catalog.tools(forExtension: ext, count: urls.count).filter { id in
            implemented.contains(id) && (!Self.writeTheSourceFormat.contains(id) || writable)
        }
    }

    // MARK: running files

    /// Runs a PDF tool and returns what it made: one result for a combining tool, otherwise one per file.
    /// The first failure is thrown.
    public func run(_ request: PDFToolRequest, on sources: [URL],
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        try Self.validate(request, sources)
        return try await runAll(toolID: request.toolID, label: nil, sources: sources, progress: progress) { cancel, first, sources, output in
            try Self.perform(request, first: first, sources: sources, output: output, cancel: cancel)
        }
    }

    /// Runs a picture tool on each file.
    public func run(_ request: ImageToolRequest, on sources: [URL],
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        try Self.validate(request, sources)
        return try await runAll(toolID: request.toolID, label: request.label, sources: sources, progress: progress) { cancel, first, _, output in
            try Self.perform(request, first: first, output: output, cancel: cancel)
        }
    }

    /// Queues a PDF tool: one job for a combining tool, otherwise one per file.
    @discardableResult
    public func enqueue(_ request: PDFToolRequest, on sources: [URL]) async -> [JobID] {
        await enqueue(toolID: request.toolID, label: nil, sources: sources, validate: { try Self.validate(request, $0) }) { cancel, first, sources, output in
            try Self.perform(request, first: first, sources: sources, output: output, cancel: cancel)
        }
    }

    /// Queues a picture tool: one job per file.
    @discardableResult
    public func enqueue(_ request: ImageToolRequest, on sources: [URL]) async -> [JobID] {
        await enqueue(toolID: request.toolID, label: request.label, sources: sources, validate: { try Self.validate(request, $0) }) { cancel, first, _, output in
            try Self.perform(request, first: first, output: output, cancel: cancel)
        }
    }

    /// What the user should be told about a result, once (for example that a PNG had to shrink to fit its target).
    public func takeNote(for result: URL) -> String? {
        notes.withLock { $0.removeValue(forKey: result) }
    }

    // MARK: running for text

    /// The text a tool finds in each picture, with a blank line between files. QR codes say so when there are
    /// none; text recognition gives an empty string for a picture without text.
    public func text(_ request: TextToolRequest, from sources: [URL]) async throws -> String {
        guard !sources.isEmpty else { throw ConversionError.failed("No files selected.") }
        var found: [String] = []
        for source in sources {
            let ext = FileName.ext(of: source)
            guard ImageEngine.sources.contains(ext), ImageFormat(rawValue: ext)?.isReadable == true else {
                throw ConversionError.unsupported(from: ext, to: request.toolID)
            }
            let text = try await runBlocking { _ in
                let (image, _) = try ImageEngine.read(source)
                switch request {
                case .readCodes: return try VisionTools.codes(in: image)
                case .recognizeText: return try VisionTools.text(in: image)
                }
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(text) }
        }
        return found.joined(separator: "\n\n")
    }

    // MARK: the machinery

    /// Writes the result; a sentence returned is something the user should be told (see `takeNote`).
    private typealias Produce = @Sendable (CancelFlag, _ first: URL, _ all: [URL], _ output: URL) throws -> String?

    private func runAll(toolID: String, label: String?, sources: [URL], progress: @escaping @Sendable (Double) -> Void,
                        produce: @escaping Produce) async throws -> [URL] {
        guard let spec = ToolSpecs.all[toolID] else { throw ConversionError.unsupported(from: "", to: toolID) }
        if spec.combinesSelection { return [try await runOne(spec, label: label, sources, progress, produce)] }
        var results: [URL] = []
        for source in sources { results.append(try await runOne(spec, label: label, [source], progress, produce)) }
        return results
    }

    private func enqueue(toolID: String, label: String?, sources: [URL], validate: @escaping @Sendable ([URL]) throws -> Void,
                         produce: @escaping Produce) async -> [JobID] {
        guard let spec = ToolSpecs.all[toolID] else { return [] }
        let groups = spec.combinesSelection ? [sources] : sources.map { [$0] }
        var ids: [JobID] = []
        for group in groups {
            let name = spec.combinesSelection ? "\(sources.count) files" : group[0].lastPathComponent
            ids.append(await runner.submit(name: name) { [self] progress in
                try validate(group)
                return try await runOne(spec, label: label, group, progress, produce)
            })
        }
        return ids
    }

    private func runOne(_ spec: ToolSpec, label: String?, _ sources: [URL], _ progress: @escaping @Sendable (Double) -> Void,
                        _ produce: @escaping Produce) async throws -> URL {
        let first = sources[0]
        let outputExtension = spec.outputExtension ?? FileName.ext(of: first)
        let final = await names.reserve(OutputNaming.proposed(for: first, ext: outputExtension, label: label ?? spec.label))
        let temporary = TemporaryOutput(directory: first.deletingLastPathComponent(), ext: outputExtension)
        do {
            let note = try await runBlocking { cancel -> String? in
                let note = try produce(cancel, first, sources, temporary.url)
                progress(1)
                return note
            }
            try Task.checkCancellation()
            let committed = try temporary.commit(to: final)
            if let note { notes.withLock { $0[committed] = note } }
            await names.release(final)
            return committed
        } catch {
            temporary.discard()
            await names.release(final)
            throw error
        }
    }

    // MARK: checks and dispatch

    private static func validate(_ request: PDFToolRequest, _ sources: [URL]) throws {
        guard !sources.isEmpty else { throw ConversionError.failed("No files selected.") }
        for source in sources where FileName.ext(of: source) != "pdf" {
            throw ConversionError.unsupported(from: FileName.ext(of: source), to: request.toolID)
        }
        if case .merge = request, sources.count < 2 { throw ConversionError.failed("Select at least two files.") }
    }

    private static func validate(_ request: ImageToolRequest, _ sources: [URL]) throws {
        guard !sources.isEmpty else { throw ConversionError.failed("No files selected.") }
        for source in sources {
            let ext = FileName.ext(of: source)
            guard ImageEngine.sources.contains(ext), ext != "svg", ImageFormat(rawValue: ext)?.isReadable == true else {
                throw ConversionError.unsupported(from: ext, to: request.toolID)
            }
            guard ImageFormat(rawValue: ext)?.isWritable == true else {
                throw ConversionError.failed("This Mac cannot write \(ext.uppercased()), so \(source.lastPathComponent) cannot be changed in place.")
            }
        }
    }

    private static func perform(_ request: PDFToolRequest, first: URL, sources: [URL], output: URL, cancel: CancelFlag) throws -> String? {
        switch request {
        case .merge: try PDFTools.merge(sources, to: output, cancel: cancel)
        case let .split(ranges): try PDFTools.split(first, ranges: ranges, intoFolder: output, cancel: cancel)
        case let .organize(order, rotations): try PDFTools.organize(first, order: order, rotations: rotations, to: output, cancel: cancel)
        case let .watermark(options): try PDFTools.watermark(first, options: options, to: output, cancel: cancel)
        case let .number(options): try PDFTools.number(first, options: options, to: output, cancel: cancel)
        case let .unlock(password): try PDFTools.unlock(first, password: password, to: output, cancel: cancel)
        case let .protect(password): try PDFTools.protect(first, password: password, to: output, cancel: cancel)
        }
        return nil
    }

    private static func perform(_ request: ImageToolRequest, first: URL, output: URL, cancel: CancelFlag) throws -> String? {
        switch request {
        case let .compress(options): return try ImageTools.compress(first, to: output, options: options, cancel: cancel)
        case .removeMetadata: try ImageTools.removeMetadata(first, to: output, cancel: cancel)
        case let .editMetadata(fields): try ImageTools.editMetadata(first, fields: fields, to: output, cancel: cancel)
        case let .crop(options): try ImageTools.crop(first, options: options, to: output, cancel: cancel)
        case let .adjust(options): try ImageTools.adjust(first, options: options, to: output, cancel: cancel)
        case let .redact(options): try ImageTools.redact(first, options: options, to: output, cancel: cancel)
        }
        return nil
    }
}
