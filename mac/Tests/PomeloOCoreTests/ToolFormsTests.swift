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

    // MARK: audio and video

    func testMediaCompress() throws {
        var form = MediaCompressForm()
        XCTAssertEqual(try form.invocation(), .media(.compress(MediaCompressOptions(percent: 50))))
        form.quality = .smallest
        XCTAssertEqual(try form.invocation(), .media(.compress(MediaCompressOptions(percent: 25))))
        form.quality = .custom
        form.percent = 99
        XCTAssertNotNil(message { try form.invocation() })
        form.percent = 40
        form.resizePercent = 5
        XCTAssertNotNil(message { try form.invocation() })
    }

    func testMediaMetadata() throws {
        var form = MediaMetadataForm()
        XCTAssertEqual(try form.invocation(), .media(.metadata(fields: nil)))
        form.mode = .edit
        XCTAssertNotNil(message { try form.invocation() }, "nothing to set")
        form.title = "Hello"
        form.album = "  "
        XCTAssertEqual(try form.invocation(), .media(.metadata(fields: ["title": "Hello"])))
    }

    func testTrimTimes() throws {
        var form = TrimForm(isVideo: true)
        XCTAssertNotNil(message { try form.invocation() }, "from 0 to the end cuts nothing")
        form.start = "1:05"
        XCTAssertEqual(try form.invocation(), .media(.trimVideo(TrimOptions(start: 65, end: 0))))
        form.end = "1:20.5"
        XCTAssertEqual(try form.invocation(), .media(.trimVideo(TrimOptions(start: 65, end: 80.5))))
        form.end = "30"
        XCTAssertEqual(message { try form.invocation() }, "The end must come after the start.")
        form.end = "soon"
        XCTAssertTrue(message { try form.invocation() }?.contains("not a time") == true)
        var audio = TrimForm(isVideo: false)
        audio.trimSilence = true
        XCTAssertEqual(try audio.invocation(), .media(.trimAudio(TrimOptions(start: 0, end: 0, trimSilence: true))), "cutting silence alone is enough")
        var video = TrimForm(isVideo: true)
        video.start = "1"
        video.trimSilence = true
        XCTAssertEqual(try video.invocation(), .media(.trimVideo(TrimOptions(start: 1, end: 0, trimSilence: false))), "silence is an audio setting")
    }

    func testBleepRanges() throws {
        var form = BleepForm()
        XCTAssertNotNil(message { try form.invocation() })
        form.ranges = "1:02-1:05, 2:00-2:03.5"
        XCTAssertEqual(try form.invocation(), .media(.bleep(BleepOptions(ranges: [TimeRange(start: 62, end: 65), TimeRange(start: 120, end: 123.5)]))))
        form.ranges = "5-3"
        XCTAssertTrue(message { try form.invocation() }?.contains("end must come after") == true)
        form.ranges = "12"
        XCTAssertTrue(message { try form.invocation() }?.contains("should look like") == true)
        form.ranges = "1-2"
        form.frequency = 10
        XCTAssertNotNil(message { try form.invocation() })
    }

    func testChannels() throws {
        var form = ChannelsForm()
        XCTAssertEqual(try form.invocation(), .media(.channels(ChannelOptions(channels: 1))))
        form.right = 250
        XCTAssertNotNil(message { try form.invocation() })
        form.right = 50
        form.channels = 3
        XCTAssertNotNil(message { try form.invocation() })
    }

    func testVideoCropAndSpeed() throws {
        var crop = VideoCropForm()
        XCTAssertNotNil(message { try crop.invocation() })
        crop.aspect = "1:1"
        XCTAssertEqual(try crop.invocation(), .media(.cropVideo(VideoCropOptions(aspect: "1:1"))))
        crop.width = 100
        XCTAssertNotNil(message { try crop.invocation() }, "one of width and height")

        var speed = SpeedForm()
        XCTAssertEqual(try speed.invocation(), .media(.speed(factor: 2)))
        speed.factor = 1
        XCTAssertNotNil(message { try speed.invocation() })
        speed.factor = 9
        XCTAssertNotNil(message { try speed.invocation() })
    }

    func testSnapshotsAndSplit() throws {
        var shots = SnapshotForm()
        XCTAssertEqual(try shots.invocation(), .media(.snapshots(SnapshotOptions(count: 1))))
        shots.mode = .moments
        XCTAssertNotNil(message { try shots.invocation() })
        shots.moments = "1.5, 1:05"
        XCTAssertEqual(try shots.invocation(), .media(.snapshots(SnapshotOptions(times: [1.5, 65]))))

        var split = SplitVideoForm()
        XCTAssertEqual(try split.invocation(), .media(.splitVideo(SplitOptions(parts: 2))))
        split.mode = .length
        split.seconds = "0.2"
        XCTAssertNotNil(message { try split.invocation() })
        split.seconds = "1:30"
        split.precise = false
        XCTAssertEqual(try split.invocation(), .media(.splitVideo(SplitOptions(seconds: 90, precise: false))))
        split.mode = .points
        split.points = ""
        XCTAssertNotNil(message { try split.invocation() })
        split.points = "30, 75"
        XCTAssertEqual(try split.invocation(), .media(.splitVideo(SplitOptions(points: [30, 75], precise: false))))
    }

    func testVideoRedactAreas() throws {
        var form = VideoRedactForm()
        guard case let .media(.redactVideo(options)) = try form.invocation() else { return XCTFail() }
        XCTAssertEqual(options.regions.count, 1)
        XCTAssertEqual(options.regions[0].rect, CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2))
        XCTAssertNil(options.regions[0].time, "no times: the whole video")
        form.areas[0].width = 95
        XCTAssertTrue(message { try form.invocation() }?.contains("must fit inside") == true)
        form.areas[0].width = 30
        form.areas[0].from = "2"
        guard case let .media(.redactVideo(timed)) = try form.invocation() else { return XCTFail() }
        XCTAssertEqual(timed.regions[0].time?.start, 2)
        XCTAssertGreaterThan(timed.regions[0].time?.end ?? 0, 3600, "no end: to the end of the video")
        form.areas[0].until = "1"
        XCTAssertTrue(message { try form.invocation() }?.contains("end must come after") == true)
        form.areas = []
        XCTAssertNotNil(message { try form.invocation() })
    }

    func testNormalizeVisualizeAndJoin() throws {
        var normalize = NormalizeForm()
        XCTAssertEqual(try normalize.invocation(), .media(.normalize(NormalizeOptions())))
        normalize.options.loudness = 3
        XCTAssertNotNil(message { try normalize.invocation() })

        var visual = VisualizeForm()
        XCTAssertEqual(try visual.invocation(), .media(.visualize(VisualizeOptions())))
        visual.options.style = .image
        XCTAssertNotNil(message { try visual.invocation() }, "a picture is needed")

        var join = JoinForm(files: [URL(fileURLWithPath: "/a.mp4"), URL(fileURLWithPath: "/b.mp4"), URL(fileURLWithPath: "/c.mp4")])
        join.move(from: 0, by: 2)
        XCTAssertEqual(join.files.map(\.lastPathComponent), ["c.mp4", "b.mp4", "a.mp4"])
        join.move(from: 0, by: -1)
        XCTAssertEqual(join.files.count, 3)
        XCTAssertEqual(try join.invocation(), .media(.join))
        XCTAssertNotNil(message { try JoinForm(files: [URL(fileURLWithPath: "/a.mp4")]).invocation() })
    }

    func testAVideoNeedsNoDialogToMute() {
        XCTAssertEqual(ToolForms.invocationWithoutDialog(toolID: "muteVideo"), .media(.mute))
        XCTAssertTrue(ToolForms.isMedia(URL(fileURLWithPath: "/a.MP3")))
        XCTAssertFalse(ToolForms.isMedia(URL(fileURLWithPath: "/a.png")))
        XCTAssertTrue(ToolForms.isVideo(URL(fileURLWithPath: "/a.mkv")))
        XCTAssertFalse(ToolForms.isVideo(URL(fileURLWithPath: "/a.mp3")))
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
