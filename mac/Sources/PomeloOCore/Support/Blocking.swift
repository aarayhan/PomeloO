import Foundation
import os

/// Set when the surrounding task is cancelled; blocking loops poll it.
final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { state.withLock { $0 } }

    func cancel() { state.withLock { $0 = true } }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Runs blocking framework calls (ImageIO, AVAudioFile) off the cooperative thread pool, and turns
/// cancellation of the calling task into a flag the work polls.
func runBlocking<T: Sendable>(
    _ work: @escaping @Sendable (CancelFlag) throws -> T
) async throws -> T {
    let flag = CancelFlag()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try flag.check()
                    continuation.resume(returning: try work(flag))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    } onCancel: {
        flag.cancel()
    }
}
