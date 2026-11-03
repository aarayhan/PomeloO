import AppKit
import PomeloOCore
import SwiftUI
import XCTest
@testable import PomeloOMac

/// Every tool dialog is built and painted into a bitmap: a form that cannot be laid out, or that shows nothing, fails
/// here. Set POMELOO_RENDER_DIR to also get the pictures as PNG files.
@MainActor
final class ToolDialogTests: XCTestCase {
    /// SwiftUI's own offscreen renderer: it lays the form out and draws text and shapes. Controls that AppKit draws
    /// (sliders, pickers, the colour well) come out as plain placeholders, so this proves the layout and the words,
    /// not how the controls look.
    private func render(_ view: some View, named name: String) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the form could not be laid out")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        if let directory = ProcessInfo.processInfo.environment["POMELOO_RENDER_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    private func visiblePixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { count += 1 }
        }
        return count
    }

    func testEveryToolDialogIsBuiltAndShowsSomething() throws {
        let files = [URL(fileURLWithPath: "/tmp/one.pdf"), URL(fileURLWithPath: "/tmp/two.pdf")]
        for toolID in ToolForms.withDialog.sorted() {
            let view = ToolDialogView(toolID: toolID, title: Catalog.bundled.tools[toolID]?.name ?? toolID, files: files, run: { _, _ in }, cancel: {})
            let rep = try render(view, named: "dialog-\(toolID)")
            XCTAssertGreaterThan(rep.pixelsWide, 600, toolID)
            XCTAssertGreaterThan(rep.pixelsHigh, 60, toolID)
            XCTAssertGreaterThan(visiblePixels(rep), 400, "\(toolID) drew nothing")
        }
    }

    func testTheAudioAndVideoDialogsAreBuilt() throws {
        let video = [URL(fileURLWithPath: "/tmp/a.mp4"), URL(fileURLWithPath: "/tmp/b.mp4")]
        let audio = [URL(fileURLWithPath: "/tmp/a.mp3")]
        let cases: [(String, [URL])] = [
            ("compress", video), ("compress", audio), ("removeMetadata", audio), ("normalizeAudio", audio), ("audioToVideo", audio),
            ("trimAudio", audio), ("audioChannels", audio), ("redactAudio", audio), ("trimVideo", video), ("cropVideo", video),
            ("changeVideoSpeed", video), ("videoSnapshots", video), ("splitVideo", video), ("redactVideo", video), ("joinVideos", video),
        ]
        for (toolID, files) in cases {
            let view = ToolDialogView(toolID: toolID, title: Catalog.bundled.tools[toolID]?.name ?? toolID, files: files, run: { _, _ in }, cancel: {})
            let rep = try render(view, named: "media-\(toolID)-\(FileName.ext(of: files[0]))")
            XCTAssertGreaterThan(visiblePixels(rep), 400, "\(toolID) drew nothing")
        }
    }

    func testAToolWithoutSettingsSaysSo() throws {
        let view = ToolDialogView(toolID: "readQR", title: "Read QR Code", files: [URL(fileURLWithPath: "/tmp/a.png")], run: { _, _ in }, cancel: {})
        XCTAssertGreaterThan(visiblePixels(try render(view, named: "dialog-none")), 100)
    }

    func testTheToolsWheelDrawsItsOwnTitleAndDots() throws {
        let service = ConversionService(engines: [ImageEngine()])
        let tools = ToolService()
        let view = WheelView()
        view.model = WheelModel(urls: [URL(fileURLWithPath: "/tmp/photo.jpg")], service: service, tools: tools, mode: .tools)
        let rep = try renderWheel(view, named: "wheel-tools")
        let scale = Double(rep.pixelsWide) / Double(view.bounds.width)
        func pixel(_ x: Double, _ y: Double) -> NSColor {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .clear
        }
        let centre = WheelGeometry.center
        let second = pixel(centre.x + 5, centre.y + 24)  // two dots: Convert at -5, Tools at +5
        XCTAssertGreaterThan(second.redComponent, 0.9, "the Tools dot is orange")
        XCTAssertLessThan(second.blueComponent, 0.3)
        let first = pixel(centre.x - 5, centre.y + 24)
        XCTAssertLessThan(first.redComponent, 0.6, "the Convert dot is dim")
        XCTAssertEqual(view.model.items.count, 7, "the seven picture tools")
    }

    private func renderWheel(_ view: NSView, named name: String) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["POMELOO_RENDER_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return rep
    }
}
