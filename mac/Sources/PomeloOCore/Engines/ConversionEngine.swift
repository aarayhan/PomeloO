import Foundation

/// One conversion: read `source`, write `destination`. The destination is a hidden temporary file that
/// the caller renames to the final name, so an engine writes exactly there and nowhere else.
public struct ConversionJob: Sendable {
    public let source: URL
    public let sourceExtension: String
    public let target: String
    public let destination: URL

    public init(source: URL, sourceExtension: String, target: String, destination: URL) {
        self.source = source
        self.sourceExtension = sourceExtension
        self.target = target
        self.destination = destination
    }
}

/// An engine converts some pairs on this machine. `canConvert` is about what the machine can do now
/// (a framework without an encoder, a missing ffmpeg), not about what the catalog lists.
public protocol ConversionEngine: Sendable {
    var name: String { get }
    func canConvert(from: String, to: String) -> Bool
    /// Must stop soon after the calling task is cancelled by throwing `CancellationError`. `progress`
    /// takes 0...1 and may be called from any thread.
    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws
}

public enum ConversionError: Error, Equatable, LocalizedError {
    case unsupported(from: String, to: String)
    case cannotRead(String)
    case cannotWrite(String)
    case engineUnavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(from, to): "Can't convert .\(from) to \(to) on this Mac."
        case let .cannotRead(name): "Can't read \(name)."
        case let .cannotWrite(name): "Can't write \(name)."
        case let .engineUnavailable(name): "\(name) is not available."
        case let .failed(message): message
        }
    }
}
