import ImageIO
import XCTest
@testable import PomeloOCore

/// The audio and video tools against a real ffmpeg (skipped when there is none). Run them with `POMELOO_FFMPEG` set to
/// the release build (`mac/build/ffmpeg/Tools/ffmpeg`) as well as with Homebrew's: the tools must work with both.
final class MediaToolsTests: TempDirectoryTestCase {
    private var ffmpeg: URL!
    private var service: ToolService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let found = FFmpegLocator.find() else { throw XCTSkip("[BELUM DIUJI] no ffmpeg on this Mac") }
        ffmpeg = found
        service = ToolService(ffmpeg: found)
    }

    // MARK: fixtures

    private func make(_ arguments: [String]) async throws {
        try await FFmpegRunner(executable: ffmpeg).run(["-hide_banner", "-loglevel", "error", "-y"] + arguments)
    }

    /// 4 seconds, 320x240 at 25 fps, with a stereo tone.
    private func makeVideo(_ name: String = "clip.mp4", size: String = "320x240", seconds: Int = 4) async throws -> URL {
        let url = file(name)
        try await make(["-f", "lavfi", "-i", "testsrc2=size=\(size):rate=25:duration=\(seconds)", "-f", "lavfi",
                        "-i", "sine=frequency=440:duration=\(seconds)", "-ac", "2", "-c:v", "h264_videotoolbox", "-b:v", "400k",
                        "-pix_fmt", "yuv420p", "-c:a", "aac", url.path])
        return url
    }

    private func makeAudio(_ name: String = "tone.wav", seconds: Int = 4) async throws -> URL {
        let url = file(name)
        try await make(["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-ac", "2", url.path])
        return url
    }

    private func run(_ request: MediaToolRequest, _ sources: [URL]) async throws -> [URL] {
        let results = try await service.run(request, on: sources)
        try assertNoTemporaryFiles()
        return results
    }

    // MARK: metadata and compression

    func testRemovingMetadataKeepsTheMediaAndDropsTheTags() async throws {
        let source = file("tagged.mp3")
        try await make(["-f", "lavfi", "-i", "sine=duration=2", "-metadata", "title=Secret", "-metadata", "artist=Someone", source.path])
        let result = try await run(.metadata(fields: nil), [source]).first!
        XCTAssertEqual(result.lastPathComponent, "tagged No Metadata.mp3")
        let probe = try await FFmpegRunner(executable: ffmpeg, tailLines: 400).run(FFmpegEngine.probeArguments(input: result))
        let header = probe.components(separatedBy: "Output #0").first ?? probe  // the probe's own output is not the file
        XCTAssertFalse(header.contains("Secret"), header)
        XCTAssertFalse(header.contains("Someone"), header)
        XCTAssertFalse(header.contains("encoder"), "ffmpeg must not stamp its own tag into a file that should carry none: \(header)")
        let resultInfo = try info(result)
        XCTAssertEqual(resultInfo.duration, 2, accuracy: 0.2)
    }

    func testEditingMetadataSetsTheFieldsAndKeepsTheRest() async throws {
        let source = file("song.m4a")
        try await make(["-f", "lavfi", "-i", "sine=duration=2", "-metadata", "artist=Keep", source.path])
        let result = try await run(.metadata(fields: ["title": "New Title"]), [source]).first!
        XCTAssertEqual(result.lastPathComponent, "song Edited.m4a")
        let header = try await FFmpegRunner(executable: ffmpeg, tailLines: 400).run(FFmpegEngine.probeArguments(input: result))
        XCTAssertTrue(header.contains("New Title"), header)
        XCTAssertTrue(header.contains("Keep"), header)
    }

    func testCompressingAVideoMakesItSmaller() async throws {
        let source = try await makeVideo(seconds: 6)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! Int
        let result = try await run(.compress(MediaCompressOptions(percent: 40)), [source]).first!
        let after = try FileManager.default.attributesOfItem(atPath: result.path)[.size] as! Int
        XCTAssertEqual(result.lastPathComponent, "clip Compressed.mp4")
        XCTAssertLessThan(after, before)
        let resultInfo = try info(result)
        XCTAssertEqual(resultInfo.duration, 6, accuracy: 0.3)
        XCTAssertTrue(resultInfo.hasAudio)
    }

    func testCompressingResizesWhenAsked() async throws {
        let source = try await makeVideo(size: "640x360")
        let result = try await run(.compress(MediaCompressOptions(percent: 50, resizePercent: 50)), [source]).first!
        let resultInfo = try info(result)
        XCTAssertEqual(resultInfo.size?.width, 320)
        XCTAssertEqual(resultInfo.size?.height, 180)
    }

    func testCompressingAWAVGivesLosslessFLAC() async throws {
        let source = try await makeAudio("voice.wav")
        let result = try await run(.compress(MediaCompressOptions()), [source]).first!
        XCTAssertEqual(result.lastPathComponent, "voice Compressed.flac")
        XCTAssertEqual(try info(result).duration, 4, accuracy: 0.2)
    }

    func testCompressingAnMP3LowersTheBitrate() async throws {
        let source = file("song.mp3")
        try await make(["-f", "lavfi", "-i", "sine=duration=10", "-c:a", "libmp3lame", "-b:a", "256k", source.path])
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! Int
        let result = try await run(.compress(MediaCompressOptions(percent: 25)), [source]).first!
        let after = try FileManager.default.attributesOfItem(atPath: result.path)[.size] as! Int
        XCTAssertLessThan(after, before / 2)
    }

    // MARK: audio

    func testTrimmingAudioKeepsTheRange() async throws {
        let source = try await makeAudio("tone.wav", seconds: 6)
        let result = try await run(.trimAudio(TrimOptions(start: 1, end: 3.5)), [source]).first!
        XCTAssertEqual(result.lastPathComponent, "tone Trimmed.wav")
        XCTAssertEqual(try info(result).duration, 2.5, accuracy: 0.1)
    }

    func testTrimmingFromTheStartToTheEnd() async throws {
        let source = try await makeAudio("tone.wav", seconds: 4)
        let result = try await run(.trimAudio(TrimOptions(start: 3, end: 0)), [source]).first!
        XCTAssertEqual(try info(result).duration, 1, accuracy: 0.1)
    }

    func testTrimmingCanCutTheSilenceAtBothEnds() async throws {
        let source = file("padded.wav")
        // 1 s of silence, 2 s of tone, 1 s of silence
        try await make(["-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-af", "adelay=1000|1000,apad=pad_dur=1", source.path])
        let result = try await run(.trimAudio(TrimOptions(trimSilence: true)), [source]).first!
        let seconds = try info(result).duration
        XCTAssertLessThan(seconds, 2.6)
        XCTAssertGreaterThan(seconds, 1.7)
    }

    func testTrimmingRefusesAStartPastTheEnd() async throws {
        let source = try await makeAudio("tone.wav", seconds: 2)
        do {
            _ = try await run(.trimAudio(TrimOptions(start: 5)), [source])
            XCTFail("should have failed")
        } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("start"), error.localizedDescription)
        }
        try assertNoTemporaryFiles()
        XCTAssertEqual(try names(), ["tone.wav"])
    }

    func testNormalizingReachesTheTargetLoudness() async throws {
        let source = file("quiet.wav")
        try await make(["-f", "lavfi", "-i", "sine=frequency=300:duration=6", "-af", "volume=-30dB", source.path])
        let result = try await run(.normalize(NormalizeOptions(loudness: -16)), [source]).first!
        XCTAssertEqual(result.lastPathComponent, "quiet Normalized.wav")
        let report = try await FFmpegRunner(executable: ffmpeg, tailLines: 100).run(
            ["-hide_banner", "-nostdin", "-i", result.path, "-af", "loudnorm=print_format=json", "-f", "null", "-"])
        let measured = try XCTUnwrap(MediaTools.loudness(inReport: report))
        XCTAssertEqual(Double(measured["input_i"]!)!, -16, accuracy: 1.0, "loudness after normalizing: \(measured)")
    }

    func testNormalizingASilentFileSaysSo() async throws {
        let source = file("silence.wav")
        try await make(["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "2", source.path])
        do {
            _ = try await run(.normalize(NormalizeOptions()), [source])
            XCTFail("should have failed")
        } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("no sound"), error.localizedDescription)
        }
    }

    func testChannelsToMono() async throws {
        let source = try await makeAudio()
        let result = try await run(.channels(ChannelOptions(channels: 1)), [source]).first!
        XCTAssertEqual(result.lastPathComponent, "tone Mono.wav")
        XCTAssertEqual(try info(result).audioChannels, 1)
        let stereo = try await run(.channels(ChannelOptions(channels: 2, left: 100, right: 50)), [source]).first!
        XCTAssertEqual(try info(stereo).audioChannels, 2)
    }

    func testBleepingKeepsTheLength() async throws {
        let source = try await makeAudio()
        for mode in BleepOptions.Mode.allCases {
            let result = try await run(.bleep(BleepOptions(ranges: [TimeRange(start: 1, end: 2)], mode: mode)), [source]).first!
            XCTAssertEqual(try info(result).duration, 4, accuracy: 0.2, mode.rawValue)
            try FileManager.default.removeItem(at: result)
        }
    }

    func testBleepNeedsAStretch() async throws {
        let source = try await makeAudio()
        do {
            _ = try await run(.bleep(BleepOptions(ranges: [])), [source])
            XCTFail("should have failed")
        } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("stretch"), error.localizedDescription)
        }
    }

    func testTheVisualizerMakesAnMP4WithTheSound() async throws {
        let source = try await makeAudio(seconds: 2)
        for style in [VisualizeOptions.Style.waves, .spectrum] {
            let result = try await run(.visualize(VisualizeOptions(style: style, shape: .square)), [source]).first!
            XCTAssertEqual(result.lastPathComponent.hasSuffix("Visualizer.mp4"), true)
            let resultInfo = try info(result)
            XCTAssertEqual(resultInfo.size?.width, 1080, "\(style)")
            XCTAssertTrue(resultInfo.hasAudio)
            XCTAssertEqual(resultInfo.duration, 2, accuracy: 0.4)
            try FileManager.default.removeItem(at: result)
        }
    }

    func testTheVisualizerWithAPicture() async throws {
        let source = try await makeAudio(seconds: 2)
        let picture = file("cover.png")
        try TestImage.writePNG(TestImage.make(width: 200, height: 100), to: picture)
        let result = try await run(.visualize(VisualizeOptions(style: .image, image: picture, shape: .landscape)), [source]).first!
        let resultInfo = try info(result)
        XCTAssertEqual(resultInfo.size?.width, 1280)
        XCTAssertEqual(resultInfo.size?.height, 720)
        XCTAssertEqual(resultInfo.duration, 2, accuracy: 0.4)
    }

    // MARK: video

    func testTrimmingAVideo() async throws {
        let source = try await makeVideo()
        let result = try await run(.trimVideo(TrimOptions(start: 1, end: 3)), [source]).first!
        XCTAssertEqual(result.lastPathComponent, "clip Trimmed.mp4")
        let resultInfo = try info(result)
        XCTAssertEqual(resultInfo.duration, 2, accuracy: 0.2)
        XCTAssertTrue(resultInfo.hasVideo)
        XCTAssertTrue(resultInfo.hasAudio)
    }

    func testRemovingTheSoundKeepsThePicture() async throws {
        let source = try await makeVideo()
        let result = try await run(.mute, [source]).first!
        XCTAssertEqual(result.lastPathComponent, "clip Muted.mp4")
        let resultInfo = try info(result)
        XCTAssertFalse(resultInfo.hasAudio)
        XCTAssertTrue(resultInfo.hasVideo)
        XCTAssertEqual(resultInfo.duration, 4, accuracy: 0.2)
    }

    func testCroppingToAnAspectTakesTheMiddle() async throws {
        let source = try await makeVideo()
        let square = try await run(.cropVideo(VideoCropOptions(aspect: "1:1")), [source]).first!
        let squareInfo = try info(square)
        XCTAssertEqual(squareInfo.size?.width, 240)
        XCTAssertEqual(squareInfo.size?.height, 240)
        XCTAssertTrue(squareInfo.hasAudio, "the sound stays")
    }

    func testCroppingToExactPixels() async throws {
        let source = try await makeVideo()
        let result = try await run(.cropVideo(VideoCropOptions(width: 160, height: 90)), [source]).first!
        let resultInfo = try info(result)
        XCTAssertEqual(resultInfo.size?.width, 160)
        XCTAssertEqual(resultInfo.size?.height, 90)
    }

    func testCroppingAnArea() async throws {
        let source = try await makeVideo()
        let result = try await run(.cropVideo(VideoCropOptions(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))), [source]).first!
        let resultInfo = try info(result)
        XCTAssertEqual(resultInfo.size?.width, 160)
        XCTAssertEqual(resultInfo.size?.height, 120)
    }

    func testSpeedingUpHalvesTheLength() async throws {
        let source = try await makeVideo()
        let result = try await run(.speed(factor: 2), [source]).first!
        XCTAssertEqual(result.lastPathComponent, "clip Speed.mp4")
        let resultInfo = try info(result)
        XCTAssertEqual(resultInfo.duration, 2, accuracy: 0.25)
        XCTAssertTrue(resultInfo.hasAudio)
        let slow = try await run(.speed(factor: 0.5), [source]).first!
        XCTAssertEqual(try info(slow).duration, 8, accuracy: 0.4)
    }

    func testSpeedStaysInItsRange() async throws {
        let source = try await makeVideo()
        do {
            _ = try await run(.speed(factor: 20), [source])
            XCTFail("should have failed")
        } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("speed"), error.localizedDescription)
        }
    }

    func testOneSnapshotIsAPicture() async throws {
        let source = try await makeVideo()
        let result = try await run(.snapshots(SnapshotOptions(times: [1.5])), [source]).first!
        XCTAssertEqual(result.lastPathComponent, "clip Snapshot.png")
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(image), 1)
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
        XCTAssertEqual(properties?[kCGImagePropertyPixelWidth] as? Int, 320)
    }

    func testSeveralSnapshotsGoInAFolder() async throws {
        let source = try await makeVideo()
        let folder = try await run(.snapshots(SnapshotOptions(count: 3)), [source]).first!
        XCTAssertEqual(folder.lastPathComponent, "clip Snapshots")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["clip 1.png", "clip 2.png", "clip 3.png"])
    }

    func testASnapshotAtTheVeryEndStillGivesAFrame() async throws {
        let source = try await makeVideo()
        let result = try await run(.snapshots(SnapshotOptions(times: [4])), [source]).first!
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: result.path)[.size] as! Int, 1000)
    }

    func testSplittingIntoEqualParts() async throws {
        let source = try await makeVideo(seconds: 6)
        let folder = try await run(.splitVideo(SplitOptions(parts: 3)), [source]).first!
        XCTAssertEqual(folder.lastPathComponent, "clip Clips")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["clip 1.mp4", "clip 2.mp4", "clip 3.mp4"])
        for name in files {
            XCTAssertEqual(try info(folder.appendingPathComponent(name)).duration, 2, accuracy: 0.3, name)
        }
    }

    func testSplittingAtPointsAndByLength() async throws {
        let source = try await makeVideo(seconds: 6)
        let points = try await run(.splitVideo(SplitOptions(points: [1, 5])), [source]).first!
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: points.path).count, 3)
        let clips = try await run(.splitVideo(SplitOptions(seconds: 2.5, precise: false)), [source]).first!
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: clips.path).count, 3, "2.5 s clips of 6 s: three")
    }

    func testSplittingOutsideTheVideoSaysSo() async throws {
        let source = try await makeVideo(seconds: 2)
        do {
            _ = try await run(.splitVideo(SplitOptions(points: [10])), [source])
            XCTFail("should have failed")
        } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("Nothing to split"), error.localizedDescription)
        }
        XCTAssertEqual(try names(), ["clip.mp4"], "the folder is not left behind")
    }

    func testCoveringAnAreaWithBlack() async throws {
        let source = try await makeVideo()
        let result = try await run(.redactVideo(VideoRedactOptions(regions: [.init(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))], style: .black)), [source]).first!
        XCTAssertEqual(result.lastPathComponent, "clip Redacted.mp4")
        let frame = file("frame.png")
        try await make(["-ss", "1", "-i", result.path, "-frames:v", "1", frame.path])
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(frame as CFURL, nil)), 0, nil))
        XCTAssertLessThan(brightness(of: image, at: CGPoint(x: 0.25, y: 0.25)), 0.12, "the covered area is black")
        XCTAssertGreaterThan(brightness(of: image, at: CGPoint(x: 0.75, y: 0.75)), 0.12, "the rest is untouched")
        XCTAssertTrue(try info(result).hasAudio, "the sound is kept")
    }

    func testCoveringAnAreaOnlyForAWhile() async throws {
        let source = try await makeVideo()
        let region = VideoRedactOptions.Region(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), time: TimeRange(start: 2, end: 4))
        let result = try await run(.redactVideo(VideoRedactOptions(regions: [region], style: .black)), [source]).first!
        let early = file("early.png"), late = file("late.png")
        try await make(["-ss", "0.5", "-i", result.path, "-frames:v", "1", early.path])
        try await make(["-ss", "3", "-i", result.path, "-frames:v", "1", late.path])
        func image(_ url: URL) throws -> CGImage { try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), 0, nil)) }
        XCTAssertGreaterThan(brightness(of: try image(early), at: CGPoint(x: 0.25, y: 0.25)), 0.12, "before the stretch")
        XCTAssertLessThan(brightness(of: try image(late), at: CGPoint(x: 0.25, y: 0.25)), 0.12, "during the stretch")
    }

    func testBlurringAnArea() async throws {
        let source = try await makeVideo()
        let result = try await run(.redactVideo(VideoRedactOptions(regions: [.init(rect: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))], style: .blur)), [source]).first!
        XCTAssertEqual(try info(result).size?.width, 320)
        XCTAssertEqual(try info(result).duration, 4, accuracy: 0.2)
    }

    func testJoiningPutsTheClipsOnTheFirstOnesCanvas() async throws {
        let first = try await makeVideo("a.mp4", size: "320x240", seconds: 2)
        let second = try await makeVideo("b.mp4", size: "640x360", seconds: 3)
        let silent = file("c.mp4")
        try await make(["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25:duration=1", "-c:v", "h264_videotoolbox", "-b:v", "200k", silent.path])
        let result = try await run(.join, [first, second, silent]).first!
        XCTAssertEqual(result.lastPathComponent, "a Joined.mp4")
        let resultInfo = try info(result)
        XCTAssertEqual(resultInfo.size?.width, 320)
        XCTAssertEqual(resultInfo.size?.height, 240)
        XCTAssertEqual(resultInfo.duration, 6, accuracy: 0.4)
        XCTAssertTrue(resultInfo.hasAudio, "the clip without sound is given silence, so the sound runs throughout")
    }

    func testJoiningNeedsTwoVideos() async throws {
        let source = try await makeVideo()
        do {
            _ = try await run(.join, [source])
            XCTFail("should have failed")
        } catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("two"), error.localizedDescription)
        }
    }

    func testOtherContainersWork() async throws {
        let mkv = file("clip.mkv")
        try await make(["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=2", "-f", "lavfi", "-i", "sine=duration=2",
                        "-c:v", "h264_videotoolbox", "-b:v", "300k", "-c:a", "aac", mkv.path])
        let trimmed = try await run(.trimVideo(TrimOptions(start: 0.5, end: 1.5)), [mkv]).first!
        XCTAssertEqual(trimmed.pathExtension, "mkv")
        XCTAssertEqual(try info(trimmed).duration, 1, accuracy: 0.2)
        let webm = file("clip.webm")
        try await make(["-i", mkv.path, "-c:v", "libvpx-vp9", "-b:v", "200k", "-c:a", "libopus", webm.path])
        let sped = try await run(.speed(factor: 2), [webm]).first!
        XCTAssertEqual(try info(sped).duration, 1, accuracy: 0.3)
    }

    // MARK: failing and cancelling

    func testAFileFfmpegCannotReadFailsAndLeavesNothing() async throws {
        let bad = file("broken.mp4")
        try Data("not a video".utf8).write(to: bad)
        do {
            _ = try await run(.mute, [bad])
            XCTFail("should have failed")
        } catch {}
        XCTAssertEqual(try names(), ["broken.mp4"])
    }

    func testCancellingLeavesNothing() async throws {
        let source = try await makeVideo("long.mp4", size: "640x360", seconds: 30)
        let service = self.service!
        let task = Task { try await service.run(.speed(factor: 1.5), on: [source]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = try? await task.value
        try assertNoTemporaryFiles()
        XCTAssertEqual(try names(), ["long.mp4"])
    }

    // MARK: what is offered

    func testWhatIsOfferedForAudioAndVideo() async throws {
        let video = try await makeVideo()
        let audio = try await makeAudio()
        let video1 = service.availableTools(for: [video])
        XCTAssertEqual(video1, ["compress", "removeMetadata", "muteVideo", "trimVideo", "cropVideo", "changeVideoSpeed",
                                "videoSnapshots", "splitVideo", "redactVideo"], "burnSubtitles waits for libass")
        XCTAssertEqual(service.availableTools(for: [audio]).prefix(7),
                       ["compress", "removeMetadata", "normalizeAudio", "audioToVideo", "trimAudio", "audioChannels", "redactAudio"])
        let second = file("two.mp4")
        try FileManager.default.copyItem(at: video, to: second)
        XCTAssertEqual(service.availableTools(for: [video, second]), ["compress", "removeMetadata", "muteVideo", "joinVideos"])
    }

    func testWithoutFfmpegNoMediaToolIsOffered() async throws {
        let video = try await makeVideo()
        let without = ToolService(ffmpeg: nil)
        XCTAssertEqual(without.availableTools(for: [video]), [])
    }

    func testAToolIsNotOfferedWhenItsEncoderIsMissing() async throws {
        let wav = try await makeAudio()
        let fake = file("fake-ffmpeg")
        try """
        #!/bin/sh
        case "$*" in *"-encoders"*)
        echo "Encoders:"
        echo " ------"
        echo " A....D pcm_s16le   PCM"
        exit 0;; esac
        exit 0
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let limited = ToolService(ffmpeg: fake)
        let offered = limited.availableTools(for: [wav])
        XCTAssertTrue(offered.contains("trimAudio"), "WAV needs only PCM")
        XCTAssertFalse(offered.contains("compress"), "compressing a WAV writes FLAC, which this build lacks")
        XCTAssertFalse(offered.contains("audioToVideo"), "the visualizer writes MP4, which this build lacks")
        XCTAssertTrue(offered.contains("removeMetadata"), "copying streams needs no encoder")
    }

    // MARK: helpers

    /// Brightness 0...1 of the pixel at a point given as fractions of the picture, y down.
    private func brightness(of image: CGImage, at point: CGPoint) -> Double {
        let x = Int(point.x * Double(image.width)), y = Int(point.y * Double(image.height))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3 / 255
    }
}

extension MediaToolsTests {
    func info(_ url: URL) throws -> MediaInfo {
        // a synchronous read for the assertions that only need a number; the header text is the same one the tools use
        let text = try runSync(["-hide_banner", "-i", url.path])
        return MediaInfo.parse(text)
    }

    private func runSync(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
