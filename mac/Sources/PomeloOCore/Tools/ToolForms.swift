import Foundation

/// A tool and its settings, ready to run.
public enum ToolInvocation: Sendable, Equatable {
    case pdf(PDFToolRequest)
    case image(ImageToolRequest)
    case text(TextToolRequest)
    case media(MediaToolRequest)
}

/// What a form says is wrong with what was typed; shown under the form.
public struct ToolFormError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The settings a tool's dialog edits, kept apart from the dialog so they can be tested: each form holds what
/// the person typed or picked, and turns it into a request or says what is wrong. The SwiftUI views only bind to these.
public enum ToolForms {
    /// Tools that show a dialog before they run. Reading QR codes and text recognition need no settings.
    public static let withDialog: Set<String> = [
        "compress", "removeMetadata", "editImage", "cropImage", "redactImage",
        "splitPDF", "organizePDF", "mergePDF", "protectPDF", "unlockPDF", "watermarkPDF", "numberPDF",
        "normalizeAudio", "audioToVideo", "trimAudio", "audioChannels", "redactAudio",
        "trimVideo", "cropVideo", "changeVideoSpeed", "videoSnapshots", "splitVideo", "redactVideo", "joinVideos",
    ]

    /// Audio and video files get the media forms for the tools they share with pictures and PDFs (compress, metadata).
    public static func isMedia(_ url: URL) -> Bool {
        let ext = FileName.ext(of: url)
        return FFmpegEngine.audioExtensions.contains(ext) || FFmpegEngine.videoExtensions.contains(ext)
    }

    public static func isVideo(_ url: URL) -> Bool { FFmpegEngine.videoExtensions.contains(FileName.ext(of: url)) }

    /// The request of a tool that has no settings.
    public static func invocationWithoutDialog(toolID: String) -> ToolInvocation? {
        switch toolID {
        case "readQR": .text(.readCodes)
        case "extractText": .text(.recognizeText)
        case "muteVideo": .media(.mute)
        default: nil
        }
    }
}

// MARK: pictures

public struct CompressForm: Sendable, Equatable {
    public enum Quality: String, CaseIterable, Sendable { case custom, highQuality, balanced, smallest }
    public var quality = Quality.custom
    /// Used by "custom": the share of the original size to aim for (5...95), or an exact size in KB (0 = not used).
    public var percent = 50
    public var targetKB = 0
    public var resizePercent = 100

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard (10...100).contains(resizePercent) else { throw ToolFormError("Resize goes from 10% to 100%.") }
        switch quality {
        case .custom:
            guard (5...95).contains(percent) else { throw ToolFormError("The target size goes from 5% to 95%.") }
            guard targetKB >= 0 else { throw ToolFormError("The exact size cannot be negative.") }
            return .image(.compress(CompressOptions(percent: percent, targetKB: targetKB, resizePercent: resizePercent)))
        case .highQuality: return .image(.compress(CompressOptions(preset: .highQuality, resizePercent: resizePercent)))
        case .balanced: return .image(.compress(CompressOptions(preset: .balanced, resizePercent: resizePercent)))
        case .smallest: return .image(.compress(CompressOptions(preset: .smallest, resizePercent: resizePercent)))
        }
    }
}

public struct MetadataForm: Sendable, Equatable {
    public enum Mode: String, CaseIterable, Sendable { case remove, edit }
    public var mode = Mode.remove
    public var title = ""
    public var artist = ""
    public var copyright = ""
    public var make = ""
    public var model = ""
    public var software = ""

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard mode == .edit else { return .image(.removeMetadata) }
        let fields = ["title": title, "artist": artist, "copyright": copyright, "make": make, "model": model, "software": software]
            .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !fields.isEmpty else { throw ToolFormError("Fill in at least one field, or choose Remove.") }
        return .image(.editMetadata(fields: fields))
    }
}

public struct CropForm: Sendable, Equatable {
    public static let aspects = ["free", "1:1", "4:5", "4:3", "3:2", "16:9", "9:16", "3:4"]
    public var aspect = "free"
    public var width = 0
    public var height = 0

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard Self.aspects.contains(aspect) else { throw ToolFormError("Unknown aspect ratio \(aspect).") }
        guard width >= 0, height >= 0, width <= 20_000, height <= 20_000 else { throw ToolFormError("Width and height go from 0 to 20000 px.") }
        guard (width == 0) == (height == 0) else { throw ToolFormError("Give both the width and the height, or neither.") }
        if aspect == "free", width == 0 { throw ToolFormError("Choose an aspect ratio or exact pixels.") }
        return .image(.crop(CropOptions(aspect: aspect, width: width, height: height)))
    }
}

public struct RedactForm: Sendable, Equatable {
    public var style = RedactOptions.Style.pixelate
    public var color = "#000000"
    public var auto = RedactOptions.Auto.both

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard auto != .none else { throw ToolFormError("Choose what to cover: faces, text or both.") }
        return .image(.redact(RedactOptions(style: style, color: color, auto: auto)))
    }
}

public struct AdjustForm: Sendable, Equatable {
    public var options = AdjustOptions()

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard !options.isIdentity else { throw ToolFormError("Move a slider first: nothing would change.") }
        return .image(.adjust(options))
    }
}

// MARK: PDF

/// `1-3, 5`: ranges and single pages, 1-based.
public enum PageList {
    /// The pages in the order written, as 0-based indexes; `1-3` is 1, 2, 3 and `3-1` is 3, 2, 1.
    public static func parse(_ text: String) throws -> [Int] {
        var pages: [Int] = []
        for part in text.split(separator: ",") {
            let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = Int(ends[0]), let last = ends.count > 1 ? Int(ends[1]) : first, first >= 1, last >= 1 else {
                throw ToolFormError("\"\(part.trimmingCharacters(in: .whitespaces))\" is not a page or a range like 2-4.")
            }
            pages += first <= last ? Array(first...last).map { $0 - 1 } : Array((last...first).reversed()).map { $0 - 1 }
        }
        return pages
    }

    /// `2:90, 4:180`: the position in the result (1-based) and the degrees to turn it.
    public static func parseRotations(_ text: String) throws -> [Int: Int] {
        var rotations: [Int: Int] = [:]
        for part in text.split(separator: ",") {
            let pair = part.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let position = Int(pair[0]), position >= 1, let degrees = Int(pair[1]), degrees % 90 == 0 else {
                throw ToolFormError("\"\(part.trimmingCharacters(in: .whitespaces))\" should look like 2:90 (page 2, 90 degrees).")
            }
            rotations[position - 1] = degrees
        }
        return rotations
    }

    /// Whether a split spec is written right (the pages are checked against the document when it runs).
    static func validateRanges(_ text: String) throws {
        for part in text.split(separator: ",") {
            let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard Int(ends[0]) != nil, ends.count == 1 || Int(ends[1]) != nil else {
                throw ToolFormError("Page ranges look like 1-3, 5. \"\(part.trimmingCharacters(in: .whitespaces))\" does not.")
            }
        }
    }
}

public struct SplitForm: Sendable, Equatable {
    /// Empty means every page on its own.
    public var ranges = ""

    public init() {}

    public func invocation() throws -> ToolInvocation {
        try PageList.validateRanges(ranges)
        return .pdf(.split(ranges: ranges))
    }
}

public struct OrganizeForm: Sendable, Equatable {
    /// The pages to keep, in the order wanted ("3, 1, 2-4"); empty keeps all pages as they are.
    public var order = ""
    /// Extra turns by position in the result ("2:90, 4:180").
    public var rotations = ""

    public init() {}

    public func invocation() throws -> ToolInvocation {
        let pages = try PageList.parse(order)
        let turns = try PageList.parseRotations(rotations)
        guard !pages.isEmpty || !turns.isEmpty else { throw ToolFormError("Type a page order or a rotation, or close the window.") }
        return .pdf(.organize(order: pages.isEmpty ? nil : pages, rotations: turns))
    }
}

public struct MergeForm: Sendable, Equatable {
    /// The documents in the order they will be joined.
    public var files: [URL]

    public init(files: [URL]) { self.files = files }

    public mutating func move(from index: Int, by step: Int) {
        let target = index + step
        guard files.indices.contains(index), files.indices.contains(target) else { return }
        files.swapAt(index, target)
    }

    public func invocation() throws -> ToolInvocation {
        guard files.count >= 2 else { throw ToolFormError("Select at least two files.") }
        return .pdf(.merge)
    }
}

public struct PasswordForm: Sendable, Equatable {
    public var password = ""
    /// Only asked when adding a password.
    public var confirmation = ""

    public init() {}

    public func protectInvocation() throws -> ToolInvocation {
        guard !password.isEmpty else { throw ToolFormError("Type a password.") }
        guard password == confirmation else { throw ToolFormError("The two passwords are not the same.") }
        return .pdf(.protect(password: password))
    }

    public func unlockInvocation() -> ToolInvocation {
        .pdf(.unlock(password: password))
    }

    /// What the dialog says about the strength. Not AES-256: Apple's frameworks write AES-128 only.
    public static let strengthNote = "AES-128. Its key comes from the password with MD5, so use a long password."
}

public struct WatermarkForm: Sendable, Equatable {
    public var options = WatermarkOptions()

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard !options.text.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolFormError("Type the text of the watermark.") }
        guard (10...100).contains(options.sizePercent) else { throw ToolFormError("The width goes from 10% to 100%.") }
        guard (5...100).contains(options.opacityPercent) else { throw ToolFormError("The opacity goes from 5% to 100%.") }
        guard [0, 45, 90].contains(options.angle) else { throw ToolFormError("The angle is 0, 45 or 90 degrees.") }
        return .pdf(.watermark(options))
    }
}

public struct NumberForm: Sendable, Equatable {
    public static let positions = ["bottom left", "bottom center", "bottom right", "top left", "top center", "top right"]
    public var options = NumberingOptions()

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard Self.positions.contains(options.position) else { throw ToolFormError("Unknown position \(options.position).") }
        guard (6...36).contains(options.size) else { throw ToolFormError("The size goes from 6 to 36 points.") }
        guard (0...99_999).contains(options.start) else { throw ToolFormError("The first number goes from 0 to 99999.") }
        return .pdf(.number(options))
    }
}

// MARK: audio and video

/// Times typed as `83.5`, `1:23.5` or `1:02:03`, separated by commas.
enum MediaText {
    static func time(_ text: String, field: String) throws -> Double {
        guard let seconds = TimeText.seconds(text) else {
            throw ToolFormError("\"\(text.trimmingCharacters(in: .whitespaces))\" is not a time for \(field). Use seconds (83.5) or minutes and seconds (1:23.5).")
        }
        return seconds
    }

    static func times(_ text: String, field: String) throws -> [Double] {
        try text.split(separator: ",").map { try time(String($0), field: field) }
    }
}

public struct MediaCompressForm: Sendable, Equatable {
    public var quality = CompressForm.Quality.custom
    public var percent = 50
    public var targetKB = 0
    /// Video only.
    public var resizePercent = 100

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard (10...100).contains(resizePercent) else { throw ToolFormError("Resize goes from 10% to 100%.") }
        switch quality {
        case .custom:
            guard (5...95).contains(percent) else { throw ToolFormError("The target size goes from 5% to 95%.") }
            guard targetKB >= 0 else { throw ToolFormError("The exact size cannot be negative.") }
            return .media(.compress(MediaCompressOptions(percent: percent, targetKB: targetKB, resizePercent: resizePercent)))
        case .highQuality: return .media(.compress(MediaCompressOptions(preset: .highQuality, resizePercent: resizePercent)))
        case .balanced: return .media(.compress(MediaCompressOptions(preset: .balanced, resizePercent: resizePercent)))
        case .smallest: return .media(.compress(MediaCompressOptions(preset: .smallest, resizePercent: resizePercent)))
        }
    }
}

public struct MediaMetadataForm: Sendable, Equatable {
    public enum Mode: String, CaseIterable, Sendable { case remove, edit }
    public var mode = Mode.remove
    public var title = ""
    public var artist = ""
    public var album = ""
    public var genre = ""
    public var date = ""
    public var comment = ""

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard mode == .edit else { return .media(.metadata(fields: nil)) }
        let fields = ["title": title, "artist": artist, "album": album, "genre": genre, "date": date, "comment": comment]
            .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !fields.isEmpty else { throw ToolFormError("Fill in at least one field, or choose Remove.") }
        return .media(.metadata(fields: fields))
    }
}

public struct NormalizeForm: Sendable, Equatable {
    /// The usual targets: podcasts and most apps -16, streaming services -14, broadcast -23.
    public static let presets: [(name: String, loudness: Double)] = [("Podcast (-16 LUFS)", -16), ("Streaming (-14 LUFS)", -14), ("Broadcast (-23 LUFS)", -23)]
    public var options = NormalizeOptions()

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard (-70.0...(-5)).contains(options.loudness) else { throw ToolFormError("The loudness goes from -70 to -5 LUFS.") }
        guard (1.0...20).contains(options.range) else { throw ToolFormError("The loudness range goes from 1 to 20 LU.") }
        guard (-9.0...0).contains(options.truePeak) else { throw ToolFormError("The true peak goes from -9 to 0 dBTP.") }
        return .media(.normalize(options))
    }
}

public struct VisualizeForm: Sendable, Equatable {
    public var options = VisualizeOptions()

    public init() {}

    public func invocation() throws -> ToolInvocation {
        if options.style == .image, options.image == nil { throw ToolFormError("Choose the picture to show.") }
        return .media(.visualize(options))
    }
}

public struct TrimForm: Sendable, Equatable {
    public var start = "0"
    /// Empty keeps everything to the end.
    public var end = ""
    public var trimSilence = false
    public let isVideo: Bool

    public init(isVideo: Bool) { self.isVideo = isVideo }

    public func invocation() throws -> ToolInvocation {
        let from = try MediaText.time(start.isEmpty ? "0" : start, field: "the start")
        let to = end.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : try MediaText.time(end, field: "the end")
        if to > 0, to <= from { throw ToolFormError("The end must come after the start.") }
        if to == 0, from == 0, !trimSilence { throw ToolFormError("Nothing to cut: give a start or an end\(isVideo ? "" : ", or choose to cut silence").") }
        let options = TrimOptions(start: from, end: to, trimSilence: trimSilence && !isVideo)
        return .media(isVideo ? .trimVideo(options) : .trimAudio(options))
    }
}

public struct ChannelsForm: Sendable, Equatable {
    public var channels = 1
    public var left = 100
    public var right = 100

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard [1, 2].contains(channels) else { throw ToolFormError("Choose mono or stereo.") }
        guard (0...200).contains(left), (0...200).contains(right) else { throw ToolFormError("The volume of each side goes from 0% to 200%.") }
        return .media(.channels(ChannelOptions(channels: channels, left: left, right: right)))
    }
}

/// `1:02-1:05, 2:00-2:03`: stretches of time.
enum RangeList {
    static func parse(_ text: String) throws -> [TimeRange] {
        try text.split(separator: ",").map { part in
            let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard ends.count == 2 else { throw ToolFormError("\"\(part.trimmingCharacters(in: .whitespaces))\" should look like 1:02-1:05.") }
            let start = try MediaText.time(String(ends[0]), field: "a stretch"), end = try MediaText.time(String(ends[1]), field: "a stretch")
            guard end > start else { throw ToolFormError("In \"\(part.trimmingCharacters(in: .whitespaces))\" the end must come after the start.") }
            return TimeRange(start: start, end: end)
        }
    }
}

public struct BleepForm: Sendable, Equatable {
    public var ranges = ""
    public var mode = BleepOptions.Mode.beep
    public var frequency = 1000

    public init() {}

    public func invocation() throws -> ToolInvocation {
        let parsed = try RangeList.parse(ranges)
        guard !parsed.isEmpty else { throw ToolFormError("Type the stretches to cover, like 1:02-1:05, 2:00-2:03.") }
        guard (200...4000).contains(frequency) else { throw ToolFormError("The beep goes from 200 to 4000 Hz.") }
        return .media(.bleep(BleepOptions(ranges: parsed, mode: mode, frequency: frequency)))
    }
}

public struct VideoCropForm: Sendable, Equatable {
    public var aspect = "free"
    public var width = 0
    public var height = 0

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard CropForm.aspects.contains(aspect) else { throw ToolFormError("Unknown aspect ratio \(aspect).") }
        guard width >= 0, height >= 0, width <= 8000, height <= 8000 else { throw ToolFormError("Width and height go from 0 to 8000 px.") }
        guard (width == 0) == (height == 0) else { throw ToolFormError("Give both the width and the height, or neither.") }
        if aspect == "free", width == 0 { throw ToolFormError("Choose an aspect ratio or exact pixels.") }
        return .media(.cropVideo(VideoCropOptions(aspect: aspect, width: width, height: height)))
    }
}

public struct SpeedForm: Sendable, Equatable {
    public static let presets: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]
    public var factor = 2.0

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard (0.25...8).contains(factor) else { throw ToolFormError("The speed goes from 0.25× to 8×.") }
        guard factor != 1 else { throw ToolFormError("1× is the speed the video has already.") }
        return .media(.speed(factor: factor))
    }
}

public struct SnapshotForm: Sendable, Equatable {
    public enum Mode: String, CaseIterable, Sendable { case count, moments }
    public var mode = Mode.count
    public var count = 1
    /// Moments, separated by commas: `1.5, 10, 1:05`.
    public var moments = ""

    public init() {}

    public func invocation() throws -> ToolInvocation {
        switch mode {
        case .count:
            guard (1...200).contains(count) else { throw ToolFormError("The number of pictures goes from 1 to 200.") }
            return .media(.snapshots(SnapshotOptions(count: count)))
        case .moments:
            let times = try MediaText.times(moments, field: "a moment")
            guard !times.isEmpty else { throw ToolFormError("Type at least one moment, like 1.5, 10, 1:05.") }
            return .media(.snapshots(SnapshotOptions(times: times)))
        }
    }
}

public struct SplitVideoForm: Sendable, Equatable {
    public enum Mode: String, CaseIterable, Sendable { case parts, length, points }
    public var mode = Mode.parts
    public var parts = 2
    public var seconds = "60"
    public var points = ""
    public var precise = true

    public init() {}

    public func invocation() throws -> ToolInvocation {
        switch mode {
        case .parts:
            guard (2...100).contains(parts) else { throw ToolFormError("The number of parts goes from 2 to 100.") }
            return .media(.splitVideo(SplitOptions(parts: parts, precise: precise)))
        case .length:
            let length = try MediaText.time(seconds, field: "the length")
            guard length >= 1 else { throw ToolFormError("A clip must be at least 1 second long.") }
            return .media(.splitVideo(SplitOptions(seconds: length, precise: precise)))
        case .points:
            let cuts = try MediaText.times(points, field: "a cut")
            guard !cuts.isEmpty else { throw ToolFormError("Type at least one moment to cut at, like 30, 1:15.") }
            return .media(.splitVideo(SplitOptions(points: cuts, precise: precise)))
        }
    }
}

public struct VideoRedactForm: Sendable, Equatable {
    /// One area to cover, in percent of the picture; the times (empty = the whole video) limit it to a stretch.
    public struct Area: Sendable, Equatable, Identifiable {
        public let id = UUID()
        public var x = 10
        public var y = 10
        public var width = 30
        public var height = 20
        public var from = ""
        public var until = ""
        public init() {}
    }

    public var areas = [Area()]
    public var style = VideoRedactOptions.Style.blur
    public var color = "#000000"

    public init() {}

    public func invocation() throws -> ToolInvocation {
        guard !areas.isEmpty else { throw ToolFormError("Add at least one area to cover.") }
        var regions: [VideoRedactOptions.Region] = []
        for (index, area) in areas.enumerated() {
            let name = "Area \(index + 1)"
            guard (0...99).contains(area.x), (0...99).contains(area.y), (1...100).contains(area.width), (1...100).contains(area.height),
                  area.x + area.width <= 100, area.y + area.height <= 100 else {
                throw ToolFormError("\(name) must fit inside the picture (percent from the top left).")
            }
            var time: TimeRange?
            let from = area.from.trimmingCharacters(in: .whitespaces), until = area.until.trimmingCharacters(in: .whitespaces)
            if !from.isEmpty || !until.isEmpty {
                let start = from.isEmpty ? 0 : try MediaText.time(from, field: name)
                let end = until.isEmpty ? 24 * 3600 : try MediaText.time(until, field: name)
                guard end > start else { throw ToolFormError("In \(name) the end must come after the start.") }
                time = TimeRange(start: start, end: end)
            }
            regions.append(.init(rect: CGRect(x: Double(area.x) / 100, y: Double(area.y) / 100,
                                              width: Double(area.width) / 100, height: Double(area.height) / 100), time: time))
        }
        return .media(.redactVideo(VideoRedactOptions(regions: regions, style: style, color: color)))
    }
}

public struct JoinForm: Sendable, Equatable {
    /// The clips in the order they will play.
    public var files: [URL]

    public init(files: [URL]) { self.files = files }

    public mutating func move(from index: Int, by step: Int) {
        let target = index + step
        guard files.indices.contains(index), files.indices.contains(target) else { return }
        files.swapAt(index, target)
    }

    public func invocation() throws -> ToolInvocation {
        guard files.count >= 2 else { throw ToolFormError("Select at least two videos.") }
        return .media(.join)
    }
}
