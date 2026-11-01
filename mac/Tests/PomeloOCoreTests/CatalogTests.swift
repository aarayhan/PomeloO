import XCTest
@testable import PomeloOCore

final class CatalogTests: XCTestCase {
    func testBundledCatalogHasTheSameSizeAsTheDocs() {
        let catalog = Catalog.bundled
        XCTAssertEqual(catalog.formats.count, 45)
        XCTAssertEqual(catalog.tools.count, 34)
        XCTAssertEqual(catalog.actions.count, 8)
    }

    /// Guards the symlink: if someone replaces it with a copy, the two catalogs can drift apart.
    func testEmbeddedCatalogIsExactlyDocsCatalogJSON() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()  // PomeloOCoreTests, Tests
            .deletingLastPathComponent().deletingLastPathComponent()  // mac, repository root
        let docs = try Data(contentsOf: repository.appendingPathComponent("docs/catalog.json"))
        XCTAssertEqual(Catalog.bundledData, docs)
    }

    func testTargetsComeFromTheCatalog() {
        let catalog = Catalog.bundled
        XCTAssertEqual(catalog.targets(forExtension: "png"), ["jpg", "webp", "heic", "tiff", "avif", "bmp", "pdf"])
        XCTAssertEqual(catalog.targets(forExtension: "rar"), ["zip", "tar", "gz"])
        XCTAssertEqual(catalog.targets(forExtension: "gif"), ["mp4", "mov", "mkv", "webm", "avi", "wmv"])
        XCTAssertEqual(catalog.targets(forExtension: "xyz"), [])
    }

    func testNoFormatConvertsToItself() {
        for (ext, format) in Catalog.bundled.formats {
            XCTAssertFalse(format.to.contains(ext), "\(ext) lists itself as a target")
        }
    }

    func testKinds() {
        let catalog = Catalog.bundled
        XCTAssertEqual(catalog.kind(ofExtension: "png"), .image)
        XCTAssertEqual(catalog.kind(ofExtension: "flac"), .audio)
        XCTAssertEqual(catalog.kind(ofExtension: "gif"), .video)
        XCTAssertEqual(catalog.kind(ofExtension: "zip"), .archive)
        XCTAssertNil(catalog.kind(ofExtension: "xyz"))
    }

    func testAliasesPointAtCatalogFormats() {
        for (alias, canonical) in FileName.aliases {
            XCTAssertNotNil(Catalog.bundled.formats[canonical], "\(alias) -> \(canonical) is not a catalog format")
            XCTAssertNil(Catalog.bundled.formats[alias], "\(alias) should not be a catalog format of its own")
        }
    }
}
