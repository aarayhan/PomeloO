import XCTest
@testable import PomeloOCore

final class NamingTests: TempDirectoryTestCase {
    func testExtensionIsLowercaseAndCanonical() {
        XCTAssertEqual(FileName.ext(ofName: "Photo.JPEG"), "jpg")
        XCTAssertEqual(FileName.ext(ofName: "a.tif"), "tiff")
        XCTAssertEqual(FileName.ext(ofName: "clip.M4V"), "mp4")
        XCTAssertEqual(FileName.ext(ofName: "page.htm"), "html")
        XCTAssertEqual(FileName.ext(ofName: "sound.oga"), "ogg")
    }

    func testTarGzAndTgzAreGzip() {
        XCTAssertEqual(FileName.ext(ofName: "backup.tar.gz"), "gz")
        XCTAssertEqual(FileName.ext(ofName: "backup.TAR.GZ"), "gz")
        XCTAssertEqual(FileName.ext(ofName: "backup.tgz"), "gz")
    }

    func testNamesWithoutAnExtension() {
        XCTAssertEqual(FileName.ext(ofName: "README"), "")
        XCTAssertEqual(FileName.ext(ofName: ".bashrc"), "")
        XCTAssertEqual(FileName.ext(ofName: "trailing."), "")
        XCTAssertEqual(FileName.ext(ofName: ".hidden.txt"), "txt")
    }

    func testStemRemovesOnlyTheLastExtension() {
        XCTAssertEqual(FileName.stem(ofName: "photo.final.jpg"), "photo.final")
        XCTAssertEqual(FileName.stem(ofName: "photo.jpg"), "photo")
        XCTAssertEqual(FileName.stem(ofName: "archive.tar.gz"), "archive")
        XCTAssertEqual(FileName.stem(ofName: "archive.TGZ"), "archive")
        XCTAssertEqual(FileName.stem(ofName: "README"), "README")
        XCTAssertEqual(FileName.stem(ofName: "trailing."), "trailing.")
    }

    func testProposedNameIsBesideTheSource() {
        let source = URL(fileURLWithPath: "/Users/me/Pictures/photo.HEIC")
        XCTAssertEqual(OutputNaming.proposed(for: source, ext: "jpg").path, "/Users/me/Pictures/photo.jpg")
        XCTAssertEqual(OutputNaming.proposed(for: source, ext: "jpg", label: "Compressed").path,
                       "/Users/me/Pictures/photo Compressed.jpg")
        XCTAssertEqual(OutputNaming.proposed(for: source, ext: "gz").lastPathComponent, "photo.tar.gz")
        XCTAssertEqual(OutputNaming.proposed(for: source, ext: "folder").lastPathComponent, "photo")
    }

    func testNumberedNames() {
        XCTAssertEqual(OutputNaming.numbered(URL(fileURLWithPath: "/a/photo.webp"), 2).lastPathComponent, "photo 2.webp")
        XCTAssertEqual(OutputNaming.numbered(URL(fileURLWithPath: "/a/photo.webp"), 10).lastPathComponent, "photo 10.webp")
        XCTAssertEqual(OutputNaming.numbered(URL(fileURLWithPath: "/a/x.tar.gz"), 3).lastPathComponent, "x 3.tar.gz")
        XCTAssertEqual(OutputNaming.numbered(URL(fileURLWithPath: "/a/folder"), 2).lastPathComponent, "folder 2")
    }

    func testReserverSkipsExistingFilesAndClaimedNames() async throws {
        try Data().write(to: file("photo.jpg"))
        let reserver = NameReserver()
        let first = await reserver.reserve(file("photo.jpg"))
        let second = await reserver.reserve(file("photo.jpg"))
        XCTAssertEqual(first.lastPathComponent, "photo 2.jpg")  // photo.jpg exists
        XCTAssertEqual(second.lastPathComponent, "photo 3.jpg")  // photo 2.jpg is claimed
        await reserver.release(first)
        let third = await reserver.reserve(file("photo.jpg"))
        XCTAssertEqual(third.lastPathComponent, "photo 2.jpg")  // released again
    }

    func testTemporaryNameIsHiddenAndKeepsTheExtensionLast() {
        let temporary = TemporaryOutput(directory: directory, ext: "mp4")
        XCTAssertTrue(temporary.url.lastPathComponent.hasPrefix(".pomeloo-"))
        XCTAssertEqual(temporary.url.pathExtension, "mp4")
        XCTAssertTrue(TemporaryOutput.isTemporaryName(temporary.url.lastPathComponent))
    }

    func testCommitMovesTheFileToItsFinalName() throws {
        let temporary = TemporaryOutput(directory: directory, ext: "png")
        try Data("new".utf8).write(to: temporary.url)
        let used = try temporary.commit(to: file("photo.png"))
        XCTAssertEqual(used, file("photo.png"))
        XCTAssertEqual(try String(contentsOf: file("photo.png"), encoding: .utf8), "new")
        XCTAssertEqual(try names(), ["photo.png"])
    }

    func testCommitNeverReplacesAnExistingFile() throws {
        try Data("original".utf8).write(to: file("photo.png"))
        let temporary = TemporaryOutput(directory: directory, ext: "png")
        try Data("new".utf8).write(to: temporary.url)
        let used = try temporary.commit(to: file("photo.png"))
        XCTAssertEqual(used.lastPathComponent, "photo 2.png")
        XCTAssertEqual(try String(contentsOf: file("photo.png"), encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: file("photo 2.png"), encoding: .utf8), "new")
        XCTAssertEqual(try names(), ["photo 2.png", "photo.png"])
    }

    func testDiscardRemovesTheTemporaryFile() throws {
        let temporary = TemporaryOutput(directory: directory, ext: "png")
        try Data("x".utf8).write(to: temporary.url)
        temporary.discard()
        XCTAssertEqual(try names(), [])
    }
}
