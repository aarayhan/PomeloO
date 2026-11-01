import CoreGraphics
import ImageIO
import XCTest
@testable import PomeloOCore

/// WebP is written in-process by libwebp and read back by ImageIO: no ffmpeg anywhere.
final class WebPTests: TempDirectoryTestCase {
    private let service = ConversionService(engines: [ImageEngine()])

    private func makePNG(_ name: String = "photo.png", transparent: Bool = false) throws -> URL {
        let url = file(name)
        try TestImage.writePNG(TestImage.make(transparentBackground: transparent), to: url)
        return url
    }

    func testWebPIsAlwaysOffered() {
        XCTAssertTrue(ImageFormat.webp.isWritable)
        XCTAssertTrue(service.availableTargets(forExtension: "png").contains("webp"))
        XCTAssertTrue(service.availableTargets(forExtension: "jpg").contains("webp"))
        XCTAssertFalse(service.availableTargets(forExtension: "webp").contains("webp"))
    }

    func testPNGToWebPReadsBackWithTheSameSizeAndColours() async throws {
        let result = try await service.convert(try makePNG(), to: "webp")
        XCTAssertEqual(result.lastPathComponent, "photo.webp")
        let image = try TestImage.read(result)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        // Lossy at quality 90, like the Windows app: a saturated orange (255, 138, 0) comes back as about
        // (255, 155, 2), which libwebp's own decoder agrees with. Close, not equal.
        let orange = TestImage.pixel(image, x: 3, y: 3)
        XCTAssertGreaterThan(orange.r, 240, "\(orange)")
        XCTAssertTrue((120...175).contains(orange.g), "\(orange)")
        XCTAssertLessThan(orange.b, 30, "\(orange)")
        XCTAssertEqual(orange.a, 255)
        try assertNoTemporaryFiles()
    }

    func testTransparencyIsKept() async throws {
        let image = try TestImage.read(try await service.convert(try makePNG("alpha.png", transparent: true), to: "webp"))
        XCTAssertLessThan(TestImage.pixel(image, x: 1, y: 1).a, 30, "the transparent corner became opaque")
        XCTAssertGreaterThan(TestImage.pixel(image, x: 32, y: 24).a, 225, "the opaque ellipse became transparent")
    }

    func testSemiTransparentPixelsKeepTheirColour() throws {
        // 50% blue over nothing: un-multiplying must give back full blue, not a darker one
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let rgba = try LibWebPEncoder.straightRGBA(context.makeImage()!)
        XCTAssertEqual(Int(rgba[2]), 255, accuracy: 3)
        XCTAssertEqual(Int(rgba[3]), 128, accuracy: 2)
    }

    func testWebPReadsBackIntoOtherFormats() async throws {
        let webp = try await service.convert(try makePNG(), to: "webp")
        let jpg = try await service.convert(webp, to: "jpg")
        XCTAssertEqual(jpg.lastPathComponent, "photo.jpg")
        XCTAssertEqual(try TestImage.read(jpg).width, 64)
    }

    func testCameraMetadataIsWrittenIntoAnEXIFChunk() async throws {
        let jpeg = file("camera.jpg")
        let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, TestImage.make(), [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PomeloO Test Camera",
                                             kCGImagePropertyTIFFModel: "Model 7"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let webp = try await service.convert(jpeg, to: "webp")
        let bytes = try Data(contentsOf: webp)
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertNotNil(bytes.range(of: Data("EXIF".utf8)), "no EXIF chunk in the WebP file")
        XCTAssertNotNil(bytes.range(of: Data("PomeloO Test Camera".utf8)), "the camera name did not reach the file")
        XCTAssertEqual(try TestImage.read(webp).width, 64, "a WebP with EXIF still decodes")
    }

    func testAPictureWithoutMetadataGetsNoEXIFChunk() async throws {
        let bytes = try Data(contentsOf: try await service.convert(try makePNG(), to: "webp"))
        XCTAssertNil(bytes.range(of: Data("EXIF".utf8)))
    }

    func testTheExifBlockIsCutOutOfAJPEG() throws {
        let block = try XCTUnwrap(ExifPayload.make(from: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "ACME"]]))
        XCTAssertTrue(block.starts(with: [0x49, 0x49, 0x2A, 0x00]) || block.starts(with: [0x4D, 0x4D, 0x00, 0x2A]),
                      "a TIFF header, without the Exif prefix")
        XCTAssertNil(ExifPayload.make(from: [:]))
    }

    func testAnImageTooLargeForWebPFailsClearly() async throws {
        let wide = file("wide.png")
        try TestImage.writePNG(TestImage.make(width: 16_384, height: 2), to: wide)
        do {
            _ = try await service.convert(wide, to: "webp")
            XCTFail("expected an error")
        } catch let error as ConversionError {
            guard case let .failed(message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("16383"), message)
        }
        try assertNoTemporaryFiles()
        XCTAssertEqual(try names(), ["wide.png"])
    }
}

final class KeptMetadataTests: TempDirectoryTestCase {
    func testWhatImageIOInventsIsNotKept() throws {
        let png = file("plain.png")
        try TestImage.writePNG(TestImage.make(), to: png)
        let source = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        XCTAssertEqual(ImageEngine.keptMetadata(properties).count, 0)
    }

    func testCameraDataIsKeptAndTheOrientationIsNot() throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "ACME", kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: 10],
        ]
        let kept = ImageEngine.keptMetadata(properties)
        let tiff = try XCTUnwrap(kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "ACME")
        XCTAssertNil(tiff[kCGImagePropertyTIFFOrientation])
    }

    func testLocationAloneIsEnoughToKeep() {
        let kept = ImageEngine.keptMetadata([kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.5]])
        XCTAssertNotNil(kept[kCGImagePropertyGPSDictionary])
    }
}
