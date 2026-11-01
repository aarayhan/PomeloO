import Foundation
import os

/// The encoders a particular ffmpeg build has, from `ffmpeg -encoders`. Builds differ (a Homebrew copy
/// may lack libvpx, a minimal bundled one may carry only what PomeloO needs), so which targets the wheel
/// offers is decided by what the ffmpeg in use can really write.
enum FFmpegEncoders {
    /// Per binary: replacing the file (an update, a new build at the same path) invalidates its entry.
    private static let cache = OSAllocatedUnfairLock(initialState: [String: Set<String>?]())

    /// Longest `ffmpeg -encoders` may take. It answers in milliseconds; this only guards against a hung binary.
    private static let timeout: TimeInterval = 5

    /// Encoder names, or nil when the list could not be read (then nothing is ruled out).
    static func available(at executable: URL) -> Set<String>? {
        let key = identity(of: executable)
        if let known = cache.withLock({ $0[key] }) { return known }
        let names = read(from: executable)
        cache.withLock { $0[key] = .some(names) }
        return names
    }

    private static func identity(of executable: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? Int) ?? 0
        let inode = (attributes?[.systemFileNumber] as? Int) ?? 0
        return "\(executable.path)|\(modified)|\(size)|\(inode)"
    }

    /// Encoders a target needs: the audio codec for audio, video and audio codec for video.
    static func required(for target: String) -> [String] {
        switch target {
        case "mp3": ["libmp3lame"]
        case "m4a": ["aac"]
        case "wav": ["pcm_s16le"]
        case "flac": ["flac"]
        case "ogg": ["libvorbis"]
        case "opus": ["libopus"]
        case "aiff": ["pcm_s16be"]
        case "wma": ["wmav2"]
        case "mp4", "mov", "mkv": ["libx264", "aac"]
        case "webm": ["libvpx-vp9", "libopus"]
        case "avi": ["mpeg4", "libmp3lame"]
        case "wmv": ["wmv2", "wmav2"]
        case "gif": ["gif"]
        case "webp": ["libwebp"]
        default: []
        }
    }

    static func supports(_ target: String, at executable: URL) -> Bool {
        guard let encoders = available(at: executable) else { return true }
        return required(for: target).allSatisfy(encoders.contains)
    }

    // MARK: reading the list

    private static func read(from executable: URL) -> Set<String>? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-hide_banner", "-encoders"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        try? output.fileHandleForWriting.close()

        let collected = OSAllocatedUnfairLock(initialState: Data())
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            collected.withLock { $0 = data }
            reading.leave()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        reading.wait()
        let names = parse(String(decoding: collected.withLock { $0 }, as: UTF8.self))
        return names.isEmpty ? nil : names
    }

    /// Lines look like ` V....D libwebp   libwebp WebP image (codec webp)`: six flag characters, then the name.
    static func parse(_ text: String) -> Set<String> {
        var names: Set<String> = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6, "VAS".contains(parts[0].first!),
                  parts[1] != "=" else { continue }  // " V..... = Video" is the legend, not an encoder
            names.insert(String(parts[1]))
        }
        return names
    }
}
