import CoreGraphics
import Foundation

/// The audio and video tools, run through ffmpeg (pomeloo/tools/media.py). Each writes to the file it is given and
/// reports progress from `-progress pipe:1`; a failed or cancelled run leaves the cleaning to the caller.
///
/// Where Windows uses libx264 (CRF, two passes), this uses what the release ffmpeg has: Apple's VideoToolbox H.264 with
/// a quality level or, to hit a size, one pass at a computed bitrate. Sizes land close to the target but not as close
/// as two passes would.
struct MediaTools: Sendable {
    let executable: URL
    /// What this ffmpeg can write; nil when the list could not be read.
    let encoders: Set<String>?

    init(executable: URL) {
        self.executable = executable
        encoders = FFmpegEncoders.available(at: executable)
    }

    typealias Progress = @Sendable (Double) -> Void

    // MARK: running ffmpeg

    /// Reads the header of a file.
    func info(of url: URL) async throws -> MediaInfo {
        var runner = FFmpegRunner(executable: executable)
        runner.tailLines = 400  // the stream lines come after all the tags of a heavily tagged file
        let text = try await runner.run(FFmpegEngine.probeArguments(input: url))
        let info = MediaInfo.parse(text)
        guard info.hasAudio || info.hasVideo else { throw ConversionError.failed("\(url.lastPathComponent) has no sound or picture ffmpeg can read.") }
        return info
    }

    /// `duration` is how long the result will be, for the progress.
    @discardableResult
    func run(_ arguments: [String], duration: Double?, level: String = "error", progress: @escaping Progress) async throws -> String {
        let full = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats", "-loglevel", level] + arguments
        return try await FFmpegRunner(executable: executable).run(full) { line in
            if let fraction = FFmpegEngine.progress(fromLine: line, duration: duration) { progress(fraction) }
        }
    }

    private func audioCodec(_ ext: String) throws -> [String] {
        guard let args = FFmpegEngine.audioCodec(for: ext) else { throw ConversionError.unsupported(from: ext, to: ext) }
        return args
    }

    private func videoCodec(_ ext: String) throws -> [String] {
        guard let args = FFmpegEngine.videoCodec(for: ext, encoders: encoders) else { throw ConversionError.unsupported(from: ext, to: ext) }
        return args
    }

    /// The encoder arguments for a result in the source's own format: the video ones for a video, the audio ones for audio.
    private func codec(for ext: String, info: MediaInfo) throws -> [String] {
        info.hasVideo && FFmpegEngine.videoCodec(for: ext, encoders: encoders) != nil ? try videoCodec(ext) : try audioCodec(ext)
    }

    /// The video encoder settings of an extension with the audio copied untouched (`video_only`).
    private func videoOnly(_ ext: String) throws -> [String] {
        var out: [String] = []
        var skip = false
        for argument in try videoCodec(ext) {
            if skip { skip = false } else if ["-c:a", "-b:a", "-q:a"].contains(argument) { skip = true } else { out.append(argument) }
        }
        return out + ["-c:a", "copy"]
    }

    private static func color(_ hex: String) -> String { "0x" + hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }

    private static func seconds(_ value: Double) -> String { String(format: "%.3f", value) }

    private func size(of url: URL) -> Double {
        Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
    }

    // MARK: metadata and compression

    func metadata(_ source: URL, fields: [String: String]?, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard let fields, !fields.isEmpty else {
            // bitexact keeps ffmpeg from writing its own "Lavf" tag into a file that is meant to carry none
            try await run(["-i", source.path, "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact",
                           "-flags:v", "+bitexact", "-flags:a", "+bitexact", "-c", "copy", output.path],
                          duration: info.duration, progress: progress)
            return
        }
        var tags: [String] = []
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) { tags += ["-metadata", "\(key)=\(value)"] }
        try await run(["-i", source.path, "-map", "0", "-c", "copy"] + tags + [output.path], duration: info.duration, progress: progress)
    }

    func compress(_ source: URL, options: MediaCompressOptions, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        let ext = FileName.ext(of: output)
        let duration = max(info.duration, 0.1)
        let targetBytes = options.targetKB > 0 ? Double(options.targetKB) * 1024 : size(of: source) * Double(options.percent) / 100
        let totalKbps = targetBytes * 8 / duration / 1000
        guard !info.hasVideo else {
            try await compressVideo(source, info: info, totalKbps: totalKbps, resizePercent: options.resizePercent, to: output, progress: progress)
            return
        }
        if ext == "flac" {  // WAV, AIFF and FLAC become FLAC at maximum compression: lossless
            try await run(["-i", source.path, "-vn", "-c:a", "flac", "-compression_level", "12", output.path], duration: duration, progress: progress)
            return
        }
        guard let encoder = Self.lossy[ext] else { throw ConversionError.unsupported(from: ext, to: "compress") }
        let kbps = Int(min(320, max(32, totalKbps)))
        try await run(["-i", source.path, "-vn", "-c:a", encoder, "-b:a", "\(kbps)k", output.path], duration: duration, progress: progress)
    }

    /// `LOSSY_ENC`: the encoder that shrinks each audio format by bitrate.
    static let lossy = ["mp3": "libmp3lame", "m4a": "aac", "ogg": "libvorbis", "opus": "libopus", "wma": "wmav2"]

    private func compressVideo(_ source: URL, info: MediaInfo, totalKbps: Double, resizePercent: Int, to output: URL,
                               progress: @escaping Progress) async throws {
        let ext = FileName.ext(of: output)
        let factor = Double(min(100, max(10, resizePercent))) / 100
        let filter = factor == 1 ? FFmpegEngine.evenSize : "scale=trunc(iw*\(factor)/2)*2:trunc(ih*\(factor)/2)*2"
        let audioKbps = info.hasAudio ? 96 : 0
        let videoKbps = Int(max(80, totalKbps - Double(audioKbps)) * 0.97)  // 3% for the container
        let audio: (String) -> [String] = { codec in audioKbps > 0 ? ["-c:a", codec, "-b:a", "\(audioKbps)k"] : ["-an"] }
        let arguments: [String]
        switch ext {
        case "mp4", "mov", "mkv":
            let encoder = FFmpegEncoders.h264(in: encoders)
            let video = encoder == "libx264"
                ? ["-c:v", "libx264", "-preset", "medium", "-b:v", "\(videoKbps)k", "-pix_fmt", "yuv420p"]
                : ["-c:v", "h264_videotoolbox", "-b:v", "\(videoKbps)k", "-pix_fmt", "yuv420p"]
            arguments = video + audio("aac")
        case "webm": arguments = ["-c:v", "libvpx-vp9", "-row-mt", "1", "-b:v", "\(videoKbps)k"] + audio("libopus")
        case "avi": arguments = ["-c:v", "mpeg4", "-b:v", "\(videoKbps)k"] + audio("libmp3lame")
        case "wmv": arguments = ["-c:v", "wmv2", "-b:v", "\(videoKbps)k"] + audio("wmav2")
        default: throw ConversionError.unsupported(from: ext, to: "compress")
        }
        try await run(["-i", source.path, "-vf", filter] + arguments + [output.path], duration: info.duration, progress: progress)
    }

    // MARK: audio

    func trim(_ source: URL, options: TrimOptions, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        let ext = FileName.ext(of: output)
        let start = max(0, options.start)
        let end = options.end > 0 ? min(options.end, info.duration) : info.duration
        guard start < info.duration else { throw ConversionError.failed("The start is after the end of \(source.lastPathComponent).") }
        guard end > start else { throw ConversionError.failed("The end must be after the start.") }
        let silence = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1,areverse,"
            + "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1,areverse"
        let filter = options.trimSilence && !info.hasVideo ? ["-af", silence] : []
        let length = max(0.01, end - start)
        try await run(["-ss", Self.seconds(start), "-i", source.path, "-t", Self.seconds(length)] + filter + (try codec(for: ext, info: info)) + [output.path],
                      duration: length, progress: progress)
    }

    func normalize(_ source: URL, options: NormalizeOptions, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard info.hasAudio else { throw ConversionError.failed("\(source.lastPathComponent) has no sound.") }
        // pass 1: measure (the numbers come out as JSON at the end of ffmpeg's messages)
        let report = try await run(["-i", source.path, "-vn", "-af", "loudnorm=print_format=json", "-f", "null", "-"],
                                   duration: info.duration, level: "info") { progress($0 * 0.5) }
        guard let measured = Self.loudness(inReport: report) else {
            throw ConversionError.failed("There is no sound to normalize in \(source.lastPathComponent).")
        }
        let filter = "loudnorm=I=\(Self.number(options.loudness)):TP=\(Self.number(options.truePeak)):LRA=\(Self.number(options.range))"
            + ":measured_I=\(measured["input_i"]!):measured_TP=\(measured["input_tp"]!):measured_LRA=\(measured["input_lra"]!)"
            + ":measured_thresh=\(measured["input_thresh"]!):offset=\(measured["target_offset"]!):linear=true"
        let ext = FileName.ext(of: output)
        let encoding = info.hasVideo ? ["-c:v", "copy", "-c:a", "aac"] : try audioCodec(ext)
        // pass 2: apply the measured numbers linearly
        try await run(["-i", source.path, "-af", filter, "-ar", "48000"] + (info.hasVideo ? [] : ["-vn"]) + encoding + [output.path],
                      duration: info.duration) { progress(0.5 + $0 * 0.5) }
    }

    /// The numbers loudnorm prints; nil when the file is silent (they are `-inf`).
    static func loudness(inReport text: String) -> [String: String]? {
        guard let open = text.lastIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for key in ["input_i", "input_tp", "input_lra", "input_thresh", "target_offset"] {
            guard let value = object[key] as? String, let number = Double(value), number.isFinite else { return nil }
            result[key] = value
        }
        return result
    }

    private static func number(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }

    func channels(_ source: URL, options: ChannelOptions, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard info.hasAudio else { throw ConversionError.failed("\(source.lastPathComponent) has no sound.") }
        let left = Double(options.left) / 100, right = Double(options.right) / 100
        let pan = options.channels == 1
            ? String(format: "pan=mono|c0=%.3f*c0+%.3f*c1", left / 2, right / 2)
            : String(format: "pan=stereo|c0=%.3f*c0|c1=%.3f*c1", left, right)
        try await run(["-i", source.path, "-vn", "-af", "aformat=channel_layouts=stereo,\(pan)"] + (try audioCodec(FileName.ext(of: output))) + [output.path],
                      duration: info.duration, progress: progress)
    }

    func bleep(_ source: URL, options: BleepOptions, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard info.hasAudio else { throw ConversionError.failed("\(source.lastPathComponent) has no sound.") }
        let on = options.ranges.map { "between(t,\(Self.seconds($0.start)),\(Self.seconds($0.end)))" }.joined(separator: "+")
        let codec = try audioCodec(FileName.ext(of: output))
        if options.mode == .mute {
            try await run(["-i", source.path, "-vn", "-af", "volume=0:enable='\(on)'"] + codec + [output.path], duration: info.duration, progress: progress)
            return
        }
        let graph = "[0:a]volume=0:enable='\(on)'[m];sine=f=\(options.frequency):sample_rate=44100,"
            + "volume=0.25,volume=0:enable='not(\(on))'[b];[m][b]amix=inputs=2:duration=first:normalize=0[a]"
        try await run(["-i", source.path, "-filter_complex", graph, "-map", "[a]"] + codec + [output.path], duration: info.duration, progress: progress)
    }

    func visualize(_ source: URL, options: VisualizeOptions, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard info.hasAudio else { throw ConversionError.failed("\(source.lastPathComponent) has no sound.") }
        let (width, height): (Int, Int) = switch options.shape {
        case .landscape: (1280, 720)
        case .portrait: (720, 1280)
        case .square: (1080, 1080)
        }
        let encoding = FFmpegEngine.h264Arguments(encoder: FFmpegEncoders.h264(in: encoders)) + ["-c:a", "aac", "-b:a", "192k", "-shortest"]
        if options.style == .image {
            guard let image = options.image else { throw ConversionError.failed("Choose the picture to show.") }
            let graph = "[0:v]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,fps=10[v]"
            try await run(["-loop", "1", "-i", image.path, "-i", source.path, "-filter_complex", graph, "-map", "[v]", "-map", "1:a"] + encoding + [output.path],
                          duration: info.duration, progress: progress)
            return
        }
        let visual = options.style == .waves
            ? "showwaves=s=\(width)x\(height):mode=cline:rate=30:colors=\(Self.color(options.color))"
            : "showspectrum=s=\(width)x\(height):mode=combined:color=fire:slide=scroll"
        try await run(["-i", source.path, "-filter_complex", "[0:a]\(visual),format=yuv420p[v]", "-map", "[v]", "-map", "0:a"] + encoding + [output.path],
                      duration: info.duration, progress: progress)
    }

    // MARK: video

    func mute(_ source: URL, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard info.hasVideo else { throw ConversionError.failed("\(source.lastPathComponent) has no picture.") }
        try await run(["-i", source.path, "-map", "0:v", "-c", "copy", "-an", output.path], duration: info.duration, progress: progress)
    }

    func crop(_ source: URL, options: VideoCropOptions, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard let size = info.size else { throw ConversionError.failed("\(source.lastPathComponent) has no picture.") }
        let width = Double(size.width), height = Double(size.height)
        var rect = options.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        if rect == CGRect(x: 0, y: 0, width: 1, height: 1) {
            if options.width > 0, options.height > 0 {
                rect = ImageTools.centredRect(width, height, ratio: Double(options.width) / Double(options.height))
            } else if let ratio = CropOptions.aspects[options.aspect] {
                rect = ImageTools.centredRect(width, height, ratio: ratio)
            }
        }
        let even: (Double) -> Int = { Int($0) / 2 * 2 }
        let (w, h, x, y) = (even(rect.width * width), even(rect.height * height), even(rect.minX * width), even(rect.minY * height))
        guard w >= 2, h >= 2 else { throw ConversionError.failed("The area to keep is too small.") }
        var filter = "crop=\(w):\(h):\(x):\(y)"
        if options.width > 0, options.height > 0 {
            let outWidth = options.width / 2 * 2, outHeight = options.height / 2 * 2
            filter += ",scale=\(outWidth):\(outHeight):force_original_aspect_ratio=increase,crop=\(outWidth):\(outHeight)"
        }
        try await run(["-i", source.path, "-map", "0:v", "-map", "0:a?", "-vf", filter] + (try videoOnly(FileName.ext(of: output))) + [output.path],
                      duration: info.duration, progress: progress)
    }

    func speed(_ source: URL, factor: Double, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard info.hasVideo else { throw ConversionError.failed("\(source.lastPathComponent) has no picture.") }
        var graph = "[0:v]setpts=PTS/\(factor)[v]"
        var maps = ["-map", "[v]"]
        if info.hasAudio {  // atempo keeps the pitch; each atempo stays between 0.5 and 2
            var chain: [String] = []
            var rest = factor
            while rest > 2 { chain.append("atempo=2.0"); rest /= 2 }
            while rest < 0.5 { chain.append("atempo=0.5"); rest /= 0.5 }
            chain.append("atempo=\(rest)")
            graph += ";[0:a]\(chain.joined(separator: ","))[a]"
            maps += ["-map", "[a]"]
        }
        try await run(["-i", source.path, "-filter_complex", graph] + maps + (try videoCodec(FileName.ext(of: output))) + [output.path],
                      duration: info.duration / factor, progress: progress)
    }

    /// One picture is written to `output`; several go in the folder `output`, named `<stem> 1.png`...
    func snapshots(_ source: URL, options: SnapshotOptions, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard info.hasVideo else { throw ConversionError.failed("\(source.lastPathComponent) has no picture.") }
        let last = max(0, info.duration - 0.05)  // a frame at the very end may not exist
        let times: [Double]
        if !options.times.isEmpty {
            times = options.times.map { min(max(0, $0), last) }
        } else if options.count <= 1 {
            times = [info.duration / 2]
        } else {
            times = (0..<options.count).map { (Double($0) + 0.5) * info.duration / Double(options.count) }
        }
        if times.count == 1 {
            try await run(["-ss", Self.seconds(times[0]), "-i", source.path, "-frames:v", "1", output.path], duration: nil, progress: progress)
            return
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let stem = FileName.stem(of: source)
        for (index, time) in times.enumerated() {
            try await run(["-ss", Self.seconds(time), "-i", source.path, "-frames:v", "1",
                           output.appendingPathComponent("\(stem) \(index + 1).png").path], duration: nil) { _ in }
            progress(Double(index + 1) / Double(times.count))
        }
    }

    func split(_ source: URL, options: SplitOptions, to folder: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard info.hasVideo else { throw ConversionError.failed("\(source.lastPathComponent) has no picture.") }
        let duration = info.duration
        let ext = FileName.ext(of: source)
        var cuts: [Double]
        if !options.points.isEmpty {
            cuts = options.points.filter { $0 > 0 && $0 < duration }.sorted()
        } else {
            let length = options.seconds > 0 ? options.seconds : duration / Double(max(1, options.parts))
            cuts = []
            var n = 1
            while length * Double(n) < duration - 0.05 { cuts.append(length * Double(n)); n += 1 }
        }
        guard !cuts.isEmpty else { throw ConversionError.failed("Nothing to split: the cuts fall outside the \(TimeText.text(duration)) of the video.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let times = cuts.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let pattern = folder.appendingPathComponent("\(FileName.stem(of: source)) %d.\(ext)").path
        let segments = ["-f", "segment", "-segment_times", times, "-reset_timestamps", "1", "-segment_start_number", "1"]
        if options.precise {
            try await run(["-i", source.path, "-map", "0:v", "-map", "0:a?", "-force_key_frames", times] + (try videoCodec(ext)) + segments + [pattern],
                          duration: duration, progress: progress)
        } else {
            try await run(["-i", source.path, "-map", "0", "-c", "copy"] + segments + [pattern], duration: duration, progress: progress)
        }
    }

    func redact(_ source: URL, options: VideoRedactOptions, to output: URL, progress: @escaping Progress) async throws {
        let info = try await info(of: source)
        guard let size = info.size else { throw ConversionError.failed("\(source.lastPathComponent) has no picture.") }
        guard !options.regions.isEmpty else { throw ConversionError.failed("Add at least one area to cover.") }
        var graph: [String] = []
        var last = "0:v"
        let fill = options.style == .black ? "black" : Self.color(options.color)
        for (i, region) in options.regions.enumerated() {
            let w = max(2, Int(region.rect.width * Double(size.width)) / 2 * 2), h = max(2, Int(region.rect.height * Double(size.height)) / 2 * 2)
            let x = Int(region.rect.minX * Double(size.width)), y = Int(region.rect.minY * Double(size.height))
            let enable = region.time.map { ":enable='between(t,\(Self.seconds($0.start)),\(Self.seconds($0.end)))'" } ?? ""
            if options.style == .blur {
                // boxblur is not in the release build; a Gaussian blur of similar strength is
                graph.append("[\(last)]split[a\(i)][b\(i)];[b\(i)]crop=\(w):\(h):\(x):\(y),gblur=sigma=\(max(2, min(w, h) / 6)):steps=2[c\(i)];"
                    + "[a\(i)][c\(i)]overlay=\(x):\(y)\(enable)[v\(i)]")
            } else {
                graph.append("[\(last)]drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=\(fill):t=fill\(enable)[v\(i)]")
            }
            last = "v\(i)"
        }
        try await run(["-i", source.path, "-filter_complex", graph.joined(separator: ";"), "-map", "[\(last)]", "-map", "0:a?"]
                      + (try videoOnly(FileName.ext(of: output))) + [output.path], duration: info.duration, progress: progress)
    }

    /// Clips one after the other on the first clip's canvas, as MP4; a clip with no sound gets silence.
    func join(_ sources: [URL], to output: URL, progress: @escaping Progress) async throws {
        var infos: [MediaInfo] = []
        for source in sources {
            let info = try await info(of: source)
            guard info.hasVideo else { throw ConversionError.failed("\(source.lastPathComponent) has no picture.") }
            infos.append(info)
        }
        let canvas = infos[0].size!
        let (width, height) = (canvas.width / 2 * 2, canvas.height / 2 * 2)
        var arguments: [String] = []
        var parts: [String] = []
        for (n, info) in infos.enumerated() {
            arguments += ["-i", sources[n].path]
            parts.append("[\(n):v]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(n)]")
            let audio = info.hasAudio ? "[\(n):a]" : "anullsrc=r=48000:cl=stereo,atrim=duration=\(Self.seconds(info.duration)),"
            parts.append("\(audio)aresample=48000,aformat=channel_layouts=stereo[a\(n)]")
        }
        let inputs = (0..<sources.count).map { "[v\($0)][a\($0)]" }.joined()
        let graph = parts.joined(separator: ";") + ";\(inputs)concat=n=\(sources.count):v=1:a=1[v][a]"
        try await run(arguments + ["-filter_complex", graph, "-map", "[v]", "-map", "[a]"] + (try videoCodec("mp4")) + [output.path],
                      duration: infos.reduce(0) { $0 + $1.duration }, progress: progress)
    }
}
