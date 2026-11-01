import CoreGraphics
import XCTest
@testable import PomeloOCore

/// The sliders, checked against the formulas of `apply_edit` in pomeloo/tools/image.py on small pictures.
final class ImageAdjustTests: TempDirectoryTestCase {
    private let cancel = CancelFlag()

    /// A picture made of one flat colour.
    private func flat(_ r: Int, _ g: Int, _ b: Int, a: Int = 255, width: Int = 8, height: Int = 6) throws -> CGImage {
        var data: [UInt8] = []
        for _ in 0..<(width * height) { data += [UInt8(r), UInt8(g), UInt8(b), UInt8(a)] }
        return try ImagePixels.image(fromStraightRGBA: data, width: width, height: height)
    }

    private func apply(_ image: CGImage, _ configure: (inout AdjustOptions) -> Void) throws -> CGImage {
        var options = AdjustOptions()
        configure(&options)
        return try ImageAdjust.apply(image, options, cancel: cancel)
    }

    private func rgba(_ image: CGImage, _ x: Int = 0, _ y: Int = 0) throws -> (Int, Int, Int, Int) {
        let data = try ImagePixels.straightRGBA(image)
        let i = (y * image.width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }

    func testNoSlidersChangeNothing() throws {
        let image = try flat(40, 90, 200, a: 180)
        XCTAssertTrue(AdjustOptions().isIdentity)
        let result = try apply(image) { _ in }
        XCTAssertEqual(try ImagePixels.straightRGBA(result), try ImagePixels.straightRGBA(image))
    }

    func testExposureIsInStops() throws {
        let image = try flat(64, 64, 64)
        let up = try rgba(try apply(image) { $0.exposure = 1 })
        XCTAssertEqual(up.0, 128, accuracy: 1)
        let down = try rgba(try apply(image) { $0.exposure = -1 })
        XCTAssertEqual(down.0, 32, accuracy: 1)
        let clipped = try rgba(try apply(try flat(200, 200, 200)) { $0.exposure = 2 })
        XCTAssertEqual(clipped.0, 255)
    }

    func testContrastPushesAwayFromGrey() throws {
        let image = try flat(191, 64, 128)  // 0.75, 0.25, 0.5
        let result = try rgba(try apply(image) { $0.contrast = 100 })
        XCTAssertEqual(result.0, 255, accuracy: 1, "(0.75 - 0.5) * 2 + 0.5 = 1")
        XCTAssertEqual(result.1, 0, "(0.25 - 0.5) * 2 + 0.5 = 0")
        XCTAssertEqual(result.2, 127, accuracy: 2, "mid grey stays")
    }

    func testTemperatureWarmsAndTintMovesGreen() throws {
        let image = try flat(128, 128, 128)
        let warm = try rgba(try apply(image) { $0.temperature = 100 })
        XCTAssertEqual(warm.0, 160, accuracy: 1, "red x 1.25")
        XCTAssertEqual(warm.2, 96, accuracy: 1, "blue x 0.75")
        XCTAssertEqual(warm.1, 128, accuracy: 1)
        let tinted = try rgba(try apply(image) { $0.tint = 100 })
        XCTAssertEqual(tinted.1, 96, accuracy: 1, "green x 0.75")
    }

    func testSaturationAndBlackAndWhite() throws {
        let orange = try flat(255, 138, 0)
        let grey = try rgba(try apply(orange) { $0.saturation = -100 })
        XCTAssertEqual(grey.0, grey.1, accuracy: 1)
        XCTAssertEqual(grey.1, grey.2, accuracy: 1)
        XCTAssertEqual(grey.0, Int(0.299 * 255 + 0.587 * 138), accuracy: 2, "luma")
        let mono = try rgba(try apply(orange) { $0.grayscale = true })
        XCTAssertEqual(mono.0, grey.0, accuracy: 1)
        let vivid = try rgba(try apply(try flat(150, 120, 100)) { $0.saturation = 100 })
        XCTAssertGreaterThan(vivid.0 - vivid.2, 150 - 100, "colours spread further apart")
    }

    func testHighlightsAndShadowsFollowTheirFormulas() throws {
        // lum = 0.5, highlights +100: + (100/200) * 0.25 = +0.125; shadows +100: + 0.5 * 0.25 = +0.125
        let image = try flat(128, 128, 128)
        let highlights = try rgba(try apply(image) { $0.highlights = 100 })
        XCTAssertEqual(highlights.0, Int((128.0 / 255 + 0.125) * 255), accuracy: 2)
        let shadows = try rgba(try apply(image) { $0.shadows = 100 })
        XCTAssertEqual(shadows.0, Int((128.0 / 255 + 0.125) * 255), accuracy: 2)
        let darker = try rgba(try apply(image) { $0.shadows = -100 })
        XCTAssertLessThan(darker.0, 128)
    }

    func testVignetteDarkensTheCornersAndLeavesTheMiddle() throws {
        let image = try flat(200, 200, 200, width: 41, height: 41)
        let result = try apply(image) { $0.vignette = 100 }
        let corner = try rgba(result, 0, 0)
        XCTAssertLessThan(corner.0, 5, "the corner has factor 1 - 1 = 0")
        let middle = try rgba(result, 20, 20)
        XCTAssertEqual(middle.0, 200, accuracy: 3)
    }

    func testAlphaIsLeftAlone() throws {
        let image = try flat(100, 100, 100, a: 77)
        let result = try rgba(try apply(image) { $0.exposure = 1; $0.contrast = 30; $0.grayscale = true })
        XCTAssertEqual(result.3, 77)
    }

    func testRotateIsAClockwiseQuarterTurn() throws {
        // top-left red, the rest blue; a clockwise quarter turn moves it to the top-right
        var data: [UInt8] = []
        for y in 0..<2 { for x in 0..<3 { data += (x == 0 && y == 0) ? [255, 0, 0, 255] : [0, 0, 255, 255] } }
        let image = try ImagePixels.image(fromStraightRGBA: data, width: 3, height: 2)
        let turned = try apply(image) { $0.rotate = 90 }
        XCTAssertEqual(turned.width, 2)
        XCTAssertEqual(turned.height, 3)
        XCTAssertEqual(try rgba(turned, 1, 0).0, 255, "red is now top-right")
        let half = try apply(image) { $0.rotate = 180 }
        XCTAssertEqual(try rgba(half, 2, 1).0, 255, "bottom-right")
        let back = try apply(image) { $0.rotate = 270 }
        XCTAssertEqual(try rgba(back, 0, 2).0, 255, "a counter-clockwise quarter turn: bottom-left")
    }

    func testFlipMirrors() throws {
        var data: [UInt8] = []
        for _ in 0..<2 { data += [255, 0, 0, 255, 0, 0, 255, 255] }  // two rows: red, blue
        let image = try ImagePixels.image(fromStraightRGBA: data, width: 2, height: 2)
        let horizontal = try apply(image) { $0.flip = .horizontal }
        XCTAssertEqual(try rgba(horizontal, 0, 0).2, 255, "blue is on the left now")
        let vertical = try apply(image) { $0.flip = .vertical }
        XCTAssertEqual(try rgba(vertical, 0, 0).0, 255, "rows swap, columns stay")
    }

    func testDehazeStretchesAFlatLookingPicture() throws {
        var data: [UInt8] = []
        for i in 0..<100 { let v = UInt8(100 + i / 2); data += [v, v, v, 255] }  // 100...149
        let image = try ImagePixels.image(fromStraightRGBA: data, width: 10, height: 10)
        let result = try ImagePixels.straightRGBA(try apply(image) { $0.dehaze = 100 })
        XCTAssertLessThan(Int(result[0]), 15, "the darkest tones go towards black")
        XCTAssertGreaterThan(Int(result[99 * 4]), 240, "the lightest towards white")
    }

    func testNoiseReductionRemovesASpeck() throws {
        var data: [UInt8] = []
        for _ in 0..<(9 * 9) { data += [100, 100, 100, 255] }
        let middle = (4 * 9 + 4) * 4
        data[middle] = 255; data[middle + 1] = 255; data[middle + 2] = 255
        let image = try ImagePixels.image(fromStraightRGBA: data, width: 9, height: 9)
        let cleaned = try rgba(try apply(image) { $0.noiseReduction = 100 }, 4, 4)
        XCTAssertEqual(cleaned.0, 100, "the median ignores a single bright pixel")
    }

    func testSharpnessAndClarityAddContrastAtAnEdge() throws {
        // 400 wide so that clarity's blur (a 80th of the long side: 5 px) is wide enough to matter
        let halves = try ImagePixels.image(fromStraightRGBA: (0..<(400 * 10)).flatMap { i -> [UInt8] in
            i % 400 < 200 ? [100, 100, 100, 255] : [150, 150, 150, 255] }, width: 400, height: 10)
        let sharp = try apply(halves) { $0.sharpness = 100 }
        XCTAssertGreaterThan(try rgba(sharp, 200, 5).0, 150, "the light side of the edge overshoots")
        XCTAssertLessThan(try rgba(sharp, 199, 5).0, 100, "the dark side undershoots")
        let clear = try apply(halves) { $0.clarity = 100 }
        XCTAssertGreaterThan(try rgba(clear, 202, 5).0, 150, "clarity lifts the light side near the edge")
        XCTAssertLessThan(try rgba(clear, 197, 5).0, 100, "and lowers the dark side")
        XCTAssertEqual(try rgba(clear, 20, 5).0, 100, "far from an edge nothing moves")
    }

    func testGrainIsTheSameEveryTime() throws {
        let image = try flat(128, 128, 128, width: 16, height: 16)
        let first = try ImagePixels.straightRGBA(try apply(image) { $0.grain = 100 })
        let second = try ImagePixels.straightRGBA(try apply(image) { $0.grain = 100 })
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, try ImagePixels.straightRGBA(image))
        let mean = stride(from: 0, to: first.count, by: 4).map { Double(first[$0]) }.reduce(0, +) / 256
        XCTAssertEqual(mean, 128, accuracy: 6, "noise, not a shift")
    }

    func testThroughTheServiceTheNameIsEdited() async throws {
        let source = file("photo.png")
        try TestImage.writePNG(TestImage.make(), to: source)
        var options = AdjustOptions()
        options.rotate = 90
        let result = try await ToolService().run(.adjust(options), on: [source])[0]
        XCTAssertEqual(result.lastPathComponent, "photo Edited.png")
        let image = try TestImage.read(result)
        XCTAssertEqual(image.width, 48)
        XCTAssertEqual(image.height, 64)
    }
}
