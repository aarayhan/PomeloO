import AppKit
import PomeloOCore

/// Starts conversions and tools and tells the user how they went: progress in the menu bar while they run, then
/// the results selected in Finder, text copied to the clipboard, or a notice for what failed.
@MainActor
final class ConversionCoordinator {
    let service: ConversionService
    let tools: ToolService
    let toast = Toast()
    private var fractions: [JobID: Double] = [:]
    private var watching: Task<Void, Never>?

    /// Overall progress 0...1 while anything runs, nil when idle.
    var onProgress: ((Double?) -> Void)?

    /// `service` and `tools` share one job runner, so one stream shows the progress of both.
    init(service: ConversionService, tools: ToolService) {
        self.service = service
        self.tools = tools
        watching = Task { [weak self] in
            guard let runner = self?.service.runner else { return }
            for await update in await runner.updates() {
                self?.apply(update)
            }
        }
    }

    deinit { watching?.cancel() }

    // MARK: starting

    func convert(_ files: [URL], to target: String) {
        let service = self.service
        Task { [weak self] in
            let ids = await service.enqueue(files, to: target)
            await self?.finish(ids, files: files)
        }
    }

    /// Runs a tool: files become new files beside the sources, text goes to the clipboard.
    func run(_ invocation: ToolInvocation, on files: [URL]) {
        let tools = self.tools
        Task { [weak self] in
            switch invocation {
            case let .pdf(request):
                let ids = await tools.enqueue(request, on: files)
                await self?.finish(ids, files: files)
            case let .image(request):
                let ids = await tools.enqueue(request, on: files)
                await self?.finish(ids, files: files)
            case let .text(request):
                await self?.copyText(request, from: files)
            }
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

    private func finish(_ ids: [JobID], files: [URL]) async {
        var outputs: [URL] = []
        var notes: [String] = []
        var failures: [String] = []
        for (index, id) in ids.enumerated() {
            let name = files.indices.contains(index) && ids.count == files.count ? files[index].lastPathComponent : "The files"
            switch await service.runner.finalState(of: id) {
            case let .finished(url):
                outputs.append(url)
                if let note = tools.takeNote(for: url) { notes.append("\(url.lastPathComponent): \(note)") }
            case let .failed(message): failures.append("\(name): \(message)")
            case .cancelled, .queued, .running: break
            }
            await service.runner.forget(id)
        }
        report(outputs: outputs, notes: notes, failures: failures)
    }

    private func report(outputs: [URL], notes: [String], failures: [String]) {
        if !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)  // selects them in Finder
        }
        var lines: [String] = []
        if outputs.count == 1, failures.isEmpty {
            lines.append("Saved \(outputs[0].lastPathComponent)")
        } else if !outputs.isEmpty {
            lines.append("\(outputs.count) file\(outputs.count == 1 ? "" : "s") saved")
        }
        lines += notes.prefix(2)
        if let first = failures.first {
            lines.append(first)
            if failures.count > 1 { lines.append("and \(failures.count - 1) more failed") }
        }
        if !lines.isEmpty { toast.show(lines.joined(separator: "\n"), seconds: failures.isEmpty && notes.isEmpty ? 4 : 8) }
    }

    private func copyText(_ request: TextToolRequest, from files: [URL]) async {
        do {
            let text = try await tools.text(request, from: files)
            guard !text.isEmpty else {
                toast.show("No text found.")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(70)
            toast.show("Copied \(text.count) character\(text.count == 1 ? "" : "s"): \(preview)\(text.count > 70 ? "…" : "")")
        } catch {
            toast.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, seconds: 8)
        }
    }
}
