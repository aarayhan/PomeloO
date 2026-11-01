import XCTest
@testable import PomeloOCore

/// WebP output and the encoder check, against a fake ffmpeg that lists encoders and copies its input
/// (the intermediate PNG) to the output, so the tests see exactly what ffmpeg would be given.
final class WebPAndEncoderTests: TempDirectoryTestCase {
    private func fakeFFmpeg(encoders: [String]) throws -> URL {
        let listing = encoders.map { "echo \" V....D \($0)   an encoder\"" }.joined(separator: "\n")
        let url = file("fake-ffmpeg")
        try """
        #!/bin/sh
        case "$*" in *"-encoders"*)
        echo "Encoders:"
        echo " ------"
        \(listing)
        exit 0;; esac
        echo "$@" > "$(dirname "$0")/args"
        while [ $# -gt 0 ]; do
          if [ "$1" = "-i" ]; then input="$2"; fi
          last="$1"
          shift
        done
        cp "$input" "$last"
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makePNG(_ name: String = "photo.png", transparent: Bool = false) throws -> URL {
        let url = file(name)
        try TestImage.writePNG(TestImage.make(transparentBackground: transparent), to: url)
        return url
    }

    // MARK: reading the encoder list

    func testEncoderListIsParsed() {
        let text = """
        Encoders:
         V..... = Video
         ------
         V....D libx264              libx264 H.264 (codec h264)
         A....D libmp3lame           libmp3lame MP3 (MPEG audio layer 3)
         V....D libwebp              libwebp WebP image (codec webp)
        """
        XCTAssertEqual(FFmpegEncoders.parse(text), ["libx264", "libmp3lame", "libwebp"])
        XCTAssertEqual(FFmpegEncoders.parse("unrelated output"), [])
    }

    func testWhatEachTargetNeeds() {
        XCTAssertEqual(FFmpegEncoders.required(for: "webp"), ["libwebp"])
        XCTAssertEqual(FFmpegEncoders.required(for: "mp3"), ["libmp3lame"])
        XCTAssertEqual(FFmpegEncoders.required(for: "mp4"), ["libx264", "aac"])
        XCTAssertEqual(FFmpegEncoders.required(for: "png"), [])
    }

    func testTargetsFollowTheEncodersOfTheFFmpegInUse() throws {
        let fake = try fakeFFmpeg(encoders: ["libmp3lame", "aac", "pcm_s16le"])
        let engine = FFmpegEngine(executable: fake)
        XCTAssertTrue(engine.canConvert(from: "ogg", to: "mp3"))
        XCTAssertFalse(engine.canConvert(from: "mp3", to: "ogg"), "no libvorbis in this build")
        XCTAssertFalse(engine.canConvert(from: "mov", to: "mp4"), "no libx264 in this build")
    }

    func testAnUnreadableEncoderListRulesNothingOut() throws {
        let url = file("silent-ffmpeg")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        XCTAssertTrue(FFmpegEngine(executable: url).canConvert(from: "ogg", to: "mp3"))
    }

    // MARK: WebP

    func testWebPIsOfferedOnlyWithLibwebp() throws {
        let with = ConversionService(engines: [ImageEngine(), WebPEngine(executable: try fakeFFmpeg(encoders: ["libwebp"]))])
        XCTAssertTrue(with.availableTargets(forExtension: "png").contains("webp"))
        XCTAssertTrue(with.availableTargets(forExtension: "jpg").contains("webp"))

        try FileManager.default.removeItem(at: file("fake-ffmpeg"))
        let without = ConversionService(engines: [ImageEngine(), WebPEngine(executable: try fakeFFmpeg(encoders: ["libx264"]))])
        XCTAssertFalse(without.availableTargets(forExtension: "png").contains("webp"))

        let noFFmpeg = ConversionService(engines: [ImageEngine(), WebPEngine(executable: nil)])
        XCTAssertFalse(noFFmpeg.availableTargets(forExtension: "png").contains("webp"))
    }

    func testWebPFromAWebPIsNotOffered() throws {
        let engine = WebPEngine(executable: try fakeFFmpeg(encoders: ["libwebp"]))
        XCTAssertFalse(engine.canConvert(from: "webp", to: "webp"))
        XCTAssertFalse(engine.canConvert(from: "mp3", to: "webp"))
        XCTAssertFalse(engine.canConvert(from: "png", to: "jpg"))
    }

    func testPNGToWebPHandsFFmpegAnUprightPNGAndTheLibwebpSettings() async throws {
        let service = ConversionService(engines: [ImageEngine(), WebPEngine(executable: try fakeFFmpeg(encoders: ["libwebp"]))])
        let source = try makePNG()
        let result = try await service.convert(source, to: "webp")
        XCTAssertEqual(result.lastPathComponent, "photo.webp")

        let arguments = try String(contentsOf: file("args"), encoding: .utf8)
        XCTAssertTrue(arguments.contains("-c:v libwebp"), arguments)
        XCTAssertTrue(arguments.contains("-quality 90"), arguments)
        XCTAssertTrue(arguments.contains("-frames:v 1"), arguments)

        // the fake copied its input, so the result is the intermediate PNG
        let image = try TestImage.read(result)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        try assertNoTemporaryFiles()
        XCTAssertEqual(try names().filter { $0.hasPrefix("pomeloo-") }, [])
    }

    func testTransparencyReachesFFmpegUntouched() async throws {
        let service = ConversionService(engines: [ImageEngine(), WebPEngine(executable: try fakeFFmpeg(encoders: ["libwebp"]))])
        let source = try makePNG("alpha.png", transparent: true)
        let image = try TestImage.read(try await service.convert(source, to: "webp"))
        XCTAssertEqual(TestImage.pixel(image, x: 1, y: 1).a, 0, "transparency must not be flattened for WebP")
    }

    func testAnUnreadableImageFailsWithoutCallingFFmpeg() async throws {
        let service = ConversionService(engines: [ImageEngine(), WebPEngine(executable: try fakeFFmpeg(encoders: ["libwebp"]))])
        let broken = file("broken.png")
        try Data("not an image".utf8).write(to: broken)
        do {
            _ = try await service.convert(broken, to: "webp")
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cannotRead("broken.png"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("args").path), "ffmpeg should not have run")
        try assertNoTemporaryFiles()
    }

    func testRealFFmpegWritesAWebPThatReadsBack() async throws {
        guard let ffmpeg = FFmpegLocator.find(), FFmpegEncoders.supports("webp", at: ffmpeg) else {
            throw XCTSkip("[BELUM DIUJI] no ffmpeg with libwebp on this Mac")
        }
        let service = ConversionService(engines: [ImageEngine(), WebPEngine(executable: ffmpeg)])
        let source = try makePNG("alpha.png", transparent: true)
        let image = try TestImage.read(try await service.convert(source, to: "webp"))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        XCTAssertLessThan(TestImage.pixel(image, x: 1, y: 1).a, 30, "alpha lost")
    }
}
