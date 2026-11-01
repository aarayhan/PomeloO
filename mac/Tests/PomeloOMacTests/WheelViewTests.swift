import AppKit
import PomeloOCore
import XCTest
@testable import PomeloOMac

/// The wheel is painted into a bitmap and a few pixels are checked: the colours and shapes of the Windows
/// wheel, without a screen. Set POMELOO_RENDER_DIR to also get the pictures as PNG files.
@MainActor
final class WheelViewTests: XCTestCase {
    private let service = ConversionService(engines: [ImageEngine()])

    private func render(_ view: NSView, named name: String) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["POMELOO_RENDER_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    /// Pixel at a point of the wheel's own (y down) coordinates. The bitmap may have more pixels than
    /// points (a Retina scale), so the point is scaled.
    private func pixel(_ rep: NSBitmapImageRep, _ point: CGPoint) throws -> (r: Int, g: Int, b: Int, a: Int) {
        let scale = Double(rep.pixelsWide) / Double(rep.size.width)
        let color = try XCTUnwrap(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
        return (Int(color.redComponent * 255), Int(color.greenComponent * 255),
                Int(color.blueComponent * 255), Int(color.alphaComponent * 255))
    }

    private func wheel(hover petal: Int?) -> (WheelView, Int) {
        let view = WheelView()
        var model = WheelModel(urls: [URL(fileURLWithPath: "/tmp/photo.png")], service: service)
        let n = model.items.count
        if let petal {
            let at = WheelGeometry.point(radius: 110, angle: WheelGeometry.angle(petal, of: n))
            model.pointerMoved(x: at.x, y: at.y)
        }
        view.model = model
        return (view, n)
    }

    func testTheHotPetalIsOrangeAndTheOthersAreDark() throws {
        let (view, n) = wheel(hover: 1)
        let rep = try render(view, named: "wheel-hover")
        func middle(_ i: Int) -> CGPoint {
            WheelGeometry.point(radius: WheelGeometry.outer - 12, angle: WheelGeometry.angle(i, of: n))
        }
        let hot = try pixel(rep, middle(1))
        XCTAssertGreaterThan(hot.r, 220, "hot petal should be orange: \(hot)")
        XCTAssertTrue((90...190).contains(hot.g), "hot petal should be orange: \(hot)")
        XCTAssertLessThan(hot.b, 90, "hot petal should be orange: \(hot)")
        let cold = try pixel(rep, middle(3))
        XCTAssertLessThan(cold.r, 90, "an idle petal stays dark glass: \(cold)")
        XCTAssertLessThan(cold.b, 100)
    }

    func testTheCentreIsDarkAndTheCornersAreTransparent() throws {
        let (view, _) = wheel(hover: nil)
        let rep = try render(view, named: "wheel-idle")
        let centre = try pixel(rep, CGPoint(x: WheelGeometry.size / 2, y: WheelGeometry.size / 2 + 40))
        XCTAssertLessThan(centre.r, 40)
        XCTAssertGreaterThan(centre.a, 200)
        let corner = try pixel(rep, CGPoint(x: 3, y: 3))
        XCTAssertEqual(corner.a, 0, "outside the disc nothing is drawn")
    }

    func testTheHintPillIsDrawnUnderTheWheel() throws {
        let (view, _) = wheel(hover: nil)
        let rep = try render(view, named: "wheel-hint")
        let pill = try pixel(rep, CGPoint(x: WheelGeometry.size / 2 - 40, y: WheelGeometry.size + 20))
        XCTAssertGreaterThan(pill.a, 200, "the pill should be drawn under the wheel")
        let beside = try pixel(rep, CGPoint(x: 4, y: WheelGeometry.size + 20))
        XCTAssertEqual(beside.a, 0)
    }

    func testAnEmptyWheelAndASingleFormatBothDraw() throws {
        let empty = WheelView()
        _ = try render(empty, named: "wheel-empty")

        let single = WheelView()
        single.model = WheelModel(urls: [URL(fileURLWithPath: "/tmp/a.rar")],
                                  service: ConversionService(engines: [StubEngine(pairs: ["rar>zip"]) { _, _ in }]))
        XCTAssertEqual(single.model.items.count, 1)
        let rep = try render(single, named: "wheel-single")
        let ring = try pixel(rep, WheelGeometry.point(radius: 110, angle: Double.pi / 2))
        XCTAssertGreaterThan(ring.a, 200, "a single format is a full ring")
    }

    func testAKeyboardWheelShowsItsHotPetalAndHint() throws {
        let view = WheelView()
        var model = WheelModel(urls: [URL(fileURLWithPath: "/tmp/photo.png")], service: service)
        model.setKeyboard(true)
        view.model = model
        let rep = try render(view, named: "wheel-keyboard")
        let n = model.items.count
        let hot = try pixel(rep, WheelGeometry.point(radius: WheelGeometry.outer - 12, angle: WheelGeometry.angle(0, of: n)))
        XCTAssertGreaterThan(hot.r, 220, "the first petal is hot from the start: \(hot)")
        XCTAssertTrue(model.hint.hasPrefix("Press Enter"))
    }

    func testTheDropPadIconDraws() throws {
        let image = NSImage(size: NSSize(width: 40, height: 40), flipped: true) { rect in
            CitrusIcon.draw(in: NSGraphicsContext.current!.cgContext, origin: .zero, side: 40)
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let scale = Double(rep.pixelsWide) / 40
        // the middle of the first segment, a little out from the hub
        let at = CGPoint(x: 20 + 10 * cos(75 * Double.pi / 180), y: 20 - 10 * sin(75 * Double.pi / 180))
        let juice = try XCTUnwrap(rep.colorAt(x: Int(at.x * scale), y: Int(at.y * scale))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(juice.redComponent, 0.85, "the segments are orange")
        XCTAssertLessThan(juice.blueComponent, 0.45)
    }
}

/// An engine that converts nothing but declares pairs, to give the wheel something to show.
struct StubEngine: ConversionEngine {
    let name = "stub"
    let pairs: Set<String>
    let behavior: @Sendable (ConversionJob, @escaping @Sendable (Double) -> Void) async throws -> Void

    init(pairs: Set<String>, behavior: @escaping @Sendable (ConversionJob, @escaping @Sendable (Double) -> Void) async throws -> Void) {
        self.pairs = pairs
        self.behavior = behavior
    }

    func canConvert(from: String, to: String) -> Bool { pairs.contains("\(from)>\(to)") }
    func convert(_ job: ConversionJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await behavior(job, progress)
    }
}
