import CoreGraphics
import Vision
import XCTest
@testable import PomeloOCore

final class RedactAndVisionTests: TempDirectoryTestCase {
    private let tools = ToolService(runner: JobRunner(maxConcurrent: 2))

    // MARK: covering areas

    private func gradientPNG(_ name: String = "grad.png", width: Int = 128, height: Int = 128) throws -> URL {
        var data: [UInt8] = []
        for y in 0..<height { for x in 0..<width { data += [UInt8(x * 2), UInt8(y * 2), UInt8((x + y) % 256), 255] } }
        let url = file(name)
        try TestImage.writePNG(try ImagePixels.image(fromStraightRGBA: data, width: width, height: height), to: url)
        return url
    }

    func testAColourFillCoversExactlyTheArea() async throws {
        let source = try gradientPNG()
        let area = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)  // pixels 32...96
        let result = try await tools.run(.redact(RedactOptions(rects: [area], style: .color, color: "#00ff00")), on: [source])[0]
        XCTAssertEqual(result.lastPathComponent, "grad Redacted.png")
        let image = try TestImage.read(result)
        let inside = TestImage.pixel(image, x: 64, y: 64)
        XCTAssertEqual([inside.r, inside.g, inside.b], [0, 255, 0])
        XCTAssertEqual(TestImage.pixel(image, x: 33, y: 33).g, 255)
        let outside = TestImage.pixel(image, x: 10, y: 10)
        XCTAssertEqual(outside.r, 20)
        XCTAssertEqual(outside.g, 20)
        XCTAssertEqual(TestImage.pixel(image, x: 100, y: 100).r, 200, "outside the area nothing changed")
    }

    func testPixelateMakesBlocks() async throws {
        let source = try gradientPNG()
        let result = try await tools.run(.redact(RedactOptions(rects: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)], style: .pixelate)), on: [source])[0]
        let image = try TestImage.read(result)
        // the area is 64 px, so 4 x 4 blocks of 16 px
        let a = TestImage.pixel(image, x: 18, y: 18), b = TestImage.pixel(image, x: 29, y: 27)
        XCTAssertEqual(a.r, b.r, accuracy: 1, "one block, one colour")
        XCTAssertEqual(a.g, b.g, accuracy: 1)
        let next = TestImage.pixel(image, x: 34, y: 18)
        XCTAssertNotEqual(a.r, next.r, "the next block is another colour")
        let untouched = TestImage.pixel(image, x: 100, y: 100)
        XCTAssertEqual(untouched.r, 200)
    }

    func testBlurSoftensAHardEdgeInsideTheAreaOnly() async throws {
        let source = file("edge.png")
        try TestImage.writePNG(TestImage.halves(width: 128, height: 64), to: source)  // red | blue at x = 64
        let area = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let result = try await tools.run(.redact(RedactOptions(rects: [area], style: .blur)), on: [source])[0]
        let image = try TestImage.read(result)
        let atEdge = TestImage.pixel(image, x: 64, y: 32)
        XCTAssertGreaterThan(atEdge.r, 40, "red bleeds across the old edge")
        XCTAssertGreaterThan(atEdge.b, 40, "and blue the other way")
        XCTAssertGreaterThan(TestImage.pixel(image, x: 10, y: 32).r, 250, "outside the area it is still sharp red")
        XCTAssertGreaterThan(TestImage.pixel(image, x: 120, y: 32).b, 250)
    }

    func testRedactingDropsCameraData() async throws {
        let source = file("camera.jpg")
        try TestImage.writeJPEG(TestImage.make(), to: source, properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PomeloO Cam"]])
        let result = try await tools.run(.redact(RedactOptions(rects: [CGRect(x: 0, y: 0, width: 0.2, height: 0.2)], style: .color)), on: [source])[0]
        XCTAssertNil(TestImage.tiff(result)[kCGImagePropertyTIFFMake])
    }

    func testAreasOutsideThePictureAreClamped() async throws {
        let source = try gradientPNG()
        let result = try await tools.run(.redact(RedactOptions(rects: [CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5), CGRect(x: 2, y: 2, width: 1, height: 1)], style: .color)), on: [source])[0]
        XCTAssertEqual(try TestImage.read(result).width, 128)
    }

    // MARK: finding things

    func testTextIsFoundAndCoveredAutomatically() async throws {
        let source = file("note.png")
        try TestImage.writePNG(TestImage.text("SECRET PASSWORD"), to: source)
        let boxes = try VisionTools.textBoxes(in: try TestImage.read(source))
        XCTAssertGreaterThanOrEqual(boxes.count, 2, "one box per word: \(boxes)")
        let result = try await tools.run(.redact(RedactOptions(style: .color, color: "#000000", auto: .text)), on: [source])[0]
        let image = try TestImage.read(result)
        let word = boxes[0]
        let pixel = TestImage.pixel(image, x: Int(word.midX * Double(image.width)), y: Int(word.midY * Double(image.height)))
        XCTAssertLessThan(pixel.r, 10, "the word is under a black box")
        XCTAssertGreaterThan(TestImage.pixel(image, x: image.width - 5, y: 5).r, 245, "the rest of the picture is untouched")
    }

    func testNoFacesInAPlainPicture() async throws {
        let source = file("plain.png")
        try TestImage.writePNG(TestImage.make(), to: source)
        XCTAssertEqual(try VisionTools.faceBoxes(in: try TestImage.read(source)), [])
        let result = try await tools.run(.redact(RedactOptions(auto: .faces)), on: [source])[0]
        XCTAssertEqual(try ImagePixels.straightRGBA(try TestImage.read(result)), try ImagePixels.straightRGBA(try TestImage.read(source)))
    }

    // MARK: QR codes and text

    func testAQRCodeIsRead() async throws {
        let source = file("code.png")
        try TestImage.writePNG(TestImage.qr("https://pomeloo.example/?a=1&b=2"), to: source)
        let text = try await tools.text(.readCodes, from: [source])
        XCTAssertEqual(text, "https://pomeloo.example/?a=1&b=2")
    }

    func testAPictureWithoutACodeSaysSo() async throws {
        let source = file("plain.png")
        try TestImage.writePNG(TestImage.make(), to: source)
        let text = try await tools.text(.readCodes, from: [source])
        XCTAssertEqual(text, "No QR code or barcode found.")
    }

    func testEnglishTextIsRecognised() async throws {
        let source = file("english.png")
        try TestImage.writePNG(TestImage.text("Hello PomeloO world"), to: source)
        let text = try await tools.text(.recognizeText, from: [source]).lowercased()
        XCTAssertTrue(text.contains("hello"), text)
        XCTAssertTrue(text.contains("world"), text)
    }

    func testIndonesianTextIsRecognised() async throws {
        let source = file("indonesia.png")
        try TestImage.writePNG(TestImage.text("Selamat pagi, apa kabar dunia"), to: source)
        let text = try await tools.text(.recognizeText, from: [source]).lowercased()
        XCTAssertTrue(text.contains("selamat"), text)
        XCTAssertTrue(text.contains("kabar"), text)
    }

    func testVisionSupportsIndonesianAtTheAccurateLevel() throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        XCTAssertTrue(try request.supportedRecognitionLanguages().contains("id-ID"), "mac/docs/parity.md promises this")
    }

    func testSeveralPicturesGiveTheirTextsSeparatedByABlankLine() async throws {
        let a = file("a.png"), b = file("b.png")
        try TestImage.writePNG(TestImage.text("First page"), to: a)
        try TestImage.writePNG(TestImage.text("Second page"), to: b)
        let text = try await tools.text(.recognizeText, from: [a, b])
        let parts = text.components(separatedBy: "\n\n")
        XCTAssertEqual(parts.count, 2, text)
        XCTAssertTrue(parts[0].lowercased().contains("first"))
        XCTAssertTrue(parts[1].lowercased().contains("second"))
    }

    func testTextToolsRefuseWhatIsNotAPicture() async throws {
        let pdf = file("doc.pdf")
        try TestPDF.make(at: pdf, pages: 1)
        do {
            _ = try await tools.text(.recognizeText, from: [pdf])
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .unsupported(from: "pdf", to: "extractText"))
        }
    }

    // MARK: reflowing lines

    func testLinesThatDoNotEndASentenceAreJoined() {
        let lines = ["This sentence runs over two lines and", "ends here.", "A new paragraph."]
        XCTAssertEqual(TextFlow.joinLines(lines), "This sentence runs over two lines and ends here.\nA new paragraph.")
    }

    func testAHyphenJoinsTheWord() {
        XCTAssertEqual(TextFlow.joinLines(["A line long enough to count as running on, inter-", "national news."]),
                       "A line long enough to count as running on, international news.")
    }

    func testShortLinesBulletsAndNumbersStayApart() {
        XCTAssertEqual(TextFlow.joinLines(["Title", "body text goes here"]), "Title\nbody text goes here")
        XCTAssertEqual(TextFlow.joinLines(["Items that keep going and going forever", "- first", "2. second"]),
                       "Items that keep going and going forever\n- first\n2. second")
        XCTAssertEqual(TextFlow.joinLines(["", "  ", "x"]), "x")
    }

    func testWordRanges() {
        let text = "  two  words "
        XCTAssertEqual(VisionTools.wordRanges(in: text).map { String(text[$0]) }, ["two", "words"])
        XCTAssertEqual(VisionTools.wordRanges(in: "").count, 0)
    }
}
