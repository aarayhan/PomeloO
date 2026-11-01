import CoreGraphics
import ImageIO
import XCTest
@testable import PomeloOCore

final class ImageToolsTests: TempDirectoryTestCase {
    private let service = ToolService(runner: JobRunner(maxConcurrent: 2))

    private func size(_ url: URL) throws -> Int { try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }

    private func makeNoisyJPEG(_ name: String = "photo.jpg") throws -> URL {
        let url = file(name)
        try TestImage.writeJPEG(TestImage.noisy(), to: url)
        return url
    }

    // MARK: compress

    func testCompressMeetsAPercentageTarget() async throws {
        let source = try makeNoisyJPEG()
        let result = try await service.run(.compress(CompressOptions(percent: 50)), on: [source])[0]
        XCTAssertEqual(result.lastPathComponent, "photo Compressed.jpg")
        XCTAssertLessThanOrEqual(try size(result), try size(source) / 2)
        XCTAssertGreaterThan(try size(result), try size(source) / 10, "no smaller than it had to be, by an order of magnitude")
        let image = try TestImage.read(result)
        XCTAssertEqual(image.width, 320, "the quality went down, not the size")
        try assertNoTemporaryFiles()
    }

    func testCompressToAnExactSize() async throws {
        let source = try makeNoisyJPEG()
        let result = try await service.run(.compress(CompressOptions(targetKB: 30)), on: [source])[0]
        XCTAssertLessThanOrEqual(try size(result), 30 * 1024)
        XCTAssertGreaterThan(try size(result), 15 * 1024, "close to the target, not far below it")
    }

    func testCompressCanScaleDownFirst() async throws {
        let source = try makeNoisyJPEG()
        let result = try await service.run(.compress(CompressOptions(percent: 95, resizePercent: 50)), on: [source])[0]
        let image = try TestImage.read(result)
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 120)
    }

    func testPresetsAreThe7550And25PercentOfWindows() {
        XCTAssertEqual(CompressOptions(preset: .highQuality).percent, 75)
        XCTAssertEqual(CompressOptions(preset: .balanced).percent, 50)
        XCTAssertEqual(CompressOptions(preset: .smallest, resizePercent: 80), CompressOptions(percent: 25, resizePercent: 80))
    }

    func testAnImpossibleTargetStillEndsWithAPictureAndTheSourceIsUntouched() async throws {
        let source = try makeNoisyJPEG()
        let before = try Data(contentsOf: source)
        let result = try await service.run(.compress(CompressOptions(targetKB: 1)), on: [source])[0]
        XCTAssertLessThan(try TestImage.read(result).width, 320, "it fell back to a smaller picture")
        XCTAssertGreaterThanOrEqual(min(try TestImage.read(result).width, try TestImage.read(result).height), 17)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testCompressWorksOnPNGAndWebP() async throws {
        let png = file("shot.png")
        try TestImage.writePNG(TestImage.noisy(), to: png)
        let pngResult = try await service.run(.compress(CompressOptions(percent: 95)), on: [png])[0]
        XCTAssertEqual(pngResult.lastPathComponent, "shot Compressed.png")
        XCTAssertLessThanOrEqual(try size(pngResult), try size(png) * 95 / 100)
        XCTAssertGreaterThan(try TestImage.read(pngResult).width, 32)

        let webp = try await ConversionService(engines: [ImageEngine()]).convert(png, to: "webp")
        let webpResult = try await service.run(.compress(CompressOptions(percent: 30)), on: [webp])[0]
        XCTAssertEqual(webpResult.lastPathComponent, "shot Compressed.webp")
        XCTAssertLessThanOrEqual(try size(webpResult), try size(webp) * 30 / 100)
    }

    func testAPNGThatCannotMeetItsTargetGetsSmaller() async throws {
        let png = file("shot.png")
        try TestImage.writePNG(TestImage.noisy(), to: png)
        let result = try await service.run(.compress(CompressOptions(percent: 20)), on: [png])[0]
        XCTAssertLessThanOrEqual(try size(result), try size(png) / 5)
        XCTAssertLessThan(try TestImage.read(result).width, 320)
    }

    // MARK: metadata

    private func makeCameraJPEG(_ name: String = "camera.jpg") throws -> URL {
        let url = file(name)
        try TestImage.writeJPEG(TestImage.make(), to: url, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PomeloO Cam", kCGImagePropertyTIFFModel: "Model 7"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 100.5, kCGImagePropertyGPSLongitudeRef: "E"],
        ])
        XCTAssertEqual(TestImage.tiff(url)[kCGImagePropertyTIFFMake] as? String, "PomeloO Cam", "the test picture really has camera data")
        return url
    }

    func testRemoveMetadataDropsCameraAndLocation() async throws {
        let source = try makeCameraJPEG()
        let result = try await service.run(.removeMetadata, on: [source])[0]
        XCTAssertEqual(result.lastPathComponent, "camera No Metadata.jpg")
        XCTAssertNil(TestImage.tiff(result)[kCGImagePropertyTIFFMake])
        XCTAssertNil(TestImage.properties(result)[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(try TestImage.read(result).width, 64)
        XCTAssertEqual(TestImage.tiff(source)[kCGImagePropertyTIFFMake] as? String, "PomeloO Cam", "the original keeps its data")
    }

    func testRemoveMetadataKeepsTheColourProfile() async throws {
        let result = try await service.run(.removeMetadata, on: [try makeCameraJPEG()])[0]
        XCTAssertNotNil(try TestImage.read(result).colorSpace)
        XCTAssertNotNil(TestImage.properties(result)[kCGImagePropertyProfileName], "an ICC profile is embedded")
    }

    func testEditMetadataSetsFieldsAndIsNamedEdited() async throws {
        let source = try makeCameraJPEG()
        let result = try await service.run(.editMetadata(fields: [
            "File/Artist": "Ada", "copyright": "© 2026 Ada", "Make": "Other Cam", "title": "A picture",
        ]), on: [source])[0]
        XCTAssertEqual(result.lastPathComponent, "camera Edited.jpg")
        let tiff = TestImage.tiff(result)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist] as? String, "Ada")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFCopyright] as? String, "© 2026 Ada")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Other Cam")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFImageDescription] as? String, "A picture")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "Model 7", "fields not named stay as they were")
    }

    // MARK: crop

    func testCropToARectangleOfFractions() async throws {
        let source = file("wide.png")
        try TestImage.writePNG(TestImage.halves(), to: source)
        let result = try await service.run(.crop(CropOptions(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))), on: [source])[0]
        XCTAssertEqual(result.lastPathComponent, "wide Cropped.png")
        let image = try TestImage.read(result)
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 50)
        XCTAssertGreaterThan(TestImage.pixel(image, x: 10, y: 10).r, 240, "left half of the crop is red")
        XCTAssertGreaterThan(TestImage.pixel(image, x: 90, y: 10).b, 240, "right half is blue")
    }

    func testCropToAnAspectTakesTheMiddle() async throws {
        let source = file("wide.png")
        try TestImage.writePNG(TestImage.halves(), to: source)
        let result = try await service.run(.crop(CropOptions(aspect: "1:1")), on: [source])[0]
        let image = try TestImage.read(result)
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 100)
        XCTAssertGreaterThan(TestImage.pixel(image, x: 5, y: 50).r, 240)
        XCTAssertGreaterThan(TestImage.pixel(image, x: 95, y: 50).b, 240)
    }

    func testCropToExactPixelsCoversTheSize() async throws {
        let source = file("wide.png")
        try TestImage.writePNG(TestImage.halves(), to: source)
        let image = try TestImage.read(try await service.run(.crop(CropOptions(width: 40, height: 40)), on: [source])[0])
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 40)
    }

    func testCropKeepsCameraData() async throws {
        let source = file("camera.jpg")
        try TestImage.writeJPEG(TestImage.make(), to: source, properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PomeloO Cam"]])
        let result = try await service.run(.crop(CropOptions(aspect: "1:1")), on: [source])[0]
        XCTAssertEqual(TestImage.tiff(result)[kCGImagePropertyTIFFMake] as? String, "PomeloO Cam")
    }

    func testTheCentredRectMatchesTheWindowsFormula() {
        let a = ImageTools.centredRect(200, 100, ratio: 1)
        XCTAssertEqual([a.minX, a.minY, a.width, a.height], [0.25, 0, 0.5, 1])
        let b = ImageTools.centredRect(100, 200, ratio: 16.0 / 9)
        XCTAssertEqual(b.minX, 0)
        XCTAssertEqual(b.width, 1)
        XCTAssertEqual(b.height, 100 / 16.0 * 9 / 200, accuracy: 1e-9)
    }

    // MARK: several files and the wheel

    func testEachPictureGetsItsOwnResult() async throws {
        let a = try makeNoisyJPEG("a.jpg"), b = try makeNoisyJPEG("b.jpg")
        let results = try await service.run(.removeMetadata, on: [a, b])
        XCTAssertEqual(results.map(\.lastPathComponent), ["a No Metadata.jpg", "b No Metadata.jpg"])
    }

    func testOtherFormatsAreRefused() async throws {
        let pdf = file("doc.pdf")
        try TestPDF.make(at: pdf, pages: 1)
        do {
            _ = try await service.run(.compress(CompressOptions()), on: [pdf])
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .unsupported(from: "pdf", to: "compress"))
        }
    }

    func testToolsOfferedForPictures() {
        let one = service.availableTools(for: [file("a.jpg")])
        XCTAssertEqual(Set(one), ["compress", "removeMetadata", "editImage", "cropImage", "redactImage", "readQR", "extractText"])
        let several = service.availableTools(for: [file("a.jpg"), file("b.jpg")])
        XCTAssertEqual(Set(several), ["compress", "removeMetadata", "cropImage", "extractText"])
        XCTAssertEqual(service.availableTools(for: [file("a.svg")]), [])
        XCTAssertFalse(service.availableTools(for: [file("a.pdf")]).contains("compress"), "a PDF cannot be compressed here yet")
    }
}
