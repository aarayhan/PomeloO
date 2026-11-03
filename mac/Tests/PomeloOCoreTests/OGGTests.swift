import XCTest
@testable import PomeloOCore

/// OGG is written by libvorbis, which the release ffmpeg has and Homebrew's does not. These tests use the release build
/// directly (`mac/build/ffmpeg/Tools/ffmpeg`, made by `mac/scripts/build-ffmpeg.sh`) whatever `POMELOO_FFMPEG` says, and are
/// reported as skipped, not passed, when it has not been built.
final class OGGTests: TempDirectoryTestCase {
    private var release: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Tests/PomeloOCoreTests/OGGTests.swift -> mac/
        let mac = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidate = mac.appendingPathComponent("build/ffmpeg/Tools/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip("[BELUM DIUJI] the release ffmpeg is not built: run mac/scripts/build-ffmpeg.sh")
        }
        release = candidate
    }

    private func makeWAV(seconds: Int = 4) async throws -> URL {
        let url = file("tone.wav")
        try await FFmpegRunner(executable: release).run(["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                                                         "sine=frequency=440:duration=\(seconds)", "-ac", "2", url.path])
        return url
    }

    private func info(_ url: URL) async throws -> MediaInfo {
        var runner = FFmpegRunner(executable: release)
        runner.tailLines = 400
        return MediaInfo.parse(try await runner.run(FFmpegEngine.probeArguments(input: url)))
    }

    func testTheReleaseBuildHasLibvorbis() {
        XCTAssertEqual(FFmpegEncoders.available(at: release)?.contains("libvorbis"), true)
    }

    func testOGGIsOfferedAsATargetAndWritten() async throws {
        let engine = FFmpegEngine(executable: release)
        XCTAssertTrue(engine.canConvert(from: "wav", to: "ogg"))
        XCTAssertTrue(engine.canConvert(from: "mp4", to: "ogg"))
        let service = ConversionService(engines: [engine])
        XCTAssertTrue(service.availableTargets(forExtension: "wav").contains("ogg"))

        let source = try await makeWAV()
        let result = try await service.convert(source, to: "ogg")
        XCTAssertEqual(result.lastPathComponent, "tone.ogg")
        let converted = try await info(result)
        XCTAssertEqual(converted.duration, 4, accuracy: 0.2)
        XCTAssertTrue(converted.hasAudio)
        let header = try await FFmpegRunner(executable: release, tailLines: 400).run(FFmpegEngine.probeArguments(input: result))
        XCTAssertTrue(header.contains("vorbis"), header)
        try assertNoTemporaryFiles()
    }

    func testOGGFilesCanBeReadAndConvertedBack() async throws {
        let service = ConversionService(engines: [FFmpegEngine(executable: release)])
        let ogg = try await service.convert(try await makeWAV(), to: "ogg")
        let mp3 = try await service.convert(ogg, to: "mp3")
        let seconds = try await info(mp3).duration
        XCTAssertEqual(seconds, 4, accuracy: 0.3)
    }

    func testTheAudioToolsWorkOnOGG() async throws {
        let engine = FFmpegEngine(executable: release)
        let ogg = try await ConversionService(engines: [engine]).convert(try await makeWAV(seconds: 6), to: "ogg")
        let tools = ToolService(ffmpeg: release)
        let offered = tools.availableTools(for: [ogg])
        for id in ["compress", "removeMetadata", "normalizeAudio", "audioToVideo", "trimAudio", "audioChannels", "redactAudio"] {
            XCTAssertTrue(offered.contains(id), "\(id) is offered for OGG: \(offered)")
        }
        let trimmed = try await tools.run(.trimAudio(TrimOptions(start: 1, end: 3)), on: [ogg]).first!
        XCTAssertEqual(trimmed.pathExtension, "ogg")
        let trimmedSeconds = try await info(trimmed).duration
        XCTAssertEqual(trimmedSeconds, 2, accuracy: 0.2)
        let compressed = try await tools.run(.compress(MediaCompressOptions(percent: 50)), on: [ogg]).first!
        XCTAssertEqual(compressed.lastPathComponent, "tone Compressed.ogg")
        let smallest = try await tools.run(.compress(MediaCompressOptions(percent: 5)), on: [ogg]).first!
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: smallest.path)[.size] as! Int, 1000, "the smallest setting still writes a file libvorbis accepts")
        let mono = try await tools.run(.channels(ChannelOptions(channels: 1)), on: [ogg]).first!
        let channels = try await info(mono).audioChannels
        XCTAssertEqual(channels, 1)
        try assertNoTemporaryFiles()
    }

    /// With a build that has no libvorbis (Homebrew's), OGG is neither offered nor attempted.
    func testOGGIsOnlyOfferedWhenLibvorbisIsThere() throws {
        guard let found = FFmpegLocator.find() else { throw XCTSkip("[BELUM DIUJI] no ffmpeg on this Mac") }
        let has = FFmpegEncoders.available(at: found)?.contains("libvorbis") ?? false
        let offered = ConversionService(engines: [FFmpegEngine(executable: found)]).availableTargets(forExtension: "wav").contains("ogg")
        XCTAssertEqual(offered, has, "OGG offered: \(offered), libvorbis present: \(has)")
    }
}
