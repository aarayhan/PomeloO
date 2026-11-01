import XCTest
@testable import PomeloOCore

final class DragGestureTests: XCTestCase {
    private var detector = DragGestureDetector()
    private var pasteboard = 10  // the drag pasteboard's change count

    /// One sample of the input state; `files` says what a changed drag pasteboard carries.
    private func sample(down: Bool, _ modifiers: ModifierKeys = [], files: Bool = true) -> [DragGestureDetector.Event] {
        detector.update(buttonDown: down, modifiers: modifiers, pasteboardChangeCount: pasteboard,
                        pasteboardHasFiles: { files })
    }

    /// The pasteboard changes a moment after the press, as it does when a drag really starts.
    private func startDrag(files: Bool = true, modifiers: ModifierKeys = []) -> [DragGestureDetector.Event] {
        _ = sample(down: false)
        _ = sample(down: true, modifiers)
        pasteboard += 1
        return sample(down: true, modifiers, files: files)
    }

    func testAFileDragThenAShiftTap() {
        XCTAssertEqual(startDrag(), [.dragBegan])
        XCTAssertEqual(sample(down: true, .shift), [.keyTapped(.shift)])
        XCTAssertEqual(sample(down: true, .shift), [], "holding it is not another tap")
        XCTAssertEqual(sample(down: true, []), [])
        XCTAssertEqual(sample(down: false), [.dragEnded])
    }

    func testEachOfTheThreeKeysIsATap() {
        _ = startDrag()
        XCTAssertEqual(sample(down: true, .control), [.keyTapped(.control)])
        XCTAssertEqual(sample(down: true, []), [])
        XCTAssertEqual(sample(down: true, .option), [.keyTapped(.option)])
    }

    func testTapsOnTheSameKeyCountAgainAfterItWasReleased() {
        _ = startDrag()
        XCTAssertEqual(sample(down: true, .shift), [.keyTapped(.shift)])
        _ = sample(down: true, [])
        XCTAssertEqual(sample(down: true, .shift), [.keyTapped(.shift)])
    }

    func testAPlainClickDoesNothing() {
        _ = sample(down: false)
        XCTAssertEqual(sample(down: true), [])
        XCTAssertEqual(sample(down: true, .shift), [], "no drag, so a key is not a gesture")
        XCTAssertEqual(sample(down: false), [])
    }

    func testDraggingSomethingThatIsNotAFileDoesNothing() {
        XCTAssertEqual(startDrag(files: false), [])
        XCTAssertEqual(sample(down: true, .shift), [])
        XCTAssertEqual(sample(down: false), [])
    }

    func testAKeyAlreadyHeldWhenTheButtonWentDownIsNotATap() {
        XCTAssertEqual(startDrag(modifiers: .shift), [.dragBegan])
        XCTAssertEqual(sample(down: true, .shift), [], "Shift-click then drag is not a gesture")
        XCTAssertEqual(sample(down: true, []), [])
        XCTAssertEqual(sample(down: true, .shift), [.keyTapped(.shift)], "a new press is")
    }

    func testTwoKeysTogetherAreNoTap() {
        _ = startDrag()
        XCTAssertEqual(sample(down: true, [.shift, .option]), [])
        XCTAssertEqual(sample(down: true, .option), [], "Option is still held from before, no new key")
    }

    func testAnotherKeyWhileOneIsHeldIsNoTap() {
        _ = startDrag()
        XCTAssertEqual(sample(down: true, .shift), [.keyTapped(.shift)])
        XCTAssertEqual(sample(down: true, [.shift, .control]), [], "two held: not a tap of exactly one")
    }

    func testCommandAloneIsNotAGestureKey() {
        _ = startDrag()
        XCTAssertEqual(sample(down: true, .command), [])
    }

    func testWhatChangedWhileNoButtonWasDownDoesNotCount() {
        _ = sample(down: false)
        pasteboard += 5  // a drag that ended unseen, or another app writing to the pasteboard
        _ = sample(down: false)
        XCTAssertEqual(sample(down: true), [], "the press starts from the current count")
        XCTAssertEqual(sample(down: true, .shift), [])
    }

    func testTheFirstSampleCanBeAPress() {
        XCTAssertEqual(sample(down: true), [])
        pasteboard += 1
        XCTAssertEqual(sample(down: true), [.dragBegan])
    }

    func testAKeyTappedBeforeTheDragWasSeenIsCountedOnceItIs() {
        _ = sample(down: false)
        XCTAssertEqual(sample(down: true), [])
        pasteboard += 1
        XCTAssertEqual(sample(down: true, .shift), [.dragBegan, .keyTapped(.shift)], "same sample: the drag and the tap")
    }

    func testTwoDragsInARow() {
        XCTAssertEqual(startDrag(), [.dragBegan])
        XCTAssertEqual(sample(down: false), [.dragEnded])
        XCTAssertEqual(startDrag(), [.dragBegan])
        XCTAssertEqual(sample(down: true, .control), [.keyTapped(.control)])
        XCTAssertEqual(sample(down: false), [.dragEnded])
    }

    func testTheDefaultKeysAreTheWindowsOnes() {
        XCTAssertEqual(GestureKeys.defaults[.shift], .convert)
        XCTAssertEqual(GestureKeys.defaults[.control], .tools)
        XCTAssertEqual(GestureKeys.defaults[.option], .actions)
    }
}

final class WheelKeyboardTests: XCTestCase {
    private let service = ConversionService(engines: [ImageEngine()])
    private let photo = [URL(fileURLWithPath: "/tmp/photo.png")]

    func testTheKeyboardStartsOnTheFirstPetal() {
        var model = WheelModel(urls: photo, service: service)
        model.setKeyboard(true)
        XCTAssertEqual(model.hover, 0)
        XCTAssertEqual(model.hint, "Press Enter to make a \(model.items[0].title)")
    }

    func testArrowsWrapRound() {
        var model = WheelModel(urls: photo, service: service)
        model.setKeyboard(true)
        let n = model.items.count
        model.moveHover(by: -1)
        XCTAssertEqual(model.hover, n - 1)
        model.moveHover(by: 1)
        XCTAssertEqual(model.hover, 0)
        model.moveHover(by: 1)
        XCTAssertEqual(model.hover, 1)
        model.hoverLast()
        XCTAssertEqual(model.hover, n - 1)
        model.hoverFirst()
        XCTAssertEqual(model.hover, 0)
    }

    func testTheHotPetalSurvivesThePointerLeaving() {
        var model = WheelModel(urls: photo, service: service)
        model.setKeyboard(true)
        model.pointerLeft()
        XCTAssertEqual(model.hover, 0, "a keyboard wheel keeps its choice")
        model.setKeyboard(false)
        XCTAssertNil(model.hover)
    }

    func testChoosingTheHotPetal() {
        var model = WheelModel(urls: photo, service: service)
        model.setKeyboard(true)
        model.moveHover(by: 2)
        XCTAssertEqual(model.chosen, model.items[2])
    }

    func testAnEmptyKeyboardWheelHasNothingToMove() {
        var model = WheelModel(urls: [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.mp3")], service: service)
        model.setKeyboard(true)
        model.moveHover(by: 1)
        XCTAssertNil(model.hover)
        XCTAssertNil(model.chosen)
    }

    func testANewSelectionKeepsTheKeyboardOnTheFirstPetal() {
        var model = WheelModel()
        model.setKeyboard(true)
        model.setSelection(photo, service: service)
        XCTAssertEqual(model.hover, 0)
    }
}
