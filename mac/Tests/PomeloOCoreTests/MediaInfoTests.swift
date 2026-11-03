import XCTest
@testable import PomeloOCore

final class MediaInfoTests: XCTestCase {
    private let header = """
    Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mp4':
      Metadata:
        major_brand     : isom
      Duration: 00:01:02.50, start: 0.000000, bitrate: 1054 kb/s
      Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 1920x1080 [SAR 1:1 DAR 16:9], 960 kb/s, 29.97 fps, 29.97 tbr, 30k tbn (default)
      Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 96 kb/s (default)
    """

    func testAVideoWithSound() {
        let info = MediaInfo.parse(header)
        XCTAssertEqual(info.duration, 62.5)
        XCTAssertEqual(info.size?.width, 1920)
        XCTAssertEqual(info.size?.height, 1080)
        XCTAssertEqual(info.fps, 29.97)
        XCTAssertTrue(info.hasVideo)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.audioKbps, 96)
        XCTAssertEqual(info.audioChannels, 2)
    }

    func testACoverPictureIsNotVideo() {
        let info = MediaInfo.parse("""
          Duration: 00:03:00.00, start: 0.025056, bitrate: 320 kb/s
          Stream #0:0: Audio: mp3, 44100 Hz, mono, fltp, 320 kb/s
          Stream #0:1: Video: mjpeg (Baseline), yuvj420p(pc, bt470bg/unknown/unknown), 500x500 [SAR 1:1 DAR 1:1], 90k tbr, 90k tbn (attached pic)
        """)
        XCTAssertFalse(info.hasVideo, "a cover picture is not a video stream")
        XCTAssertEqual(info.audioChannels, 1)
        XCTAssertEqual(info.duration, 180)
    }

    func testCodecTagsAreNotTakenForASize() {
        let info = MediaInfo.parse("  Stream #0:0: Video: mpeg4 (Simple Profile) (mp4v / 0x7634706D), yuv420p, 640x360 [SAR 1:1 DAR 16:9], 25 fps")
        XCTAssertEqual(info.size?.width, 640)
        XCTAssertEqual(info.size?.height, 360)
    }

    func testNothingReadable() {
        let info = MediaInfo.parse("garbage")
        XCTAssertFalse(info.hasVideo)
        XCTAssertFalse(info.hasAudio)
        XCTAssertEqual(info.duration, 0)
    }

    func testTimesAsTyped() {
        XCTAssertEqual(TimeText.seconds("83.5"), 83.5)
        XCTAssertEqual(TimeText.seconds("1:23.5"), 83.5)
        XCTAssertEqual(TimeText.seconds("1:02:03"), 3723)
        XCTAssertEqual(TimeText.seconds(" 7 "), 7)
        XCTAssertNil(TimeText.seconds("abc"))
        XCTAssertNil(TimeText.seconds("-3"))
        XCTAssertNil(TimeText.seconds("1:2:3:4"))
        XCTAssertNil(TimeText.seconds(""))
    }

    func testTimesAsShown() {
        XCTAssertEqual(TimeText.text(0), "0:00")
        XCTAssertEqual(TimeText.text(83.5), "1:23.5")
        XCTAssertEqual(TimeText.text(3723), "1:02:03")
        XCTAssertEqual(TimeText.text(59.96), "1:00")
        XCTAssertEqual(TimeText.seconds(TimeText.text(754.3)), 754.3)
    }

    func testLoudnessNumbersAreReadFromTheReport() throws {
        let report = """
        [Parsed_loudnorm_0 @ 0x1234]
        {
            "input_i" : "-23.45",
            "input_tp" : "-4.10",
            "input_lra" : "6.20",
            "input_thresh" : "-33.80",
            "output_i" : "-27.20",
            "target_offset" : "0.30"
        }
        """
        let numbers = try XCTUnwrap(MediaTools.loudness(inReport: report))
        XCTAssertEqual(numbers["input_i"], "-23.45")
        XCTAssertEqual(numbers["target_offset"], "0.30")
        XCTAssertNil(MediaTools.loudness(inReport: report.replacingOccurrences(of: "-23.45", with: "-inf")), "silence has no loudness")
        XCTAssertNil(MediaTools.loudness(inReport: "no json here"))
    }
}
