import Foundation

/// Ties the catalog, the engines, the naming rules and the job runner together: what a drop on the wheel
/// calls. The catalog says what may be converted; the engines say what this Mac can do.
public final class ConversionService: Sendable {
    public let catalog: Catalog
    public let runner: JobRunner
    private let engines: [any ConversionEngine]
    private let names = NameReserver()

    /// Apple frameworks first, ffmpeg for what they cannot do (WebP output, and audio and video beyond AVFoundation).
    public static func defaultEngines() -> [any ConversionEngine] {
        [ImageEngine(), WebPEngine(), AppleAudioEngine(), FFmpegEngine()]
    }

    public init(catalog: Catalog = .bundled,
                engines: [any ConversionEngine] = ConversionService.defaultEngines(),
                runner: JobRunner = JobRunner()) {
        self.catalog = catalog
        self.engines = engines
        self.runner = runner
    }

    // MARK: what is possible here

    public func engine(from: String, to: String) -> (any ConversionEngine)? {
        engines.first { $0.canConvert(from: from, to: to) }
    }

    /// The catalog's targets for this extension that some engine can write on this Mac, in catalog order.
    public func availableTargets(forExtension ext: String) -> [String] {
        catalog.targets(forExtension: ext).filter { engine(from: ext, to: $0) != nil }
    }

    /// Targets every one of these extensions can become: what the wheel shows for a mixed selection.
    public func commonTargets(forExtensions exts: [String]) -> [String] {
        guard let first = exts.first else { return [] }
        let others = exts.dropFirst().map { Set(availableTargets(forExtension: $0)) }
        return availableTargets(forExtension: first).filter { target in others.allSatisfy { $0.contains(target) } }
    }

    // MARK: converting

    /// Converts one file and returns the new file, next to the source. The source is never touched.
    /// The result appears under its final name only when it is complete.
    @discardableResult
    public func convert(_ source: URL, to target: String,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let ext = FileName.ext(of: source)
        guard catalog.targets(forExtension: ext).contains(target), let engine = engine(from: ext, to: target) else {
            throw ConversionError.unsupported(from: ext, to: target)
        }
        let finalName = await names.reserve(OutputNaming.proposed(for: source, ext: target))
        let temporary = TemporaryOutput(directory: source.deletingLastPathComponent(), ext: target)
        do {
            try await engine.convert(
                ConversionJob(source: source, sourceExtension: ext, target: target, destination: temporary.url),
                progress: progress)
            try Task.checkCancellation()
            let committed = try temporary.commit(to: finalName)
            await names.release(finalName)
            return committed
        } catch {
            temporary.discard()
            await names.release(finalName)
            throw error
        }
    }

    /// Queues one job per file. Progress and results come through `runner`.
    @discardableResult
    public func enqueue(_ sources: [URL], to target: String) async -> [JobID] {
        var ids: [JobID] = []
        for source in sources {
            let id = await runner.submit(name: source.lastPathComponent) { [self] progress in
                try await convert(source, to: target, progress: progress)
            }
            ids.append(id)
        }
        return ids
    }
}
