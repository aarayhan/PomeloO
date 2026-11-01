import XCTest
@testable import PomeloOCore

/// SVG is drawn by the system's renderer and then converted like any other picture.
final class SVGTests: TempDirectoryTestCase {
    private let service = ConversionService(engines: [ImageEngine()], runner: JobRunner(maxConcurrent: 2))

    private func makeSVG(_ name: String = "logo.svg", width: Int = 100, height: Int = 80, background: Bool = false) throws -> URL {
        let url = file(name)
        let backdrop = background ? "<rect width=\"\(width)\" height=\"\(height)\" fill=\"#ff8a00\"/>" : ""
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)">
        \(backdrop)<circle cx="\(width / 2)" cy="\(height / 2)" r="\(min(width, height) / 4)" fill="blue"/></svg>
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSVGIsReadableAndOffered() throws {
        try XCTSkipUnless(ImageFormat.svg.isReadable, "this Mac cannot draw SVG")
        let targets = service.availableTargets(forExtension: "svg")
        XCTAssertTrue(["jpg", "png", "webp", "pdf"].allSatisfy(targets.contains), "\(targets)")
        XCTAssertFalse(ImageFormat.svg.isWritable)
        XCTAssertFalse(targets.contains("svg"))
    }

    func testASmallSVGIsDrawnAboutTwoThousandPixelsWide() async throws {
        try XCTSkipUnless(ImageFormat.svg.isReadable, "this Mac cannot draw SVG")
        let image = try TestImage.read(try await service.convert(try makeSVG(), to: "png"))
        XCTAssertEqual(image.width, 2000)
        XCTAssertEqual(image.height, 1600)
    }

    func testALargeSVGKeepsItsOwnSize() async throws {
        try XCTSkipUnless(ImageFormat.svg.isReadable, "this Mac cannot draw SVG")
        let image = try TestImage.read(try await service.convert(try makeSVG(width: 3000, height: 1000), to: "png"))
        XCTAssertEqual(image.width, 3000, "the zoom never goes below 1")
        XCTAssertEqual(image.height, 1000)
    }

    func testTransparencyIsKeptForPNGAndFlattenedForJPEG() async throws {
        try XCTSkipUnless(ImageFormat.svg.isReadable, "this Mac cannot draw SVG")
        let source = try makeSVG()
        let png = try TestImage.read(try await service.convert(source, to: "png"))
        XCTAssertEqual(TestImage.pixel(png, x: 5, y: 5).a, 0, "nothing is drawn in the corner")
        XCTAssertGreaterThan(TestImage.pixel(png, x: 1000, y: 800).a, 250, "the circle is solid")
        let jpg = try TestImage.read(try await service.convert(source, to: "jpg"))
        let corner = TestImage.pixel(jpg, x: 5, y: 5)
        XCTAssertGreaterThan(corner.r, 240)
        XCTAssertGreaterThan(corner.b, 240, "transparency becomes white")
    }

    func testTheColoursAreTheSVGsOwn() async throws {
        try XCTSkipUnless(ImageFormat.svg.isReadable, "this Mac cannot draw SVG")
        let image = try TestImage.read(try await service.convert(try makeSVG("bg.svg", background: true), to: "png"))
        let orange = TestImage.pixel(image, x: 5, y: 5)
        XCTAssertEqual(orange.r, 255, accuracy: 3)
        XCTAssertEqual(orange.g, 138, accuracy: 3)
        XCTAssertEqual(orange.b, 0, accuracy: 3)
        let blue = TestImage.pixel(image, x: 1000, y: 800)
        XCTAssertGreaterThan(blue.b, 240)
        XCTAssertLessThan(blue.r, 20)
    }

    /// The job runner draws on its own threads, not the main one.
    func testSVGDrawnFromTheJobRunnerThreads() async throws {
        try XCTSkipUnless(ImageFormat.svg.isReadable, "this Mac cannot draw SVG")
        let sources = try (1...6).map { try makeSVG("logo\($0).svg", width: 100 + $0, height: 80) }
        let ids = await service.enqueue(sources, to: "png")
        for id in ids {
            guard case let .finished(url) = await service.runner.finalState(of: id) else { return XCTFail("a job did not finish") }
            let image = try TestImage.read(url)
            XCTAssertEqual(image.width, 2000)
            XCTAssertTrue((1500...1600).contains(image.height), "kept the 80 : 100+ proportions: \(image.height)")
        }
        try assertNoTemporaryFiles()
    }

    func testABrokenSVGFailsCleanly() async throws {
        try XCTSkipUnless(ImageFormat.svg.isReadable, "this Mac cannot draw SVG")
        let broken = file("broken.svg")
        try Data("this is not svg".utf8).write(to: broken)
        do {
            _ = try await service.convert(broken, to: "png")
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cannotRead("broken.svg"))
        }
        XCTAssertEqual(try names(), ["broken.svg"])
    }
}
