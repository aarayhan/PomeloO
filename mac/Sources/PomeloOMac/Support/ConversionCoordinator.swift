import AppKit
import PomeloOCore

/// Starts conversions and tells the user how they went: progress in the menu bar while they run, then
/// the results selected in Finder, or a notice for what failed.
@MainActor
final class ConversionCoordinator {
    let service: ConversionService
    private let toast = Toast()
    private var fractions: [JobID: Double] = [:]
    private var watching: Task<Void, Never>?

    /// Overall progress 0...1 while anything runs, nil when idle.
    var onProgress: ((Double?) -> Void)?

    init(service: ConversionService) {
        self.service = service
        watching = Task { [weak self] in
            guard let runner = self?.service.runner else { return }
            for await update in await runner.updates() {
                self?.apply(update)
            }
        }
    }

    deinit { watching?.cancel() }

    func convert(_ files: [URL], to target: String) {
        let service = self.service
        Task { [weak self] in
            let ids = await service.enqueue(files, to: target)
            var outputs: [URL] = []
            var failures: [String] = []
            for (id, file) in zip(ids, files) {
                switch await service.runner.finalState(of: id) {
                case let .finished(url): outputs.append(url)
                case let .failed(message): failures.append("\(file.lastPathComponent): \(message)")
                case .cancelled, .queued, .running: break
                }
                await service.runner.forget(id)
            }
            self?.report(outputs: outputs, failures: failures)
        }
    }

    // MARK: progress

    private func apply(_ update: JobUpdate) {
        switch update.state {
        case .queued: fractions[update.id] = 0
        case let .running(fraction): fractions[update.id] = fraction
        case .finished, .failed, .cancelled: fractions[update.id] = nil
        }
        onProgress?(fractions.isEmpty ? nil : fractions.values.reduce(0, +) / Double(fractions.count))
    }

    // MARK: outcome

    private func report(outputs: [URL], failures: [String]) {
        if !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)  // selects them in Finder
        }
        var lines: [String] = []
        if outputs.count == 1, failures.isEmpty {
            lines.append("Saved \(outputs[0].lastPathComponent)")
        } else if !outputs.isEmpty {
            lines.append("\(outputs.count) file\(outputs.count == 1 ? "" : "s") converted")
        }
        if let first = failures.first {
            lines.append(first)
            if failures.count > 1 { lines.append("and \(failures.count - 1) more failed") }
        }
        if !lines.isEmpty { toast.show(lines.joined(separator: "\n"), seconds: failures.isEmpty ? 4 : 8) }
    }
}
