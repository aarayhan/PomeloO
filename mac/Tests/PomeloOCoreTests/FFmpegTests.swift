import XCTest
@testable import PomeloOCore

/// The ffmpeg engine against a fake `ffmpeg` shell script: this tests how the app talks to the process
/// (probe, progress, a flooded error pipe, cancel), not ffmpeg itself. Tests against a real ffmpeg
/// are at the bottom and skip when none is installed.
final class FFmpegTests: TempDirectoryTestCase {
    /// Writes an executable script into the test folder.
    private func fakeFFmpeg(_ body: String) throws -> URL {
        let url = file("fake-ffmpeg")
        // The engine asks which encoders exist before it converts; the fakes have nothing to say about that.
        let encoders = "case \"$*\" in *\"-encoders\"*) exit 0;; esac\n"
        try ("#!/bin/sh\n" + encoders + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Answers the probe (the call that ends in `-f null -`) with a 10 second header, like ffmpeg does.
    private let probeBranch = """
    case "$*" in
      *"-f null"*) echo "  Duration: 00:00:10.00, start: 0.000000, bitrate: 128 kb/s" >&2; exit 0;;
    esac
    for last; do :; done
    """

    private func service(_ script: URL) -> ConversionService {
        ConversionService(engines: [FFmpegEngine(executable: script)], runner: JobRunner(maxConcurrent: 1))
    }

    private func makeSource(_ name: String = "clip.ogg") throws -> URL {
        let url = file(name)
        try Data("source".utf8).write(to: url)
        return url
    }

    // MARK: reading ffmpeg's output

    func testDurationIsReadFromTheHeader() {
        XCTAssertEqual(FFmpegEngine.duration(inProbeOutput: "  Duration: 00:01:02.50, start: 0"), 62.5)
        XCTAssertEqual(FFmpegEngine.duration(inProbeOutput: "Duration: 01:00:00.00"), 3600)
        XCTAssertNil(FFmpegEngine.duration(inProbeOutput: "Duration: N/A, start: 0"))
        XCTAssertNil(FFmpegEngine.duration(inProbeOutput: ""))
    }

    func testProgressLines() {
        XCTAssertEqual(FFmpegEngine.progress(fromLine: "out_time_us=2500000", duration: 10), 0.25)
        XCTAssertEqual(FFmpegEngine.progress(fromLine: "out_time_us=99000000", duration: 10), 1, "never above 1")
        XCTAssertNil(FFmpegEngine.progress(fromLine: "out_time_us=N/A", duration: 10))
        XCTAssertNil(FFmpegEngine.progress(fromLine: "out_time_us=2500000", duration: nil))
        XCTAssertNil(FFmpegEngine.progress(fromLine: "frame=12", duration: 10))
        XCTAssertEqual(FFmpegEngine.progress(fromLine: "progress=end", duration: nil), 1)
    }

    func testArgumentsFollowTheWindowsSettings() {
        XCTAssertEqual(FFmpegEngine.outputArguments(for: "mp3"), ["-vn", "-c:a", "libmp3lame", "-q:a", "2"])
        XCTAssertEqual(FFmpegEngine.outputArguments(for: "opus"), ["-vn", "-c:a", "libopus", "-b:a", "128k"])
        XCTAssertTrue(FFmpegEngine.outputArguments(for: "mp4")!.contains("h264_videotoolbox"), "the release build has no libx264")
        XCTAssertTrue(FFmpegEngine.outputArguments(for: "mp4", encoders: ["libx264"])!.contains("libx264"))
        XCTAssertTrue(FFmpegEngine.outputArguments(for: "mp4")!.contains("+faststart"))
        XCTAssertTrue(FFmpegEngine.outputArguments(for: "gif")!.contains("-filter_complex"))
        XCTAssertNil(FFmpegEngine.outputArguments(for: "png"))
    }

    func testProbeReadsTheStreamsAndWritesNothing() {
        let args = FFmpegEngine.probeArguments(input: URL(fileURLWithPath: "/in/clip.mp4"))
        XCTAssertEqual(Array(args.suffix(7)), ["-c", "copy", "-t", "0", "-f", "null", "-"])
        XCTAssertTrue(args.joined(separator: " ").contains("-map 0:v? -map 0:a?"))
    }

    func testWhichPairsFFmpegTakes() {
        let engine = FFmpegEngine(executable: URL(fileURLWithPath: "/bin/echo"))
        XCTAssertTrue(engine.canConvert(from: "mp3", to: "ogg"))
        XCTAssertTrue(engine.canConvert(from: "mp4", to: "mp3"))
        XCTAssertTrue(engine.canConvert(from: "mov", to: "gif"))
        XCTAssertTrue(engine.canConvert(from: "gif", to: "mp4"))
        XCTAssertFalse(engine.canConvert(from: "gif", to: "mp3"))
        XCTAssertFalse(engine.canConvert(from: "mp3", to: "mp3"))
        XCTAssertFalse(engine.canConvert(from: "png", to: "jpg"))
        XCTAssertFalse(FFmpegEngine(executable: nil).canConvert(from: "mp3", to: "ogg"), "no ffmpeg, no conversions")
    }

    func testTheLocatorPrefersTheEnvironmentOverride() throws {
        let fake = try fakeFFmpeg("exit 0")
        XCTAssertEqual(FFmpegLocator.find(environment: ["POMELOO_FFMPEG": fake.path]), fake)
        XCTAssertNotEqual(FFmpegLocator.find(environment: ["POMELOO_FFMPEG": "/nonexistent/ffmpeg"]),
                          URL(fileURLWithPath: "/nonexistent/ffmpeg"))
    }

    // MARK: running it

    func testProgressIsReadFromStandardOutputAndTheResultIsRenamed() async throws {
        let script = try fakeFFmpeg(probeBranch + """

        i=0
        while [ $i -lt 5 ]; do
          i=$((i+1))
          echo "out_time_us=$((i*2000000))"
          echo "progress=continue"
          sleep 0.05
        done
        echo "progress=end"
        printf done > "$last"
        """)
        let source = try makeSource()
        let seen = Collector<Double>()
        let conversion = service(script)
        let result = try await withTimeout(20) {
            try await conversion.convert(source, to: "mp3") { seen.add($0) }
        }
        XCTAssertEqual(result.lastPathComponent, "clip.mp3")
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "done")
        XCTAssertEqual(seen.values.last, 1)
        XCTAssertTrue(seen.values.contains(0.4), "got \(seen.values)")
        XCTAssertEqual(seen.values, seen.values.sorted())
        XCTAssertEqual(try names(), ["clip.mp3", "clip.ogg", "fake-ffmpeg"])
    }

    func testAFloodOnStandardErrorDoesNotStallTheProcess() async throws {
        // 400 KB on stderr is several times the size of a pipe buffer: if nobody reads it, the script hangs.
        let script = try fakeFFmpeg(probeBranch + """

        i=0
        while [ $i -lt 4000 ]; do
          i=$((i+1))
          echo "warning: line $i of a very chatty encoder, padded padded padded padded padded padded padded padded padded" >&2
        done
        echo "out_time_us=5000000"
        printf done > "$last"
        """)
        let source = try makeSource()
        let conversion = service(script)
        let result = try await withTimeout(20) { try await conversion.convert(source, to: "mp3") }
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "done")
    }

    func testAFailureReportsTheEndOfStandardError() async throws {
        let script = try fakeFFmpeg(probeBranch + """

        echo "first line" >&2
        echo "Invalid data found when processing input" >&2
        exit 1
        """)
        let source = try makeSource()
        let conversion = service(script)
        do {
            _ = try await withTimeout(20) { try await conversion.convert(source, to: "mp3") }
            XCTFail("expected an error")
        } catch let error as ConversionError {
            guard case let .failed(message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("Invalid data found"), message)
            XCTAssertTrue(message.hasPrefix("ffmpeg:"), message)
        }
        XCTAssertEqual(try names(), ["clip.ogg", "fake-ffmpeg"], "no result and no temporary file")
    }

    func testAFileTheProbeRejectsFailsBeforeAnythingIsWritten() async throws {
        let script = try fakeFFmpeg("""
        case "$*" in *"-f null"*) echo "clip.ogg: Invalid data found when processing input" >&2; exit 1;; esac
        echo "the conversion must not start" > "$(dirname "$0")/started"
        """)
        let source = try makeSource()
        let conversion = service(script)
        do {
            _ = try await withTimeout(20) { try await conversion.convert(source, to: "mp3") }
            XCTFail("expected an error")
        } catch is ConversionError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("started").path))
    }

    func testCancellingKillsTheProcessAndRemovesTheTemporaryFile() async throws {
        let pidFile = file("pid")
        let script = try fakeFFmpeg(probeBranch + """

        echo $$ > "\(pidFile.path)"
        printf partial > "$last"
        exec sleep 60
        """)
        let source = try makeSource()
        let conversion = service(script)
        let task = Task { try await conversion.convert(source, to: "mp3") }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), 0, "the fake ffmpeg should be running")
        task.cancel()
        do {
            _ = try await withTimeout(10) { try await task.value }
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        for _ in 0..<200 where kill(pid, 0) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the process is still running")
        XCTAssertEqual(try names(), ["clip.ogg", "fake-ffmpeg", "pid"])
    }

    func testAMissingExecutableIsReportedNotCrashed() async throws {
        let conversion = ConversionService(engines: [FFmpegEngine(executable: file("not-there"))])
        let source = try makeSource()
        do {
            _ = try await conversion.convert(source, to: "mp3")
            XCTFail("expected an error")
        } catch is ConversionError {}
    }

    // MARK: a real ffmpeg, when there is one

    /// Every video and audio target the installed ffmpeg offers for an MP4, each checked by reading the result
    /// back with ffmpeg. This is what proves the argument tables against a real build.
    func testRealFFmpegConvertsAnMP4ToEveryOfferedTarget() async throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("[BELUM DIUJI] no ffmpeg on this Mac") }
        let runner = FFmpegRunner(executable: ffmpeg)
        let source = file("clip.mp4")
        try await runner.run(["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2",
                              "-f", "lavfi", "-i", "sine=duration=2", "-shortest", "-c:v", "h264_videotoolbox", "-b:v", "500k",  // an encoder the release build has too
                              "-c:a", "aac", source.path])
        let real = ConversionService(engines: [FFmpegEngine(executable: ffmpeg)])
        let targets = real.availableTargets(forExtension: "mp4")
        XCTAssertTrue(targets.contains("mp3"), "offered: \(targets)")
        for target in targets {
            let result = try await real.convert(source, to: target)
            XCTAssertGreaterThan(try result.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0, target)
            // reads back: every stream decodes
            try await runner.run(["-hide_banner", "-loglevel", "error", "-i", result.path, "-f", "null", "-"])
        }
        try assertNoTemporaryFiles()
    }

    func testRealFFmpegConvertsAToneToMP3() async throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("[BELUM DIUJI] no ffmpeg on this Mac") }
        let source = file("tone.wav")
        try TestAudio.writeTone(to: source, seconds: 2)
        let real = ConversionService(engines: [FFmpegEngine(executable: ffmpeg)])
        let seen = Collector<Double>()
        let result = try await real.convert(source, to: "mp3") { seen.add($0) }
        XCTAssertEqual(result.lastPathComponent, "tone.mp3")
        XCTAssertEqual(try TestAudio.duration(of: result), 2, accuracy: 0.2)
        XCTAssertEqual(seen.values.last, 1)
        try assertNoTemporaryFiles()
    }
}
