import PDFKit
import XCTest
@testable import PomeloOCore

final class PDFToolsTests: TempDirectoryTestCase {
    private let service = ToolService(runner: JobRunner(maxConcurrent: 2))

    private func makePDF(_ name: String, pages: Int, label: String = "Page", sizes: [CGSize] = [CGSize(width: 300, height: 400)]) throws -> URL {
        let url = file(name)
        try TestPDF.make(at: url, pages: pages, label: label, sizes: sizes)
        return url
    }

    // MARK: merge

    func testMergeJoinsDocumentsInTheGivenOrder() async throws {
        let a = try makePDF("a.pdf", pages: 2, label: "A")
        let b = try makePDF("b.pdf", pages: 3, label: "B")
        let result = try await service.run(.merge, on: [a, b])
        XCTAssertEqual(result.map(\.lastPathComponent), ["a Merged.pdf"])
        XCTAssertEqual(try TestPDF.texts(result[0]), ["A 1", "A 2", "B 1", "B 2", "B 3"])
        XCTAssertEqual(try names(), ["a Merged.pdf", "a.pdf", "b.pdf"])
        try assertNoTemporaryFiles()
    }

    func testMergeReversedOrder() async throws {
        let a = try makePDF("a.pdf", pages: 1, label: "A")
        let b = try makePDF("b.pdf", pages: 1, label: "B")
        let result = try await service.run(.merge, on: [b, a])
        XCTAssertEqual(result.map(\.lastPathComponent), ["b Merged.pdf"])
        XCTAssertEqual(try TestPDF.texts(result[0]), ["B 1", "A 1"])
    }

    func testMergeNeedsTwoFiles() async throws {
        let a = try makePDF("a.pdf", pages: 1)
        do {
            _ = try await service.run(.merge, on: [a])
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .failed("Select at least two files."))
        }
        XCTAssertEqual(try names(), ["a.pdf"])
    }

    func testMergeKeepsEachPagesOwnSize() async throws {
        let a = try makePDF("a.pdf", pages: 1, sizes: [CGSize(width: 200, height: 200)])
        let b = try makePDF("b.pdf", pages: 1, sizes: [CGSize(width: 500, height: 300)])
        let document = try TestPDF.document(try await service.run(.merge, on: [a, b])[0])
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 200, height: 200))
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 500, height: 300))
    }

    func testOnlyPDFsAreAccepted() async throws {
        let text = file("notes.txt")
        try Data("x".utf8).write(to: text)
        do {
            _ = try await service.run(.merge, on: [text, text])
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .unsupported(from: "txt", to: "mergePDF"))
        }
    }

    // MARK: split

    func testSplitMakesOneFilePerPageInAFolder() async throws {
        let source = try makePDF("doc.pdf", pages: 3)
        let folder = try await service.run(.split(ranges: ""), on: [source])[0]
        XCTAssertEqual(folder.lastPathComponent, "doc Pages")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["doc 1.pdf", "doc 2.pdf", "doc 3.pdf"])
        XCTAssertEqual(try TestPDF.texts(folder.appendingPathComponent("doc 2.pdf")), ["Page 2"])
        try assertNoTemporaryFiles()
    }

    func testSplitByRanges() async throws {
        let source = try makePDF("doc.pdf", pages: 5)
        let folder = try await service.run(.split(ranges: "1-3, 5"), on: [source])[0]
        XCTAssertEqual(try TestPDF.texts(folder.appendingPathComponent("doc 1.pdf")), ["Page 1", "Page 2", "Page 3"])
        XCTAssertEqual(try TestPDF.texts(folder.appendingPathComponent("doc 2.pdf")), ["Page 5"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    func testASecondSplitGetsANumberedFolder() async throws {
        let source = try makePDF("doc.pdf", pages: 2)
        let first = try await service.run(.split(ranges: ""), on: [source])[0]
        let second = try await service.run(.split(ranges: ""), on: [source])[0]
        XCTAssertEqual(first.lastPathComponent, "doc Pages")
        XCTAssertEqual(second.lastPathComponent, "doc Pages 2")
    }

    func testSplitWithNoExistingPagesFailsAndLeavesNothing() async throws {
        let source = try makePDF("doc.pdf", pages: 2)
        do {
            _ = try await service.run(.split(ranges: "9"), on: [source])
            XCTFail("expected an error")
        } catch let error as ConversionError {
            guard case .failed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try names(), ["doc.pdf"])
    }

    func testPageRangeParsing() throws {
        XCTAssertEqual(try PDFTools.pageGroups("1-3, 5", pageCount: 5), [[0, 1, 2], [4]])
        XCTAssertEqual(try PDFTools.pageGroups("", pageCount: 3), [[0], [1], [2]])
        XCTAssertEqual(try PDFTools.pageGroups("  ", pageCount: 2), [[0], [1]])
        XCTAssertEqual(try PDFTools.pageGroups("2-9", pageCount: 3), [[1, 2]], "pages beyond the end are dropped")
        XCTAssertEqual(try PDFTools.pageGroups("5", pageCount: 3), [])
        XCTAssertEqual(try PDFTools.pageGroups("3-1", pageCount: 5), [], "a reversed range is empty, like the Windows app")
        XCTAssertEqual(try PDFTools.pageGroups("1,1", pageCount: 2), [[0], [0]], "the same page twice is two files")
        XCTAssertThrowsError(try PDFTools.pageGroups("a-b", pageCount: 3))
        XCTAssertThrowsError(try PDFTools.pageGroups("1-", pageCount: 3))
    }

    // MARK: organize

    func testOrganizeReordersDropsAndDuplicatesPages() async throws {
        let source = try makePDF("doc.pdf", pages: 3)
        let result = try await service.run(.organize(order: [2, 0, 0], rotations: [:]), on: [source])[0]
        XCTAssertEqual(result.lastPathComponent, "doc Organized.pdf")
        XCTAssertEqual(try TestPDF.texts(result), ["Page 3", "Page 1", "Page 1"])
    }

    func testOrganizeRotatesByOutputPosition() async throws {
        let source = try makePDF("doc.pdf", pages: 2)
        let result = try await service.run(.organize(order: [1, 0], rotations: [0: 90, 1: 270]), on: [source])[0]
        let document = try TestPDF.document(result)
        XCTAssertEqual(document.page(at: 0)?.rotation, 90)
        XCTAssertEqual(document.page(at: 1)?.rotation, 270)
        XCTAssertEqual(try TestPDF.texts(result), ["Page 2", "Page 1"])
    }

    func testOrganizeWithOnlyARotationKeepsEveryPage() async throws {
        let source = try makePDF("doc.pdf", pages: 2)
        let result = try await service.run(.organize(order: nil, rotations: [1: 180]), on: [source])[0]
        XCTAssertEqual(try TestPDF.document(result).page(at: 1)?.rotation, 180)
        XCTAssertEqual(try TestPDF.texts(result), ["Page 1", "Page 2"])
    }

    func testOrganizeRefusesAPageThatDoesNotExist() async throws {
        let source = try makePDF("doc.pdf", pages: 2)
        do {
            _ = try await service.run(.organize(order: [0, 7], rotations: [:]), on: [source])
            XCTFail("expected an error")
        } catch is ConversionError {}
        XCTAssertEqual(try names(), ["doc.pdf"])
    }

    // MARK: several files

    func testEachFileGetsItsOwnResult() async throws {
        let a = try makePDF("a.pdf", pages: 2, label: "A")
        let b = try makePDF("b.pdf", pages: 2, label: "B")
        let results = try await service.run(.organize(order: [1, 0], rotations: [:]), on: [a, b])
        XCTAssertEqual(results.map(\.lastPathComponent), ["a Organized.pdf", "b Organized.pdf"])
    }

    func testTheJobRunnerPathMakesTheSameResult() async throws {
        let a = try makePDF("a.pdf", pages: 1, label: "A")
        let b = try makePDF("b.pdf", pages: 1, label: "B")
        let ids = await service.enqueue(.merge, on: [a, b])
        XCTAssertEqual(ids.count, 1, "merging is one job for the whole selection")
        guard case let .finished(url) = await service.runner.finalState(of: ids[0]) else { return XCTFail("did not finish") }
        XCTAssertEqual(try TestPDF.texts(url), ["A 1", "B 1"])
        try assertNoTemporaryFiles()
    }

    // MARK: what the wheel may offer

    func testToolsForOnePDFAndForSeveral() {
        let one = service.availableTools(for: [file("a.pdf")])
        XCTAssertEqual(Set(one), ["splitPDF", "organizePDF", "unlockPDF", "watermarkPDF", "numberPDF"])
        let several = service.availableTools(for: [file("a.pdf"), file("b.pdf")])
        XCTAssertEqual(Set(several), ["mergePDF", "splitPDF", "unlockPDF", "watermarkPDF", "numberPDF"])
        XCTAssertFalse(several.contains("organizePDF"), "reordering pages of one document is a single-file tool")
        XCTAssertEqual(service.availableTools(for: [file("a.pdf"), file("b.png")]), [])
        XCTAssertEqual(service.availableTools(for: []), [])
    }

    func testEveryImplementedToolIsInTheCatalog() {
        for id in ToolService.implemented {
            XCTAssertNotNil(Catalog.bundled.tools[id], id)
        }
    }
}
