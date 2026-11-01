import Foundation

public struct JobID: Hashable, Sendable {
    let raw = UUID()
}

public enum JobState: Sendable, Equatable {
    case queued
    case running(Double)
    case finished(URL)
    case failed(String)
    case cancelled

    public var isFinal: Bool {
        switch self {
        case .finished, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

public struct JobUpdate: Sendable, Equatable {
    public let id: JobID
    public let name: String
    public let state: JobState
}

/// Runs jobs a few at a time and reports their progress. Finished jobs stay queryable until `forget`.
public actor JobRunner {
    public typealias Work = @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> URL

    private struct Entry {
        let name: String
        let work: Work
        var state: JobState = .queued
        var task: Task<Void, Never>?
        var cancelRequested = false
        var lastReported = -1.0
    }

    private var entries: [JobID: Entry] = [:]
    private var queue: [JobID] = []
    private var running = 0
    private let limit: Int
    private var subscribers: [UUID: AsyncStream<JobUpdate>.Continuation] = [:]
    private var waiters: [JobID: [CheckedContinuation<JobState, Never>]] = [:]

    /// `maxConcurrent` defaults to half the cores (at least 2), like the Windows app.
    public init(maxConcurrent: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) {
        limit = max(1, maxConcurrent)
    }

    // MARK: submitting

    @discardableResult
    public func submit(name: String, work: @escaping Work) -> JobID {
        let id = JobID()
        entries[id] = Entry(name: name, work: work)
        queue.append(id)
        publish(id)
        startWaiting()
        return id
    }

    public func state(of id: JobID) -> JobState? { entries[id]?.state }

    /// Waits for the job to be finished, failed or cancelled.
    public func finalState(of id: JobID) async -> JobState {
        guard let entry = entries[id] else { return .cancelled }
        if entry.state.isFinal { return entry.state }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    public func forget(_ id: JobID) {
        if let entry = entries[id], entry.state.isFinal { entries[id] = nil }
    }

    // MARK: cancelling

    /// A queued job never starts. A running one is told to stop; its engine removes what it wrote.
    public func cancel(_ id: JobID) {
        guard var entry = entries[id], !entry.state.isFinal else { return }
        if let position = queue.firstIndex(of: id) {
            queue.remove(at: position)
            entry.state = .cancelled
            entries[id] = entry
            publish(id)
            resumeWaiters(id, entry.state)
        } else {
            entry.cancelRequested = true
            entries[id] = entry
            entry.task?.cancel()
        }
    }

    public func cancelAll() {
        for id in Array(entries.keys) { cancel(id) }
    }

    public var hasActiveJobs: Bool { entries.values.contains { !$0.state.isFinal } }

    // MARK: updates

    /// A stream of every state change from now on.
    public func updates() -> AsyncStream<JobUpdate> {
        let key = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: JobUpdate.self)
        subscribers[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(key) }
        }
        return stream
    }

    private func removeSubscriber(_ key: UUID) { subscribers[key] = nil }

    private func publish(_ id: JobID) {
        guard let entry = entries[id] else { return }
        let update = JobUpdate(id: id, name: entry.name, state: entry.state)
        for continuation in subscribers.values { continuation.yield(update) }
    }

    private func resumeWaiters(_ id: JobID, _ state: JobState) {
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: state) }
    }

    // MARK: running

    private func startWaiting() {
        while running < limit, !queue.isEmpty {
            start(queue.removeFirst())
        }
    }

    private func start(_ id: JobID) {
        guard var entry = entries[id] else { return }
        running += 1
        entry.state = .running(0)
        let work = entry.work

        // Progress arrives from engine threads. A stream keeps the reports in order on their way to the actor.
        let (reports, sink) = AsyncStream.makeStream(of: Double.self)
        let forwarder = Task { [weak self] in
            for await fraction in reports { await self?.report(id, fraction) }
        }
        entry.task = Task { [weak self] in
            let outcome: Result<URL, Error>
            do {
                outcome = .success(try await work { sink.yield($0) })
            } catch {
                outcome = .failure(error)
            }
            sink.finish()
            await forwarder.value
            await self?.finish(id, outcome)
        }
        entries[id] = entry
        publish(id)
    }

    /// One update per percent, and never backwards.
    private func report(_ id: JobID, _ fraction: Double) {
        guard var entry = entries[id], case .running = entry.state else { return }
        let value = min(1, max(0, fraction))
        guard value - entry.lastReported >= 0.01 || (value >= 1 && entry.lastReported < 1) else { return }
        entry.lastReported = value
        entry.state = .running(value)
        entries[id] = entry
        publish(id)
    }

    private func finish(_ id: JobID, _ outcome: Result<URL, Error>) {
        guard var entry = entries[id] else { return }
        running -= 1
        entry.task = nil
        switch outcome {
        case let .success(url):
            if entry.cancelRequested {
                // Cancelled too late to stop the engine: the result is thrown away like any other cancelled one.
                try? FileManager.default.removeItem(at: url)
                entry.state = .cancelled
            } else {
                entry.state = .finished(url)
            }
        case let .failure(error):
            if entry.cancelRequested || error is CancellationError {
                entry.state = .cancelled
            } else {
                entry.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        entries[id] = entry
        publish(id)
        resumeWaiters(id, entry.state)
        startWaiting()
    }
}
