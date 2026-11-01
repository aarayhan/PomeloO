import os
import XCTest
@testable import PomeloOCore

final class JobRunnerTests: TempDirectoryTestCase {
    // MARK: the runner alone

    func testAJobFinishesWithItsResult() async throws {
        let runner = JobRunner(maxConcurrent: 2)
        let url = URL(fileURLWithPath: "/tmp/result")
        let id = await runner.submit(name: "a") { _ in url }
        let state = await runner.finalState(of: id)
        XCTAssertEqual(state, .finished(url))
    }

    func testAFailureCarriesItsMessage() async throws {
        let runner = JobRunner()
        let id = await runner.submit(name: "a") { _ in throw ConversionError.failed("it broke") }
        let state = await runner.finalState(of: id)
        XCTAssertEqual(state, .failed("it broke"))
    }

    func testNoMoreJobsRunAtOnceThanTheLimit() async throws {
        let runner = JobRunner(maxConcurrent: 2)
        let counter = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))
        var ids: [JobID] = []
        for i in 0..<6 {
            ids.append(await runner.submit(name: "job \(i)") { _ in
                counter.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) }
                try await Task.sleep(nanoseconds: 60_000_000)
                counter.withLock { $0.current -= 1 }
                return URL(fileURLWithPath: "/tmp/x")
            })
        }
        for id in ids { _ = await runner.finalState(of: id) }
        XCTAssertEqual(counter.withLock { $0.peak }, 2)
    }

    func testUpdatesArriveInOrder() async throws {
        let runner = JobRunner(maxConcurrent: 1)
        let stream = await runner.updates()
        let id = await runner.submit(name: "a") { progress in
            for step in 1...10 {
                progress(Double(step) / 10)
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return URL(fileURLWithPath: "/tmp/x")
        }
        var states: [JobState] = []
        for await update in stream where update.id == id {
            states.append(update.state)
            if update.state.isFinal { break }
        }
        XCTAssertEqual(states.first, .queued)
        XCTAssertEqual(states.last, .finished(URL(fileURLWithPath: "/tmp/x")))
        let fractions = states.compactMap { state -> Double? in
            if case let .running(value) = state { return value }
            return nil
        }
        XCTAssertEqual(fractions, fractions.sorted(), "progress went backwards")
        XCTAssertEqual(fractions.last, 1)
    }

    func testAQueuedJobCanBeCancelledBeforeItStarts() async throws {
        let runner = JobRunner(maxConcurrent: 1)
        let started = Collector<String>()
        let first = await runner.submit(name: "first") { _ in
            started.add("first")
            try await Task.sleep(nanoseconds: 200_000_000)
            return URL(fileURLWithPath: "/tmp/x")
        }
        let second = await runner.submit(name: "second") { _ in
            started.add("second")
            return URL(fileURLWithPath: "/tmp/y")
        }
        await runner.cancel(second)
        let secondState = await runner.finalState(of: second)
        XCTAssertEqual(secondState, .cancelled)
        _ = await runner.finalState(of: first)
        XCTAssertEqual(started.values, ["first"])
    }

    func testARunningJobIsToldToStop() async throws {
        let runner = JobRunner()
        let stopped = Collector<Bool>()
        let id = await runner.submit(name: "long") { _ in
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                stopped.add(true)
                throw error
            }
            return URL(fileURLWithPath: "/tmp/x")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await runner.cancel(id)
        let state = try await withTimeout(5) { await runner.finalState(of: id) }
        XCTAssertEqual(state, .cancelled)
        XCTAssertEqual(stopped.values, [true])
    }

    func testCancelAllStopsEverything() async throws {
        let runner = JobRunner(maxConcurrent: 1)
        var ids: [JobID] = []
        for i in 0..<3 {
            ids.append(await runner.submit(name: "job \(i)") { _ in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return URL(fileURLWithPath: "/tmp/x")
            })
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await runner.cancelAll()
        for id in ids {
            let state = try await withTimeout(5) { await runner.finalState(of: id) }
            XCTAssertEqual(state, .cancelled)
        }
        let active = await runner.hasActiveJobs
        XCTAssertFalse(active)
    }

    // MARK: through the service

    private func stubService(_ behavior: @escaping @Sendable (ConversionJob, @escaping @Sendable (Double) -> Void) async throws -> Void) -> ConversionService {
        ConversionService(engines: [StubEngine(pairs: ["png>jpg"], behavior: behavior)], runner: JobRunner(maxConcurrent: 2))
    }

    func testAFailedConversionRemovesItsTemporaryFile() async throws {
        let service = stubService { job, _ in
            try Data("half".utf8).write(to: job.destination)
            throw ConversionError.failed("disk full")
        }
        let source = file("photo.png")
        try Data("png".utf8).write(to: source)
        let ids = await service.enqueue([source], to: "jpg")
        let state = await service.runner.finalState(of: ids[0])
        XCTAssertEqual(state, .failed("disk full"))
        XCTAssertEqual(try names(), ["photo.png"])
    }

    func testACancelledConversionRemovesItsTemporaryFileAndNeverShowsAResult() async throws {
        let started = Collector<Bool>()
        let service = stubService { job, _ in
            try Data("half".utf8).write(to: job.destination)
            started.add(true)
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let source = file("photo.png")
        try Data("png".utf8).write(to: source)
        let ids = await service.enqueue([source], to: "jpg")
        while started.values.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(try names().contains { TemporaryOutput.isTemporaryName($0) }, "the half-written file should be hidden")
        XCTAssertFalse(try names().contains("photo.jpg"))
        await service.runner.cancel(ids[0])
        let state = try await withTimeout(5) { await service.runner.finalState(of: ids[0]) }
        XCTAssertEqual(state, .cancelled)
        XCTAssertEqual(try names(), ["photo.png"])
    }

    func testTheFinalNameAppearsOnlyWhenTheResultIsComplete() async throws {
        let sawFinalName = Collector<Bool>()
        let directory = self.directory!
        let service = stubService { job, progress in
            try Data("complete".utf8).write(to: job.destination)
            progress(0.5)
            sawFinalName.add(FileManager.default.fileExists(atPath: directory.appendingPathComponent("photo.jpg").path))
        }
        let source = file("photo.png")
        try Data("png".utf8).write(to: source)
        let result = try await service.convert(source, to: "jpg")
        XCTAssertEqual(sawFinalName.values, [false])
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "complete")
    }

    func testSeveralFilesBecomeSeveralJobsWithDistinctNames() async throws {
        let service = stubService { job, _ in try Data(job.source.lastPathComponent.utf8).write(to: job.destination) }
        let a = file("photo.png")
        let b = file("photo.PNG.png")  // stem "photo.PNG"
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let ids = await service.enqueue([a, b], to: "jpg")
        var outputs: [String] = []
        for id in ids {
            if case let .finished(url) = await service.runner.finalState(of: id) { outputs.append(url.lastPathComponent) }
        }
        XCTAssertEqual(outputs.sorted(), ["photo.PNG.jpg", "photo.jpg"])
        try assertNoTemporaryFiles()
    }
}
