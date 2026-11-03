import Foundation

/// What the audio and video tools need to know about a file, read from the header ffmpeg prints (`probe` in
/// pomeloo/engines/media.py; there is no ffprobe in the bundled build).
public struct MediaInfo: Sendable, Equatable {
    public var duration: Double = 0
    /// Pixels of the first real video stream; nil for audio files. A cover picture ("attached pic") is not video.
    public var size: (width: Int, height: Int)?
    public var hasAudio = false
    public var audioKbps: Int?
    /// 1 for mono, 2 for stereo, nil when ffmpeg names a layout this does not read.
    public var audioChannels: Int?
    public var fps = 30.0

    public var hasVideo: Bool { size != nil }

    public init() {}

    public static func == (lhs: MediaInfo, rhs: MediaInfo) -> Bool {
        lhs.duration == rhs.duration && lhs.size?.width == rhs.size?.width && lhs.size?.height == rhs.size?.height
            && lhs.hasAudio == rhs.hasAudio && lhs.audioKbps == rhs.audioKbps && lhs.audioChannels == rhs.audioChannels
            && lhs.fps == rhs.fps
    }

    /// Parses the text of `ffmpeg -i file` (the stream lines and the `Duration:` line).
    public static func parse(_ text: String) -> MediaInfo {
        var info = MediaInfo()
        if let seconds = FFmpegEngine.duration(inProbeOutput: text) { info.duration = seconds }
        for line in text.split(separator: "\n") {
            if line.contains("Video:"), !line.contains("attached pic"), info.size == nil,
               let range = line.range(of: #"\b(\d{2,5})x(\d{2,5})\b"#, options: .regularExpression) {
                let parts = line[range].split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                    info.size = (w, h)
                    if let fpsRange = line.range(of: #"([\d.]+) fps"#, options: .regularExpression),
                       let fps = Double(line[fpsRange].dropLast(4)), fps > 0 {
                        info.fps = fps
                    }
                }
            }
            if line.contains("Audio:") {
                info.hasAudio = true
                if info.audioChannels == nil {
                    if line.contains(", mono") { info.audioChannels = 1 } else if line.contains(", stereo") { info.audioChannels = 2 }
                }
                if info.audioKbps == nil, let range = line.range(of: #"(\d+) kb/s"#, options: .regularExpression) {
                    info.audioKbps = Int(line[range].dropLast(5))
                }
            }
        }
        return info
    }
}

/// Times typed by a person: `83.5`, `1:23.5` or `1:02:03`.
public enum TimeText {
    /// Seconds, or nil when the text is not a time.
    public static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// `1:23.5` style text for a number of seconds (the tenth is left out when it is zero).
    public static func text(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let h = tenths / 36000, m = tenths / 600 % 60, s = Double(tenths % 600) / 10
        let secs = s == s.rounded() ? String(format: "%02d", Int(s)) : String(format: "%04.1f", s)
        return h > 0 ? String(format: "%d:%02d:", h, m) + secs : "\(m):" + secs
    }
}
