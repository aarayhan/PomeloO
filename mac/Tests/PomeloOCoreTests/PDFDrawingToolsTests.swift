import PDFKit
import XCTest
@testable import PomeloOCore

/// Watermark, page numbers and removing a password: tools that draw each page again.
final class PDFDrawingToolsTests: TempDirectoryTestCase {
    private let service = ToolService(runner: JobRunner(maxConcurrent: 2))

    private func makePDF(_ name: String = "doc.pdf", pages: Int = 3, sizes: [CGSize] = [CGSize(width: 300, height: 400)]) throws -> URL {
        let url = file(name)
        try TestPDF.make(at: url, pages: pages, sizes: sizes)
        return url
    }

    /// Where the text `needle` sits on a page, in PDF points (origin bottom left).
    private func bounds(of needle: String, in document: PDFDocument, page: Int) throws -> CGRect {
        let selection = try XCTUnwrap(document.findString(needle, withOptions: []).first { selection in
            selection.pages.first.map { document.index(for: $0) == page } ?? false
        }, "\"\(needle)\" is not on page \(page + 1)")
        return selection.bounds(for: try XCTUnwrap(document.page(at: page)))
    }

    // MARK: watermark

    func testWatermarkDrawsTextOnEveryPageAndKeepsTheOriginal() async throws {
        let source = try makePDF()
        let result = try await service.run(.watermark(WatermarkOptions(text: "DRAFT")), on: [source])[0]
        XCTAssertEqual(result.lastPathComponent, "doc Watermarked.pdf")
        let texts = try TestPDF.texts(result)
        XCTAssertEqual(texts.count, 3)
        for (index, text) in texts.enumerated() {
            XCTAssertTrue(text.contains("Page \(index + 1)"), "the page's own text is still there: \(text)")
            XCTAssertTrue(text.contains("DRAFT"), "the watermark is text in the page: \(text)")
        }
        try assertNoTemporaryFiles()
    }

    func testTheWatermarkIsAtTheMiddleOfThePageAtTheAskedWidth() async throws {
        let options = WatermarkOptions(text: "DRAFT", sizePercent: 70, opacityPercent: 100, angle: 0, color: "#ff0000")
        let result = try await service.run(.watermark(options), on: [try makePDF(pages: 1)])[0]
        let box = try XCTUnwrap(TestPDF.redBounds(try XCTUnwrap(try TestPDF.document(result).page(at: 0))), "no red watermark drawn")
        XCTAssertEqual(box.midX, 150, accuracy: 8, "centred across the page: \(box)")
        XCTAssertEqual(box.midY, 200, accuracy: 20, "centred down the page: \(box)")
        XCTAssertEqual(box.width, 300 * 0.7, accuracy: 20, "70% of the page width: \(box)")
    }

    func testAFortyFiveDegreeWatermarkRisesToTheRight() async throws {
        let options = WatermarkOptions(text: "DRAFT", opacityPercent: 100, angle: 45, color: "#ff0000")
        let result = try await service.run(.watermark(options), on: [try makePDF(pages: 1)])[0]
        let box = try XCTUnwrap(TestPDF.redBounds(try XCTUnwrap(try TestPDF.document(result).page(at: 0))))
        XCTAssertGreaterThan(box.height, 100, "turned text is tall: \(box)")
        XCTAssertEqual(box.midX, 150, accuracy: 12)
        XCTAssertEqual(box.midY, 200, accuracy: 12)
    }

    func testTheWatermarkHasItsColourAndItsAbsenceIsDetected() async throws {
        let source = try makePDF()
        XCTAssertFalse(TestPDF.hasRedPixels(try XCTUnwrap(try TestPDF.document(source).page(at: 0))), "the test page has no red to begin with")
        let result = try await service.run(.watermark(WatermarkOptions(text: "DRAFT", opacityPercent: 60, color: "#ff0000")), on: [source])[0]
        XCTAssertTrue(TestPDF.hasRedPixels(try XCTUnwrap(try TestPDF.document(result).page(at: 0))))
    }

    func testPagesKeepTheirSizesAndARotatedPageComesOutUpright() async throws {
        let source = try makePDF(pages: 2, sizes: [CGSize(width: 300, height: 400), CGSize(width: 500, height: 200)])
        let organized = try await service.run(.organize(order: nil, rotations: [0: 90]), on: [source])[0]
        let result = try await service.run(.watermark(WatermarkOptions()), on: [organized])[0]
        let document = try TestPDF.document(result)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 400, height: 300), "the first page was turned a quarter")
        XCTAssertEqual(document.page(at: 0)?.rotation, 0)
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 500, height: 200))
    }

    // MARK: page numbers

    func testNumbersAreWrittenOnEachPage() async throws {
        let result = try await service.run(.number(NumberingOptions(style: .pageOfTotal)), on: [try makePDF()])[0]
        XCTAssertEqual(result.lastPathComponent, "doc Numbered.pdf")
        let texts = try TestPDF.texts(result)
        XCTAssertTrue(texts[0].contains("Page 1 of 3"), texts[0])
        XCTAssertTrue(texts[1].contains("Page 2 of 3"), texts[1])
        XCTAssertTrue(texts[2].contains("Page 3 of 3"), texts[2])
    }

    func testTheFourStyles() async throws {
        let source = try makePDF(pages: 2)
        let expected: [(NumberingOptions.Style, String)] = [(.plain, "7"), (.page, "Page 7"), (.ofTotal, "7 / 8"), (.pageOfTotal, "Page 7 of 8")]
        for (style, text) in expected {
            let result = try await service.run(.number(NumberingOptions(style: style, start: 7)), on: [source])[0]
            let first = try TestPDF.texts(result)[0]
            XCTAssertTrue(first.contains(text), "\(style): \(first)")
            try FileManager.default.removeItem(at: result)
        }
    }

    func testPositions() async throws {
        let source = try makePDF(pages: 1)
        let cases: [(String, (CGRect) -> Bool)] = [
            ("bottom left", { $0.minX < 60 && $0.midY < 60 }),
            ("bottom center", { abs($0.midX - 150) < 20 && $0.midY < 60 }),
            ("bottom right", { $0.maxX > 240 && $0.midY < 60 }),
            ("top left", { $0.minX < 60 && $0.midY > 340 }),
            ("top center", { abs($0.midX - 150) < 20 && $0.midY > 340 }),
            ("top right", { $0.maxX > 240 && $0.midY > 340 }),
        ]
        for (position, check) in cases {
            let result = try await service.run(.number(NumberingOptions(style: .plain, position: position, start: 42)), on: [source])[0]
            let box = try bounds(of: "42", in: try TestPDF.document(result), page: 0)
            XCTAssertTrue(check(box), "\(position): \(box)")
            try FileManager.default.removeItem(at: result)
        }
    }

    func testAnUnknownPositionFails() async throws {
        do {
            _ = try await service.run(.number(NumberingOptions(position: "middle")), on: [try makePDF()])
            XCTFail("expected an error")
        } catch is ConversionError {}
        XCTAssertEqual(try names(), ["doc.pdf"])
    }

    // MARK: password

    private func makeLockedPDF(password: String) throws -> URL {
        let plain = try makePDF("plain.pdf", pages: 2)
        let locked = file("locked.pdf")
        let ok = try TestPDF.document(plain).write(to: locked, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password])
        XCTAssertTrue(ok)
        XCTAssertTrue(try TestPDF.document(locked).isLocked, "the test file really is locked")
        return locked
    }

    func testUnlockRemovesThePassword() async throws {
        let locked = try makeLockedPDF(password: "secret")
        let result = try await service.run(.unlock(password: "secret"), on: [locked])[0]
        XCTAssertEqual(result.lastPathComponent, "locked Unlocked.pdf")
        let document = try TestPDF.document(result)
        XCTAssertFalse(document.isLocked)
        XCTAssertFalse(document.isEncrypted, "the copy carries no encryption at all")
        XCTAssertEqual(try TestPDF.texts(result), ["Page 1", "Page 2"])
    }

    func testAWrongOrMissingPasswordSaysSo() async throws {
        let locked = try makeLockedPDF(password: "secret")
        do {
            _ = try await service.run(.unlock(password: "nope"), on: [locked])
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .failed("Wrong password."))
        }
        do {
            _ = try await service.run(.unlock(password: ""), on: [locked])
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .failed("This PDF needs its password."))
        }
        try assertNoTemporaryFiles()
        XCTAssertFalse(try names().contains { $0.contains("Unlocked") })
    }

    func testUnlockingAnUnprotectedPDFJustCopiesIt() async throws {
        let result = try await service.run(.unlock(password: ""), on: [try makePDF()])[0]
        XCTAssertEqual(try TestPDF.texts(result).count, 3)
    }

    func testTheToolsThatNeedAPasswordSayWhenTheFileIsLocked() async throws {
        let locked = try makeLockedPDF(password: "secret")
        let other = try makePDF("other.pdf", pages: 1)
        do {
            _ = try await service.run(.merge, on: [locked, other])
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .failed("locked.pdf needs its password."))
        }
    }
}

/// "Add password": AES-128 is what the Mac's frameworks write, and these tests pin that down.
final class PDFProtectTests: TempDirectoryTestCase {
    private let service = ToolService(runner: JobRunner(maxConcurrent: 2))

    private func makePDF(_ name: String = "doc.pdf", pages: Int = 2) throws -> URL {
        let url = file(name)
        try TestPDF.make(at: url, pages: pages)
        return url
    }

    func testProtectedFileNeedsThePasswordAndKeepsItsPages() async throws {
        let result = try await service.run(.protect(password: "correct horse battery staple"), on: [try makePDF()])[0]
        XCTAssertEqual(result.lastPathComponent, "doc Protected.pdf")
        let document = try TestPDF.document(result)
        XCTAssertTrue(document.isLocked)
        XCTAssertFalse(document.unlock(withPassword: "wrong"))
        XCTAssertTrue(document.unlock(withPassword: "correct horse battery staple"))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(try TestPDF.texts(try makePDF("again.pdf")).count, 2)
        let page = try XCTUnwrap(document.page(at: 0)?.string).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(page, "Page 1")
        try assertNoTemporaryFiles()
    }

    func testTheEncryptionIsAES128AsMeasured() async throws {
        let result = try await service.run(.protect(password: "secret"), on: [try makePDF()])[0]
        let text = String(decoding: try Data(contentsOf: result), as: UTF8.self)
        XCTAssertTrue(text.contains("/Filter /Standard"), "the standard security handler")
        XCTAssertTrue(text.contains("/V 4"), "encryption version 4")
        XCTAssertTrue(text.contains("/R 4"), "revision 4")
        XCTAssertTrue(text.contains("/CFM /AESV2"), "AES-128 crypt filter")
        XCTAssertTrue(text.contains("/Length 128"), "a 128-bit key")
        XCTAssertFalse(text.contains("AESV3"), "no AES-256 here; the UI must not claim it")
    }

    func testProtectThenUnlockGivesAPlainCopy() async throws {
        let protected = try await service.run(.protect(password: "secret"), on: [try makePDF()])[0]
        let plain = try await service.run(.unlock(password: "secret"), on: [protected])[0]
        XCTAssertEqual(plain.lastPathComponent, "doc Protected Unlocked.pdf")
        let document = try TestPDF.document(plain)
        XCTAssertFalse(document.isEncrypted)
        XCTAssertEqual(document.pageCount, 2)
    }

    func testAnEmptyPasswordIsRefusedAndNothingIsWritten() async throws {
        do {
            _ = try await service.run(.protect(password: ""), on: [try makePDF()])
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .failed("Type a password."))
        }
        XCTAssertEqual(try names(), ["doc.pdf"])
    }

    func testAFileThatAlreadyHasAPasswordMustBeUnlockedFirst() async throws {
        let protected = try await service.run(.protect(password: "one"), on: [try makePDF()])[0]
        do {
            _ = try await service.run(.protect(password: "two"), on: [protected])
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .failed("doc Protected.pdf needs its password."))
        }
    }

    func testBookmarksSurviveProtecting() async throws {
        let source = try makePDF()
        let document = try TestPDF.document(source)
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter"
        chapter.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 1)), at: .zero)
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root
        let withOutline = file("outlined.pdf")
        XCTAssertTrue(document.write(to: withOutline))
        let result = try await service.run(.protect(password: "secret"), on: [withOutline])[0]
        let reopened = try TestPDF.document(result)
        XCTAssertTrue(reopened.unlock(withPassword: "secret"))
        XCTAssertEqual(reopened.outlineRoot?.child(at: 0)?.label, "Chapter", "unlike the tools that draw pages again")
    }
}
