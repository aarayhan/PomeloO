import AppKit
import XCTest
@testable import PomeloOCore

final class ShortcutFilesTests: XCTestCase {
    private let finderFile = URL(fileURLWithPath: "/tmp/from-finder.png")
    private let copiedFile = URL(fileURLWithPath: "/tmp/copied.png")

    /// A Finder that answers as told and remembers how it was asked.
    private final class FakeFinder: FinderSelectionProviding, @unchecked Sendable {
        var isFrontmost = true
        var permissionNow: FinderPermission = .granted
        var answer: FinderSelectionOutcome = .files([])
        private(set) var asked: [(askUser: Bool, timeout: TimeInterval)] = []

        func permission() -> FinderPermission { permissionNow }
        func selection(askUser: Bool, timeout: TimeInterval) async -> FinderSelectionOutcome {
            asked.append((askUser, timeout))
            return answer
        }
    }

    private func resolve(_ finder: FakeFinder, useFinder: Bool = true, agrees: Bool = true) async -> ShortcutFilesResult {
        await ShortcutFiles.resolve(finder: finder, useFinder: useFinder, explain: { agrees }, clipboard: { [copiedFile] in [copiedFile] })
    }

    func testTheFinderSelectionWinsWhenFinderIsInFrontAndMayBeAsked() async {
        let finder = FakeFinder()
        finder.answer = .files([finderFile])
        let result = await resolve(finder)
        XCTAssertEqual(result, ShortcutFilesResult(files: [finderFile], source: .finderSelection, finderRefused: false))
        XCTAssertEqual(finder.asked.count, 1)
        XCTAssertFalse(finder.asked[0].askUser, "permission is there: no dialog")
        XCTAssertEqual(finder.asked[0].timeout, ShortcutFiles.quickTimeout)
    }

    func testFinderIsNotAskedWhenItIsNotInFront() async {
        let finder = FakeFinder()
        finder.isFrontmost = false
        finder.answer = .files([finderFile])
        let result = await resolve(finder)
        XCTAssertEqual(result.files, [copiedFile], "its selection could be stale")
        XCTAssertEqual(result.source, .clipboard)
        XCTAssertEqual(finder.asked.count, 0)
    }

    func testAnEmptySelectionFallsBackToWhatWasCopied() async {
        let finder = FakeFinder()
        finder.answer = .empty
        let result = await resolve(finder)
        XCTAssertEqual(result.files, [copiedFile])
        XCTAssertEqual(result.source, .clipboard)
        XCTAssertFalse(result.finderRefused)
    }

    func testARefusedPermissionFallsBackWithoutAskingAgain() async {
        let finder = FakeFinder()
        finder.permissionNow = .denied
        let result = await resolve(finder)
        XCTAssertEqual(result.files, [copiedFile])
        XCTAssertTrue(result.finderRefused, "the caller may mention where to allow it")
        XCTAssertEqual(finder.asked.count, 0, "no Apple Event for a refused app")
    }

    func testARefusalDuringTheQueryFallsBackToo() async {
        let finder = FakeFinder()
        finder.answer = .notPermitted
        let result = await resolve(finder)
        XCTAssertEqual(result.files, [copiedFile])
        XCTAssertTrue(result.finderRefused)
    }

    func testTheFirstTimeTheUserIsToldBeforeMacOSAsks() async {
        let finder = FakeFinder()
        finder.permissionNow = .askFirst
        finder.answer = .files([finderFile])
        let result = await resolve(finder, agrees: true)
        XCTAssertEqual(result.source, .finderSelection)
        XCTAssertEqual(finder.asked.count, 1)
        XCTAssertTrue(finder.asked[0].askUser, "now the system dialog may appear")
        XCTAssertEqual(finder.asked[0].timeout, ShortcutFiles.dialogTimeout, "time to read and answer the dialog")
    }

    func testDecliningTheExplanationUsesTheCopiedFilesAndNeverAsksMacOS() async {
        let finder = FakeFinder()
        finder.permissionNow = .askFirst
        finder.answer = .files([finderFile])
        let result = await resolve(finder, agrees: false)
        XCTAssertEqual(result.files, [copiedFile])
        XCTAssertEqual(finder.asked.count, 0)
        XCTAssertFalse(result.finderRefused)
    }

    func testTheSettingCanTurnFinderOff() async {
        let finder = FakeFinder()
        finder.answer = .files([finderFile])
        let result = await resolve(finder, useFinder: false)
        XCTAssertEqual(result.source, .clipboard)
        XCTAssertEqual(finder.asked.count, 0)
    }

    func testASlowOrBrokenFinderFallsBack() async {
        let finder = FakeFinder()
        finder.answer = .unavailable("Finder did not answer in time.")
        let result = await resolve(finder)
        XCTAssertEqual(result.files, [copiedFile])
        XCTAssertFalse(result.finderRefused)
    }

    func testFinderNotRunningFallsBack() async {
        let finder = FakeFinder()
        finder.permissionNow = .notRunning
        let result = await resolve(finder)
        XCTAssertEqual(result.source, .clipboard)
        XCTAssertEqual(finder.asked.count, 0)
    }

    func testNothingAnywhereIsAnEmptyResult() async {
        let finder = FakeFinder()
        finder.answer = .empty
        let result = await ShortcutFiles.resolve(finder: finder, explain: { true }, clipboard: { [] })
        XCTAssertEqual(result.files, [])
    }
}

final class FinderAppleEventsTests: XCTestCase {
    func testTheEventAsksFinderForItsSelectionAsFileURLs() throws {
        let event = FinderAppleEvents.makeSelectionEvent()
        XCTAssertEqual(event.eventClass, fourCC("core"))
        XCTAssertEqual(event.eventID, fourCC("getd"))
        XCTAssertEqual(event.attributeDescriptor(forKeyword: fourCC("addr"))?.data.count ?? 0 > 0, true, "has a target")
        let target = try XCTUnwrap(event.attributeDescriptor(forKeyword: fourCC("addr")))
        XCTAssertEqual(target.descriptorType, fourCC("bund"), "addressed by bundle identifier")
        XCTAssertEqual(String(data: target.data, encoding: .utf8), "com.apple.finder")

        let object = try XCTUnwrap(event.paramDescriptor(forKeyword: fourCC("----")))
        XCTAssertEqual(object.descriptorType, fourCC("obj "), "an object specifier")
        XCTAssertEqual(object.forKeyword(fourCC("want"))?.typeCodeValue, fourCC("prop"))
        XCTAssertEqual(object.forKeyword(fourCC("seld"))?.typeCodeValue, fourCC("sele"), "the selection property")
        XCTAssertEqual(event.paramDescriptor(forKeyword: fourCC("rtyp"))?.typeCodeValue, fourCC("furl"))
    }

    func testAReplyWithSeveralFilesIsRead() {
        let reply = NSAppleEventDescriptor.record()
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/a.png")), at: 1)
        list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/b b.png")), at: 2)
        reply.setParam(list, forKeyword: fourCC("----"))
        XCTAssertEqual(FinderAppleEvents.parse(reply: reply),
                       .files([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b b.png")]))
    }

    func testAReplyWithOneFileInsteadOfAListIsRead() {
        let reply = NSAppleEventDescriptor.record()
        reply.setParam(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/only.png")), forKeyword: fourCC("----"))
        XCTAssertEqual(FinderAppleEvents.parse(reply: reply), .files([URL(fileURLWithPath: "/tmp/only.png")]))
    }

    func testAnEmptySelectionIsEmpty() {
        let reply = NSAppleEventDescriptor.record()
        reply.setParam(NSAppleEventDescriptor.list(), forKeyword: fourCC("----"))
        XCTAssertEqual(FinderAppleEvents.parse(reply: reply), .empty)
        XCTAssertEqual(FinderAppleEvents.parse(reply: NSAppleEventDescriptor.record()), .empty)
    }

    func testAnErrorInTheReplyIsNotAFileList() {
        let denied = NSAppleEventDescriptor.record()
        denied.setParam(NSAppleEventDescriptor(int32: -1743), forKeyword: fourCC("errn"))
        XCTAssertEqual(FinderAppleEvents.parse(reply: denied), .notPermitted)

        let slow = NSAppleEventDescriptor.record()
        slow.setParam(NSAppleEventDescriptor(int32: -1712), forKeyword: fourCC("errn"))
        guard case .unavailable = FinderAppleEvents.parse(reply: slow) else { return XCTFail("a timeout is not a refusal") }
    }

    func testPermissionStatusesAreMapped() {
        XCTAssertEqual(FinderAppleEvents.permission(forStatus: 0), .granted)
        XCTAssertEqual(FinderAppleEvents.permission(forStatus: -1744), .askFirst)
        XCTAssertEqual(FinderAppleEvents.permission(forStatus: -1743), .denied)
        XCTAssertEqual(FinderAppleEvents.permission(forStatus: -600), .notRunning)
    }

    func testAskingForThePermissionStateNeverShowsADialogOrBlocks() {
        // askUserIfNeeded is false: this returns at once with one of the four answers
        let state = FinderAppleEvents().permission()
        XCTAssertTrue([.granted, .denied, .askFirst, .notRunning].contains(state))
    }
}
