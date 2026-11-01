import XCTest
@testable import PomeloOCore

final class ToolFormsTests: XCTestCase {
    private func invocation(_ body: () throws -> ToolInvocation) -> ToolInvocation? { try? body() }
    private func message(_ body: () throws -> ToolInvocation) -> String? {
        do { _ = try body(); return nil } catch let error as ToolFormError { return error.message } catch { return "\(error)" }
    }

    // MARK: pictures

    func testCompressCustomAndPresets() throws {
        var form = CompressForm()
        form.percent = 40
        form.targetKB = 200
        XCTAssertEqual(try form.invocation(), .image(.compress(CompressOptions(percent: 40, targetKB: 200, resizePercent: 100))))
        form.quality = .smallest
        form.resizePercent = 80
        XCTAssertEqual(try form.invocation(), .image(.compress(CompressOptions(percent: 25, targetKB: 0, resizePercent: 80))),
                       "a preset ignores the custom size, like the Windows dialog")
        form.quality = .custom
        form.percent = 2
        XCTAssertNotNil(message { try form.invocation() })
        form.percent = 50
        form.resizePercent = 5
        XCTAssertNotNil(message { try form.invocation() })
    }

    func testMetadataRemoveAndEdit() throws {
        var form = MetadataForm()
        XCTAssertEqual(try form.invocation(), .image(.removeMetadata))
        form.mode = .edit
        XCTAssertEqual(message { try form.invocation() }, "Fill in at least one field, or choose Remove.")
        form.artist = "Ada"
        form.copyright = "  "
        XCTAssertEqual(try form.invocation(), .image(.editMetadata(fields: ["artist": "Ada"])), "blank fields are not written")
    }

    func testCropNeedsAnAspectOrBothSides() throws {
        var form = CropForm()
        XCTAssertNotNil(message { try form.invocation() })
        form.aspect = "16:9"
        XCTAssertEqual(try form.invocation(), .image(.crop(CropOptions(aspect: "16:9"))))
        form.width = 100
        XCTAssertEqual(message { try form.invocation() }, "Give both the width and the height, or neither.")
        form.height = 50
        XCTAssertEqual(try form.invocation(), .image(.crop(CropOptions(aspect: "16:9", width: 100, height: 50))))
        form.aspect = "7:3"
        XCTAssertNotNil(message { try form.invocation() })
    }

    func testRedactNeedsSomethingToCover() throws {
        var form = RedactForm()
        XCTAssertEqual(try form.invocation(), .image(.redact(RedactOptions(style: .pixelate, color: "#000000", auto: .both))))
        form.auto = .none
        XCTAssertNotNil(message { try form.invocation() }, "no regions can be drawn yet, so nothing would be covered")
    }

    func testAdjustNeedsAMovedSlider() throws {
        var form = AdjustForm()
        XCTAssertNotNil(message { try form.invocation() })
        form.options.exposure = 0.5
        XCTAssertEqual(try form.invocation(), .image(.adjust(form.options)))
    }

    // MARK: PDF

    func testPageListParsing() throws {
        XCTAssertEqual(try PageList.parse("3, 1, 2-4"), [2, 0, 1, 2, 3])
        XCTAssertEqual(try PageList.parse("4-2"), [3, 2, 1], "a reversed range reverses the pages")
        XCTAssertEqual(try PageList.parse(""), [])
        XCTAssertThrowsError(try PageList.parse("1, x"))
        XCTAssertThrowsError(try PageList.parse("0"))
        XCTAssertThrowsError(try PageList.parse("2-"))
    }

    func testRotationParsing() throws {
        XCTAssertEqual(try PageList.parseRotations("2:90, 4:180"), [1: 90, 3: 180])
        XCTAssertEqual(try PageList.parseRotations(""), [:])
        XCTAssertThrowsError(try PageList.parseRotations("2:45"))
        XCTAssertThrowsError(try PageList.parseRotations("0:90"))
        XCTAssertThrowsError(try PageList.parseRotations("2"))
    }

    func testSplitChecksTheSyntax() throws {
        var form = SplitForm()
        XCTAssertEqual(try form.invocation(), .pdf(.split(ranges: "")))
        form.ranges = "1-3, 5"
        XCTAssertEqual(try form.invocation(), .pdf(.split(ranges: "1-3, 5")))
        form.ranges = "1-x"
        XCTAssertNotNil(message { try form.invocation() })
    }

    func testOrganizeBuildsOrderAndRotations() throws {
        var form = OrganizeForm()
        XCTAssertNotNil(message { try form.invocation() })
        form.order = "2, 1"
        XCTAssertEqual(try form.invocation(), .pdf(.organize(order: [1, 0], rotations: [:])))
        form.order = ""
        form.rotations = "1:90"
        XCTAssertEqual(try form.invocation(), .pdf(.organize(order: nil, rotations: [0: 90])))
    }

    func testMergeOrderCanBeChanged() throws {
        let a = URL(fileURLWithPath: "/a.pdf"), b = URL(fileURLWithPath: "/b.pdf"), c = URL(fileURLWithPath: "/c.pdf")
        var form = MergeForm(files: [a, b, c])
        form.move(from: 2, by: -1)
        XCTAssertEqual(form.files, [a, c, b])
        form.move(from: 0, by: -1)
        XCTAssertEqual(form.files, [a, c, b], "the first cannot move up")
        form.move(from: 2, by: 1)
        XCTAssertEqual(form.files, [a, c, b], "the last cannot move down")
        XCTAssertEqual(try form.invocation(), .pdf(.merge))
        XCTAssertNotNil(message { try MergeForm(files: [a]).invocation() })
    }

    func testPasswordFormsAndTheStrengthNote() throws {
        var form = PasswordForm()
        XCTAssertEqual(message { try form.protectInvocation() }, "Type a password.")
        form.password = "secret"
        XCTAssertEqual(message { try form.protectInvocation() }, "The two passwords are not the same.")
        form.confirmation = "secret"
        XCTAssertEqual(try form.protectInvocation(), .pdf(.protect(password: "secret")))
        XCTAssertEqual(form.unlockInvocation(), .pdf(.unlock(password: "secret")))
        XCTAssertTrue(PasswordForm.strengthNote.hasPrefix("AES-128"))
        XCTAssertFalse(PasswordForm.strengthNote.contains("256"), "the Mac does not write AES-256")
    }

    func testWatermarkAndNumberValidation() throws {
        var watermark = WatermarkForm()
        XCTAssertEqual(try watermark.invocation(), .pdf(.watermark(WatermarkOptions())))
        watermark.options.text = " "
        XCTAssertNotNil(message { try watermark.invocation() })
        watermark.options.text = "X"
        watermark.options.angle = 30
        XCTAssertNotNil(message { try watermark.invocation() })

        var number = NumberForm()
        XCTAssertEqual(try number.invocation(), .pdf(.number(NumberingOptions())))
        number.options.position = "middle"
        XCTAssertNotNil(message { try number.invocation() })
        number.options.position = "top right"
        number.options.size = 3
        XCTAssertNotNil(message { try number.invocation() })
    }

    func testWhichToolsHaveADialog() {
        XCTAssertTrue(ToolForms.withDialog.contains("compress"))
        XCTAssertTrue(ToolForms.withDialog.contains("protectPDF"))
        XCTAssertFalse(ToolForms.withDialog.contains("readQR"))
        XCTAssertEqual(ToolForms.invocationWithoutDialog(toolID: "readQR"), .text(.readCodes))
        XCTAssertEqual(ToolForms.invocationWithoutDialog(toolID: "extractText"), .text(.recognizeText))
        XCTAssertNil(ToolForms.invocationWithoutDialog(toolID: "compress"))
        for id in ToolForms.withDialog { XCTAssertTrue(ToolService.implemented.contains(id), "\(id) has a dialog but no tool") }
        for id in ToolService.implemented { XCTAssertTrue(ToolForms.withDialog.contains(id) || ToolForms.invocationWithoutDialog(toolID: id) != nil, "\(id) is neither") }
    }
}
