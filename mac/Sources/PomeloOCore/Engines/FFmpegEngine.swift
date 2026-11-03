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

    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "wmv"]
    private static var audio: Set<String> { audioExtensions }
    private static var video: Set<String> { videoExtensions }

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
        guard let codec = Self.outputArguments(for: job.target, encoders: FFmpegEncoders.available(at: executable)) else {
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

    static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    /// H.264 settings. Windows uses libx264 at CRF 23; Apple's encoder has no CRF, its `-q:v` (0 to 100) is the nearest
    /// thing. **[BELUM DIUJI]** that 65 looks as good as CRF 23 on real footage; only synthetic clips were compared.
    static func h264Arguments(encoder: String) -> [String] {
        encoder == "libx264"
            ? ["-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p"]
            : ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]
    }

    /// The audio encoder and its settings for an audio extension (`AUDIO_CODEC` in pomeloo/engines/media.py).
    static func audioCodec(for ext: String) -> [String]? {
        switch ext {
        case "mp3": ["-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": ["-c:a", "aac", "-b:a", "192k"]
        case "wav": ["-c:a", "pcm_s16le"]
        case "flac": ["-c:a", "flac"]
        case "ogg": ["-c:a", "libvorbis", "-q:a", "5"]
        case "opus": ["-c:a", "libopus", "-b:a", "128k"]
        case "aiff": ["-c:a", "pcm_s16be"]
        case "wma": ["-c:a", "wmav2", "-b:a", "192k"]
        default: nil
        }
    }

    /// Video and audio encoders and settings for a video extension (`VIDEO_CODEC`). `encoders` is what the ffmpeg
    /// in use can write (nil when unknown); it picks the H.264 encoder.
    static func videoCodec(for ext: String, encoders: Set<String>? = nil) -> [String]? {
        switch ext {
        case "mp4": h264Arguments(encoder: FFmpegEncoders.h264(in: encoders)) + ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case "mov", "mkv": h264Arguments(encoder: FFmpegEncoders.h264(in: encoders)) + ["-c:a", "aac", "-b:a", "160k"]
        case "webm": ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"]
        case "avi": ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv": ["-c:v", "wmv2", "-q:v", "3", "-c:a", "wmav2", "-b:a", "160k"]
        default: nil
        }
    }

    /// Everything between the input and the output file for this target. `encoders` is what the ffmpeg in use can
    /// write (nil when unknown); it picks the H.264 encoder.
    static func outputArguments(for target: String, encoders: Set<String>? = nil) -> [String]? {
        if let audio = audioCodec(for: target) { return ["-vn"] + audio }
        if let video = videoCodec(for: target, encoders: encoders) { return ["-vf", evenSize] + video }
        if target == "gif" {
            return ["-filter_complex", "fps=12,scale='min(iw,640)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                    "-loop", "0"]
        }
        return nil
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
