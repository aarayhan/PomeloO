import XCTest
@testable import PomeloOCore

/// Which targets ffmpeg is offered for depends on the encoders of the ffmpeg in use.
final class FFmpegEncoderTests: TempDirectoryTestCase {
    private func fakeFFmpeg(encoders: [String]) throws -> URL {
        let listing = encoders.map { "echo \" A....D \($0)   an encoder\"" }.joined(separator: "\n")
        let url = file("fake-ffmpeg")
        try """
        #!/bin/sh
        case "$*" in *"-encoders"*)
        echo "Encoders:"
        echo " ------"
        \(listing)
        exit 0;; esac
        exit 0
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testEncoderListIsParsed() {
        let text = """
        Encoders:
         V..... = Video
         ------
         V....D libx264              libx264 H.264 (codec h264)
         A....D libmp3lame           libmp3lame MP3 (MPEG audio layer 3)
        """
        XCTAssertEqual(FFmpegEncoders.parse(text), ["libx264", "libmp3lame"])
        XCTAssertEqual(FFmpegEncoders.parse("unrelated output"), [])
    }

    func testWhatEachTargetNeeds() {
        XCTAssertEqual(FFmpegEncoders.required(for: "mp3"), ["libmp3lame"])
        XCTAssertEqual(FFmpegEncoders.required(for: "mp4"), ["libx264", "aac"])
        XCTAssertEqual(FFmpegEncoders.required(for: "png"), [])
        XCTAssertEqual(FFmpegEncoders.required(for: "webp"), [], "WebP no longer goes through ffmpeg")
    }

    func testTargetsFollowTheEncodersOfTheFFmpegInUse() throws {
        let engine = FFmpegEngine(executable: try fakeFFmpeg(encoders: ["libmp3lame", "aac", "pcm_s16le"]))
        XCTAssertTrue(engine.canConvert(from: "ogg", to: "mp3"))
        XCTAssertFalse(engine.canConvert(from: "mp3", to: "ogg"), "no libvorbis in this build")
        XCTAssertFalse(engine.canConvert(from: "mov", to: "mp4"), "no libx264 in this build")
    }

    func testAChangedBinaryIsReadAgain() throws {
        let fake = try fakeFFmpeg(encoders: ["libmp3lame"])
        XCTAssertTrue(FFmpegEngine(executable: fake).canConvert(from: "ogg", to: "mp3"))
        try FileManager.default.removeItem(at: fake)
        let replaced = try fakeFFmpeg(encoders: ["libvorbis"])  // same path, other build
        XCTAssertFalse(FFmpegEngine(executable: replaced).canConvert(from: "wav", to: "mp3"))
        XCTAssertTrue(FFmpegEngine(executable: replaced).canConvert(from: "wav", to: "ogg"))
    }

    func testAnUnreadableEncoderListRulesNothingOut() throws {
        let url = file("silent-ffmpeg")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        XCTAssertTrue(FFmpegEngine(executable: url).canConvert(from: "ogg", to: "mp3"))
    }
}
