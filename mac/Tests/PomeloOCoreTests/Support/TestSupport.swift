import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PomeloOCore

/// A fresh folder per test, removed afterwards.
class TempDirectoryTestCase: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomeloo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Names in the test folder, hidden files included.
    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// No `.pomeloo-…` temporary file may be left behind by a finished, failed or cancelled job.
    func assertNoTemporaryFiles(file: StaticString = #filePath, line: UInt = #line) throws {
        let leftovers = try names().filter(TemporaryOutput.isTemporaryName)
        XCTAssertEqual(leftovers, [], "temporary files left behind", file: file, line: line)
    }
}

// MARK: images

enum TestImage {
    /// An orange image with a blue ellipse. `transparentBackground` makes the orange part fully transparent.
    static func make(width: Int = 64, height: Int = 48, transparentBackground: Bool = false) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparentBackground {
            context.setFillColor(CGColor(red: 1, green: 0.54, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.setFillColor(CGColor(red: 0.12, green: 0.31, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return context.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.cannotWrite(url.lastPathComponent) }
    }

    static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.cannotRead(url.lastPathComponent)
        }
        return image
    }

    /// RGBA of one pixel (0,0 is the top-left corner), as drawn.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let i = (y * image.width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }
}

// MARK: audio

enum TestAudio {
    /// A 440 Hz tone as 16-bit stereo WAV.
    static func writeTone(to url: URL, seconds: Double = 1, sampleRate: Double = 44_100) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(file.processingFormat.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate)) * 0.5 }
        }
        try file.write(from: buffer)
    }

    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

// MARK: concurrency helpers

/// Collects values from `@Sendable` callbacks.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

struct TimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "timed out after \(seconds) s" }
}

/// Fails the test (by throwing) instead of hanging when `body` takes longer than `seconds`.
func withTimeout<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// An engine for tests: converts the given pairs by running `behavior`.
struct StubEngine: ConversionEngine {
    let name = "stub"
    let pairs: Set<String>
    let behavior: @Sendable (ConversionJob, @escaping @Sendable (Double) -> Void) async throws -> Void

    init(pairs: Set<String>, behavior: @escaping @Sendable (ConversionJob, @escaping @Sendable (Double) -> Void) async throws -> Void) {
        self.pairs = pairs
        self.behavior = behavior
    }

    func canConvert(from: String, to: String) -> Bool { pairs.contains("\(from)>\(to)") }

    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await behavior(job, progress)
    }
}
