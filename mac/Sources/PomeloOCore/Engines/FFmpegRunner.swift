import Foundation
import os

/// Runs one ffmpeg process. Standard output and standard error are both read as the process runs: a pipe
/// nobody reads fills up (about 64 KB) and stalls ffmpeg for good. Cancelling the task terminates the process.
struct FFmpegRunner: Sendable {
    let executable: URL
    /// Lines of standard error kept for the error message; reading a header needs far more than an error does.
    var tailLines = 40

    /// Returns the tail of standard error. `onOutputLine` gets every line of standard output (`-progress pipe:1`).
    @discardableResult
    func run(_ arguments: [String], onOutputLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let finishedReading = DispatchGroup()
        let tail = LineTail(limit: tailLines)
        let outputReader = LineReader(output.fileHandleForReading, group: finishedReading, onLine: onOutputLine)
        let errorReader = LineReader(errors.fileHandleForReading, group: finishedReading) { tail.add($0) }

        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let handle = ProcessHandle(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                process.terminationHandler = { finished in
                    // Both pipes must be read to their end before the tail is complete.
                    finishedReading.notify(queue: .global()) {
                        if cancelled.withLock({ $0 }) {
                            continuation.resume(throwing: CancellationError())
                        } else if finished.terminationStatus != 0 {
                            continuation.resume(throwing: ConversionError.failed(
                                Self.message(from: tail.text, status: finished.terminationStatus)))
                        } else {
                            continuation.resume(returning: tail.text)
                        }
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    outputReader.stop()
                    errorReader.stop()
                    continuation.resume(throwing: ConversionError.engineUnavailable("ffmpeg (\(error.localizedDescription))"))
                    return
                }
                // The child has its own copies; ours must close or the readers never see the end.
                try? output.fileHandleForWriting.close()
                try? errors.fileHandleForWriting.close()
                if Task.isCancelled {  // cancelled between the first check and the launch
                    cancelled.withLock { $0 = true }
                    handle.terminate()
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            handle.terminate()
        }
    }

    private static func message(from tail: String, status: Int32) -> String {
        let lines = tail.split(separator: "\n").suffix(4).joined(separator: "\n")
        return lines.isEmpty ? "ffmpeg stopped with status \(status)." : "ffmpeg: \(lines)"
    }
}

/// Reads a pipe in the background and hands out complete lines. Leaves `group` when the pipe ends.
private final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let group: DispatchGroup
    private let onLine: @Sendable (String) -> Void
    private let state = OSAllocatedUnfairLock(initialState: (pending: Data(), ended: false))

    init(_ handle: FileHandle, group: DispatchGroup, onLine: @escaping @Sendable (String) -> Void) {
        self.handle = handle
        self.group = group
        self.onLine = onLine
        group.enter()
        // Strong on purpose: the reader must live until the pipe ends, whatever the caller does with it.
        // `stop()` clears the handler and so ends the cycle.
        handle.readabilityHandler = { readable in
            self.receive(readable.availableData)
        }
    }

    private func receive(_ data: Data) {
        if data.isEmpty {  // end of the pipe
            let rest = state.withLock { state -> Data in
                defer { state.pending = Data() }
                return state.pending
            }
            if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
            stop()
            return
        }
        let lines = state.withLock { state -> [Data] in
            state.pending.append(data)
            var complete: [Data] = []
            while let newline = state.pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                complete.append(state.pending[state.pending.startIndex..<newline])
                state.pending.removeSubrange(state.pending.startIndex...newline)
            }
            return complete
        }
        for line in lines where !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
    }

    /// Stops reading and lets go of the group; safe to call twice.
    func stop() {
        handle.readabilityHandler = nil
        let first = state.withLock { state -> Bool in
            defer { state.ended = true }
            return !state.ended
        }
        if first { group.leave() }
    }
}

/// The last lines of standard error.
private final class LineTail: @unchecked Sendable {
    private let limit: Int
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    init(limit: Int) { self.limit = limit }

    func add(_ line: String) {
        lines.withLock { lines in
            lines.append(line)
            if lines.count > limit { lines.removeFirst() }
        }
    }

    var text: String { lines.withLock { $0.joined(separator: "\n") } }
}

/// `Process` is not Sendable; `terminate` is safe to call from any thread once it is running.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
