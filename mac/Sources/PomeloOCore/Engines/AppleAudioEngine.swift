import AVFoundation
import Foundation

/// Audio that AVFoundation can both read and write on this Mac: WAV and AIFF (16-bit PCM), AAC in M4A
/// (192 kbps), and FLAC when the system can encode it. Everything else (MP3, OGG, Opus, WMA targets)
/// goes to ffmpeg.
public struct AppleAudioEngine: ConversionEngine {
    public let name = "AVFoundation"

    private static let readable: Set<String> = ["mp3", "m4a", "wav", "flac", "aiff"]
    /// Decided once by trying to open an empty file for each format.
    private static let writable: Set<String> = {
        var found: Set<String> = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomeloo-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for target in ["wav", "aiff", "m4a", "flac"] {
            let url = directory.appendingPathComponent("probe.\(target)")
            if (try? makeOutput(url, target: target, sampleRate: 44_100, channels: 2)) != nil { found.insert(target) }
        }
        return found
    }()

    public init() {}

    public func canConvert(from: String, to: String) -> Bool {
        from != to && Self.readable.contains(from) && Self.writable.contains(to)
    }

    public func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await runBlocking { cancel in
            let input: AVAudioFile
            do { input = try AVAudioFile(forReading: job.source) } catch {
                throw ConversionError.cannotRead(job.source.lastPathComponent)
            }
            let format = input.processingFormat
            let output: AVAudioFile
            do {
                output = try Self.makeOutput(job.destination, target: job.target,
                                             sampleRate: format.sampleRate, channels: Int(format.channelCount))
            } catch {
                throw ConversionError.cannotWrite(job.destination.lastPathComponent)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
                throw ConversionError.failed("Not enough memory to convert this audio.")
            }
            let total = Double(max(input.length, 1))
            while input.framePosition < input.length {
                try cancel.check()
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
                progress(min(1, Double(input.framePosition) / total))
            }
            progress(1)
        }
    }

    private static func makeOutput(_ url: URL, target: String, sampleRate: Double, channels: Int) throws -> AVAudioFile {
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        switch target {
        case "wav", "aiff":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = target == "aiff"
            settings[AVLinearPCMIsNonInterleaved] = false
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 192_000
        case "flac":
            settings[AVFormatIDKey] = kAudioFormatFLAC
        default:
            throw ConversionError.unsupported(from: "audio", to: target)
        }
        return try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}
