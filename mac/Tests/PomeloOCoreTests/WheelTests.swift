import XCTest
@testable import PomeloOCore

final class WheelGeometryTests: XCTestCase {
    func testConstantsMatchTheWindowsWheel() {
        XCTAssertEqual(WheelGeometry.size, 330)
        XCTAssertEqual(WheelGeometry.inner, 65.78, accuracy: 1e-9)
        XCTAssertEqual(WheelGeometry.outer, 155.35, accuracy: 1e-9)
        XCTAssertEqual(WheelGeometry.gap, 5.2, accuracy: 1e-9)
    }

    func testTheFirstPetalIsAtTheTopAndWithThreeAtTheLeft() {
        XCTAssertEqual(WheelGeometry.angle(0, of: 4), Double.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(WheelGeometry.angle(1, of: 4), 0, accuracy: 1e-12, "clockwise: the second petal is on the right")
        XCTAssertEqual(WheelGeometry.angle(0, of: 3), Double.pi, accuracy: 1e-12)
    }

    func testHitTestAgreesWithThePythonWheel() {
        for row in wheelGoldenHits {
            XCTAssertEqual(WheelGeometry.petal(atX: row.x, y: row.y, count: row.count), row.petal,
                           "n=\(row.count) at (\(row.x), \(row.y))")
        }
    }

    func testTheHoleTheOutsideAndAnEmptyWheelHitNothing() {
        let c = WheelGeometry.size / 2
        XCTAssertNil(WheelGeometry.petal(atX: c, y: c, count: 6))
        XCTAssertNil(WheelGeometry.petal(atX: 0, y: 0, count: 6))
        XCTAssertNil(WheelGeometry.petal(atX: c, y: c - WheelGeometry.outer - 1, count: 6))
        XCTAssertNil(WheelGeometry.petal(atX: c, y: c - 100, count: 0))
    }

    func testEachPetalIsHitAtItsMiddle() {
        for n in 2...12 {
            for i in 0..<n {
                let middle = WheelGeometry.point(radius: (WheelGeometry.inner + WheelGeometry.outer) / 2,
                                                 angle: WheelGeometry.angle(i, of: n))
                XCTAssertEqual(WheelGeometry.petal(atX: middle.x, y: middle.y, count: n), i, "petal \(i) of \(n)")
            }
        }
    }

    func testPetalOutlinesStayBetweenTheTwoRadii() {
        for n in [2, 3, 5, 8, 12] {
            for i in 0..<n {
                let outline = WheelGeometry.petalOutline(i, of: n)
                XCTAssertGreaterThan(outline.count, 4)
                for point in outline {
                    let r = hypot(point.x - WheelGeometry.size / 2, point.y - WheelGeometry.size / 2)
                    XCTAssertGreaterThanOrEqual(r, WheelGeometry.inner - 0.01)
                    XCTAssertLessThanOrEqual(r, WheelGeometry.outer + 0.01)
                }
            }
        }
    }
}

final class WheelModelTests: XCTestCase {
    private let service = ConversionService(engines: [ImageEngine()])

    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    func testFormatsAreTheOnesThisMacCanWriteInCatalogOrder() {
        let model = WheelModel(urls: urls("photo.png"), service: service)
        XCTAssertEqual(model.items.map(\.id), service.availableTargets(forExtension: "png"))
        XCTAssertTrue(model.items.map(\.title).contains("JPG"))
        XCTAssertFalse(model.items.map(\.id).contains("png"))
    }

    func testSeveralFilesOfOneKindShareTheirFormats() {
        let model = WheelModel(urls: urls("a.png", "b.png"), service: service)
        XCTAssertEqual(model.items.map(\.id), service.availableTargets(forExtension: "png"))
        XCTAssertEqual(model.countText, "2 files")
    }

    func testImagesOfDifferentFormatsGetThePNGFormats() {
        XCTAssertEqual(service.selectionExtension(of: urls("a.jpg", "b.heic")), "png")
        let model = WheelModel(urls: urls("a.jpg", "b.bmp"), service: service)
        XCTAssertEqual(model.items.map(\.id), service.availableTargets(forExtension: "png"))
    }

    func testAMixedSelectionHasNoFormats() {
        XCTAssertNil(service.selectionExtension(of: urls("a.jpg", "b.mp3")))
        let model = WheelModel(urls: urls("a.jpg", "b.mp3"), service: service)
        XCTAssertEqual(model.items, [])
        XCTAssertEqual(model.hint, "No conversions for this selection")
    }

    func testFormatsAreTitledInCapitals() {
        XCTAssertEqual(WheelItem(target: "jpg").title, "JPG")
        XCTAssertEqual(WheelItem(target: "gz").title, "GZIP")
    }

    func testHoverFollowsThePointer() {
        var model = WheelModel(urls: urls("photo.png"), service: service)
        let n = model.items.count
        XCTAssertGreaterThan(n, 1)
        let middle = WheelGeometry.point(radius: (WheelGeometry.inner + WheelGeometry.outer) / 2,
                                         angle: WheelGeometry.angle(1, of: n))
        XCTAssertTrue(model.pointerMoved(x: middle.x, y: middle.y), "entering a petal changes the hover")
        XCTAssertEqual(model.hover, 1)
        XCTAssertFalse(model.pointerMoved(x: middle.x + 0.5, y: middle.y), "moving inside the same petal does not")
        XCTAssertEqual(model.chosen, model.items[1])
        XCTAssertEqual(model.hint, "Let go to make a \(model.items[1].title)")

        XCTAssertTrue(model.pointerMoved(x: WheelGeometry.size / 2, y: WheelGeometry.size / 2), "the hole is no petal")
        XCTAssertNil(model.chosen)
        XCTAssertEqual(model.hint, "Drop on a format")
    }

    func testANewSelectionClearsTheHover() {
        var model = WheelModel(urls: urls("photo.png"), service: service)
        let middle = WheelGeometry.point(radius: 110, angle: WheelGeometry.angle(0, of: model.items.count))
        model.pointerMoved(x: middle.x, y: middle.y)
        XCTAssertNotNil(model.hover)
        model.setSelection(urls("clip.wav"), service: service)
        XCTAssertNil(model.hover)
    }

    func testAnEmptyModelAsksForADrop() {
        let model = WheelModel()
        XCTAssertEqual(model.countText, "Drop here")
        XCTAssertEqual(model.hint, "Drop on a format")
        XCTAssertNil(model.chosen)
    }
}


final class WheelModeTests: XCTestCase {
    private let conversions = ConversionService(engines: [ImageEngine()])
    private let tools = ToolService()

    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    func testTheToolsWheelHoldsTheToolsOfTheSelection() {
        let model = WheelModel(urls: urls("photo.jpg"), service: conversions, tools: tools, mode: .tools)
        XCTAssertEqual(model.items.map(\.id), tools.availableTools(for: urls("photo.jpg")))
        XCTAssertEqual(model.title, "Tools")
        XCTAssertTrue(model.items.map(\.title).contains("COMPRESS"), "the catalog's short title")
        XCTAssertTrue(model.items.map(\.title).contains("CROP"))
    }

    func testPDFsGetTheirOwnTools() {
        let model = WheelModel(urls: urls("a.pdf"), service: conversions, tools: tools, mode: .tools)
        XCTAssertEqual(Set(model.items.map(\.id)), ["splitPDF", "organizePDF", "protectPDF", "unlockPDF", "watermarkPDF", "numberPDF"])
        let several = WheelModel(urls: urls("a.pdf", "b.pdf"), service: conversions, tools: tools, mode: .tools)
        XCTAssertTrue(several.items.map(\.id).contains("mergePDF"))
    }

    func testSwitchingKeepsTheFilesAndChangesThePetals() {
        var model = WheelModel(urls: urls("photo.png"), service: conversions, tools: tools)
        let formats = model.items
        XCTAssertTrue(model.setMode(.tools))
        XCTAssertEqual(model.urls, urls("photo.png"))
        XCTAssertNotEqual(model.items, formats)
        XCTAssertEqual(model.title, "Tools")
        XCTAssertFalse(model.setMode(.tools), "already there")
        XCTAssertTrue(model.setMode(.convert))
        XCTAssertEqual(model.items, formats)
    }

    func testTheActionsWheelDoesNotExistYet() {
        var model = WheelModel(urls: urls("photo.png"), service: conversions, tools: tools)
        XCTAssertFalse(model.setMode(.actions))
        XCTAssertEqual(model.mode, .convert)
        XCTAssertEqual(WheelModel.availableModes, [.convert, .tools])
    }

    func testTheModeSurvivesANewSelection() {
        var model = WheelModel(urls: [], service: conversions, tools: tools)
        model.setMode(.tools)
        model.setSelection(urls("photo.png"), service: conversions)
        XCTAssertEqual(model.mode, .tools, "a drag that enters the wheel after the key tap keeps the wheel the key chose")
        XCTAssertFalse(model.items.isEmpty)
    }

    func testHintsNameTheTool() {
        var model = WheelModel(urls: urls("photo.png"), service: conversions, tools: tools, mode: .tools)
        let middle = WheelGeometry.point(radius: 110, angle: WheelGeometry.angle(0, of: model.items.count))
        model.pointerMoved(x: middle.x, y: middle.y)
        XCTAssertEqual(model.hint, "Let go to use \(tools.catalog.tools[model.chosen!.id]!.name)")
        model.pointerLeft()
        XCTAssertEqual(model.hint, "Drop on a tool")
    }

    func testNoToolsForAMixedSelection() {
        let model = WheelModel(urls: urls("a.png", "b.pdf"), service: conversions, tools: tools, mode: .tools)
        XCTAssertEqual(model.items, [])
        XCTAssertEqual(model.hint, "No tools for this selection")
    }

    func testWithoutAToolServiceTheToolsWheelIsEmpty() {
        let model = WheelModel(urls: urls("photo.png"), service: conversions, mode: .tools)
        XCTAssertEqual(model.items, [])
    }

    func testKeyboardStartsOnTheFirstToolToo() {
        var model = WheelModel(urls: urls("photo.png"), service: conversions, tools: tools, mode: .tools)
        model.setKeyboard(true)
        XCTAssertEqual(model.hover, 0)
        model.setMode(.convert)
        XCTAssertEqual(model.hover, 0, "switching wheels with the keyboard on starts at the first petal")
    }
}
