import CoreGraphics
import Foundation

/// What an audio or video tool is asked to do, with its options. Times are seconds, regions are fractions of the
/// picture (x, y, width, height, y down from the top), as in pomeloo/tools/media.py.
public enum MediaToolRequest: Sendable, Equatable {
    case compress(MediaCompressOptions)
    /// nil removes all metadata; fields (title, artist, album, genre, date, comment) are set and the rest is kept.
    case metadata(fields: [String: String]?)
    case normalize(NormalizeOptions)
    case visualize(VisualizeOptions)
    case trimAudio(TrimOptions)
    case channels(ChannelOptions)
    case bleep(BleepOptions)
    case mute
    case trimVideo(TrimOptions)
    case cropVideo(VideoCropOptions)
    case speed(factor: Double)
    case snapshots(SnapshotOptions)
    case splitVideo(SplitOptions)
    case redactVideo(VideoRedactOptions)
    case join

    public var toolID: String {
        switch self {
        case .compress: "compress"
        case .metadata: "removeMetadata"
        case .normalize: "normalizeAudio"
        case .visualize: "audioToVideo"
        case .trimAudio: "trimAudio"
        case .channels: "audioChannels"
        case .bleep: "redactAudio"
        case .mute: "muteVideo"
        case .trimVideo: "trimVideo"
        case .cropVideo: "cropVideo"
        case .speed: "changeVideoSpeed"
        case .snapshots: "videoSnapshots"
        case .splitVideo: "splitVideo"
        case .redactVideo: "redactVideo"
        case .join: "joinVideos"
        }
    }

    /// Editing metadata is named "Edited", not "No Metadata" (as for pictures).
    var label: String? {
        switch self {
        case .metadata(let fields?) where !fields.isEmpty: "Edited"
        case .snapshots(let options) where options.isSeveral: "Snapshots"
        default: ToolSpecs.all[toolID]?.label
        }
    }

    /// The extension of the result when it is not the source's own (`outputExtension` of the tool's spec, with the
    /// cases that depend on the options: several snapshots go in a folder, WAV and AIFF shrink to FLAC).
    func outputExtension(forSource ext: String) -> String? {
        switch self {
        case .snapshots(let options): options.isSeveral ? "folder" : "png"
        case .compress where ext == "wav" || ext == "aiff": "flac"
        default: ToolSpecs.all[toolID]?.outputExtension
        }
    }
}

public struct MediaCompressOptions: Sendable, Equatable {
    public var percent: Int
    /// Aim for exactly this many kilobytes; wins over `percent` when above zero.
    public var targetKB: Int
    /// Video only: scale to this percentage of the size first (10...100).
    public var resizePercent: Int

    public init(percent: Int = 50, targetKB: Int = 0, resizePercent: Int = 100) {
        self.percent = percent
        self.targetKB = targetKB
        self.resizePercent = resizePercent
    }

    public init(preset: CompressOptions.Preset, resizePercent: Int = 100) {
        self.init(percent: preset.rawValue, resizePercent: resizePercent)
    }
}

public struct NormalizeOptions: Sendable, Equatable {
    /// Integrated loudness target in LUFS, loudness range in LU and true peak in dBTP (EBU R128).
    public var loudness: Double
    public var range: Double
    public var truePeak: Double

    public init(loudness: Double = -16, range: Double = 11, truePeak: Double = -1.5) {
        self.loudness = loudness
        self.range = range
        self.truePeak = truePeak
    }
}

public struct VisualizeOptions: Sendable, Equatable {
    public enum Style: String, Sendable, CaseIterable { case waves, spectrum, image }
    public enum Shape: String, Sendable, CaseIterable { case landscape, portrait, square }

    public var style: Style
    public var color: String
    /// The picture shown for the `image` style.
    public var image: URL?
    public var shape: Shape

    public init(style: Style = .waves, color: String = "#ff8a00", image: URL? = nil, shape: Shape = .landscape) {
        self.style = style
        self.color = color
        self.image = image
        self.shape = shape
    }
}

public struct TrimOptions: Sendable, Equatable {
    public var start: Double
    /// 0 keeps everything from `start` to the end.
    public var end: Double
    /// Audio only: also cut silence at the start and end.
    public var trimSilence: Bool

    public init(start: Double = 0, end: Double = 0, trimSilence: Bool = false) {
        self.start = start
        self.end = end
        self.trimSilence = trimSilence
    }
}

public struct ChannelOptions: Sendable, Equatable {
    /// 1 (mono) or 2 (stereo).
    public var channels: Int
    /// Volume of each side in percent.
    public var left: Int
    public var right: Int

    public init(channels: Int = 1, left: Int = 100, right: Int = 100) {
        self.channels = channels
        self.left = left
        self.right = right
    }
}

/// A stretch of time, in seconds.
public struct TimeRange: Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public struct BleepOptions: Sendable, Equatable {
    public enum Mode: String, Sendable, CaseIterable { case beep, mute }

    public var ranges: [TimeRange]
    public var mode: Mode
    /// Pitch of the beep in hertz.
    public var frequency: Int

    public init(ranges: [TimeRange] = [], mode: Mode = .beep, frequency: Int = 1000) {
        self.ranges = ranges
        self.mode = mode
        self.frequency = frequency
    }
}

public struct VideoCropOptions: Sendable, Equatable {
    /// The area to keep; nil takes the biggest area of the chosen aspect (or exact size's ratio) from the middle.
    public var rect: CGRect?
    public var aspect: String
    /// With both above zero the result has exactly these pixels.
    public var width: Int
    public var height: Int

    public init(rect: CGRect? = nil, aspect: String = "free", width: Int = 0, height: Int = 0) {
        self.rect = rect
        self.aspect = aspect
        self.width = width
        self.height = height
    }
}

public struct SnapshotOptions: Sendable, Equatable {
    /// This many frames, evenly spaced; ignored when `times` is not empty.
    public var count: Int
    /// Exact moments in seconds.
    public var times: [Double]

    public init(count: Int = 1, times: [Double] = []) {
        self.count = count
        self.times = times
    }

    /// More than one picture goes in a folder; one is a file.
    var isSeveral: Bool { times.isEmpty ? count > 1 : times.count > 1 }
}

public struct SplitOptions: Sendable, Equatable {
    /// Equal parts, or clips of `seconds` each, or cuts at `points`: the first of these that is set, last to first.
    public var parts: Int
    public var seconds: Double
    public var points: [Double]
    /// Re-encode so cuts land exactly; otherwise the streams are copied and cuts land on key frames (fast).
    public var precise: Bool

    public init(parts: Int = 2, seconds: Double = 0, points: [Double] = [], precise: Bool = true) {
        self.parts = parts
        self.seconds = seconds
        self.points = points
        self.precise = precise
    }
}

public struct VideoRedactOptions: Sendable, Equatable {
    public enum Style: String, Sendable, CaseIterable { case blur, black, color }

    public struct Region: Sendable, Equatable {
        public var rect: CGRect
        /// Only part of the video; nil covers all of it.
        public var time: TimeRange?

        public init(rect: CGRect, time: TimeRange? = nil) {
            self.rect = rect
            self.time = time
        }
    }

    public var regions: [Region]
    public var style: Style
    public var color: String

    public init(regions: [Region] = [], style: Style = .blur, color: String = "#000000") {
        self.regions = regions
        self.style = style
        self.color = color
    }
}
