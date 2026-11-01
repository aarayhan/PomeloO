import AppKit
import PomeloOCore

/// Draws the wheel and receives the drop. What is shown and which petal is hot lives in `WheelModel`;
/// this view only paints it and passes the drag events on to the controller.
final class WheelView: NSView {
    var model = WheelModel() { didSet { needsDisplay = true } }
    weak var controller: WheelController?

    private let size = WheelGeometry.size

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: WheelGeometry.size, height: WheelGeometry.size + WheelGeometry.hintHeight))
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Top-left origin and y down, like the geometry in Core.
    override var isFlipped: Bool { true }

    // MARK: keyboard (only when the wheel was opened with the shortcut)

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        controller?.key(event)
    }

    private var lastFlags: NSEvent.ModifierFlags = []

    /// A modifier going down on the keyboard wheel switches wheels; releasing one does nothing.
    override func flagsChanged(with event: NSEvent) {
        let now = event.modifierFlags.intersection([.shift, .control, .option])
        if now.rawValue > lastFlags.rawValue || !now.subtracting(lastFlags).isEmpty { controller?.modifierPressed(now) }
        lastFlags = now
    }

    // MARK: drag destination

    private func files(_ info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    private func point(_ info: NSDraggingInfo) -> CGPoint {
        convert(info.draggingLocation, from: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragEntered(files: files(sender), at: point(sender))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragMoved(to: point(sender))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.dragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.drop(at: point(sender)) ?? false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.dragEnded()
    }

    // MARK: painting

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let c = WheelGeometry.center
        let n = model.items.count
        let outer = WheelGeometry.outer
        let inner = WheelGeometry.inner

        // backdrop: a dark glass disc with a faint rim
        g.saveGState()
        g.addEllipse(in: CGRect(x: c.x - outer - 9, y: c.y - outer - 9, width: 2 * outer + 18, height: 2 * outer + 18))
        g.clip()
        g.drawRadialGradient(gradient([NSColor.rgb(40, 40, 46, 0.93), NSColor.rgb(20, 20, 23, 0.93)], [0, 1]),
                             startCenter: c, startRadius: 0, endCenter: c, endRadius: outer + 10,
                             options: [.drawsAfterEndLocation])
        g.restoreGState()
        g.setStrokeColor(NSColor.white.withAlphaComponent(30 / 255).cgColor)
        g.setLineWidth(1)
        g.strokeEllipse(in: CGRect(x: c.x - outer - 9, y: c.y - outer - 9, width: 2 * outer + 18, height: 2 * outer + 18))

        for (i, item) in model.items.enumerated() {
            let hot = i == model.hover
            let a = n > 1 ? WheelGeometry.angle(i, of: n) : Double.pi / 2
            let lift = hot && n > 1 ? 5.0 : 0
            let dx = cos(a) * lift
            let dy = -sin(a) * lift

            g.saveGState()
            g.translateBy(x: dx, y: dy)
            let path = CGMutablePath()
            if n == 1 {
                path.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: 2 * outer, height: 2 * outer))
                path.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner))
            } else {
                path.addLines(between: WheelGeometry.petalOutline(i, of: n))
                path.closeSubpath()
            }
            g.addPath(path)
            if hot {
                g.saveGState()
                g.clip(using: .evenOdd)
                g.drawRadialGradient(gradient([.hex(0xFFB04D), .hex(0xFF7A00)], [0.35, 1]),
                                     startCenter: c, startRadius: 0, endCenter: c, endRadius: outer,
                                     options: [.drawsAfterEndLocation])
                g.restoreGState()
            } else {
                g.setFillColor(NSColor.white.withAlphaComponent(16 / 255).cgColor)
                g.setStrokeColor(NSColor.white.withAlphaComponent(22 / 255).cgColor)
                g.drawPath(using: .eoFillStroke)
            }
            g.restoreGState()

            let mid = (inner + outer) / 2
            let at = WheelGeometry.point(radius: mid, angle: a)
            let width = min(outer - inner, 2 * Double.pi * mid / Double(n) - 6)
            drawText(item.title, in: CGRect(x: at.x + dx - width / 2, y: at.y + dy - 20, width: width, height: 40),
                     font: .systemFont(ofSize: 11, weight: hot ? .bold : .semibold),
                     color: hot ? .hex(0x18181B) : .rgb(235, 235, 240))
        }

        // centre: what this wheel does, and what it holds
        g.setFillColor(NSColor.rgb(18, 18, 21, 0.96).cgColor)
        g.setStrokeColor(NSColor.white.withAlphaComponent(25 / 255).cgColor)
        let hole = CGRect(x: c.x - inner + 6, y: c.y - inner + 6, width: 2 * inner - 12, height: 2 * inner - 12)
        g.fillEllipse(in: hole)
        g.strokeEllipse(in: hole)
        drawText(model.title, in: CGRect(x: c.x - inner, y: c.y - 24, width: 2 * inner, height: 22),
                 font: .systemFont(ofSize: 12, weight: .bold), color: .white)
        drawText(model.countText, in: CGRect(x: c.x - inner, y: c.y - 2, width: 2 * inner, height: 18),
                 font: .systemFont(ofSize: 10), color: .rgb(161, 161, 170))

        // one dot per wheel, the current one orange
        let modes = WheelModel.availableModes
        for (index, wheelMode) in modes.enumerated() {
            let x = c.x + (Double(index) - Double(modes.count - 1) / 2) * 10
            g.setFillColor((wheelMode == model.mode ? NSColor.hex(0xFF8A00) : NSColor.white.withAlphaComponent(60 / 255)).cgColor)
            g.fillEllipse(in: CGRect(x: x - 3, y: c.y + 24 - 3, width: 6, height: 6))
        }

        // hint pill under the wheel
        let hint = model.hint
        let font = NSFont.systemFont(ofSize: 11)
        let textWidth = (hint as NSString).size(withAttributes: [.font: font]).width + 36
        let pill = CGRect(x: (size - textWidth) / 2, y: size + 6, width: textWidth, height: 28)
        let pillPath = CGPath(roundedRect: pill, cornerWidth: 14, cornerHeight: 14, transform: nil)
        g.addPath(pillPath)
        g.setFillColor(NSColor.rgb(24, 24, 27, 0.92).cgColor)
        g.setStrokeColor(NSColor.white.withAlphaComponent(30 / 255).cgColor)
        g.drawPath(using: .fillStroke)
        drawText(hint, in: pill, font: font, color: .white)
    }

    private func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: colors.map(\.cgColor) as CFArray, locations: locations)!
    }

    /// Text centred in a rectangle, wrapped when it is too wide.
    private func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let string = NSAttributedString(string: text, attributes: attributes)
        let height = string.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
        string.draw(with: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                    options: [.usesLineFragmentOrigin])
    }
}
