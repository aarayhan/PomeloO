import Foundation

/// Finds the ffmpeg to run.
public enum FFmpegLocator {
    /// In order: `POMELOO_FFMPEG`, the copy inside the app (`Contents/Resources/Tools/ffmpeg`), then the
    /// Homebrew locations. The Homebrew copies are a convenience for development; their encoders vary, so
    /// a release build is expected to carry its own.
    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [String] = []
        if let override = environment["POMELOO_FFMPEG"], !override.isEmpty { candidates.append(override) }
        if let tools = Bundle.main.resourceURL?.appendingPathComponent("Tools/ffmpeg") { candidates.append(tools.path) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// Audio and video through a bundled or installed ffmpeg. The encoder settings are the ones of
/// pomeloo/engines/media.py, so a file converted on either system is comparable.
public struct FFmpegEngine: ConversionEngine {
    public let name = "ffmpeg"
    private let executable: URL?

    private static let audio: Set<String> = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
    private static let video: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "wmv"]

    public init(executable: URL? = FFmpegLocator.find()) {
        self.executable = executable
    }

    public var isAvailable: Bool { executable != nil }

    public func canConvert(from: String, to: String) -> Bool {
        guard let executable, from != to else { return false }
        let pair: Bool
        if from == "gif" {
            pair = Self.video.contains(to)  // a GIF only becomes video
        } else {
            let media = Self.audio.union(Self.video)
            pair = media.contains(from) && (media.contains(to) || to == "gif")
        }
        return pair && FFmpegEncoders.supports(to, at: executable)
    }

    public func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let executable else { throw ConversionError.engineUnavailable("ffmpeg") }
        guard let codec = Self.outputArguments(for: job.target) else {
            throw ConversionError.unsupported(from: job.sourceExtension, to: job.target)
        }
        let runner = FFmpegRunner(executable: executable)

        // Look at the file first (reads the streams, writes nothing): a bad file fails here, not halfway,
        // and the header gives the duration that progress is measured against.
        let probe = try await runner.run(Self.probeArguments(input: job.source))
        let duration = Self.duration(inProbeOutput: probe)

        let arguments = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats", "-loglevel", "error",
                         "-i", job.source.path] + codec + [job.destination.path]
        try await runner.run(arguments) { line in
            if let fraction = Self.progress(fromLine: line, duration: duration) { progress(fraction) }
        }
        progress(1)
    }

    // MARK: arguments

    static func probeArguments(input: URL) -> [String] {
        ["-hide_banner", "-nostdin", "-i", input.path, "-map", "0:v?", "-map", "0:a?", "-c", "copy",
         "-t", "0", "-f", "null", "-"]
    }

    private static let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p"]
    private static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    /// Everything between the input and the output file for this target.
    static func outputArguments(for target: String) -> [String]? {
        switch target {
        case "mp3": ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "wav": ["-vn", "-c:a", "pcm_s16le"]
        case "flac": ["-vn", "-c:a", "flac"]
        case "ogg": ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case "opus": ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "aiff": ["-vn", "-c:a", "pcm_s16be"]
        case "wma": ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        case "mp4": ["-vf", evenSize] + h264 + ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case "mov", "mkv": ["-vf", evenSize] + h264 + ["-c:a", "aac", "-b:a", "160k"]
        case "webm": ["-vf", evenSize, "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"]
        case "avi": ["-vf", evenSize, "-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv": ["-vf", evenSize, "-c:v", "wmv2", "-q:v", "3", "-c:a", "wmav2", "-b:a", "160k"]
        case "gif":
            ["-filter_complex", "fps=12,scale='min(iw,640)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
             "-loop", "0"]
        default: nil
        }
    }

    // MARK: reading ffmpeg's output

    /// `Duration: 00:01:02.50` in the header, in seconds; nil when ffmpeg prints N/A (live or broken files).
    static func duration(inProbeOutput text: String) -> Double? {
        guard let range = text.range(of: #"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) else { return nil }
        let parts = text[range].dropFirst("Duration: ".count).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// One line of `-progress` output as a fraction: `out_time_us=1500000` against the duration, `progress=end` as 1.
    static func progress(fromLine line: String, duration: Double?) -> Double? {
        if line == "progress=end" { return 1 }
        guard line.hasPrefix("out_time_us="), let duration, duration > 0,
              let microseconds = Double(line.dropFirst("out_time_us=".count)) else { return nil }  // "N/A" before the first frame
        return min(1, max(0, microseconds / 1_000_000 / duration))
    }
}
