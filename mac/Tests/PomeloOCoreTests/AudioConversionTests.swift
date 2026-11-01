import XCTest
@testable import PomeloOCore

final class AudioConversionTests: TempDirectoryTestCase {
    private let service = ConversionService(engines: [AppleAudioEngine()])

    private func makeTone(_ name: String = "tone.wav", seconds: Double = 1) throws -> URL {
        let url = file(name)
        try TestAudio.writeTone(to: url, seconds: seconds)
        return url
    }

    func testWAVToM4AReadsBackWithTheSameLength() async throws {
        let source = try makeTone()
        let result = try await service.convert(source, to: "m4a")
        XCTAssertEqual(result.lastPathComponent, "tone.m4a")
        XCTAssertEqual(try TestAudio.duration(of: result), 1, accuracy: 0.15)
        XCTAssertEqual(try names(), ["tone.m4a", "tone.wav"])
    }

    func testWAVToAIFFAndBack() async throws {
        let source = try makeTone()
        let aiff = try await service.convert(source, to: "aiff")
        XCTAssertEqual(try TestAudio.duration(of: aiff), 1, accuracy: 0.01)
        let wav = try await service.convert(aiff, to: "wav")
        XCTAssertEqual(wav.lastPathComponent, "tone 2.wav")  // tone.wav is the original
        XCTAssertEqual(try TestAudio.duration(of: wav), 1, accuracy: 0.01)
    }

    func testFLACRoundTripIsLossless() async throws {
        try XCTSkipUnless(service.availableTargets(forExtension: "wav").contains("flac"), "this Mac cannot write FLAC")
        let source = try makeTone()
        let flac = try await service.convert(source, to: "flac")
        XCTAssertEqual(try TestAudio.duration(of: flac), 1, accuracy: 0.01)
        let back = try await service.convert(flac, to: "aiff")
        XCTAssertEqual(try TestAudio.duration(of: back), 1, accuracy: 0.01)
    }

    func testProgressRisesToOne() async throws {
        let source = try makeTone(seconds: 3)
        let seen = Collector<Double>()
        try await _ = service.convert(source, to: "m4a") { seen.add($0) }
        let values = seen.values
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted(), "progress went backwards")
        XCTAssertGreaterThan(values.count, 1)
    }

    func testMP3IsNotWrittenByAppleFrameworks() {
        // MP3 targets are ffmpeg's job; AVFoundation reads MP3 but has no encoder for it.
        XCTAssertFalse(AppleAudioEngine().canConvert(from: "wav", to: "mp3"))
        XCTAssertFalse(AppleAudioEngine().canConvert(from: "wav", to: "ogg"))
        XCTAssertFalse(AppleAudioEngine().canConvert(from: "wav", to: "wav"))
        XCTAssertTrue(AppleAudioEngine().canConvert(from: "mp3", to: "wav"))
    }

    func testAnUnreadableFileFailsAndLeavesNothingBehind() async throws {
        let broken = file("broken.wav")
        try Data("not audio".utf8).write(to: broken)
        do {
            _ = try await service.convert(broken, to: "m4a")
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cannotRead("broken.wav"))
        }
        XCTAssertEqual(try names(), ["broken.wav"])
    }

    func testAudioTargetsDoNotIncludeWhatOnlyFFmpegCanWrite() {
        let withoutFFmpeg = service.availableTargets(forExtension: "wav")
        XCTAssertFalse(withoutFFmpeg.contains("mp3"))
        XCTAssertFalse(withoutFFmpeg.contains("wma"))
        XCTAssertTrue(withoutFFmpeg.contains("m4a"))
        XCTAssertTrue(withoutFFmpeg.contains("aiff"))
    }
}
