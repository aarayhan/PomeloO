import CoreGraphics
import ImageIO
import XCTest
@testable import PomeloOCore

final class ImageConversionTests: TempDirectoryTestCase {
    private let service = ConversionService(engines: [ImageEngine()])

    private func makePNG(_ name: String = "photo.png", transparent: Bool = false) throws -> URL {
        let url = file(name)
        try TestImage.writePNG(TestImage.make(transparentBackground: transparent), to: url)
        return url
    }

    // MARK: formats that every Mac writes

    func testPNGToJPEGKeepsTheSizeAndLeavesTheSourceAlone() async throws {
        let source = try makePNG()
        let before = try Data(contentsOf: source)
        let result = try await service.convert(source, to: "jpg")
        XCTAssertEqual(result.lastPathComponent, "photo.jpg")
        let image = try TestImage.read(result)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try names(), ["photo.jpg", "photo.png"])
    }

    func testTheSecondConversionGetsANumberedName() async throws {
        let source = try makePNG()
        let first = try await service.convert(source, to: "jpg")
        let second = try await service.convert(source, to: "jpg")
        XCTAssertEqual(first.lastPathComponent, "photo.jpg")
        XCTAssertEqual(second.lastPathComponent, "photo 2.jpg")
        try assertNoTemporaryFiles()
    }

    func testTwoSourcesWithTheSameStemAtOnceDoNotCollide() async throws {
        let png = try makePNG("photo.png")
        let bmp = file("photo.bmp")
        try await _ = service.convert(png, to: "bmp")  // photo.bmp now exists as a source
        XCTAssertTrue(FileManager.default.fileExists(atPath: bmp.path))
        let service = self.service
        async let a = service.convert(png, to: "tiff")
        async let b = service.convert(bmp, to: "tiff")
        let results = try await [a, b].map(\.lastPathComponent).sorted()
        XCTAssertEqual(results, ["photo 2.tiff", "photo.tiff"])
        try assertNoTemporaryFiles()
    }

    func testTransparencyIsFlattenedOntoWhiteForJPEG() async throws {
        let source = try makePNG(transparent: true)
        let jpeg = try TestImage.read(try await service.convert(source, to: "jpg"))
        let corner = TestImage.pixel(jpeg, x: 1, y: 1)
        XCTAssertGreaterThan(corner.r, 240)
        XCTAssertGreaterThan(corner.g, 240)
        XCTAssertGreaterThan(corner.b, 240)
        XCTAssertEqual(corner.a, 255)
    }

    func testTransparencyIsKeptForPNGAndTIFF() async throws {
        let source = try makePNG("alpha.png", transparent: true)
        let tiff = try TestImage.read(try await service.convert(source, to: "tiff"))
        XCTAssertEqual(TestImage.pixel(tiff, x: 1, y: 1).a, 0)
    }

    func testBMPAndTIFFReadBack() async throws {
        let source = try makePNG()
        for target in ["bmp", "tiff"] {
            let image = try TestImage.read(try await service.convert(source, to: target))
            XCTAssertEqual(image.width, 64, target)
            XCTAssertEqual(image.height, 48, target)
        }
    }

    func testPDFPageIsSizedFor300DPI() async throws {
        let source = try makePNG()
        let pdf = try await service.convert(source, to: "pdf")
        let document = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
        XCTAssertEqual(document.numberOfPages, 1)
        let box = try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, 64 * 72 / 300, accuracy: 0.01)
        XCTAssertEqual(box.height, 48 * 72 / 300, accuracy: 0.01)
    }

    func testAnUnreadableFileFailsAndLeavesNothingBehind() async throws {
        let broken = file("broken.png")
        try Data("not an image".utf8).write(to: broken)
        do {
            _ = try await service.convert(broken, to: "jpg")
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cannotRead("broken.png"))
        }
        XCTAssertEqual(try names(), ["broken.png"])
    }

    func testAnUnsupportedPairIsRefusedBeforeAnythingIsWritten() async throws {
        let source = try makePNG()
        do {
            _ = try await service.convert(source, to: "mp3")
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .unsupported(from: "png", to: "mp3"))
        }
        XCTAssertEqual(try names(), ["photo.png"])
    }

    func testProgressEndsAtOne() async throws {
        let source = try makePNG()
        let seen = Collector<Double>()
        try await _ = service.convert(source, to: "jpg") { seen.add($0) }
        XCTAssertEqual(seen.values.last, 1)
    }

    // MARK: formats that depend on the Mac

    func testHEICIsOptionalOnThisMachine() async throws {
        try XCTSkipUnless(ImageFormat.heic.isWritable, "this Mac has no HEIC encoder")
        let source = try makePNG()
        let result = try await service.convert(source, to: "heic")
        let image = try TestImage.read(result)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }

    func testAVIFIsDescribedAsLossyWithAlpha() {
        XCTAssertEqual(ImageFormat.avif.fileExtension, "avif")
        XCTAssertEqual(ImageFormat.avif.utTypeIdentifier, "public.avif")
        XCTAssertTrue(ImageFormat.avif.isLossy)
        XCTAssertTrue(ImageFormat.avif.supportsAlpha)
    }

    func testAVIFIsOptionalOnThisMachine() async throws {
        try XCTSkipUnless(ImageFormat.avif.isWritable, "this Mac has no AVIF encoder")
        let source = try makePNG()
        let result = try await service.convert(source, to: "avif")
        XCTAssertEqual(result.lastPathComponent, "photo.avif")
        let image = try TestImage.read(result)  // it can be read again
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }

    func testTransparentPNGKeepsItsAlphaInAVIF() async throws {
        try XCTSkipUnless(ImageFormat.avif.isWritable, "this Mac has no AVIF encoder")
        let source = try makePNG("alpha.png", transparent: true)
        let avif = try TestImage.read(try await service.convert(source, to: "avif"))
        XCTAssertLessThan(TestImage.pixel(avif, x: 1, y: 1).a, 30, "the transparent corner became opaque")
        let ellipse = TestImage.pixel(avif, x: 32, y: 24)
        XCTAssertGreaterThan(ellipse.a, 225, "the opaque ellipse became transparent")
    }

    // MARK: what the wheel may offer

    func testAvailableTargetsFollowTheMachine() {
        let targets = service.availableTargets(forExtension: "png")
        for format in ImageFormat.allCases where format != .png {
            XCTAssertEqual(targets.contains(format.fileExtension), format.isWritable,
                           "\(format) is \(format.isWritable ? "" : "not ")writable here")
        }
        XCTAssertTrue(["jpg", "tiff", "bmp", "pdf"].allSatisfy(targets.contains))
        XCTAssertFalse(targets.contains("png"))
        XCTAssertFalse(targets.contains("mp3"))
    }

    func testAvailableTargetsKeepTheCatalogOrder() {
        let catalogOrder = Catalog.bundled.targets(forExtension: "png")
        let available = service.availableTargets(forExtension: "png")
        XCTAssertEqual(available, catalogOrder.filter(available.contains))
    }

    func testCommonTargetsOfSeveralFormats() {
        let common = service.commonTargets(forExtensions: ["png", "jpg", "bmp"])
        XCTAssertTrue(common.contains("tiff"))
        XCTAssertFalse(common.contains("png"), "png is not a target for the png file")
        XCTAssertEqual(service.commonTargets(forExtensions: []), [])
        XCTAssertEqual(service.commonTargets(forExtensions: ["png", "mp3"]), [])
    }

    func testUnknownSourcesHaveNoTargets() {
        XCTAssertEqual(service.availableTargets(forExtension: "xyz"), [])
        XCTAssertEqual(service.availableTargets(forExtension: ""), [])
    }
}
