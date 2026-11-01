import XCTest
@testable import PomeloOCore

/// The tool table repeats three columns of `TOOLS` in pomeloo/catalog.py. This reads that file, so the two
/// cannot drift apart without a test failing.
final class ToolSpecTests: XCTestCase {
    private func catalogPython() throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appendingPathComponent("pomeloo/catalog.py")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("pomeloo/catalog.py is not next to this package") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEveryToolSpecMatchesTheWindowsTable() throws {
        let source = try catalogPython()
        // "mergePDF": ("MERGE PDF", "Merge PDFs", "Merged", "pdf", True),
        let pattern = try NSRegularExpression(pattern: #""(\w+)": \("[^"]*", "[^"]*", (None|"[^"]*"), (None|"[^"]*"), (True|False)\)"#)
        var found: [String: (label: String?, ext: String?, combine: Bool)] = [:]
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            func text(_ i: Int) -> String { String(source[Range(match.range(at: i), in: source)!]) }
            func value(_ i: Int) -> String? { text(i) == "None" ? nil : String(text(i).dropFirst().dropLast()) }
            found[text(1)] = (value(2), value(3), text(4) == "True")
        }
        XCTAssertGreaterThan(found.count, 30, "the TOOLS table was not found")
        for spec in ToolSpecs.pdf {
            let windows = try XCTUnwrap(found[spec.id], "\(spec.id) is not in pomeloo/catalog.py")
            XCTAssertEqual(spec.label, windows.label, "\(spec.id) label")
            XCTAssertEqual(spec.outputExtension, windows.ext, "\(spec.id) output extension")
            XCTAssertEqual(spec.combinesSelection, windows.combine, "\(spec.id) combine")
        }
    }

    func testTheMultiFileSetMatchesTheWindowsOne() throws {
        let source = try catalogPython()
        let start = try XCTUnwrap(source.range(of: "MULTI_OK = {"))
        let end = try XCTUnwrap(source.range(of: "}", range: start.upperBound..<source.endIndex))
        let ids = source[start.upperBound..<end.lowerBound].split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        XCTAssertEqual(Set(ids.map(String.init)), ToolSpecs.multipleFilesOK)
    }

    func testToolNamesInTheTableExistInTheCatalogJSON() {
        for spec in ToolSpecs.pdf { XCTAssertNotNil(Catalog.bundled.tools[spec.id], spec.id) }
    }

    func testToolsForASelectionFollowTheCatalog() {
        let catalog = Catalog.bundled
        XCTAssertEqual(catalog.tools(forExtension: "pdf", count: 1), catalog.formats["pdf"]!.tools)
        XCTAssertTrue(catalog.tools(forExtension: "pdf", count: 2).contains("mergePDF"))
        XCTAssertFalse(catalog.tools(forExtension: "pdf", count: 2).contains("organizePDF"))
        XCTAssertEqual(catalog.tools(forExtension: "pdf", count: 0), [])
        XCTAssertEqual(catalog.tools(forExtension: "xyz", count: 1), [])
    }
}
